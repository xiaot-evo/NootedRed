import Foundation

struct OffsetSite: Codable, Identifiable {
    var id: String { "\(siteInPage)-\(find)" }
    let siteInPage: UInt32
    let find: String
    let replace: String
    let function: String?
    let displacement: UInt64?
}

struct OffsetPage: Codable, Identifiable {
    var id: String { "\(driver)-\(pageFileOffset)" }
    let driver: String
    let pageVM: UInt64
    let pageFileOffset: UInt64
    let sites: [OffsetSite]
}

struct OffsetProfile: Codable {
    let format: Int
    let build: String
    let parserVersion: String
    let generatedAt: String
    let pages: [OffsetPage]

    var siteCount: Int { pages.reduce(0) { $0 + $1.sites.count } }
    var pageCount: Int { pages.count }
}

private struct SiteSpec {
    let offset: UInt32
    let find: String
    let replace: String
}

private struct PageSpec {
    enum Source {
        case file(String)
        case cache(String)
    }
    let driver: String
    let source: Source
    let pageOffset: UInt64
    let sites: [SiteSpec]
}

enum OffsetProfileGenerator {
    static let parserVersion = "1.0"

    static func generate(build: String) async throws -> OffsetProfile {
        try await Task.detached(priority: .userInitiated) {
            try generateSync(build: build)
        }.value
    }

    static func currentBuild() async -> String {
        let result = await CommandRunner.run("/usr/bin/sw_vers", ["-buildVersion"])
        return result.output.isEmpty ? "unknown" : result.output
    }

    private static func generateSync(build: String) throws -> OffsetProfile {
        let specs = pageSpecs()
        var pages: [OffsetPage] = []
        var fileCache: [String: Data] = [:]
        var cacheReader: DyldCacheReader?
        var imageCache: [String: MachOImage] = [:]

        for spec in specs {
            let image: MachOImage
            let readPage: (UInt64, Int) throws -> Data
            let pageVM: UInt64
            let pageFileOffset: UInt64

            switch spec.source {
            case .file(let name):
                let url = URL(fileURLWithPath: "\(glDriverPath)")
                if fileCache[url.path] == nil {
                    fileCache[url.path] = try Data(contentsOf: url)
                }
                let data = fileCache[url.path]!
                image = try MachOParser.parseFile(at: url)
                let text = image.segments.first { $0.name == "__TEXT" }!
                pageVM = image.textStart + spec.pageOffset
                pageFileOffset = text.fileoff + spec.pageOffset
                readPage = { address, size in
                    let offset = Int(address - image.textStart)
                    guard offset >= 0, offset + size <= data.count else { throw CacheError.truncated }
                    return data.subdata(in: offset..<(offset + size))
                }

            case .cache(let name):
                if cacheReader == nil { cacheReader = try DyldCacheReader() }
                let reader = cacheReader!
                if imageCache[name] == nil { imageCache[name] = try reader.image(at: name) }
                image = imageCache[name]!
                pageVM = image.textStart + spec.pageOffset
                pageFileOffset = try reader.fileOffset(for: pageVM)
                readPage = { address, size in try reader.read(address: address, size: size) }
            }

            let pageData = try readPage(pageVM, 0x1000)
            var siteResults: [OffsetSite] = []

            for site in spec.sites {
                guard Int(site.offset) + site.find.count / 2 <= pageData.count else {
                    throw GeneratorError.siteOutOfRange(spec.driver, site.offset)
                }
                let expected = data(fromHex: site.find)
                let actual = pageData.subdata(in: Int(site.offset)..<(Int(site.offset) + expected.count))
                guard actual == expected else {
                    throw GeneratorError.findMismatch(spec.driver, site.offset, site.find)
                }

                let siteVM = pageVM + UInt64(site.offset)
                let symbol = image.symbol(containing: siteVM)
                siteResults.append(OffsetSite(
                    siteInPage: site.offset,
                    find: site.find,
                    replace: site.replace,
                    function: symbol?.name,
                    displacement: symbol.map { siteVM - $0.value }
                ))
            }

            pages.append(OffsetPage(
                driver: spec.driver,
                pageVM: pageVM,
                pageFileOffset: pageFileOffset,
                sites: siteResults
            ))
        }

        let formatter = ISO8601DateFormatter()
        return OffsetProfile(
            format: 1,
            build: build,
            parserVersion: parserVersion,
            generatedAt: formatter.string(from: Date()),
            pages: pages
        )
    }

    static func save(_ profile: OffsetProfile) throws -> URL {
        let directory = try profileDirectory()
        let url = directory.appendingPathComponent("offset-profile-\(profile.build).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        let temp = url.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
        return url
    }

    static func binaryData(_ profile: OffsetProfile) -> Data {
        var data = Data()
        data.append(contentsOf: Array("NRPF".utf8))
        appendLE(UInt16(1), to: &data)                        // version
        appendLE(UInt16(32), to: &data)                       // header size
        appendLE(UInt16(profile.pages.count), to: &data)      // page count
        appendLE(UInt16(0), to: &data)                        // reserved

        var build = Array(profile.build.utf8.prefix(16))
        build.append(contentsOf: [UInt8](repeating: 0, count: 16 - build.count))
        data.append(contentsOf: build)

        var offsets = Data()
        for page in profile.pages {
            appendLE(page.pageFileOffset, to: &offsets)
        }
        appendLE(fnv1a32(offsets), to: &data)
        data.append(offsets)
        return data
    }

    static func installToSystem(_ profile: OffsetProfile) async throws -> URL {
        let binary = binaryData(profile)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nootedred-offset-profile.bin")
        try binary.write(to: temporary, options: .atomic)
        let destination = "/var/db/nootedred/offset-profile.bin"
        let command = "mkdir -p /var/db/nootedred && cp '\(temporary.path)' '\(destination)' && chmod 644 '\(destination)'"
        let result = await CommandRunner.runAsAdmin(command)
        guard result.status == 0 else {
            throw NSError(domain: "NootedRedTool", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty ? "授权被取消" : result.output])
        }
        return URL(fileURLWithPath: destination)
    }

    static func fnv1a32(_ data: Data) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in data {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return hash
    }

    static func appendLE(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    static func appendLE(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    static func appendLE(_ value: UInt64, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    static func loadCached(build: String) -> OffsetProfile? {
        guard let directory = try? profileDirectory() else { return nil }
        let url = directory.appendingPathComponent("offset-profile-\(build).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OffsetProfile.self, from: data)
    }

    static func profileDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("NootedRedTool", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func data(fromHex string: String) -> Data {
        let clean = string.replacingOccurrences(of: " ", with: "")
        var bytes: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            if let byte = UInt8(clean[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return Data(bytes)
    }

    private static let glDriverPath = "/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver"

    private static func pageSpecs() -> [PageSpec] {
        [
            PageSpec(driver: "GL HwInfo", source: .file("GL"), pageOffset: 0xE000, sites: [
                SiteSpec(offset: 0x81, find: "c7477804000000", replace: "c7477801000000")
            ]),
            PageSpec(driver: "GL DualQuad", source: .file("GL"), pageOffset: 0x8000, sites: [
                SiteSpec(offset: 0x160, find: "83e0fe", replace: "83c801")
            ]),
            PageSpec(driver: "MTLControl", source: .cache("AMDRadeonX5000MTLDriver"), pageOffset: 0x5C000, sites: [
                SiteSpec(offset: 0x164, find: "750b", replace: "eb0b"),
                SiteSpec(offset: 0x198, find: "0f94c0", replace: "31c990")
            ]),
            PageSpec(driver: "MTL HwInfo", source: .cache("AMDRadeonX5000MTLDriver"), pageOffset: 0x98000, sites: [
                SiteSpec(offset: 0x51D, find: "c7477804000000", replace: "c7477801000000")
            ]),
            PageSpec(driver: "VDA page0", source: .cache("AMDRadeonVADriver2"), pageOffset: 0x0, sites: [
                SiteSpec(offset: 0xB96, find: "bb0b000000e991feffff", replace: "bb05000000e991feffff")
            ]),
            PageSpec(driver: "VDA page1", source: .cache("AMDRadeonVADriver2"), pageOffset: 0x2000, sites: [
                SiteSpec(offset: 0x449, find: "4181fc8d000000", replace: "4181fc8e000000")
            ]),
            PageSpec(driver: "VDA page2", source: .cache("AMDRadeonVADriver2"), pageOffset: 0x9000, sites: [
                SiteSpec(offset: 0x987, find: "8d46ff83f802721f", replace: "8d46ff83f802eb1f"),
                SiteSpec(offset: 0xA49, find: "8d46ff83f802721f", replace: "8d46ff83f802eb1f"),
                SiteSpec(offset: 0xACB, find: "8d46ff83f802721f", replace: "8d46ff83f802eb1f"),
                SiteSpec(offset: 0xBD0, find: "488b86600400008b400c8d48ff83", replace: "b80200000090909090908d48ff83"),
                SiteSpec(offset: 0xC69, find: "488b86600400008b400c8d48ff83", replace: "b80200000090909090908d48ff83")
            ]),
            PageSpec(driver: "VDA page3", source: .cache("AMDRadeonVADriver2"), pageOffset: 0x47000, sites: [
                SiteSpec(offset: 0xF88, find: "b8a40000005dc3", replace: "b8300000005dc3")
            ]),
            PageSpec(driver: "VDA page4", source: .cache("AMDRadeonVADriver2"), pageOffset: 0x49000, sites: [
                SiteSpec(offset: 0x626, find: "4869c0a4000000", replace: "4869c030000000")
            ]),
            PageSpec(driver: "VDA page5", source: .cache("AMDRadeonVADriver2"), pageOffset: 0x4A000, sites: [
                SiteSpec(offset: 0x82C, find: "4869c0a4000000", replace: "4869c030000000")
            ]),
            PageSpec(driver: "VDA page6", source: .cache("AMDRadeonVADriver2"), pageOffset: 0x61000, sites: [
                SiteSpec(offset: 0xC65, find: "3d8d0000000f85", replace: "3d8e0000000f85")
            ]),
            PageSpec(driver: "VDA page7", source: .cache("AMDRadeonVADriver2"), pageOffset: 0x77000, sites: [
                SiteSpec(offset: 0x770, find: "81fe8d0000000f8588000000", replace: "81fe8e0000000f8588000000")
            ]),
            PageSpec(driver: "AppleGVA", source: .cache("AppleGVA"), pageOffset: 0x24000, sites: [
                SiteSpec(offset: 0x41B, find: "0f84d6030000", replace: "0f842a000000")
            ])
        ]
    }
}

enum GeneratorError: LocalizedError {
    case siteOutOfRange(String, UInt32)
    case findMismatch(String, UInt32, String)

    var errorDescription: String? {
        switch self {
        case .siteOutOfRange(let driver, let offset):
            return "\(driver): site offset \(String(format: "0x%X", offset)) 超出页范围"
        case .findMismatch(let driver, let offset, let find):
            return "\(driver): page offset \(String(format: "0x%X", offset)) find 不匹配（期望 \(find)）"
        }
    }
}
