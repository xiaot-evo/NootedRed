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
    let pageHash: UInt64?
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

/// 写入 EFI 的结果：目标 Info.plist 与本次自动备份（备份失败时为 nil）。
struct OffsetProfileInstallResult {
    let infoPlistURL: URL
    let backupURL: URL?
}

/// EFI 中 NootedRedUserPatch personality 里已经写入的 profile 摘要。
struct InstalledProfileSummary {
    let build: String
    let pageCount: Int
    let byteCount: Int
    let infoPlistPath: String
    let modifiedAt: Date?
}

struct SiteSpec {
    let offset: UInt32
    let find: String
    let replace: String
}

struct PageSpec {
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
    static let parserVersion = "2.0"
    static let profileMagic = Data("NRP3".utf8)
    static let profileVersion: UInt16 = 3
    static let profileHeaderSize: UInt16 = 64
    static let profilePageEntrySize: UInt16 = 24
    static let profileSiteEntrySize: UInt16 = 40
    static let profileMaxPages: UInt16 = 64
    static let profileMaxSites: UInt16 = 256
    static let profileMaxPatchBytes = 16

    static func generate(build: String) async throws -> OffsetProfile {
        try await Task.detached(priority: .userInitiated) {
            try generateSync(build: build)
        }.value
    }

    static func currentBuild() async -> String {
        if let fixtureBuild = FixturePaths.buildVersion {
            return fixtureBuild
        }
        let result = await CommandRunner.run("/usr/bin/sw_vers", ["-buildVersion"])
        return result.output.isEmpty ? "unknown" : result.output
    }

    private static func generateSync(build: String) throws -> OffsetProfile {
        let specs = try SiteDiscovery.discover()
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
            case .file:
                let url = URL(fileURLWithPath: "\(glDriverPath)")
                if fileCache[url.path] == nil {
                    fileCache[url.path] = try UncachedFile.read(url)
                }
                let data = fileCache[url.path]!
                image = try MachOParser.parse(data: data)
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
            let pageHash = fnv1a64(pageData)
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
                pageHash: pageHash,
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
        let pages = profile.pages.filter { !$0.sites.isEmpty }
        let pageCount = pages.count
        let siteCount = pages.reduce(0) { $0 + $1.sites.count }
        guard pageCount > 0,
              pageCount <= Int(profileMaxPages),
              siteCount > 0,
              siteCount <= Int(profileMaxSites) else { return Data() }

        var pageTable = Data()
        var siteTable = Data()
        var firstSite = 0

        for page in pages {
            appendLE(page.pageFileOffset, to: &pageTable)
            appendLE(page.pageHash ?? 0, to: &pageTable)
            appendLE(UInt32(firstSite), to: &pageTable)
            appendLE(UInt16(page.sites.count), to: &pageTable)
            appendLE(UInt16(0), to: &pageTable) // flags

            for site in page.sites {
                let find = data(fromHex: site.find)
                let replace = data(fromHex: site.replace)
                guard find.count > 0,
                      find.count <= profileMaxPatchBytes,
                      replace.count == find.count,
                      site.siteInPage + UInt32(find.count) <= 0x1000 else { return Data() }

                appendLE(UInt16(site.siteInPage), to: &siteTable)
                siteTable.append(UInt8(find.count))
                siteTable.append(UInt8(replace.count))
                siteTable.append(contentsOf: find)
                siteTable.append(contentsOf: [UInt8](repeating: 0, count: profileMaxPatchBytes - find.count))
                siteTable.append(contentsOf: replace)
                siteTable.append(contentsOf: [UInt8](repeating: 0, count: profileMaxPatchBytes - replace.count))
                siteTable.append(contentsOf: [UInt8](repeating: 0, count: 4)) // reserved
                firstSite += 1
            }
        }

        var payload = Data()
        payload.append(pageTable)
        payload.append(siteTable)

        var build = Array(profile.build.utf8.prefix(16))
        build.append(contentsOf: [UInt8](repeating: 0, count: 16 - build.count))

        var data = Data()
        data.append(profileMagic)
        appendLE(profileVersion, to: &data)
        appendLE(profileHeaderSize, to: &data)
        appendLE(UInt16(pageCount), to: &data)
        appendLE(UInt16(siteCount), to: &data)
        data.append(contentsOf: build)
        appendLE(profilePageEntrySize, to: &data)
        appendLE(profileSiteEntrySize, to: &data)
        appendLE(UInt32(pageTable.count), to: &data)
        appendLE(UInt32(siteTable.count), to: &data)
        appendLE(fnv1a32(payload), to: &data)
        appendLE(UInt32(0), to: &data) // flags
        data.append(contentsOf: [UInt8](repeating: 0, count: 16)) // reserved
        data.append(payload)
        return data
    }

    /// 纯函数：把 OffsetProfile 写入 Info.plist 的 NootedRedUserPatch personality，返回新的 plist 数据。
    /// 用于安装与自测（不触碰磁盘）。
    static func updatedInfoPlistData(_ original: Data, profile: OffsetProfile) throws -> Data {
        let binary = binaryData(profile)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var root = try PropertyListSerialization.propertyList(from: original, options: [], format: &format)
                as? [String: Any],
              var personalities = root["IOKitPersonalities"] as? [String: Any],
              var personality = personalities["org.ChefKiss.NootedRedUserPatch"] as? [String: Any]
        else {
            throw NSError(domain: "NootedRedTool", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Info.plist 缺少 NootedRedUserPatch personality"])
        }

        personality["NRedOffsetProfile"] = binary
        personality["NRedSystemBuild"] = profile.build
        personalities["org.ChefKiss.NootedRedUserPatch"] = personality
        root["IOKitPersonalities"] = personalities
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    /// 把 OffsetProfile 写入已挂载 EFI 中的 NootedRedUserPatch.kext personality。
    ///
    /// 前置条件：调用方已经确认 EFI 已挂载，并把 EFI 分区的根路径传进来。
    static func installToEFI(_ profile: OffsetProfile, efiRoot: URL) async throws -> OffsetProfileInstallResult {
        guard !profile.pages.isEmpty else {
            throw NSError(domain: "NootedRedTool", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "OffsetProfile 为空，没有可写入的页面"])
        }
        let infoPlist = efiRoot.appendingPathComponent(
            "EFI/OC/Kexts/NootedRedUserPatch.kext/Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: infoPlist.path) else {
            throw NSError(domain: "NootedRedTool", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "EFI 中未找到 NootedRedUserPatch.kext（\(infoPlist.deletingLastPathComponent().path)）"])
        }

        let original = try Data(contentsOf: infoPlist)
        let backupURL = backupOriginalInfoPlist(original)
        let updated = try updatedInfoPlistData(original, profile: profile)

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nootedred-info.plist")
        try updated.write(to: temporary, options: .atomic)
        let command = installCommand(temporaryInfoPlist: temporary.path, targetInfoPlist: infoPlist.path)
        let result = await CommandRunner.runAsAdmin(command)
        guard result.status == 0 else {
            let message: String
            if CommandRunner.isUserCancellation(result) {
                message = "授权被取消，未写入 EFI"
            } else {
                message = result.output.isEmpty ? "写入 EFI 失败" : result.output
            }
            throw NSError(domain: "NootedRedTool", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }

        // 写入后复查：确认 personality 里能读回同样的构建号与页数。
        guard let summary = installedProfileSummary(efiRoot: efiRoot),
              summary.build == profile.build,
              summary.pageCount == profile.pages.count else {
            throw NSError(domain: "NootedRedTool", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "写入后校验失败，EFI 中的 OffsetProfile 与生成结果不一致"])
        }
        return OffsetProfileInstallResult(infoPlistURL: infoPlist, backupURL: backupURL)
    }

    /// 纯函数：构造把临时 Info.plist 覆盖到 EFI 的提权命令。
    /// 两个路径都经过 `shellSingleQuoted`，卷名中的引号/分号不会逃逸出参数。
    static func installCommand(temporaryInfoPlist: String, targetInfoPlist: String) -> String {
        let source = CommandRunner.shellSingleQuoted(temporaryInfoPlist)
        let target = CommandRunner.shellSingleQuoted(targetInfoPlist)
        return """
        cp \(source) \(target) && chmod 644 \(target) && \
        rm -f /var/db/nootedred/offset-profile.bin /var/db/nootedred/offset-profile.bin.disabled && \
        rmdir /var/db/nootedred 2>/dev/null || true
        """
    }

    /// 写入前把原 Info.plist 备份到本机 Application Support，便于回滚。
    @discardableResult
    static func backupOriginalInfoPlist(_ data: Data) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("NootedRedTool/backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("NootedRedUserPatch-Info-\(formatter.string(from: Date())).plist")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 读取 EFI 中已经写入的 OffsetProfile，用于健康检查与页面状态。
    static func installedProfileSummary(efiRoot: URL) -> InstalledProfileSummary? {
        let infoPlist = efiRoot.appendingPathComponent(
            "EFI/OC/Kexts/NootedRedUserPatch.kext/Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: infoPlist.path),
              let root = NSDictionary(contentsOf: infoPlist) as? [String: Any],
              let personalities = root["IOKitPersonalities"] as? [String: Any],
              let personality = personalities["org.ChefKiss.NootedRedUserPatch"] as? [String: Any],
              let data = personality["NRedOffsetProfile"] as? Data,
              data.count >= 64,
              data.prefix(4) == profileMagic
        else { return nil }

        let bytes = [UInt8](data)
        let pageCount = Int(bytes[8]) | (Int(bytes[9]) << 8)
        let buildBytes = bytes[12..<28]
        let build = String(decoding: buildBytes.prefix { $0 != 0 }, as: UTF8.self)
        let modified = (try? FileManager.default.attributesOfItem(atPath: infoPlist.path))?[.modificationDate] as? Date
        return InstalledProfileSummary(build: build,
                                       pageCount: pageCount,
                                       byteCount: data.count,
                                       infoPlistPath: infoPlist.path,
                                       modifiedAt: modified)
    }

    static func fnv1a32(_ data: Data) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in data {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return hash
    }

    static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
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

    private static let glDriverPath = FixturePaths.glDriverPath

}

enum GeneratorError: LocalizedError {
    case siteOutOfRange(String, UInt32)
    case findMismatch(String, UInt32, String)
    case symbolNotFound(String)
    case patternMissing(String)
    case replacementLengthMismatch(String)
    case pageOffsetMismatch(String)

    var errorDescription: String? {
        switch self {
        case .siteOutOfRange(let driver, let offset):
            return "\(driver): site offset \(String(format: "0x%X", offset)) 超出页范围"
        case .findMismatch(let driver, let offset, let find):
            return "\(driver): page offset \(String(format: "0x%X", offset)) find 不匹配（期望 \(find)）"
        case .symbolNotFound(let symbol):
            return "找不到驱动符号 \(symbol)"
        case .patternMissing(let detail):
            return "无法定位补丁指令：\(detail)"
        case .replacementLengthMismatch(let driver):
            return "\(driver): replacement 长度与 find 不一致"
        case .pageOffsetMismatch(let driver):
            return "\(driver): 同组站点落在不同页面"
        }
    }
}
