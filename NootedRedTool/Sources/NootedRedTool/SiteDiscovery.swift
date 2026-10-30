import Foundation

/// Runtime discovery of patch sites.
///
/// The previous generator used a `PageSpec` table with fixed page offsets and
/// fixed `find` bytes.  That table is only valid for the build it was written
/// for.  This file replaces it with semantic rules:
///
///   driver image -> symbol -> instruction prefix -> current bytes -> page/site
///
/// Page offsets and site offsets are always derived from the parsed driver.
/// The replacement bytes still encode the intended semantic change.
enum SiteDiscovery {
    static let glDriverPath = FixturePaths.glDriverPath

    private struct Rule {
        let driver: String
        let source: PageSpec.Source
        let symbol: String
        let prefix: [UInt8]
        let findLength: Int
        let replacement: (Data) -> Data
        let validate: (Data) -> Bool
        let desired: [UInt8]?
        let optional: Bool

        init(driver: String, source: PageSpec.Source, symbol: String, prefix: [UInt8],
             findLength: Int, replacement: @escaping (Data) -> Data,
             validate: @escaping (Data) -> Bool = { _ in true },
             desired: [UInt8]? = nil,
             optional: Bool = false) {
            self.driver = driver
            self.source = source
            self.symbol = symbol
            self.prefix = prefix
            self.findLength = findLength
            self.replacement = replacement
            self.validate = validate
            self.desired = desired
            self.optional = optional
        }
    }

    private struct LoadedImage {
        let image: MachOImage
        let text: MachOSegment
        let fileData: Data?
        let reader: DyldCacheReader?
    }

    static func discover() throws -> [PageSpec] {
        var groups: [(driver: String, source: PageSpec.Source, sites: [SiteSpec], pageOffset: UInt64)] = []

        for rule in rules() {
            let loaded = try load(rule.source)
            let (bytes, baseVM) = try readText(loaded)
            if let desired = rule.desired {
                let desiredData = Data(desired)
                var desiredOffset = bytes.startIndex
                var alreadySatisfied = false
                while desiredOffset < bytes.endIndex,
                      let found = bytes.range(of: desiredData, options: [], in: desiredOffset..<bytes.endIndex) {
                    let relative = bytes.distance(from: bytes.startIndex, to: found.lowerBound)
                    guard relative + desired.count <= bytes.count else { break }
                    let vm = baseVM + UInt64(relative)
                    if let containing = loaded.image.symbol(containing: vm),
                       containing.name == rule.symbol || containing.name.contains(rule.symbol) {
                        alreadySatisfied = true
                        break
                    }
                    desiredOffset = bytes.index(after: found.lowerBound)
                }
                if alreadySatisfied { continue }
            }
            let prefix = Data(rule.prefix)
            var vm: UInt64? = nil
            var fallback: [UInt64] = []
            var searchOffset = bytes.startIndex
            while searchOffset < bytes.endIndex,
                  let found = bytes.range(of: prefix, options: [], in: searchOffset..<bytes.endIndex)
            {
                let candidateRelative = bytes.distance(from: bytes.startIndex, to: found.lowerBound)
                guard candidateRelative + rule.findLength <= bytes.count else { break }
                let candidateVM = baseVM + UInt64(candidateRelative)
                let candidate = bytes.subdata(in: candidateRelative..<(candidateRelative + rule.findLength))
                if rule.validate(candidate) {
                    if let containing = loaded.image.symbol(containing: candidateVM),
                       containing.name == rule.symbol || containing.name.contains(rule.symbol)
                    {
                        vm = candidateVM
                        break
                    }
                    fallback.append(candidateVM)
                }
                searchOffset = bytes.index(after: found.lowerBound)
            }
            if vm == nil && fallback.count == 1 { vm = fallback[0] }
            guard let vm else {
                if rule.optional { continue }
                throw GeneratorError.patternNotFound(rule.driver, rule.symbol,
                                                     rule.prefix.map { String(format: "%02x", $0) }.joined())
            }
            let relative = Int(vm - baseVM)
            let matchData = bytes.subdata(in: relative..<(relative + rule.findLength))
            let replacement = rule.replacement(matchData)
            guard replacement.count == matchData.count else {
                throw GeneratorError.replacementLengthMismatch(rule.driver)
            }
            let imageRelative = vm - loaded.image.textStart
            let pageOffset = imageRelative & ~UInt64(0xFFF)
            let siteInPage = UInt32(imageRelative - pageOffset)

            let site = SiteSpec(
                offset: siteInPage,
                find: hex(matchData),
                replace: hex(replacement)
            )

            if let index = groups.firstIndex(where: { $0.driver == rule.driver }) {
                guard groups[index].pageOffset == pageOffset else {
                    if rule.optional { continue }
                    throw GeneratorError.pageOffsetMismatch(rule.driver)
                }
                groups[index].sites.append(site)
            } else {
                groups.append((rule.driver, rule.source, [site], pageOffset))
            }
        }

        let seeds: [(driver: String, source: PageSpec.Source, symbol: String)] = [
            ("VDA page2", .cache("AMDRadeonVADriver2"), "__ZN9VAFactory29createColourFormatConverterVPEi"),
        ]
        for seed in seeds where !groups.contains(where: { $0.driver == seed.driver }) {
            let loaded = try load(seed.source)
            let range = try functionRange(seed.symbol, in: loaded)
            let pageOffset = (range.start - loaded.image.textStart) & ~UInt64(0xFFF)
            groups.append((seed.driver, seed.source, [], pageOffset))
        }

        let order = [
            "GL HwInfo", "GL DualQuad", "MTLControl", "MTL HwInfo",
            "VDA page0", "VDA page1", "VDA page2", "VDA page3", "VDA page4",
            "VDA page5", "VDA page6", "VDA page7", "AppleGVA",
        ]
        return order.compactMap { name in
            groups.first(where: { $0.driver == name }).map { group in
                PageSpec(driver: group.driver, source: group.source, pageOffset: group.pageOffset, sites: group.sites)
            }
        }
    }

    // MARK: - Rules

    private static func rules() -> [Rule] {
        let file = PageSpec.Source.file("GL")
        let mtl = PageSpec.Source.cache("AMDRadeonX5000MTLDriver")
        let vda = PageSpec.Source.cache("AMDRadeonVADriver2")
        let gva = PageSpec.Source.cache("AppleGVA")

        func exact(_ driver: String, _ source: PageSpec.Source, _ symbol: String,
                   _ find: [UInt8], _ replace: [UInt8], optional: Bool = false) -> Rule {
            Rule(driver: driver, source: source, symbol: symbol, prefix: find,
                 findLength: find.count, replacement: { _ in Data(replace) },
                 optional: optional)
        }

        return [
            // movl imm32, 0x78(%rdi) — shader engine count.
            Rule(driver: "GL HwInfo", source: file, symbol: "_gfx9_HwInfoInitData",
                 prefix: [0xC7, 0x47, 0x78], findLength: 7,
                 replacement: { _ in Data([0xC7, 0x47, 0x78, 0x01, 0x00, 0x00, 0x00]) }),

            exact("GL DualQuad", file, "_glrAMD_GFX9_UpdateHwCbDualQuadMode",
                  [0x83, 0xE0, 0xFE], [0x83, 0xC8, 0x01]),

            exact("MTLControl", mtl,
                  "-[GFX9_MtlRenderPipelineState initWithDevice:pipelineStateDescriptor:vertexVariant:fragmentVariant:]",
                  [0x75, 0x0B], [0xEB, 0x0B], optional: true),
            Rule(driver: "MTLControl", source: mtl,
                 symbol: "-[GFX9_MtlRenderPipelineState initWithDevice:pipelineStateDescriptor:vertexVariant:fragmentVariant:]",
                 prefix: [0x75], findLength: 2,
                 replacement: { original in
                     var data = original
                     data[0] = 0xEB
                     return data
                 }, optional: true),
            exact("MTLControl", mtl,
                  "-[GFX9_MtlRenderPipelineState initWithDevice:pipelineStateDescriptor:vertexVariant:fragmentVariant:]",
                  [0x0F, 0x94, 0xC0], [0x31, 0xC9, 0x90], optional: true),

            Rule(driver: "MTL HwInfo", source: mtl,
                 symbol: "__Z19gfx9_HwInfoInitDataP14GFX9_HwInfoRecP24_sAMD_GET_HW_INFO_VALUESj",
                 prefix: [0xC7, 0x47, 0x78], findLength: 7,
                 replacement: { _ in Data([0xC7, 0x47, 0x78, 0x01, 0x00, 0x00, 0x00]) }),

            Rule(driver: "VDA page0", source: vda, symbol: "__ZN17VAAcceleratorInfo8identifyEjj",
                 prefix: [0xBB], findLength: 10,
                 replacement: { original in
                     var data = Data([0xBB, 0x05, 0x00, 0x00, 0x00])
                     data.append(original.subdata(in: 5..<10))
                     return data
                 },
                 validate: { $0[5] == 0xE9 }),

            Rule(driver: "VDA page1", source: vda, symbol: "__ZN18VAAddrLibInterface4initEP11VAIOConnectP13sHardwareInfo",
                 prefix: [0x41, 0x81, 0xFC], findLength: 7,
                 replacement: { _ in Data([0x41, 0x81, 0xFC, 0x8E, 0x00, 0x00, 0x00]) }),

            Rule(driver: "VDA page2", source: vda, symbol: "__ZN9VAFactory29createColourFormatConverterVPEi",
                 prefix: [0x8D, 0x46, 0xFF, 0x83, 0xF8, 0x02], findLength: 8,
                 replacement: { original in
                     var data = original
                     data[6] = 0xEB
                     return data
                 },
                 desired: [0x8D, 0x46, 0xFF, 0x83, 0xF8, 0x02, 0xEB, 0x1F], optional: true),
            Rule(driver: "VDA page2", source: vda, symbol: "__ZN9VAFactory17createDitheringVPEi",
                 prefix: [0x8D, 0x46, 0xFF, 0x83, 0xF8, 0x02], findLength: 8,
                 replacement: { original in
                     var data = original
                     data[6] = 0xEB
                     return data
                 },
                 desired: [0x8D, 0x46, 0xFF, 0x83, 0xF8, 0x02, 0xEB, 0x1F], optional: true),
            Rule(driver: "VDA page2", source: vda, symbol: "__ZN9VAFactory17createDeblockerVPEi",
                 prefix: [0x8D, 0x46, 0xFF, 0x83, 0xF8, 0x02], findLength: 8,
                 replacement: { original in
                     var data = original
                     data[6] = 0xEB
                     return data
                 },
                 desired: [0x8D, 0x46, 0xFF, 0x83, 0xF8, 0x02, 0xEB, 0x1F], optional: true),
            Rule(driver: "VDA page2", source: vda, symbol: "__ZN9VAFactory20createGraphicsEngineEP9VAContext",
                 prefix: [0x48, 0x8B, 0x86, 0x60, 0x04, 0x00, 0x00, 0x8B, 0x40, 0x0C, 0x8D, 0x48, 0xFF, 0x83],
                 findLength: 14,
                 replacement: { _ in Data([0xB8, 0x02, 0x00, 0x00, 0x00, 0x90, 0x90, 0x90, 0x90, 0x90,
                                           0x8D, 0x48, 0xFF, 0x83]) },
                 desired: [0xB8, 0x02, 0x00, 0x00, 0x00, 0x90, 0x90, 0x90, 0x90, 0x90,
                           0x8D, 0x48, 0xFF, 0x83], optional: true),
            Rule(driver: "VDA page2", source: vda, symbol: "__ZN9VAFactory14createImageBltEP9VAContextj",
                 prefix: [0x48, 0x8B, 0x86, 0x60, 0x04, 0x00, 0x00, 0x8B, 0x40, 0x0C, 0x8D, 0x48, 0xFF, 0x83],
                 findLength: 14,
                 replacement: { _ in Data([0xB8, 0x02, 0x00, 0x00, 0x00, 0x90, 0x90, 0x90, 0x90, 0x90,
                                           0x8D, 0x48, 0xFF, 0x83]) },
                 desired: [0xB8, 0x02, 0x00, 0x00, 0x00, 0x90, 0x90, 0x90, 0x90, 0x90,
                           0x8D, 0x48, 0xFF, 0x83], optional: true),

            Rule(driver: "VDA page3", source: vda, symbol: "__ZN14Vcn2EncCommand15getFeedbackSizeEv",
                 prefix: [0xB8], findLength: 7,
                 replacement: { _ in Data([0xB8, 0x30, 0x00, 0x00, 0x00, 0x5D, 0xC3]) },
                 validate: { $0[5] == 0x5D && $0[6] == 0xC3 }),

            Rule(driver: "VDA page4", source: vda, symbol: "__ZN26AVDVcn2AvcEncDataProcessor19ProcessEncodeStatusEP19_VAEncodeStatusInfoPvP15VAVendorTexture",
                 prefix: [0x48, 0x69, 0xC0], findLength: 7,
                 replacement: { _ in Data([0x48, 0x69, 0xC0, 0x30, 0x00, 0x00, 0x00]) }),
            Rule(driver: "VDA page5", source: vda, symbol: "__ZN27AVDVcn2HevcEncDataProcessor19ProcessEncodeStatusEP19_VAEncodeStatusInfoPvP15VAVendorTexture",
                 prefix: [0x48, 0x69, 0xC0], findLength: 7,
                 replacement: { _ in Data([0x48, 0x69, 0xC0, 0x30, 0x00, 0x00, 0x00]) }),

            Rule(driver: "VDA page6", source: vda, symbol: "__ZN4Addr3Lib6CreateEPK18_ADDR_CREATE_INPUTP19_ADDR_CREATE_OUTPUT",
                 prefix: [0x3D], findLength: 7,
                 replacement: { _ in Data([0x3D, 0x8E, 0x00, 0x00, 0x00, 0x0F, 0x85]) },
                 validate: { $0[5] == 0x0F && $0[6] == 0x85 }),
            Rule(driver: "VDA page7", source: vda, symbol: "__ZN4Addr2V27Gfx9Lib20HwlConvertChipFamilyEjj",
                 prefix: [0x81, 0xFE], findLength: 12,
                 replacement: { original in
                     var data = Data([0x81, 0xFE, 0x8E, 0x00, 0x00, 0x00])
                     data.append(original.subdata(in: 6..<12))
                     return data
                 },
                 validate: { $0[6] == 0x0F && $0[7] == 0x85 }),

            Rule(driver: "AppleGVA", source: gva, symbol: "_AVFJPG_GetJPEGDecodeAvailability",
                 prefix: [0x0F, 0x84], findLength: 6,
                 replacement: { _ in Data([0x0F, 0x84, 0x2A, 0x00, 0x00, 0x00]) }),
        ]
    }

    // MARK: - Image access

    static func debugDump() throws {
        let loaded = try load(.cache("AMDRadeonVADriver2"))
        print("textStart=0x\(String(loaded.image.textStart, radix: 16)) vmsize=0x\(String(loaded.text.vmsize, radix: 16)) filesize=0x\(String(loaded.text.filesize, radix: 16))")
        for symbol in loaded.image.symbols where symbol.name.contains("VAFactory") {
            print("symbol 0x\(String(symbol.value, radix: 16)) \(symbol.name)")
        }
        let (bytes, baseVM) = try readText(loaded)
        let targets = [
            "__ZN9VAFactory20createGraphicsEngineEP9VAContext",
            "__ZN9VAFactory14createImageBltEP9VAContextj",
        ]
        let sorted = loaded.image.symbols
            .filter { $0.type & 0x0E != 0 }
            .sorted { $0.value < $1.value }
        for target in targets {
            guard let symbol = sorted.first(where: { $0.name == target }) else {
                print("missing symbol \(target)")
                continue
            }
            let next = sorted.first(where: { $0.value > symbol.value })?.value
                ?? (loaded.image.textStart + loaded.text.vmsize)
            let start = Int(symbol.value - baseVM)
            let length = min(0x300, Int(next - symbol.value))
            guard start >= 0, start + length <= bytes.count else { continue }
            print("--- \(target) start=0x\(String(symbol.value, radix: 16)) len=0x\(String(length, radix: 16))")
            let chunk = bytes.subdata(in: start..<(start + length))
            var line = ""
            for (index, byte) in chunk.enumerated() {
                if index % 16 == 0 {
                    if !line.isEmpty { print(line) }
                    line = String(format: "%04x:", index)
                }
                line += String(format: " %02x", byte)
            }
            if !line.isEmpty { print(line) }
        }

        let mtl = try load(.cache("AMDRadeonX5000MTLDriver"))
        print("MTL textStart=0x\(String(mtl.image.textStart, radix: 16)) vmsize=0x\(String(mtl.text.vmsize, radix: 16))")
        let mtlSymbols = mtl.image.symbols
            .filter { $0.name.contains("MtlRenderPipelineState") }
            .sorted { $0.value < $1.value }
        for symbol in mtlSymbols { print("MTL symbol 0x\(String(symbol.value, radix: 16)) \(symbol.name)") }
        let (mtlBytes, mtlBase) = try readText(mtl)
        for symbol in mtlSymbols.prefix(2) {
            let next = mtlSymbols.first(where: { $0.value > symbol.value })?.value
                ?? (mtl.image.textStart + mtl.text.vmsize)
            let start = Int(symbol.value - mtlBase)
            let length = min(0x300, Int(next - symbol.value))
            guard start >= 0, start + length <= mtlBytes.count else { continue }
            print("--- MTL \(symbol.name) start=0x\(String(symbol.value, radix: 16)) len=0x\(String(length, radix: 16))")
            let chunk = mtlBytes.subdata(in: start..<(start + length))
            var line = ""
            for (index, byte) in chunk.enumerated() {
                if index % 16 == 0 {
                    if !line.isEmpty { print(line) }
                    line = String(format: "%04x:", index)
                }
                line += String(format: " %02x", byte)
            }
            if !line.isEmpty { print(line) }
        }
    }

    private static func load(_ source: PageSpec.Source) throws -> LoadedImage {
        switch source {
        case .file:
            let url = URL(fileURLWithPath: glDriverPath)
            let data = try UncachedFile.read(url)
            let image = try MachOParser.parse(data: data)
            guard let text = image.segments.first(where: { $0.name == "__TEXT" }) else {
                throw MachOError.missingText
            }
            return LoadedImage(image: image, text: text, fileData: data, reader: nil)
        case .cache(let name):
            let reader = try DyldCacheReader()
            let image = try reader.image(at: name)
            guard let text = image.segments.first(where: { $0.name == "__TEXT" }) else {
                throw MachOError.missingText
            }
            return LoadedImage(image: image, text: text, fileData: nil, reader: reader)
        }
    }

    private static func functionRange(_ symbol: String, in loaded: LoadedImage) throws -> (start: UInt64, end: UInt64) {
        let symbols = loaded.image.symbols
            .filter { $0.type & 0x0E != 0 }
            .sorted { $0.value < $1.value }

        guard let match = symbols.first(where: { $0.name == symbol })
                ?? symbols.first(where: { $0.name.contains(symbol) }) else {
            throw GeneratorError.symbolNotFound(symbol)
        }
        let textEnd = loaded.image.textStart + loaded.text.vmsize
        let next = symbols.first(where: { $0.value > match.value })?.value ?? textEnd
        let end = min(next, textEnd)
        guard end > match.value else { throw GeneratorError.symbolNotFound(symbol) }
        return (match.value, end)
    }

    private static func readText(_ loaded: LoadedImage) throws -> (Data, UInt64) {
        let size = Int(loaded.text.filesize != 0 ? loaded.text.filesize : loaded.text.vmsize)
        if let data = loaded.fileData {
            let offset = Int(loaded.text.fileoff)
            guard offset >= 0, offset + size <= data.count else { throw MachOError.truncated }
            return (data.subdata(in: offset..<(offset + size)), loaded.image.textStart)
        }
        guard let reader = loaded.reader else { throw MachOError.truncated }
        return (try reader.read(address: loaded.image.textStart, size: size), loaded.image.textStart)
    }

    private static func read(_ range: (start: UInt64, end: UInt64), from loaded: LoadedImage) throws -> Data {
        let size = Int(range.end - range.start)
        if let data = loaded.fileData {
            let offset = Int(range.start - loaded.image.textStart) + Int(loaded.text.fileoff)
            guard offset >= 0, offset + size <= data.count else { throw MachOError.truncated }
            return data.subdata(in: offset..<(offset + size))
        }
        guard let reader = loaded.reader else { throw MachOError.truncated }
        return try reader.read(address: range.start, size: size)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

extension GeneratorError {
    static func patternNotFound(_ driver: String, _ symbol: String, _ prefix: String) -> GeneratorError {
        .patternMissing("\(driver) [\(symbol)] prefix \(prefix)")
    }
}
