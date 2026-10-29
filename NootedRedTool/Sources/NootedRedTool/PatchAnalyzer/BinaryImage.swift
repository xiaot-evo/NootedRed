import Foundation

// MARK: - Errors

/// Analyzer errors. Every failure is explicit and fail-closed: the generator never
/// guesses a value and never falls back to a fixed address.
enum AnalyzerError: Error, CustomStringConvertible {
    case io(String)
    case truncated(String, Int, Int)
    case malformed(String)
    case unsupported(String)
    case notFound(String)
    case ambiguous(String)
    case validation(String)

    var description: String {
        switch self {
        case let .io(message): return "io: \(message)"
        case let .truncated(what, needed, actual): return "truncated \(what): need \(needed), have \(actual)"
        case let .malformed(message): return "malformed: \(message)"
        case let .unsupported(message): return "unsupported: \(message)"
        case let .notFound(message): return "not found: \(message)"
        case let .ambiguous(message): return "ambiguous: \(message)"
        case let .validation(message): return "validation: \(message)"
        }
    }
}

// MARK: - Bounds-checked little-endian byte reader

struct ByteBuffer {
    let bytes: [UInt8]
    let label: String

    init(_ data: Data, label: String = "buffer") {
        self.bytes = [UInt8](data)
        self.label = label
    }

    init(_ bytes: [UInt8], label: String = "buffer") {
        self.bytes = bytes
        self.label = label
    }

    var count: Int { bytes.count }

    func check(_ offset: Int, _ size: Int) throws {
        guard offset >= 0, size >= 0, offset <= count, size <= count - offset else {
            throw AnalyzerError.truncated("\(label)[\(offset)...]", offset + size, count)
        }
    }

    func u8(_ offset: Int) throws -> UInt8 {
        try check(offset, 1)
        return bytes[offset]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        try check(offset, 2)
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    func u32(_ offset: Int) throws -> UInt32 {
        try check(offset, 4)
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    func u64(_ offset: Int) throws -> UInt64 {
        let low = try UInt64(u32(offset))
        let high = try UInt64(u32(offset + 4))
        return low | high << 32
    }

    func slice(_ offset: Int, _ size: Int) throws -> [UInt8] {
        try check(offset, size)
        return Array(bytes[offset..<(offset + size)])
    }

    /// Fixed-width NUL-padded ASCII string.
    func fixedString(_ offset: Int, _ size: Int) throws -> String {
        let raw = try slice(offset, size)
        let end = raw.firstIndex(of: 0) ?? raw.count
        return String(decoding: raw[0..<end], as: UTF8.self)
    }

    /// NUL-terminated UTF-8 string bounded by `limit` bytes from `offset`.
    func cString(_ offset: Int, limit: Int? = nil) throws -> String {
        let bound = min(count, offset + (limit ?? count))
        guard offset >= 0, offset <= count else {
            throw AnalyzerError.truncated("\(label) cstring", offset, count)
        }
        var end = offset
        while end < bound, bytes[end] != 0 { end += 1 }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }
}

enum Hex {
    static func string(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func spaced(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func value(_ value: UInt64) -> String {
        String(format: "0x%llX", value)
    }
}

// MARK: - Mach-O model

struct AnalyzedSegment {
    let name: String
    let vmaddr: UInt64
    let vmsize: UInt64
    let fileoff: UInt64
    let filesize: UInt64
    let maxprot: UInt32
    let initprot: UInt32
    let sections: [AnalyzedSection]

    func contains(_ address: UInt64) -> Bool {
        address >= vmaddr && address < vmaddr &+ max(vmsize, 1)
    }
}

struct AnalyzedSection {
    let segname: String
    let sectname: String
    let addr: UInt64
    let size: UInt64
    let offset: UInt64
    let align: UInt32
    let flags: UInt32
    let nreloc: UInt32
}

struct AnalyzedSymbol {
    let name: String
    let strx: UInt32
    let type: UInt8
    let sect: UInt8
    let desc: UInt16
    let value: UInt64

    static let typeMask: UInt8 = 0x0e
    static let typeSect: UInt8 = 0x0e
    static let typeAbs: UInt8 = 0x02
    static let extMask: UInt8 = 0x01

    var isDefined: Bool {
        (type & AnalyzedSymbol.typeMask) == AnalyzedSymbol.typeSect
            || (type & AnalyzedSymbol.typeMask) == AnalyzedSymbol.typeAbs
    }

    var isExternal: Bool { type & AnalyzedSymbol.extMask != 0 }
}

struct AnalyzedDysymtab {
    let ilocalsym: UInt32
    let nlocalsym: UInt32
    let iextdefsym: UInt32
    let nextdefsym: UInt32
    let iundefsym: UInt32
    let nundefsym: UInt32
    let indirectsymoff: UInt32
    let nindirectsyms: UInt32
}

struct FunctionStartInfo {
    let starts: [UInt64]
    let source: String
}

/// Where the image bytes come from.
enum AnalyzedImageBacking {
    case file(Data)
    case cache(DyldCacheStore)
}

/// A parsed Mach-O image, either a standalone file or an image hosted by the
/// dyld shared cache. All reads go through bounds-checked translation; nothing
/// outside the image/segment/file bounds can be fetched.
final class AnalyzedImage {
    let label: String
    let path: String
    let backing: AnalyzedImageBacking
    /// VM address of the mach header, i.e. the `__TEXT` segment vmaddr.
    let loadAddress: UInt64
    let segments: [AnalyzedSegment]
    let sections: [AnalyzedSection]
    let symbols: [AnalyzedSymbol]
    let dysymtab: AnalyzedDysymtab?
    let functionStarts: FunctionStartInfo?
    private(set) var symbolsByName: [String: [AnalyzedSymbol]] = [:]

    private init(label: String,
                 path: String,
                 backing: AnalyzedImageBacking,
                 loadAddress: UInt64,
                 segments: [AnalyzedSegment],
                 sections: [AnalyzedSection],
                 symbols: [AnalyzedSymbol],
                 dysymtab: AnalyzedDysymtab?,
                 functionStarts: FunctionStartInfo?) {
        self.label = label
        self.path = path
        self.backing = backing
        self.loadAddress = loadAddress
        self.segments = segments
        self.sections = sections
        self.symbols = symbols
        self.dysymtab = dysymtab
        self.functionStarts = functionStarts
        for symbol in symbols where !symbol.name.isEmpty {
            symbolsByName[symbol.name, default: []].append(symbol)
        }
    }

    // MARK: loading

    static func loadStandaloneFile(at url: URL, label: String) throws -> AnalyzedImage {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AnalyzerError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
        return try parse(label: label, path: url.path, backing: .file(data), headerAddress: nil)
    }

    static func loadCacheImage(store: DyldCacheStore, pathSuffix: String, label: String) throws -> AnalyzedImage {
        let reference = try store.image(pathSuffix: pathSuffix)
        return try parse(label: label, path: reference.path, backing: .cache(store),
                         headerAddress: reference.address)
    }

    private static func parse(label: String,
                              path: String,
                              backing: AnalyzedImageBacking,
                              headerAddress: UInt64?) throws -> AnalyzedImage {
        func read(_ address: UInt64, _ size: Int) throws -> Data {
            switch backing {
            case let .file(data):
                // A standalone image is addressed by file offset during header/load
                // command parsing (the mach header is at file offset 0).
                guard address <= UInt64(Int.max) else { throw AnalyzerError.truncated("image read", size, 0) }
                let offset = Int(address)
                guard offset <= data.count, size <= data.count - offset else {
                    throw AnalyzerError.truncated("file image read", offset + size, data.count)
                }
                return data.subdata(in: offset..<(offset + size))
            case let .cache(store):
                return try store.read(address: address, size: size)
            }
        }

        let headerVM: UInt64
        switch backing {
        case .file:
            headerVM = 0
        case .cache:
            guard let headerAddress else {
                throw AnalyzerError.malformed("cache image without text address")
            }
            headerVM = headerAddress
        }

        let headerBuffer = ByteBuffer(try read(headerVM, 32), label: "\(label) header")
        let magic = try headerBuffer.u32(0)
        guard magic == 0xfeedfacf else {
            throw AnalyzerError.malformed("\(label): not a 64-bit Mach-O (magic \(Hex.value(UInt64(magic))))")
        }
        let cpuType = try headerBuffer.u32(4)
        guard cpuType == 0x01000007 else {
            throw AnalyzerError.unsupported("\(label): cpu type \(Hex.value(UInt64(cpuType))) is not x86_64")
        }
        let fileType = try headerBuffer.u32(12)
        let ncmds = Int(try headerBuffer.u32(16))
        let sizeofcmds = Int(try headerBuffer.u32(20))
        guard ncmds > 0, ncmds < 0x10000, sizeofcmds > 0, sizeofcmds < 0x100000 else {
            throw AnalyzerError.malformed("\(label): implausible load command sizes ncmds=\(ncmds) sizeofcmds=\(sizeofcmds)")
        }
        let commands = ByteBuffer(try read(headerVM + 32, sizeofcmds), label: "\(label) load commands")

        var segments: [AnalyzedSegment] = []
        var sections: [AnalyzedSection] = []
        var symtab: (symoff: UInt64, nsyms: UInt64, stroff: UInt64, strsize: UInt64)?
        var dysymtab: AnalyzedDysymtab?
        var functionStartsCommand: (dataoff: UInt64, datasize: UInt64)?
        var cursor = 0
        for index in 0..<ncmds {
            guard cursor + 8 <= commands.count else {
                throw AnalyzerError.truncated("\(label) load command \(index)", cursor + 8, commands.count)
            }
            let cmd = try commands.u32(cursor)
            let size = Int(try commands.u32(cursor + 4))
            guard size >= 8, size <= commands.count - cursor else {
                throw AnalyzerError.malformed("\(label): load command \(index) size \(size) out of bounds")
            }
            switch cmd {
            case 0x19: // LC_SEGMENT_64
                let name = try commands.fixedString(cursor + 8, 16)
                let vmaddr = try commands.u64(cursor + 24)
                let vmsize = try commands.u64(cursor + 32)
                let fileoff = try commands.u64(cursor + 40)
                let filesize = try commands.u64(cursor + 48)
                let maxprot = try commands.u32(cursor + 56)
                let initprot = try commands.u32(cursor + 60)
                let nsects = Int(try commands.u32(cursor + 64))
                guard 72 + nsects * 80 == size else {
                    throw AnalyzerError.malformed("\(label): segment \(name) section count disagrees with cmdsize")
                }
                var segmentSections: [AnalyzedSection] = []
                for sectionIndex in 0..<nsects {
                    let base = cursor + 72 + sectionIndex * 80
                    let section = AnalyzedSection(
                        segname: try commands.fixedString(base + 16, 16),
                        sectname: try commands.fixedString(base, 16),
                        addr: try commands.u64(base + 32),
                        size: try commands.u64(base + 40),
                        offset: UInt64(try commands.u32(base + 48)),
                        align: try commands.u32(base + 52),
                        flags: try commands.u32(base + 64),
                        nreloc: try commands.u32(base + 60)
                    )
                    segmentSections.append(section)
                    sections.append(section)
                }
                segments.append(AnalyzedSegment(name: name, vmaddr: vmaddr, vmsize: vmsize,
                                             fileoff: fileoff, filesize: filesize,
                                             maxprot: maxprot, initprot: initprot,
                                             sections: segmentSections))
            case 0x2: // LC_SYMTAB
                guard size >= 24 else { throw AnalyzerError.malformed("\(label): short LC_SYMTAB") }
                symtab = (UInt64(try commands.u32(cursor + 8)),
                          UInt64(try commands.u32(cursor + 12)),
                          UInt64(try commands.u32(cursor + 16)),
                          UInt64(try commands.u32(cursor + 20)))
            case 0xb: // LC_DYSYMTAB
                guard size >= 80 else { throw AnalyzerError.malformed("\(label): short LC_DYSYMTAB") }
                dysymtab = AnalyzedDysymtab(
                    ilocalsym: try commands.u32(cursor + 8),
                    nlocalsym: try commands.u32(cursor + 12),
                    iextdefsym: try commands.u32(cursor + 16),
                    nextdefsym: try commands.u32(cursor + 20),
                    iundefsym: try commands.u32(cursor + 24),
                    nundefsym: try commands.u32(cursor + 28),
                    indirectsymoff: try commands.u32(cursor + 56),
                    nindirectsyms: try commands.u32(cursor + 60)
                )
            case 0x26: // LC_FUNCTION_STARTS
                guard size >= 16 else { throw AnalyzerError.malformed("\(label): short LC_FUNCTION_STARTS") }
                functionStartsCommand = (UInt64(try commands.u32(cursor + 8)),
                                         UInt64(try commands.u32(cursor + 12)))
            default:
                break
            }
            cursor += size
        }

        guard let text = segments.first(where: { $0.name == "__TEXT" }) else {
            throw AnalyzerError.malformed("\(label): no __TEXT segment")
        }
        let loadAddress: UInt64
        switch backing {
        case .file:
            loadAddress = text.vmaddr
        case .cache:
            guard let headerAddress else { throw AnalyzerError.malformed("\(label): no cache header") }
            loadAddress = headerAddress
        }
        guard loadAddress == text.vmaddr else {
            throw AnalyzerError.malformed("\(label): header address \(Hex.value(loadAddress)) != __TEXT vmaddr \(Hex.value(text.vmaddr))")
        }

        var symbols: [AnalyzedSymbol] = []
        if let symtab, symtab.nsyms > 0 {
            symbols = try readSymbols(label: label, backing: backing, segments: segments,
                                      symtab: symtab)
        }

        var functionStarts: FunctionStartInfo?
        if let functionStartsCommand, functionStartsCommand.datasize > 0 {
            if let starts = try readFunctionStarts(label: label, backing: backing, segments: segments,
                                                   command: functionStartsCommand, text: text) {
                functionStarts = starts
            }
        }

        _ = fileType
        return AnalyzedImage(label: label, path: path, backing: backing, loadAddress: loadAddress,
                          segments: segments, sections: sections, symbols: symbols,
                          dysymtab: dysymtab, functionStarts: functionStarts)
    }

    // MARK: symbol reading

    private static func readSymbols(label: String,
                                    backing: AnalyzedImageBacking,
                                    segments: [AnalyzedSegment],
                                    symtab: (symoff: UInt64, nsyms: UInt64, stroff: UInt64, strsize: UInt64)) throws -> [AnalyzedSymbol] {
        guard symtab.nsyms < 4_000_000, symtab.strsize < 256 * 1024 * 1024 else {
            throw AnalyzerError.malformed("\(label): implausible symbol table size")
        }
        let symbolBytes = try readLinkeditData(label: label, backing: backing, segments: segments,
                                               offset: symtab.symoff, size: symtab.nsyms * 16)
        let stringBytes = try readLinkeditData(label: label, backing: backing, segments: segments,
                                               offset: symtab.stroff, size: symtab.strsize)
        let symbolBuffer = ByteBuffer(symbolBytes, label: "\(label) nlist")
        let stringBuffer = ByteBuffer(stringBytes, label: "\(label) strtab")
        var symbols: [AnalyzedSymbol] = []
        symbols.reserveCapacity(Int(symtab.nsyms))
        for index in 0..<Int(symtab.nsyms) {
            let base = index * 16
            let strx = try symbolBuffer.u32(base)
            let type = try symbolBuffer.u8(base + 4)
            let sect = try symbolBuffer.u8(base + 5)
            let desc = try symbolBuffer.u16(base + 6)
            let value = try symbolBuffer.u64(base + 8)
            var name = ""
            if strx < symtab.strsize {
                name = (try? stringBuffer.cString(Int(strx), limit: Int(symtab.strsize - UInt64(strx)))) ?? ""
            }
            symbols.append(AnalyzedSymbol(name: name, strx: strx, type: type, sect: sect,
                                       desc: desc, value: value))
        }
        return symbols
    }

    /// Reads bytes addressed by a `__LINKEDIT`-relative file offset.
    ///
    /// Standalone images address `__LINKEDIT` data by file offset directly.
    /// Shared-cache images have every image's `__LINKEDIT` mapped at a shared
    /// VM base whose `fileoff` is the subcache file offset, so the table offset
    /// is first converted to a VM address inside that segment. Both conventions
    /// are tried and validated; if neither resolves the data is rejected.
    private static func readLinkeditData(label: String,
                                         backing: AnalyzedImageBacking,
                                         segments: [AnalyzedSegment],
                                         offset: UInt64,
                                         size: UInt64) throws -> Data {
        guard size <= 512 * 1024 * 1024 else {
            throw AnalyzerError.malformed("\(label): implausible linkedit data size \(size)")
        }
        switch backing {
        case let .file(data):
            guard offset <= UInt64(data.count), size <= UInt64(data.count) - offset else {
                throw AnalyzerError.truncated("\(label) linkedit", Int(offset + size), data.count)
            }
            return data.subdata(in: Int(offset)..<Int(offset + size))
        case let .cache(store):
            guard let linkedit = segments.first(where: { $0.name == "__LINKEDIT" }) else {
                throw AnalyzerError.malformed("\(label): cache image without __LINKEDIT")
            }
            var candidates: [UInt64] = []
            if offset >= linkedit.fileoff {
                candidates.append(linkedit.vmaddr + (offset - linkedit.fileoff))
            }
            candidates.append(linkedit.vmaddr + offset)
            for address in candidates {
                if let data = try? store.read(address: address, size: Int(size)) {
                    return data
                }
            }
            throw AnalyzerError.malformed("\(label): cannot resolve __LINKEDIT data at offset \(Hex.value(offset))")
        }
    }

    // MARK: function starts

    private static func readFunctionStarts(label: String,
                                           backing: AnalyzedImageBacking,
                                           segments: [AnalyzedSegment],
                                           command: (dataoff: UInt64, datasize: UInt64),
                                           text: AnalyzedSegment) throws -> FunctionStartInfo? {
        guard command.datasize <= 16 * 1024 * 1024 else { return nil }
        let raw = try readLinkeditData(label: label, backing: backing, segments: segments,
                                       offset: command.dataoff, size: command.datasize)
        let bytes = ByteBuffer(raw, label: "\(label) function starts")
        var starts: [UInt64] = []
        var address = text.vmaddr
        var cursor = 0
        var terminated = false
        while cursor < bytes.count {
            var delta: UInt64 = 0
            var shift: UInt64 = 0
            var byte: UInt8
            repeat {
                byte = try bytes.u8(cursor)
                cursor += 1
                delta |= UInt64(byte & 0x7f) << shift
                shift += 7
                if shift > 63 { throw AnalyzerError.malformed("\(label): overlong function start delta") }
            } while byte & 0x80 != 0
            if delta == 0 {
                terminated = true
                break
            }
            address &+= delta
            starts.append(address)
        }
        guard terminated, starts.count > 1 else { return nil }
        let textEnd = text.vmaddr + text.vmsize
        for start in starts {
            guard start >= text.vmaddr, start < textEnd else {
                throw AnalyzerError.malformed("\(label): function start \(Hex.value(start)) outside __TEXT")
            }
        }
        for index in 1..<starts.count where starts[index] <= starts[index - 1] {
            throw AnalyzerError.malformed("\(label): function starts are not strictly increasing")
        }
        return FunctionStartInfo(starts: starts, source: "LC_FUNCTION_STARTS")
    }

    // MARK: access

    var text: AnalyzedSegment {
        // parse() guarantees __TEXT exists.
        segments.first(where: { $0.name == "__TEXT" })!
    }

    func read(address: UInt64, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        switch backing {
        case let .file(data):
            guard let segment = segments.first(where: { $0.contains(address) && $0.filesize > 0 }) else {
                throw AnalyzerError.truncated("\(label) read", size, 0)
            }
            let delta = address - segment.vmaddr
            guard delta < segment.filesize, UInt64(size) <= segment.filesize - delta else {
                throw AnalyzerError.truncated("\(label) read crosses file segment end", Int(delta) + size, Int(segment.filesize))
            }
            let offset = Int(segment.fileoff + delta)
            guard offset <= data.count, size <= data.count - offset else {
                throw AnalyzerError.truncated("\(label) file read", offset + size, data.count)
            }
            return data.subdata(in: offset..<(offset + size))
        case let .cache(store):
            return try store.read(address: address, size: size)
        }
    }

    /// File offset of a VM address in the pager namespace of the backing file.
    func fileOffset(address: UInt64) throws -> UInt64 {
        switch backing {
        case .file:
            guard let segment = segments.first(where: { address >= $0.vmaddr && address < $0.vmaddr + $0.filesize }) else {
                throw AnalyzerError.truncated("\(label) file offset", 0, 0)
            }
            return segment.fileoff + (address - segment.vmaddr)
        case let .cache(store):
            return try store.fileOffset(address: address)
        }
    }

    func section(seg: String, sect: String) -> AnalyzedSection? {
        sections.first { $0.segname == seg && $0.sectname == sect }
    }

    func symbol(named name: String) -> AnalyzedSymbol? {
        symbolsByName[name]?.first
    }

    func symbols(containing address: UInt64) -> [AnalyzedSymbol] {
        symbols.filter { $0.isDefined && $0.value == address }
    }

    /// Resolves a function extent from LC_FUNCTION_STARTS (primary) with a
    /// symbol-table-based fallback. The extent must be inside `__TEXT`.
    func functionExtent(symbolAddress: UInt64, functionName: String) throws -> (start: UInt64, end: UInt64, source: String) {
        let text = self.text
        let textEnd = text.vmaddr + text.vmsize
        guard symbolAddress >= text.vmaddr, symbolAddress < textEnd else {
            throw AnalyzerError.malformed("function \(functionName) address \(Hex.value(symbolAddress)) outside __TEXT")
        }
        if let functionStarts, let index = functionStarts.starts.firstIndex(of: symbolAddress) {
            let end = index + 1 < functionStarts.starts.count ? functionStarts.starts[index + 1] : textEnd
            guard end > symbolAddress else {
                throw AnalyzerError.malformed("function \(functionName) has empty extent")
            }
            return (symbolAddress, end, functionStarts.source)
        }
        let defined = symbols
            .filter { $0.isDefined && $0.value > symbolAddress && $0.value < textEnd }
            .map(\.value)
            .sorted()
        if let next = defined.first {
            return (symbolAddress, next, "next-symbol")
        }
        guard textEnd > symbolAddress else {
            throw AnalyzerError.malformed("function \(functionName) at end of __TEXT")
        }
        return (symbolAddress, textEnd, "__TEXT-end")
    }

    /// The 4 KiB page that contains `address`, read from the backing image.
    func pageBytes(containing address: UInt64) throws -> (pageStart: UInt64, bytes: Data) {
        guard address >= loadAddress else {
            throw AnalyzerError.malformed("address \(Hex.value(address)) before image base")
        }
        let pageStart = address & ~UInt64(0xfff)
        let page = try read(address: pageStart, size: 0x1000)
        guard page.count == 0x1000 else {
            throw AnalyzerError.truncated("\(label) page", 0x1000, page.count)
        }
        return (pageStart, page)
    }

    /// All 4 KiB pages reachable through the image's byte ranges, for the
    /// generator's false-positive scan. Pages are emitted once.
    func fileBackedPages() -> [(pageStart: UInt64, fileOffset: UInt64)] {
        var pages: Set<UInt64> = []
        var result: [(UInt64, UInt64)] = []
        for segment in segments where segment.filesize > 0 {
            var address = segment.vmaddr & ~UInt64(0xfff)
            let end = segment.vmaddr + segment.filesize
            while address < end {
                if !pages.contains(address) {
                    pages.insert(address)
                    result.append((address, segment.fileoff + (address - segment.vmaddr)))
                }
                address &+= 0x1000
            }
        }
        return result
    }
}

// MARK: - dyld shared cache

struct CacheFileMapping {
    let address: UInt64
    let size: UInt64
    let fileOffset: UInt64
    let fileURL: URL
}

struct DyldCacheImageReference {
    let address: UInt64
    let textSize: UInt64
    let path: String
}

/// Reader for a split dyld shared cache: unions the per-subcache mapping tables,
/// resolves image paths through the image-text array and translates VM addresses
/// to (subcache file, file offset) pairs. No address is guessed; every read is
/// validated against a mapping.
final class DyldCacheStore {
    let directory: URL
    let mappings: [CacheFileMapping]
    let images: [DyldCacheImageReference]
    private var handles: [String: FileHandle] = [:]
    private let lock = NSLock()

    init(directory: URL) throws {
        self.directory = directory
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("dyld_shared_cache_") }
                .filter {
                    // Only cache data files: skip map/atlas/symbols sidecars. Split
                    // caches have numeric suffixes (.01..., .06) that are real data.
                    let name = $0.lastPathComponent
                    return !name.hasSuffix(".map") && !name.hasSuffix(".atlas")
                        && !name.hasSuffix(".symbols")
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw AnalyzerError.io("cannot list dyld cache directory \(directory.path): \(error.localizedDescription)")
        }
        guard !files.isEmpty else {
            throw AnalyzerError.notFound("no dyld shared cache files in \(directory.path)")
        }

        var mappings: [CacheFileMapping] = []
        var mainHeader: Data?
        var mainFile: URL?
        for file in files {
            let headerData: Data
            do {
                let handle = try FileHandle(forReadingFrom: file)
                headerData = (try handle.read(upToCount: 0x400)) ?? Data()
                try handle.close()
            } catch {
                throw AnalyzerError.io("cannot read cache header \(file.path): \(error.localizedDescription)")
            }
            guard headerData.count >= 0x100 else { continue }
            let header = ByteBuffer(headerData, label: "\(file.lastPathComponent) header")
            let magic = try header.cString(0, limit: 16)
            guard magic.hasPrefix("dyld_v1") else { continue }
            if mainHeader == nil || file.lastPathComponent == files[0].lastPathComponent {
                // The unsuffixed main cache file carries the image-text array.
                if !file.lastPathComponent.contains(".") || mainHeader == nil {
                    mainHeader = headerData
                    mainFile = file
                }
            }
            let mappingOffset = Int(try header.u32(0x10))
            let mappingCount = Int(try header.u32(0x14))
            guard mappingCount > 0, mappingCount < 64 else {
                throw AnalyzerError.malformed("\(file.lastPathComponent): mapping count \(mappingCount)")
            }
            let table = ByteBuffer(try Self.readFile(file: file, offset: UInt64(mappingOffset),
                                                size: mappingCount * 32), label: "\(file.lastPathComponent) mappings")
            for index in 0..<mappingCount {
                let base = index * 32
                let mapping = CacheFileMapping(
                    address: try table.u64(base),
                    size: try table.u64(base + 8),
                    fileOffset: try table.u64(base + 16),
                    fileURL: file
                )
                guard mapping.size > 0 else {
                    throw AnalyzerError.malformed("\(file.lastPathComponent): empty cache mapping")
                }
                mappings.append(mapping)
            }
        }
        guard !mappings.isEmpty else {
            throw AnalyzerError.notFound("dyld cache has no mappings")
        }
        mappings.sort { $0.address < $1.address }
        for index in 1..<mappings.count where mappings[index].address < mappings[index - 1].address + mappings[index - 1].size {
            throw AnalyzerError.malformed("dyld cache mappings overlap at \(Hex.value(mappings[index].address))")
        }
        self.mappings = mappings
        guard let mainHeader, let mainFile else {
            throw AnalyzerError.notFound("dyld cache main file not found")
        }
        self.images = try DyldCacheStore.readImageList(header: mainHeader, mainFile: mainFile,
                                                       directory: directory, mappings: mappings)
    }

    private static func readFile(file: URL, offset: UInt64, size: Int) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw AnalyzerError.io("cannot open \(file.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: size), data.count == size else {
                throw AnalyzerError.truncated("\(file.lastPathComponent) @\(Hex.value(offset))", size, 0)
            }
            return data
        } catch let error as AnalyzerError {
            throw error
        } catch {
            throw AnalyzerError.io("cannot read \(file.path): \(error.localizedDescription)")
        }
    }

    /// Parses the image-text array. The array location is discovered from the
    /// documented header field candidates and validated structurally; if no
    /// candidate validates, the `.map` sidecar is used as a documented fallback.
    private static func readImageList(header: Data, mainFile: URL, directory: URL,
                                      mappings: [CacheFileMapping]) throws -> [DyldCacheImageReference] {
        let buffer = ByteBuffer(header, label: "dyld cache main header")
        // Candidate (imagesTextOffset, imagesTextCount) field pairs. The first is
        // the layout of the macOS 15/26 dyld4 caches; the others are older layouts.
        let candidates: [(UInt64, UInt64)] = [
            (try? buffer.u64(0x88)).map { ($0, (try? buffer.u64(0x90)) ?? 0) } ?? (0, 0),
            (try? buffer.u64(0x98)).map { ($0, (try? buffer.u64(0xa0)) ?? 0) } ?? (0, 0),
            (0, 0)
        ]
        for (offset, count) in candidates where offset > 0 && count > 0 {
            do {
                let images = try parseImageList(offset: offset, count: count, mainFile: mainFile,
                                                mappings: mappings)
                if !images.isEmpty { return images }
            } catch {
                if ProcessInfo.processInfo.environment["NRED_ANALYZER_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("image-list candidate @\(offset) count \(count) failed: \(error)\n".utf8))
                }
            }
        }
        do {
            return try parseImageMap(directory: directory, mappings: mappings)
        } catch {
            if ProcessInfo.processInfo.environment["NRED_ANALYZER_DEBUG"] != nil {
                FileHandle.standardError.write(Data(".map image list failed: \(error)\n".utf8))
            }
            throw error
        }
    }

    private static func parseImageList(offset: UInt64, count: UInt64, mainFile: URL,
                                       mappings: [CacheFileMapping]) throws -> [DyldCacheImageReference] {
        guard count >= 16, count < 100_000 else { return [] }
        let raw = try readFile(file: mainFile, offset: offset, size: Int(count) * 32)
        let buffer = ByteBuffer(raw, label: "image text array")
        var images: [DyldCacheImageReference] = []
        images.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            // dyld_cache_image_text_info: uuid[16], loadAddress, textSegmentSize, pathFileOffset
            let base = index * 32
            let address = try buffer.u64(base + 16)
            let size = UInt64(try buffer.u32(base + 24))
            let pathOffset = UInt64(try buffer.u32(base + 28))
            let lowBound = mappings[0].address
            let highBound = mappings[mappings.count - 1].address + mappings[mappings.count - 1].size
            guard address >= lowBound, address < highBound,
                  size > 0, size < 0x4000_0000 else {
                throw AnalyzerError.malformed(
                    "image text info \(index) has implausible fields addr=\(Hex.value(address)) size=\(Hex.value(size)) bounds=\(Hex.value(lowBound))..\(Hex.value(highBound))")
            }
            guard pathOffset < UInt64(try readFileSize(mainFile)) else {
                throw AnalyzerError.malformed("image text info path offset out of file")
            }
            let path = try readFilePath(nameOffset: pathOffset, mainFile: mainFile)
            images.append(DyldCacheImageReference(address: address, textSize: size, path: path))
        }
        // Validate a prefix of the image list against real Mach-O headers.
        let sampleCount = min(64, images.count)
        var validated = 0
        for image in images.prefix(sampleCount) {
            guard let mapping = mappings.first(where: { image.address >= $0.address && image.address + 4 <= $0.address + $0.size }) else {
                continue
            }
            let data = try readFile(file: mapping.fileURL, offset: mapping.fileOffset + (image.address - mapping.address), size: 4)
            let magic = (try? ByteBuffer(data).u32(0)) ?? 0
            if magic == 0xfeedfacf { validated += 1 }
        }
        guard validated >= sampleCount * 3 / 4, validated > 0 else {
            throw AnalyzerError.malformed("image text array did not validate")
        }
        return images
    }

    private static func readFilePath(nameOffset: UInt64, mainFile: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: mainFile)
        } catch {
            throw AnalyzerError.io("cannot open \(mainFile.path)")
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: nameOffset)
            guard let data = try handle.read(upToCount: 4096), data.count > 0 else {
                throw AnalyzerError.truncated("cache image path", 1, 0)
            }
            let bytes = [UInt8](data)
            guard let zero = bytes.firstIndex(of: 0) else {
                throw AnalyzerError.malformed("cache image path is not NUL terminated")
            }
            let path = String(decoding: bytes[0..<zero], as: UTF8.self)
            return path
        } catch let error as AnalyzerError {
            throw error
        } catch {
            throw AnalyzerError.io("cannot read cache image path: \(error.localizedDescription)")
        }
    }

    private static func readFileSize(_ file: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Fallback image locator using the documented `dyld_shared_cache*.map` text file.
    private static func parseImageMap(directory: URL, mappings: [CacheFileMapping]) throws -> [DyldCacheImageReference] {
        let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".map") }
        guard let mapURL = candidates.first(where: { $0.lastPathComponent.contains("x86_64h") }) ?? candidates.first else {
            throw AnalyzerError.notFound("no dyld cache .map file in \(directory.path)")
        }
        let text: String
        do {
            text = try String(contentsOf: mapURL, encoding: .utf8)
        } catch {
            throw AnalyzerError.io("cannot read \(mapURL.path): \(error.localizedDescription)")
        }
        let lines = text.components(separatedBy: .newlines)
        var images: [DyldCacheImageReference] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("/"), !line.contains(" ") {
                var address: UInt64?
                var size: UInt64?
                var scan = index + 1
                while scan < lines.count, scan <= index + 32 {
                    let candidate = lines[scan].trimmingCharacters(in: .whitespaces)
                    let fields = candidate.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    if fields.count >= 2, fields[0] == "__TEXT" {
                        var startToken: String?
                        var endToken: String?
                        for (fieldIndex, field) in fields.enumerated() {
                            if field.contains("->") {
                                let parts = field.components(separatedBy: "->")
                                if parts.count == 2 {
                                    startToken = parts[0]
                                    endToken = parts[1]
                                }
                            } else if field == "->", fieldIndex > 0, fieldIndex + 1 < fields.count {
                                startToken = fields[fieldIndex - 1]
                                endToken = fields[fieldIndex + 1]
                            }
                            if startToken != nil, endToken != nil { break }
                        }
                        func parseAddress(_ token: String) -> UInt64? {
                            UInt64(token.replacingOccurrences(of: "0x", with: ""), radix: 16)
                        }
                        if let startToken, let endToken,
                           let start = parseAddress(startToken), let end = parseAddress(endToken), end > start {
                            address = start
                            size = end - start
                            break
                        }
                    }
                    if candidate.hasPrefix("/"), !candidate.contains(" ") { break }
                    scan += 1
                }
                if let address, let size, size > 0,
                   mappings.contains(where: { address >= $0.address && address < $0.address + $0.size }) {
                    images.append(DyldCacheImageReference(address: address, textSize: size, path: line))
                    index = scan
                }
            }
            index += 1
        }
        guard !images.isEmpty else {
            throw AnalyzerError.malformed("cannot locate cache images from .map")
        }
        return images
    }

    // MARK: access

    func image(pathSuffix: String) throws -> DyldCacheImageReference {
        let matches = images.filter { image in
            image.path == pathSuffix
                || image.path.hasSuffix("/" + pathSuffix)
                || image.path.hasSuffix(pathSuffix)
        }
        guard matches.count == 1 else {
            if matches.isEmpty {
                throw AnalyzerError.notFound("cache image \(pathSuffix)")
            }
            throw AnalyzerError.ambiguous("cache image \(pathSuffix) matches \(matches.count) images")
        }
        return matches[0]
    }

    func mapping(for address: UInt64) -> CacheFileMapping? {
        mappings.first { address >= $0.address && address < $0.address + $0.size }
    }

    func fileOffset(address: UInt64) throws -> UInt64 {
        guard let mapping = mapping(for: address) else {
            throw AnalyzerError.malformed("address \(Hex.value(address)) is not in the dyld cache")
        }
        return mapping.fileOffset + (address - mapping.address)
    }

    func read(address: UInt64, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        guard let mapping = mapping(for: address) else {
            throw AnalyzerError.malformed("address \(Hex.value(address)) is not in the dyld cache")
        }
        let delta = address - mapping.address
        guard UInt64(size) <= mapping.size - delta else {
            throw AnalyzerError.truncated("cache read at \(Hex.value(address))", size, Int(mapping.size - delta))
        }
        let handle = try handle(for: mapping.fileURL)
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.seek(toOffset: mapping.fileOffset + delta)
            guard let data = try handle.read(upToCount: size), data.count == size else {
                throw AnalyzerError.truncated("cache file read at \(Hex.value(address))", size, 0)
            }
            return data
        } catch let error as AnalyzerError {
            throw error
        } catch {
            throw AnalyzerError.io("cache read failed: \(error.localizedDescription)")
        }
    }

    private func handle(for file: URL) throws -> FileHandle {
        lock.lock()
        defer { lock.unlock() }
        if let handle = handles[file.path] { return handle }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw AnalyzerError.io("cannot open \(file.path): \(error.localizedDescription)")
        }
        handles[file.path] = handle
        return handle
    }
}
