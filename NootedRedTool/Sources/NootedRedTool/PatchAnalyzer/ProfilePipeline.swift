import CryptoKit
import Foundation
import IOKit

// MARK: - Fixture environment

/// Resolved analysis inputs: fixture root (or the live system), build, hardware
/// identity and the on-disk locations of the target images.
struct AnalyzerEnvironment {
    let root: URL
    let isLive: Bool
    let build: String
    let deviceID: UInt32?
    let apuMask: UInt32
    let dyldDirectory: URL
    let glDriverPath: URL

    static let liveRoot = URL(fileURLWithPath: "/", isDirectory: true)

    static func resolve(fixtureRoot: String?) throws -> AnalyzerEnvironment {
        var requestedRoot: URL?
        if let fixtureRoot, !fixtureRoot.isEmpty {
            requestedRoot = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
        }
        var live = requestedRoot == nil || requestedRoot!.standardizedFileURL.path == "/"
        if live {
            // Regenerating on a system where the profile is already loaded is
            // forbidden: the validated pages are already patched in memory. An
            // explicit fixture root (argument or NRED_FIXTURE_ROOT) is required.
            if AnalyzerEnvironment.isUserPatchLoaded() {
                if let override = ProcessInfo.processInfo.environment["NRED_FIXTURE_ROOT"],
                   !override.isEmpty, override != "/" {
                    requestedRoot = URL(fileURLWithPath: override, isDirectory: true)
                    live = false
                } else {
                    throw AnalyzerError.validation(
                        "NootedRedUserPatch is loaded in this system; refusing to regenerate a profile from "
                            + "patched pages. Extract a clean fixture (collect_validation_fixtures.py) and pass "
                            + "its root, or set NRED_FIXTURE_ROOT.")
                }
            }
        }
        let root = requestedRoot ?? liveRoot
        let isLive = live

        let build = try readBuild(root: root)
        let deviceID = isLive ? runningDeviceID() : fixtureDeviceID(root: root) ?? runningDeviceID()
        let apuMask = try apuMask(for: deviceID)

        let dyldDirectory: URL
        let preboot = root.appendingPathComponent(
            "System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld", isDirectory: true)
        if FileManager.default.fileExists(atPath: preboot.path) {
            dyldDirectory = preboot
        } else {
            dyldDirectory = root.appendingPathComponent("System/Library/dyld", isDirectory: true)
        }
        let glDriverPath = root.appendingPathComponent(
            "System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver")
        guard FileManager.default.fileExists(atPath: glDriverPath.path) else {
            throw AnalyzerError.notFound("GL driver at \(glDriverPath.path)")
        }
        guard FileManager.default.fileExists(atPath: dyldDirectory.path) else {
            throw AnalyzerError.notFound("dyld shared cache directory at \(dyldDirectory.path)")
        }
        return AnalyzerEnvironment(root: root, isLive: isLive, build: build, deviceID: deviceID,
                                   apuMask: apuMask, dyldDirectory: dyldDirectory,
                                   glDriverPath: glDriverPath)
    }

    static func readBuild(root: URL) throws -> String {
        let plist = root.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any],
              let build = dictionary["ProductBuildVersion"] as? String else {
            throw AnalyzerError.notFound("ProductBuildVersion in \(plist.path)")
        }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-")
        guard build.count >= 1, build.count <= 15,
              build.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AnalyzerError.malformed("invalid build string \(build)")
        }
        return build
    }

    static func fixtureDeviceID(root: URL) -> UInt32? {
        let manifest = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hardware = object["hardware"] as? [String: Any] else { return nil }
        if let value = hardware["deviceID"] as? String {
            let cleaned = value.hasPrefix("0x") || value.hasPrefix("0X") ? String(value.dropFirst(2)) : value
            if let numeric = UInt32(cleaned, radix: 16) {
                return numeric & 0xffff
            }
        }
        if let numeric = hardware["deviceID"] as? UInt32 {
            return numeric & 0xffff
        }
        return nil
    }

    /// APU family candidate mask derived from the PCI device ID, exactly as the
    /// profile spec §3.2 requires. Unknown devices have no family: generation
    /// fails closed instead of emitting a profile that can never match.
    static func apuMask(for deviceID: UInt32?) throws -> UInt32 {
        guard let deviceID else {
            throw AnalyzerError.validation("cannot determine the iGPU PCI device ID; refusing to guess the APU family")
        }
        switch deviceID {
        case 0x15dd: return 0x0000_0001 // Raven
        case 0x15d8: return 0x0000_0006 // Raven2 | Picasso
        case 0x1636, 0x164c: return 0x0000_0018 // Renoir | RenoirE
        case 0x15e7, 0x1638: return 0x0000_0028 // Renoir | Green Sardine
        default:
            throw AnalyzerError.validation(
                "PCI device ID \(Hex.value(UInt64(deviceID))) is not a supported APU family")
        }
    }

    /// True when the NootedRedUserPatch user-space kext is loaded in this boot.
    static func isUserPatchLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/kmutil")
        process.arguments = ["showloaded"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return output.contains("NootedRedUserPatch")
    }

    /// Supported APU PCI device IDs, used to select the iGPU among non-GPU AMD
    /// PCI functions (audio/USB controllers share the vendor ID).
    static let supportedAPUDeviceIDs: Set<UInt32> = [0x15dd, 0x15d8, 0x1636, 0x164c,
                                                    0x15e7, 0x1638]

    /// Reads the iGPU PCI device ID from the matching IOPCIDevice service.
    static func runningDeviceID() -> UInt32? {
        let matching = IOServiceMatching("IOPCIDevice") as CFDictionary?
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            func property(_ name: String) -> UInt32? {
                guard let unmanaged = IORegistryEntryCreateCFProperty(
                    service, name as CFString, kCFAllocatorDefault, 0) else {
                    return nil
                }
                guard let data = unmanaged.takeRetainedValue() as? Data, data.count == 4 else { return nil }
                return UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
            }
            guard let vendor = property("vendor-id"), vendor & 0xffff == 0x1002 else { continue }
            guard let device = property("device-id"), supportedAPUDeviceIDs.contains(device & 0xffff) else {
                continue
            }
            return device & 0xffff
        }
        return nil
    }
}

// MARK: - Image set

final class AnalyzerImageSet {
    let environment: AnalyzerEnvironment
    let decoder: X86Decoder
    let cache: DyldCacheStore?
    private var cacheImages: [DriverImage: AnalyzedImage] = [:]
    private var glImage: AnalyzedImage?

    init(environment: AnalyzerEnvironment) throws {
        self.environment = environment
        self.decoder = X86Decoder.shared
        let store = try DyldCacheStore(directory: environment.dyldDirectory)
        self.cache = store
        try decoder.requireAvailable()
    }

    func image(for driver: DriverImage) throws -> AnalyzedImage {
        switch driver {
        case .gl:
            if let glImage { return glImage }
            let image = try AnalyzedImage.loadStandaloneFile(at: environment.glDriverPath, label: driver.rawValue)
            glImage = image
            return image
        default:
            if let cached = cacheImages[driver] { return cached }
            guard let cache else {
                throw AnalyzerError.notFound("dyld cache store")
            }
            let image = try AnalyzedImage.loadCacheImage(store: cache, pathSuffix: driver.cachePathSuffix,
                                                      label: driver.rawValue)
            cacheImages[driver] = image
            return image
        }
    }

    func allImages() throws -> [DriverImage: AnalyzedImage] {
        var images: [DriverImage: AnalyzedImage] = [:]
        for driver in DriverImage.allCases {
            images[driver] = try image(for: driver)
        }
        return images
    }

    func kind(for driver: DriverImage) -> NRPTImageKind {
        driver.isStandaloneFile ? .standaloneFile : .dyldSharedCache
    }

    /// Canonical, install-path-independent image path for the profile image table.
    ///
    /// Cache images already carry the dyld-cache image path (absolute). The standalone
    /// GL bundle is discovered through the fixture root, so the fixture prefix is
    /// stripped to obtain the same "/System/Library/..." path on every host and
    /// fixture extraction. The value is always derived from the parsed image and the
    /// environment root; no path is hardcoded.
    func canonicalPath(for driver: DriverImage) throws -> String {
        let image = try image(for: driver)
        var path = image.path
        let rootPath = environment.root.standardizedFileURL.path
        if rootPath != "/" {
            if path == rootPath {
                path = "/"
            } else if path.hasPrefix(rootPath + "/") {
                path = String(path.dropFirst(rootPath.count))
            }
        }
        guard path.hasPrefix("/") else { return "/" + path }
        return path
    }
}

// MARK: - Generated site / page model

struct GeneratedSite {
    let ruleID: String
    let driver: DriverImage
    let match: SiteMatch
    let siteAddress: UInt64
    let siteInPage: UInt16
    let pageStart: UInt64
    let pageFileOffset: UInt64
    let pageHash: UInt64
    /// v3 patch mode, derived from the parsed image kind (standalone file → PAGE,
    /// dyld shared cache image → DYLD). Never guessed from addresses.
    let mode: NRPTPageMode
    let imageIndex: UInt16
    let pageVmOffset: UInt32
    /// Evidence-only parsed geometry (not part of the wire profile in v3).
    let pageIndex: UInt32
    let segmentName: String
    let sectionName: String
}

// MARK: - Generator

enum ProfileGenerator {
    static let generatorVersion = "PatchAnalyzer/3.0"

    struct Output {
        let profile: NRPTProfile
        let profileData: Data
        let evidenceJSON: Data
        let sites: [GeneratedSite]
    }

    static func generate(environment: AnalyzerEnvironment) throws -> Output {
        let images = try AnalyzerImageSet(environment: environment)
        let decoder = images.decoder
        var sites: [GeneratedSite] = []

        // Target image table (NRPT v3), in deterministic first-discovery order.
        var imageTable: [NRPTImage] = []
        func imageRecord(for driver: DriverImage) throws -> UInt16 {
            let path = try images.canonicalPath(for: driver)
            let kind = images.kind(for: driver)
            if let existing = imageTable.firstIndex(where: { $0.kind == kind && $0.path == path }) {
                return UInt16(existing)
            }
            let image = try images.image(for: driver)
            guard image.loadAddress == image.text.vmaddr else {
                throw AnalyzerError.malformed(
                    "\(driver.rawValue): image load address differs from __TEXT vmaddr")
            }
            guard image.text.vmsize > 0, image.text.vmsize <= 0xFFFF_F000 else {
                throw AnalyzerError.malformed("\(driver.rawValue): __TEXT vmsize out of range")
            }
            imageTable.append(NRPTImage(kind: kind, path: path,
                                        unslidVMAddress: image.loadAddress,
                                        vmSize: UInt32(image.text.vmsize)))
            return UInt16(imageTable.count - 1)
        }

        var ruleEvidence: [[String: Any]] = []
        var usedAddresses: Set<UInt64> = []

        for rule in SemanticRules.rules() {
            let image = try images.image(for: rule.driver)
            var ruleSiteCount = 0
            var ruleFunctionEvidence: [[String: Any]] = []
            for target in rule.functions {
                let analyses = try target.resolve(image, decoder)
                guard !analyses.isEmpty else {
                    throw AnalyzerError.notFound("\(rule.id): \(target.description) resolved no function")
                }
                for analysis in analyses {
                    let matches = try rule.match(analysis, decoder, [])
                    guard matches.count == target.expectedSites else {
                        throw AnalyzerError.ambiguous(
                            "\(rule.id): \(target.description) produced \(matches.count) sites, expected \(target.expectedSites)")
                    }
                    for match in matches {
                        guard let siteAddress = match.instructionAddresses.first else {
                            throw AnalyzerError.malformed("\(rule.id): match without an instruction address")
                        }
                        guard analysis.isReachable(siteAddress) else {
                            throw AnalyzerError.validation(
                                "\(rule.id): site \(Hex.value(siteAddress)) is not reachable in the function CFG")
                        }
                        guard usedAddresses.insert(siteAddress).inserted else {
                            throw AnalyzerError.ambiguous("\(rule.id): duplicate site \(Hex.value(siteAddress))")
                        }
                        guard match.find.count >= 1, match.find.count <= 16,
                              match.find.count == match.replace.count,
                              match.find != match.replace else {
                            throw AnalyzerError.validation(
                                "\(rule.id): invalid site find/replace at \(Hex.value(siteAddress))")
                        }
                        let actual = [UInt8](try image.read(address: siteAddress, size: match.find.count))
                        guard actual == match.find else {
                            throw AnalyzerError.validation(
                                "\(rule.id): find bytes at \(Hex.value(siteAddress)) do not match the parsed image")
                        }
                        let pageStart = siteAddress & ~UInt64(0xfff)
                        let inPage = Int(siteAddress - pageStart)
                        guard inPage + match.find.count <= 0x1000 else {
                            throw AnalyzerError.validation("\(rule.id): site straddles a page boundary")
                        }
                        let page = try image.pageBytes(containing: siteAddress)
                        let pageFileOffset = try image.fileOffset(address: page.pageStart)
                        guard pageFileOffset & 0xfff == 0 else {
                            throw AnalyzerError.validation(
                                "\(rule.id): derived page file offset \(Hex.value(pageFileOffset)) is not 4 KiB aligned")
                        }
                        let pageHash = try ProfileCodec.pageHash(page.bytes)
                        let mode: NRPTPageMode = rule.driver.isStandaloneFile ? .page : .dyld
                        let targetImageIndex = try imageRecord(for: rule.driver)
                        let targetImage = imageTable[Int(targetImageIndex)]
                        guard let segment = image.segments.first(where: {
                            page.pageStart >= $0.vmaddr
                                && page.pageStart < $0.vmaddr &+ $0.vmsize
                                && $0.filesize > 0
                        }) else {
                            throw AnalyzerError.validation(
                                "\(rule.id): no segment contains page \(Hex.value(page.pageStart))")
                        }
                        guard page.pageStart >= segment.vmaddr,
                              (page.pageStart - segment.vmaddr) % 0x1000 == 0 else {
                            throw AnalyzerError.validation(
                                "\(rule.id): page is not segment-aligned in \(segment.name)")
                        }
                        let pageIndexOfSegment = UInt32((page.pageStart - segment.vmaddr) / 0x1000)
                        guard let section = image.sections.first(where: {
                            siteAddress >= $0.addr && siteAddress < $0.addr &+ $0.size
                        }) else {
                            throw AnalyzerError.validation(
                                "\(rule.id): no section contains site \(Hex.value(siteAddress))")
                        }
                        guard page.pageStart >= image.loadAddress else {
                            throw AnalyzerError.validation(
                                "\(rule.id): page precedes the image load address")
                        }
                        let vmOffset = page.pageStart - image.loadAddress
                        guard vmOffset % 0x1000 == 0,
                              vmOffset <= UInt64(UInt32.max),
                              vmOffset &+ 0x1000 <= UInt64(targetImage.vmSize) else {
                            throw AnalyzerError.validation(
                                "\(rule.id): derived pageVmOffset \(Hex.value(vmOffset)) is invalid")
                        }
                        sites.append(GeneratedSite(ruleID: rule.id, driver: rule.driver, match: match,
                                                   siteAddress: siteAddress, siteInPage: UInt16(inPage),
                                                   pageStart: page.pageStart, pageFileOffset: pageFileOffset,
                                                   pageHash: pageHash, mode: mode,
                                                   imageIndex: targetImageIndex,
                                                   pageVmOffset: UInt32(vmOffset),
                                                   pageIndex: pageIndexOfSegment,
                                                   segmentName: segment.name,
                                                   sectionName: section.sectname))
                        ruleSiteCount += 1
                        var siteEvidence: [String: Any] = [
                            "function": analysis.functionName,
                            "functionStart": Hex.value(analysis.start),
                            "functionEnd": Hex.value(analysis.end),
                            "extentSource": analysis.extentSource,
                            "siteAddress": Hex.value(siteAddress),
                            "instruction": match.matchedInstruction,
                            "intent": match.intent,
                            "find": Hex.spaced(match.find),
                            "replace": Hex.spaced(match.replace),
                            "cfgBlocks": analysis.blocks.count,
                            "reachable": analysis.isReachable(siteAddress),
                            "mode": mode == .page ? "PAGE" : "DYLD",
                            "targetKind": images.kind(for: rule.driver) == .standaloneFile
                                ? "standalone-file" : "dyld-shared-cache"
                        ]
                        for (key, value) in match.details {
                            siteEvidence[key] = value
                        }
                        ruleFunctionEvidence.append(siteEvidence)
                    }
                }
            }
            ruleEvidence.append([
                "rule": rule.id,
                "driver": rule.driver.rawValue,
                "description": rule.description,
                "sites": ruleSiteCount,
                "evidence": ruleFunctionEvidence
            ])
        }

        // Group sites by page, preserving first-discovery order of drivers/pages.
        var pageOrder: [String] = []
        var pageSites: [String: [GeneratedSite]] = [:]
        for site in sites {
            let key = "\(site.driver.rawValue)#\(site.pageStart)"
            if pageSites[key] == nil {
                pageOrder.append(key)
            }
            pageSites[key, default: []].append(site)
        }

        var pages: [NRPTPage] = []
        var pageEvidence: [[String: Any]] = []
        for key in pageOrder {
            guard let group = pageSites[key], let first = group.first else { continue }
            let sorted = group.sorted { $0.siteInPage < $1.siteInPage }
            var records: [NRPTSite] = []
            var ranges: [(Int, Int)] = []
            for site in sorted {
                let start = Int(site.siteInPage)
                let end = start + site.match.find.count
                for existing in ranges {
                    guard end <= existing.0 || start >= existing.1 else {
                        throw AnalyzerError.validation("overlapping sites on page \(Hex.value(first.pageStart))")
                    }
                }
                ranges.append((start, end))
                records.append(NRPTSite(siteInPage: site.siteInPage,
                                        find: site.match.find, replace: site.match.replace))
            }
            guard records.count >= 1, records.count <= NRPTFormat.maxSitesPerPage else {
                throw AnalyzerError.validation("invalid sites-per-page count \(records.count)")
            }
            for site in group {
                guard site.imageIndex == first.imageIndex,
                      site.mode == first.mode,
                      site.pageVmOffset == first.pageVmOffset else {
                    throw AnalyzerError.validation(
                        "inconsistent target-image metadata for page \(Hex.value(first.pageStart))")
                }
            }
            let targetImage = imageTable[Int(first.imageIndex)]
            pages.append(NRPTPage(pageFileOffset: first.pageFileOffset, pageHash: first.pageHash,
                                  mode: first.mode, imageIndex: first.imageIndex,
                                  pageVmOffset: first.pageVmOffset, sites: records))
            pageEvidence.append([
                "driver": first.driver.rawValue,
                "pageStart": Hex.value(first.pageStart),
                "pageFileOffset": Hex.value(first.pageFileOffset),
                "pageHash": Hex.value(first.pageHash),
                "mode": first.mode == .page ? "PAGE" : "DYLD",
                "targetKind": first.mode == .page ? "standalone-file" : "dyld-shared-cache",
                "route": first.mode == .page ? "_cs_validate_page" : "_cs_validate_range",
                "imageIndex": Int(first.imageIndex),
                "imagePath": targetImage.path,
                "imageUnslidVmaddr": Hex.value(targetImage.unslidVMAddress),
                "imageVmSize": Hex.value(UInt64(targetImage.vmSize)),
                "segment": first.segmentName,
                "section": first.sectionName,
                "pageIndexInSegment": Int(first.pageIndex),
                "pageVmOffset": Hex.value(UInt64(first.pageVmOffset)),
                "pageVA": Hex.value(first.pageStart),
                "sites": records.count
            ])
        }

        let deviceID = environment.deviceID
        let header = NRPTHeader(build: environment.build, apuMask: environment.apuMask,
                                deviceID: deviceID ?? 0)
        let imageEvidence = imageTable.map { image -> [String: Any] in
            ["kind": image.kind == .standaloneFile ? "standalone-file" : "dyld-shared-cache",
             "path": image.path,
             "unslidVmaddr": Hex.value(image.unslidVMAddress),
             "vmSize": Hex.value(UInt64(image.vmSize)),
             "entrySize": image.entrySize]
        }
        let profile = NRPTProfile(header: header, images: imageTable, pages: pages)
        let profileData: Data
        do {
            profileData = try ProfileCodec.encode(profile)
        } catch {
            throw AnalyzerError.validation("profile encode failed: \(error)")
        }

        // Producer obligation: no unintended page of any target image may match a
        // record identity. v3 identity is content-defined (full-page hash + all site
        // finds) and mode-scoped, so pages are compared by hash in their delivery mode.
        let collisionScan = try scanForIdentityCollisions(sites: sites, images: images)
        // Offline validation with the exact kext algorithm and mode routing.
        let validation = try OfflineValidator.validate(profileData: profileData,
                                                       environment: environment, images: images)

        let modePageCount = pages.filter { $0.mode == .page }.count
        let modeDyldCount = pages.filter { $0.mode == .dyld }.count
        var evidence: [String: Any] = [
            "schema": 3,
            "profileVersion": Int(NRPTFormat.version),
            "generator": generatorVersion,
            "decoder": X86Decoder.shared.libraryPath ?? "unavailable",
            "fixtureRoot": environment.root.path,
            "live": environment.isLive,
            "build": environment.build,
            "apuMask": Hex.value(UInt64(environment.apuMask)),
            "deviceID": deviceID.map { Hex.value(UInt64($0)) } ?? "unavailable",
            "profile": [
                "size": profileData.count,
                "pageCount": pages.count,
                "siteCount": sites.count,
                "imageCount": imageTable.count,
                "modePageCount": modePageCount,
                "modeDyldCount": modeDyldCount,
                "checksum": Hex.value(UInt64(ProfileCodec.fnv1a32(profileData.subdata(in: 64..<profileData.count)))),
                "sha256": sha256(profileData)
            ],
            "images": imageEvidence,
            "rules": ruleEvidence,
            "pages": pageEvidence,
            "identityCollisionScan": collisionScan,
            "offlineValidation": validation
        ]
        evidence["result"] = "PASS"
        let json: Data
        do {
            json = try JSONSerialization.data(withJSONObject: evidence,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw AnalyzerError.malformed("cannot serialize evidence: \(error.localizedDescription)")
        }
        return Output(profile: profile, profileData: profileData, evidenceJSON: json, sites: sites)
    }

    private static func scanForIdentityCollisions(sites: [GeneratedSite],
                                                  images: AnalyzerImageSet) throws -> [String: Any] {
        // Profile identity: one record per (mode, full-page hash). The codec enforces
        // E031 for duplicates; this map catches unintended page matches.
        struct Identity: Hashable {
            let mode: UInt8
            let hash: UInt64
        }
        var identities: [Identity: GeneratedSite] = [:]
        for site in sites {
            let identity = Identity(mode: site.mode.rawValue, hash: site.pageHash)
            if let other = identities[identity] {
                // Several sites of the same page share the page identity.
                if other.driver == site.driver, other.pageStart == site.pageStart { continue }
                throw AnalyzerError.ambiguous(
                    "duplicate \(site.mode == .page ? "PAGE" : "DYLD") identity "
                        + "\(Hex.value(site.pageHash)) on \(other.driver.rawValue) page "
                        + "\(Hex.value(other.pageStart)) and \(site.driver.rawValue) page "
                        + "\(Hex.value(site.pageStart))")
            }
            identities[identity] = site
        }

        var scanned = 0
        var contentIdentical: [[String: Any]] = []
        let allImages = try images.allImages()
        for driver in DriverImage.allCases {
            guard let image = allImages[driver], let text = image.segments.first(where: { $0.name == "__TEXT" }) else {
                continue
            }
            let deliveryMode: NRPTPageMode = driver.isStandaloneFile ? .page : .dyld
            var address = text.vmaddr & ~UInt64(0xfff)
            let end = text.vmaddr &+ min(text.filesize, text.vmsize)
            while address &+ 0x1000 <= end {
                let pageBytes = try image.read(address: address, size: 0x1000)
                let hash = ProfileCodec.fnv1a64(pageBytes)
                let identity = Identity(mode: deliveryMode.rawValue, hash: hash)
                if let unintended = identities[identity] {
                    let isIntendedPage = unintended.driver == driver && unintended.pageStart == address
                    if !isIntendedPage {
                        // Identity is hash + every site find; check the record's finds at
                        // their in-page offsets directly against this candidate page.
                        let recordSites = sites.filter {
                            $0.driver == unintended.driver && $0.pageStart == unintended.pageStart
                        }
                        let pageBuffer = ByteBuffer(pageBytes)
                        let allFindsMatch = recordSites.allSatisfy { recordSite in
                            let start = Int(recordSite.siteInPage)
                            guard start >= 0, start + recordSite.match.find.count <= pageBuffer.count else {
                                return false
                            }
                            return (try? pageBuffer.slice(start, recordSite.match.find.count))
                                == recordSite.match.find
                        }
                        if allFindsMatch {
                            throw AnalyzerError.ambiguous(
                                "unintended \(deliveryMode == .page ? "PAGE" : "DYLD") page "
                                    + "\(driver.rawValue)@\(Hex.value(address)) matches the identity of "
                                    + "\(unintended.driver.rawValue) page \(Hex.value(unintended.pageStart))")
                        }
                        contentIdentical.append([
                            "driver": driver.rawValue,
                            "pageStart": Hex.value(address),
                            "mode": deliveryMode == .page ? "PAGE" : "DYLD",
                            "pageHash": Hex.value(hash),
                            "note": "content-identical page; the record's site finds do not match, "
                                + "so the identity cannot match"
                        ])
                    }
                }
                scanned += 1
                address &+= 0x1000
            }
        }
        return ["pagesScanned": scanned,
                "contentIdenticalNonMatchingPages": contentIdentical,
                "identityRules": "one record per (mode, full-page FNV-1a-64 hash); no offset gates",
                "result": "PASS"]
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Offline validator (same algorithm and mode routing as the kext)

enum OfflineValidator {
    static func validate(profileData: Data,
                         environment: AnalyzerEnvironment,
                         images: AnalyzerImageSet) throws -> [String: Any] {
        let profile: NRPTProfile
        do {
            profile = try ProfileCodec.decode(profileData)
        } catch {
            throw AnalyzerError.validation("profile decode failed: \(error)")
        }
        guard profile.header.build == environment.build else {
            throw AnalyzerError.validation(
                "profile build \(profile.header.build) does not match fixture build \(environment.build)")
        }
        guard profile.header.apuMask & environment.apuMask != 0 else {
            throw AnalyzerError.validation("profile apuMask does not intersect the running APU family")
        }
        if profile.header.deviceID != 0 {
            guard let deviceID = environment.deviceID, profile.header.deviceID == deviceID else {
                throw AnalyzerError.validation("profile deviceID does not match the fixture device ID")
            }
        }

        // Simulate the exact bundle selector against a one-entry bundle.
        let bundle = NRedProfilesBundle(entries: [
            NRedProfilesEntry(build: profile.header.build, apuMask: profile.header.apuMask,
                              deviceID: profile.header.deviceID, profile: profile)
        ])
        try ProfileCodec.validateBundle(bundle)
        let runningDeviceID = UInt16(environment.deviceID ?? 0)
        let selection = try ProfileCodec.select(from: bundle, build: environment.build,
                                                runningApuMask: environment.apuMask,
                                                runningDeviceID: runningDeviceID)
        guard case let .selected(index, selectedProfile) = selection, index == 0,
              selectedProfile.pageCount == profile.pageCount else {
            throw AnalyzerError.validation("bundle selector did not select the generated profile")
        }

        let allImages = try images.allImages()
        var knownImages: [String: (driver: DriverImage, image: AnalyzedImage, kind: NRPTImageKind)] = [:]
        for driver in DriverImage.allCases {
            guard let image = allImages[driver] else { continue }
            knownImages[try images.canonicalPath(for: driver)] = (driver, image, images.kind(for: driver))
        }

        // All fixture pages grouped by delivery mode, with their parsed addresses.
        struct FixturePage {
            let driver: DriverImage
            let image: AnalyzedImage
            let address: UInt64
            let bytes: Data
            let mode: NRPTPageMode
        }
        var fixturePages: [FixturePage] = []
        for driver in DriverImage.allCases {
            guard let image = allImages[driver], let text = image.segments.first(where: { $0.name == "__TEXT" }) else {
                continue
            }
            let deliveryMode: NRPTPageMode = driver.isStandaloneFile ? .page : .dyld
            var address = text.vmaddr & ~UInt64(0xfff)
            let end = text.vmaddr &+ min(text.filesize, text.vmsize)
            while address &+ 0x1000 <= end {
                fixturePages.append(FixturePage(driver: driver, image: image, address: address,
                                                bytes: try image.read(address: address, size: 0x1000),
                                                mode: deliveryMode))
                address &+= 0x1000
            }
        }

        // Resolve the intended fixture page of every record from target image metadata.
        var intendedPage: [Int: FixturePage] = [:]
        var metadataReports: [[String: Any]] = []
        for (index, record) in profile.pages.enumerated() {
            guard Int(record.imageIndex) < profile.images.count else {
                throw AnalyzerError.validation("page record \(index) imageIndex out of range")
            }
            let targetImage = profile.images[Int(record.imageIndex)]
            guard let known = knownImages[targetImage.path], known.kind == targetImage.kind else {
                throw AnalyzerError.validation(
                    "page record \(index) target image \(targetImage.path) does not resolve in the fixture")
            }
            let expectedMode: NRPTPageMode = known.kind == .standaloneFile ? .page : .dyld
            guard record.mode == expectedMode else {
                throw AnalyzerError.validation(
                    "page record \(index) mode \(record.mode) disagrees with image kind "
                        + "\(known.kind == .standaloneFile ? "standalone" : "dyld-cache")")
            }
            guard targetImage.unslidVMAddress == known.image.loadAddress,
                  targetImage.vmSize == UInt32(known.image.text.vmsize) else {
                throw AnalyzerError.validation(
                    "page record \(index) image geometry disagrees with the parsed image")
            }
            let intendedStart = targetImage.unslidVMAddress &+ UInt64(record.pageVmOffset)
            guard intendedStart >= targetImage.unslidVMAddress,
                  UInt64(record.pageVmOffset) &+ 0x1000 <= UInt64(targetImage.vmSize) else {
                throw AnalyzerError.validation("page record \(index) pageVmOffset is invalid")
            }
            guard record.pageFileOffset == (try known.image.fileOffset(address: intendedStart)) else {
                throw AnalyzerError.validation(
                    "page record \(index) diagnostic pageFileOffset disagrees with the parsed image")
            }
            guard let page = fixturePages.first(where: {
                $0.driver == known.driver && $0.address == intendedStart
            }) else {
                throw AnalyzerError.notFound(
                    "page record \(index) intended fixture page \(Hex.value(intendedStart)) is not in the target image")
            }
            guard page.mode == record.mode else {
                throw AnalyzerError.validation("page record \(index) mode does not match its fixture delivery domain")
            }
            let pageHash = ProfileCodec.fnv1a64(page.bytes)
            guard pageHash == record.pageHash else {
                throw AnalyzerError.validation(
                    "page record \(index) pageHash \(Hex.value(record.pageHash)) differs from fixture page "
                        + "\(Hex.value(pageHash)) in \(known.driver.rawValue)@\(Hex.value(intendedStart))")
            }
            guard ProfileCodec.pageMatches(record, data: page.bytes) else {
                throw AnalyzerError.validation(
                    "page record \(index) site finds do not match the fixture page")
            }
            intendedPage[index] = page
            metadataReports.append([
                "pageIndex": index,
                "mode": record.mode == .page ? "PAGE" : "DYLD",
                "route": record.mode == .page ? "_cs_validate_page" : "_cs_validate_range",
                "imageIndex": Int(record.imageIndex),
                "imagePath": targetImage.path,
                "imageKind": targetImage.kind == .standaloneFile ? "standalone-file" : "dyld-shared-cache",
                "imageUnslidVmaddr": Hex.value(targetImage.unslidVMAddress),
                "imageVmSize": Hex.value(UInt64(targetImage.vmSize)),
                "pageVmOffset": Hex.value(UInt64(record.pageVmOffset)),
                "pageStart": Hex.value(intendedStart),
                "pageFileOffset": Hex.value(record.pageFileOffset),
                "pageHash": Hex.value(record.pageHash),
                "result": "PASS"
            ])
        }

        // Delivery simulation: every fixture chunk through the mode-routed matcher.
        var appliedByRecord: [Int: [FixturePage]] = [:]
        var pageReports: [[String: Any]] = []
        for page in fixturePages {
            let application = ProfileCodec.applyPage(profile, data: page.bytes, mode: page.mode)
            switch application {
            case .noMatch:
                continue
            case let .siteFindMismatch(pageIndex, _):
                throw AnalyzerError.validation(
                    "fixture page \(page.driver.rawValue)@\(Hex.value(page.address)) matched record "
                        + "\(pageIndex) but a site find did not match")
            case let .applied(pageIndex, patched):
                appliedByRecord[pageIndex, default: []].append(page)
                let record = profile.pages[pageIndex]
                let originalHash = ProfileCodec.fnv1a64(page.bytes)
                let resultingHash = ProfileCodec.fnv1a64(patched)
                pageReports.append([
                    "recordIndex": pageIndex,
                    "mode": record.mode == .page ? "PAGE" : "DYLD",
                    "driver": page.driver.rawValue,
                    "pageStart": Hex.value(page.address),
                    "originalPageHash": Hex.value(originalHash),
                    "resultingPageHash": Hex.value(resultingHash),
                    "sitesMatched": record.sites.count,
                    "sites": record.sites.map { [
                        "siteInPage": Int($0.siteInPage),
                        "find": Hex.spaced($0.find),
                        "replace": Hex.spaced($0.replace)
                    ] }
                ])
            case let .alreadyPatched(pageIndex):
                throw AnalyzerError.validation(
                    "clean fixture page unexpectedly reported already patched for record \(pageIndex)")
            }
        }

        // Every record must match exactly its intended fixture page, and no other page
        // may match a record identity in its mode.
        var alreadyPatchedChecks: [[String: Any]] = []
        for (index, record) in profile.pages.enumerated() {
            let matches = appliedByRecord[index] ?? []
            guard matches.count == 1, let match = matches.first, let intended = intendedPage[index],
                  match.driver == intended.driver, match.address == intended.address else {
                let matchList = matches.map { "\($0.driver.rawValue)@\(Hex.value($0.address))" }
                throw AnalyzerError.validation(
                    "page record \(index) matched \(matches.count) fixture pages \(matchList); "
                        + "expected exactly the intended page")
            }
            let patched = ProfileCodec.applySites(record, to: match.bytes)
            let secondPass = ProfileCodec.applyPage(profile, data: patched, mode: record.mode)
            guard case let .alreadyPatched(pageIndex) = secondPass, pageIndex == index else {
                throw AnalyzerError.validation(
                    "already-patched pass did not recognise record \(index) on its patched page")
            }
            alreadyPatchedChecks.append(["pageIndex": index,
                                         "mode": record.mode == .page ? "PAGE" : "DYLD",
                                         "result": "alreadyPatched"])
        }

        let modePageRecords = profile.pages.filter { $0.mode == .page }.count
        let modeDyldRecords = profile.pages.filter { $0.mode == .dyld }.count
        return [
            "result": "PASS",
            "profileVersion": Int(NRPTFormat.version),
            "pagesScanned": fixturePages.count,
            "pagesMatched": appliedByRecord.keys.count,
            "modePageRecords": modePageRecords,
            "modeDyldRecords": modeDyldRecords,
            "selector": [
                "selectedIndex": 0,
                "build": profile.header.build,
                "apuMask": Hex.value(UInt64(profile.header.apuMask)),
                "deviceID": Hex.value(UInt64(profile.header.deviceID)),
                "runningDeviceID": Hex.value(UInt64(runningDeviceID)),
                "result": "selected"
            ],
            "pages": pageReports,
            "targetImageMetadata": [
                "images": profile.images.count,
                "pagesVerified": metadataReports.count,
                "pages": metadataReports,
                "result": "PASS"
            ],
            "alreadyPatchedPass": [
                "records": alreadyPatchedChecks.count,
                "checks": alreadyPatchedChecks,
                "result": "PASS"
            ],
            "falsePositiveScan": [
                "pagesScanned": fixturePages.count,
                "unintendedMatches": 0,
                "result": "PASS"
            ],
            "findMismatches": 0
        ]
    }
}

// MARK: - CLI

enum ProfileCLI {
    static let generateFlag = "--generate-profile"
    static let validateFlag = "--validate-profile"
    static let bundleFlag = "--bundle-profiles"
    static let outFlag = "--out"
    static let fixtureFlag = "--fixture-root"

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.contains(generateFlag) || arguments.contains(validateFlag) || arguments.contains(bundleFlag)
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            if let index = arguments.firstIndex(of: generateFlag) {
                let value = valueAfter(index, in: arguments)
                let fixtureRoot = value ?? valueOf(fixtureFlag, in: arguments)
                guard let outDirectory = valueOf(outFlag, in: arguments) else {
                    throw AnalyzerError.validation("--generate-profile requires --out <directory>")
                }
                return try runGenerate(fixtureRoot: fixtureRoot, outDirectory: outDirectory)
            }
            if let index = arguments.firstIndex(of: bundleFlag) {
                guard let manifest = valueAfter(index, in: arguments) else {
                    throw AnalyzerError.validation("--bundle-profiles requires a manifest.json path")
                }
                guard let outDirectory = valueOf(outFlag, in: arguments) else {
                    throw AnalyzerError.validation("--bundle-profiles requires --out <directory>")
                }
                return try runBundle(manifestPath: manifest, outDirectory: outDirectory)
            }
            if let index = arguments.firstIndex(of: validateFlag) {
                let profilePath = valueAfter(index, in: arguments)
                guard let profilePath else {
                    throw AnalyzerError.validation("--validate-profile requires a profile path")
                }
                guard let fixtureRoot = valueOf(fixtureFlag, in: arguments) else {
                    throw AnalyzerError.validation("--validate-profile requires --fixture-root <root>")
                }
                return try runValidate(profilePath: profilePath, fixtureRoot: fixtureRoot)
            }
            throw AnalyzerError.validation("no analyzer command requested")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            return 1
        }
    }

    private static func valueAfter(_ index: Int, in arguments: [String]) -> String? {
        guard index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    private static func valueOf(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return valueAfter(index, in: arguments)
    }

    private static func runGenerate(fixtureRoot: String?, outDirectory: String) throws -> Int32 {
        let environment = try AnalyzerEnvironment.resolve(fixtureRoot: fixtureRoot)
        let output = try ProfileGenerator.generate(environment: environment)
        let directory = try prepareOutputDirectory(outDirectory)
        let profileURL = directory.appendingPathComponent("nred-\(environment.build).nrpt")
        let evidenceURL = directory.appendingPathComponent("nred-\(environment.build)-evidence.json")
        do {
            try output.profileData.write(to: profileURL, options: .atomic)
            try output.evidenceJSON.write(to: evidenceURL, options: .atomic)
        } catch {
            throw AnalyzerError.io("cannot write output: \(error.localizedDescription)")
        }
        let pageModes = modeCounts(profile: output.profile)
        let lines = [
            "PASS: generated NRPT v\(NRPTFormat.version) profile",
            "build: \(environment.build)",
            "device: \(environment.deviceID.map { Hex.value(UInt64($0)) } ?? "unknown") apuMask: \(Hex.value(UInt64(environment.apuMask)))",
            "images: \(output.profile.images.count) pages: \(output.profile.pageCount) "
                + "sites: \(output.profile.siteCount) size: \(output.profileData.count)",
            "modes: PAGE=\(pageModes.page) DYLD=\(pageModes.dyld)",
            "sha256: \(ProfileGenerator.sha256(output.profileData))",
            "profile: \(profileURL.path)",
            "evidence: \(evidenceURL.path)",
            "offline validation: PASS"
        ]
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        return 0
    }

    private static func runBundle(manifestPath: String, outDirectory: String) throws -> Int32 {
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifest = try ProfileBundleManifest.load(at: manifestURL)
        var entries: [NRedProfilesEntry] = []
        var facts: [BundleProfileFacts] = []
        for (index, entry) in manifest.entries.enumerated() {
            if let profilePath = entry.profilePath {
                let data: Data
                do {
                    data = try Data(contentsOf: URL(fileURLWithPath: profilePath))
                } catch {
                    throw AnalyzerError.io("bundle entry \(index): cannot read \(profilePath): \(error.localizedDescription)")
                }
                let profile = try ProfileCodec.decode(data)
                var revalidated = false
                if let fixtureRoot = entry.fixtureRoot {
                    let environment = try AnalyzerEnvironment.resolve(fixtureRoot: fixtureRoot)
                    let images = try AnalyzerImageSet(environment: environment)
                    _ = try OfflineValidator.validate(profileData: data, environment: environment, images: images)
                    revalidated = true
                }
                try checkOverrides(entry: entry, profile: profile, index: index)
                entries.append(NRedProfilesEntry(build: profile.header.build,
                                                 apuMask: profile.header.apuMask,
                                                 deviceID: profile.header.deviceID,
                                                 profile: profile))
                facts.append(BundleProfileFacts(build: profile.header.build,
                                                apuMask: profile.header.apuMask,
                                                deviceID: profile.header.deviceID,
                                                profileData: data,
                                                source: ProfileBundleSupport.sourceLabel(for: profilePath),
                                                revalidated: revalidated,
                                                profile: profile))
            } else if let fixtureRoot = entry.fixtureRoot {
                let environment = try AnalyzerEnvironment.resolve(fixtureRoot: fixtureRoot)
                let output = try ProfileGenerator.generate(environment: environment)
                try checkOverrides(entry: entry, profile: output.profile, index: index)
                entries.append(NRedProfilesEntry(build: output.profile.header.build,
                                                 apuMask: output.profile.header.apuMask,
                                                 deviceID: output.profile.header.deviceID,
                                                 profile: output.profile))
                facts.append(BundleProfileFacts(build: output.profile.header.build,
                                                apuMask: output.profile.header.apuMask,
                                                deviceID: output.profile.header.deviceID,
                                                profileData: output.profileData,
                                                source: ProfileBundleSupport.sourceLabel(for: fixtureRoot),
                                                revalidated: true,
                                                profile: output.profile))
            } else {
                throw AnalyzerError.malformed("bundle entry \(index) has neither fixtureRoot nor profile")
            }
        }
        let bundle = NRedProfilesBundle(entries: entries)
        do {
            try ProfileCodec.validateBundle(bundle)
        } catch {
            throw AnalyzerError.validation("bundle validation failed: \(error)")
        }
        let plistData = try ProfileCodec.encodeBundlePlist(bundle)
        let bundleEvidence = try ProfileBundleSupport.evidenceJSON(facts: facts)
        let directory = try prepareOutputDirectory(outDirectory)
        let plistURL = directory.appendingPathComponent("nred-profiles.plist")
        let evidenceURL = directory.appendingPathComponent("nred-profiles-evidence.json")
        do {
            try plistData.write(to: plistURL, options: .atomic)
            try bundleEvidence.write(to: evidenceURL, options: .atomic)
        } catch {
            throw AnalyzerError.io("cannot write bundle output: \(error.localizedDescription)")
        }
        var lines = [
            "PASS: generated NRedProfiles bundle (NRPT v\(NRPTFormat.version))",
            "profiles: \(entries.count)"
        ]
        for fact in facts {
            lines.append("  build: \(fact.build) apuMask: \(Hex.value(UInt64(fact.apuMask))) "
                + "device: \(Hex.value(UInt64(fact.deviceID))) modePAGE=\(fact.modePageCount) "
                + "modeDYLD=\(fact.modeDyldCount) sha256: \(fact.sha256)")
        }
        lines.append("plist: \(plistURL.path)")
        lines.append("plist sha256: \(ProfileGenerator.sha256(plistData))")
        lines.append("evidence: \(evidenceURL.path)")
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        return 0
    }

    private static func checkOverrides(entry: ProfileBundleManifest.Entry,
                                       profile: NRPTProfile,
                                       index: Int) throws {
        if let build = entry.buildOverride, build != profile.header.build {
            throw AnalyzerError.validation(
                "bundle entry \(index): build override \(build) differs from profile build \(profile.header.build)")
        }
        if let apuMask = entry.apuMaskOverride, apuMask != profile.header.apuMask {
            throw AnalyzerError.validation(
                "bundle entry \(index): apuMask override \(Hex.value(UInt64(apuMask))) differs from profile "
                    + "apuMask \(Hex.value(UInt64(profile.header.apuMask)))")
        }
        if let deviceID = entry.deviceIDOverride, deviceID != profile.header.deviceID {
            throw AnalyzerError.validation(
                "bundle entry \(index): deviceID override \(Hex.value(UInt64(deviceID))) differs from profile "
                    + "deviceID \(Hex.value(UInt64(profile.header.deviceID)))")
        }
    }

    private static func runValidate(profilePath: String, fixtureRoot: String) throws -> Int32 {
        let environment = try AnalyzerEnvironment.resolve(fixtureRoot: fixtureRoot)
        let images = try AnalyzerImageSet(environment: environment)
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: profilePath))
        } catch {
            throw AnalyzerError.io("cannot read profile \(profilePath): \(error.localizedDescription)")
        }
        let report = try OfflineValidator.validate(profileData: data, environment: environment, images: images)
        let profile = try ProfileCodec.decode(data)
        let pageModes = modeCounts(profile: profile)
        var lines: [String] = []
        lines.append("PASS: profile validated offline")
        lines.append("build: \(profile.header.build) version: v\(NRPTFormat.version) "
            + "images: \(profile.images.count) pages: \(profile.pageCount) "
            + "sites: \(profile.siteCount) bytes: \(data.count)")
        lines.append("modes: PAGE=\(pageModes.page) DYLD=\(pageModes.dyld)")
        lines.append("sha256: \(ProfileGenerator.sha256(data))")
        lines.append("pages scanned: \(report["pagesScanned"] ?? "?") matched: \(report["pagesMatched"] ?? "?")")
        if let metadata = report["targetImageMetadata"] as? [String: Any] {
            lines.append("target image metadata: images=\(metadata["images"] ?? "?") "
                + "pagesVerified=\(metadata["pagesVerified"] ?? "?")")
        }
        if let selector = report["selector"] as? [String: Any] {
            lines.append("bundle selector: result=\(selector["result"] ?? "?") "
                + "build=\(selector["build"] ?? "?")")
        }
        if let pages = report["pages"] as? [[String: Any]] {
            for page in pages {
                let index = page["recordIndex"] as? Int ?? -1
                let mode = page["mode"] as? String ?? "?"
                let driver = page["driver"] as? String ?? "?"
                let start = page["pageStart"] as? String ?? "?"
                let sites = page["sitesMatched"] as? Int ?? 0
                lines.append("  record \(index): \(mode) \(driver) @\(start) sites=\(sites)")
            }
        }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        return 0
    }

    private static func prepareOutputDirectory(_ path: String) throws -> URL {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AnalyzerError.io("cannot create output directory \(directory.path): \(error.localizedDescription)")
        }
        return directory
    }

    private static func modeCounts(profile: NRPTProfile) -> (page: Int, dyld: Int) {
        (profile.pages.filter { $0.mode == .page }.count,
         profile.pages.filter { $0.mode == .dyld }.count)
    }
}
