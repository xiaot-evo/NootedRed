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
    let matchFlags: NRPTMatchFlags
    let pageBytes: Data
}

// MARK: - Generator

enum ProfileGenerator {
    static let generatorVersion = "PatchAnalyzer/1.0"

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
                        // The offset gate is required on every page: standalone bundles
                        // are paged with their file offset, and for split caches the pager
                        // offset is the subcache file offset derived here (validated
                        // against the fixture by the offline validator). The offset also
                        // disambiguates identical 4 KiB content in different subcache
                        // files / driver images (e.g. VADriver2 .03 0x867D000 vs the
                        // legacy VADriver 0x85C4000 page).
                        let matchFlags: NRPTMatchFlags = .defaultV1
                        let pageHash = try ProfileCodec.pageHash(page.bytes)
                        sites.append(GeneratedSite(ruleID: rule.id, driver: rule.driver, match: match,
                                                   siteAddress: siteAddress, siteInPage: UInt16(inPage),
                                                   pageStart: page.pageStart, pageFileOffset: pageFileOffset,
                                                   pageHash: pageHash, matchFlags: matchFlags,
                                                   pageBytes: page.bytes))
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
                            "reachable": analysis.isReachable(siteAddress)
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
            pages.append(NRPTPage(pageFileOffset: first.pageFileOffset, pageHash: first.pageHash,
                                  matchFlags: first.matchFlags, sites: records))
            pageEvidence.append([
                "driver": first.driver.rawValue,
                "pageStart": Hex.value(first.pageStart),
                "pageFileOffset": Hex.value(first.pageFileOffset),
                "pageHash": Hex.value(first.pageHash),
                "matchFlags": Hex.value(UInt64(first.matchFlags.rawValue)),
                "offsetNamespaceProven": true,
                "offsetNamespace": first.driver.isStandaloneFile
                    ? "standalone-file-offset" : "subcache-file-offset",
                "sites": records.count
            ])
        }

        let deviceID = environment.deviceID
        let header = NRPTHeader(build: environment.build, apuMask: environment.apuMask,
                                deviceID: deviceID ?? 0,
                                flags: deviceID != nil ? .requireDeviceID : [])
        let profile = NRPTProfile(header: header, pages: pages)
        let profileData: Data
        do {
            profileData = try ProfileCodec.encode(profile)
        } catch {
            throw AnalyzerError.validation("profile encode failed: \(error)")
        }

        // Producer obligation: no other page of any target image may match a
        // record identity. Cache pages are hash-identified, so scan all __TEXT
        // pages of all target images for hash collisions.
        let collisionScan = try scanForIdentityCollisions(sites: sites, images: images)
        // Offline validation with the exact kext algorithm.
        let validation = try OfflineValidator.validate(profileData: profileData,
                                                       environment: environment, images: images)

        var evidence: [String: Any] = [
            "schema": 1,
            "generator": generatorVersion,
            "decoder": X86Decoder.shared.libraryPath ?? "unavailable",
            "fixtureRoot": environment.root.path,
            "live": environment.isLive,
            "build": environment.build,
            "apuMask": Hex.value(UInt64(environment.apuMask)),
            "deviceID": deviceID.map { Hex.value(UInt64($0)) } ?? "unavailable",
            "requireDeviceID": deviceID != nil,
            "profile": [
                "size": profileData.count,
                "pageCount": pages.count,
                "siteCount": sites.count,
                "checksum": Hex.value(UInt64(ProfileCodec.fnv1a32(profileData.subdata(in: 64..<profileData.count)))),
                "sha256": sha256(profileData)
            ],
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
        var pagesByHash: [UInt64: GeneratedSite] = [:]
        for site in sites {
            pagesByHash[site.pageHash] = site
        }
        var collisions: [[String: Any]] = []
        var offsetDisambiguated: [[String: Any]] = []
        var scanned = 0
        let allImages = try images.allImages()
        for driver in DriverImage.allCases {
            guard let image = allImages[driver], let text = image.segments.first(where: { $0.name == "__TEXT" }) else {
                continue
            }
            var address = text.vmaddr & ~UInt64(0xfff)
            let end = text.vmaddr + min(text.filesize, text.vmsize)
            while address < end {
                guard address + 0x1000 <= end else { break }
                if let intended = pagesByHash.values.first(where: { $0.driver == driver && $0.pageStart == address }) {
                    // The intended page is the one the site was found on.
                    _ = intended
                    address &+= 0x1000
                    continue
                }
                let pageBytes = [UInt8](try image.read(address: address, size: 0x1000))
                let hash = ProfileCodec.fnv1a64(Data(pageBytes))
                scanned += 1
                if let conflicting = pagesByHash[hash] {
                    let conflictingOffset = conflicting.pageFileOffset
                    let candidateOffset = try image.fileOffset(address: address)
                    if conflictingOffset == candidateOffset {
                        throw AnalyzerError.ambiguous(
                            "identical page identity (offset \(Hex.value(candidateOffset)), hash \(Hex.value(hash))) "
                                + "on \(driver.rawValue) page \(Hex.value(address))")
                    }
                    // Identical content in a different offset namespace is legal:
                    // every record sets REQUIRE_OFFSET, so the offset distinguishes it.
                    offsetDisambiguated.append([
                        "recordDriver": conflicting.driver.rawValue,
                        "recordPageFileOffset": Hex.value(conflictingOffset),
                        "collisionDriver": driver.rawValue,
                        "collisionPageStart": Hex.value(address),
                        "collisionPageFileOffset": Hex.value(candidateOffset),
                        "pageHash": Hex.value(hash)
                    ])
                }
                address &+= 0x1000
            }
        }
        if !collisions.isEmpty {
            throw AnalyzerError.ambiguous(
                "\(collisions.count) unintended image pages match a profile page identity")
        }
        return ["pagesScanned": scanned,
                "sameIdentityCollisions": collisions.count,
                "offsetDisambiguatedContentMatches": offsetDisambiguated,
                "allRecordsRequireOffset": true,
                "offsetGateNote": "every page record sets REQUIRE_OFFSET, so identical 4 KiB content "
                    + "delivered through another image/pager offset (e.g. VADriver2 .03 0x867D000 vs "
                    + "legacy VADriver 0x85C4000) is rejected by the offset gate before hashing",
                "result": "PASS"]
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Offline validator (same algorithm as the kext)

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
        if profile.header.flags.contains(.requireDeviceID) {
            guard let deviceID = environment.deviceID, profile.header.deviceID == deviceID else {
                throw AnalyzerError.validation("profile deviceID does not match the fixture device ID")
            }
        }

        let allImages = try images.allImages()
        var matchedPages: [Int: [(driver: DriverImage, pageFileOffset: UInt64, pageStart: UInt64, data: Data)]] = [:]
        var pageReports: [[String: Any]] = []
        var totalPagesScanned = 0
        for driver in DriverImage.allCases {
            guard let image = allImages[driver], let text = image.segments.first(where: { $0.name == "__TEXT" }) else {
                continue
            }
            var address = text.vmaddr & ~UInt64(0xfff)
            let end = text.vmaddr + min(text.filesize, text.vmsize)
            while address < end {
                guard address + 0x1000 <= end else { break }
                let pageBytes = try image.read(address: address, size: 0x1000)
                let fileOffset = try image.fileOffset(address: address)
                totalPagesScanned += 1
                for (index, record) in profile.pages.enumerated() {
                    let offsetGate = !record.matchFlags.contains(.requireOffset) || record.pageFileOffset == fileOffset
                    guard offsetGate else { continue }
                    guard ProfileCodec.fnv1a64(pageBytes) == record.pageHash else { continue }
                    let application = ProfileCodec.applyPage(profile, data: pageBytes, pageOffset: fileOffset)
                    switch application {
                    case .noMatch:
                        continue
                    case let .siteFindMismatch(pageIndex, siteIndex):
                        throw AnalyzerError.validation(
                            "page \(Hex.value(fileOffset)) in \(driver.rawValue) matched record \(pageIndex) "
                                + "but site \(siteIndex) find did not match")
                    case let .applied(appliedIndex, patched):
                        guard appliedIndex == index else {
                            throw AnalyzerError.validation("first-matching-record invariant broken")
                        }
                        matchedPages[index, default: []].append(
                            (driver, fileOffset, address, patched))
                    }
                }
                address &+= 0x1000
            }
        }

        for (index, record) in profile.pages.enumerated() {
            let matches = matchedPages[index] ?? []
            guard matches.count == 1, let match = matches.first else {
                throw AnalyzerError.validation(
                    "page record \(index) matched \(matches.count) fixture pages; expected exactly one")
            }
            let original = try allImages[match.driver]!.read(address: match.pageStart, size: 0x1000)
            let resultingHash = ProfileCodec.fnv1a64(match.data)
            pageReports.append([
                "pageIndex": index,
                "driver": match.driver.rawValue,
                "pageFileOffset": Hex.value(match.pageFileOffset),
                "pageStart": Hex.value(match.pageStart),
                "offsetGate": record.matchFlags.contains(.requireOffset) ? "required" : "cleared",
                "hashMatch": true,
                "sitesMatched": record.sites.count,
                "originalPageHash": Hex.value(ProfileCodec.fnv1a64(original)),
                "recordPageHash": Hex.value(record.pageHash),
                "resultingPageHash": Hex.value(resultingHash),
                "sites": record.sites.map { [
                    "siteInPage": Int($0.siteInPage),
                    "find": Hex.spaced($0.find),
                    "replace": Hex.spaced($0.replace)
                ] }
            ])
        }
        let matchedPageCount = matchedPages.keys.count
        guard matchedPageCount == profile.pages.count else {
            throw AnalyzerError.validation(
                "only \(matchedPageCount) of \(profile.pages.count) page records matched fixture pages")
        }
        for (index, matches) in matchedPages where matches.count > 1 {
            throw AnalyzerError.validation(
                "page record \(index) matched \(matches.count) different fixture pages")
        }
        return [
            "result": "PASS",
            "pagesScanned": totalPagesScanned,
            "pagesMatched": matchedPageCount,
            "pages": pageReports,
            "appliedPages": matchedPageCount,
            "findMismatches": 0,
            "falsePositives": 0
        ]
    }
}

// MARK: - CLI

enum ProfileCLI {
    static let generateFlag = "--generate-profile"
    static let validateFlag = "--validate-profile"
    static let outFlag = "--out"
    static let fixtureFlag = "--fixture-root"

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.contains(generateFlag) || arguments.contains(validateFlag)
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
            if let index = arguments.firstIndex(of: validateFlag) {
                let profilePath = valueAfter(index, in: arguments)
                guard let profilePath else {
                    throw AnalyzerError.validation("--validate-profile requires a profile path")
                }
                guard let fixtureRoot = valueOf(fixtureFlag, in: arguments) ?? valueAfter(index + 2, in: arguments) else {
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
        let directory = URL(fileURLWithPath: outDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AnalyzerError.io("cannot create output directory \(directory.path): \(error.localizedDescription)")
        }
        let profileURL = directory.appendingPathComponent("nred-\(environment.build).nrpt")
        let evidenceURL = directory.appendingPathComponent("nred-\(environment.build)-evidence.json")
        do {
            try output.profileData.write(to: profileURL, options: .atomic)
            try output.evidenceJSON.write(to: evidenceURL, options: .atomic)
        } catch {
            throw AnalyzerError.io("cannot write output: \(error.localizedDescription)")
        }
        let lines = [
            "PASS: generated NRPT v1 profile",
            "build: \(environment.build)",
            "device: \(environment.deviceID.map { Hex.value(UInt64($0)) } ?? "unknown") apuMask: \(Hex.value(UInt64(environment.apuMask)))",
            "pages: \(output.profile.pageCount) sites: \(output.profile.siteCount) size: \(output.profileData.count)",
            "sha256: \(ProfileGenerator.sha256(output.profileData))",
            "profile: \(profileURL.path)",
            "evidence: \(evidenceURL.path)",
            "offline validation: PASS"
        ]
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        return 0
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
        var lines: [String] = []
        lines.append("PASS: profile validated offline")
        lines.append("build: \(profile.header.build) pages: \(profile.pageCount) sites: \(profile.siteCount) bytes: \(data.count)")
        lines.append("sha256: \(ProfileGenerator.sha256(data))")
        lines.append("pages scanned: \(report["pagesScanned"] ?? "?") matched: \(report["pagesMatched"] ?? "?")")
        if let pages = report["pages"] as? [[String: Any]] {
            for page in pages {
                let index = page["pageIndex"] as? Int ?? -1
                let driver = page["driver"] as? String ?? "?"
                let offset = page["pageFileOffset"] as? String ?? "?"
                let sites = page["sitesMatched"] as? Int ?? 0
                lines.append("  page \(index): \(driver) @\(offset) sites=\(sites) offsetGate=\(page["offsetGate"] ?? "?")")
            }
        }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        return 0
    }
}
