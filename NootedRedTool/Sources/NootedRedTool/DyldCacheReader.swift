import Foundation

struct DyldCacheMapping {
    let address: UInt64
    let size: UInt64
    let fileOffset: UInt64
    let handle: FileHandle
}

final class DyldCacheReader {
    static let defaultDirectory = URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld")

    private let directory: URL
    private var mappings: [DyldCacheMapping] = []
    private var handles: [FileHandle] = []

    init(directory: URL = defaultDirectory) throws {
        self.directory = directory
        try loadMappings()
    }

    deinit {
        for handle in handles {
            try? handle.close()
        }
    }

    func fileOffset(for address: UInt64) throws -> UInt64 {
        guard let mapping = mappings.first(where: { address >= $0.address && address < $0.address + $0.size }) else {
            throw CacheError.unmapped
        }
        return mapping.fileOffset + (address - mapping.address)
    }

    func read(address: UInt64, size: Int) throws -> Data {
        guard let mapping = mappings.first(where: { address >= $0.address && address + UInt64(size) <= $0.address + $0.size }) else {
            throw CacheError.unmapped
        }
        try mapping.handle.seek(toOffset: mapping.fileOffset + (address - mapping.address))
        let data = mapping.handle.readData(ofLength: size)
        guard data.count == size else { throw CacheError.truncated }
        return data
    }

    func textStart(forImage suffix: String) throws -> UInt64 {
        let mapURL = directory.appendingPathComponent("dyld_shared_cache_x86_64h.map")
        let text = try String(contentsOf: mapURL, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed == suffix || trimmed.hasSuffix("/" + suffix) else { continue }
            for following in lines[(index + 1)...] {
                let fields = following.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if fields.count >= 2, fields[0] == "__TEXT" {
                    return UInt64(fields[1].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
                }
            }
        }
        throw CacheError.imageNotFound(suffix)
    }

    func image(at suffix: String) throws -> MachOImage {
        let textStart = try textStart(forImage: suffix)
        return try parseImage(textStart: textStart)
    }

    private func parseImage(textStart: UInt64) throws -> MachOImage {
        let header = try read(address: textStart, size: 32)
        guard MachOParser.readU32(header, 0) == 0xfeedfacf else { throw MachOError.badMagic }
        let ncmds = Int(MachOParser.readU32(header, 16))
        let sizeofcmds = Int(MachOParser.readU32(header, 20))
        let commands = try read(address: textStart + 32, size: sizeofcmds)

        var segments: [MachOSegment] = []
        var symtab: (symoff: Int, nsyms: Int, stroff: Int, strsize: Int)?
        var offset = 0
        for _ in 0..<ncmds {
            let cmd = MachOParser.readU32(commands, offset)
            let size = Int(MachOParser.readU32(commands, offset + 4))
            if cmd == 0x19 {
                segments.append(MachOSegment(
                    name: MachOParser.readCString(commands, offset + 8, 16),
                    vmaddr: MachOParser.readU64(commands, offset + 24),
                    vmsize: MachOParser.readU64(commands, offset + 32),
                    fileoff: MachOParser.readU64(commands, offset + 40),
                    filesize: MachOParser.readU64(commands, offset + 48)
                ))
            } else if cmd == 0x2 {
                symtab = (Int(MachOParser.readU32(commands, offset + 8)),
                           Int(MachOParser.readU32(commands, offset + 12)),
                           Int(MachOParser.readU32(commands, offset + 16)),
                           Int(MachOParser.readU32(commands, offset + 20)))
            }
            offset += size
        }

        guard let text = segments.first(where: { $0.name == "__TEXT" }) else { throw MachOError.missingText }
        guard let linkedit = segments.first(where: { $0.name == "__LINKEDIT" }) else { throw MachOError.missingLinkedit }
        guard let symtab else { throw MachOError.missingSymtab }

        var symbols: [MachOSymbol] = []
        if symtab.nsyms > 0 {
            let symbolAddress = linkedit.vmaddr + UInt64(symtab.symoff) - linkedit.fileoff
            let stringAddress = linkedit.vmaddr + UInt64(symtab.stroff) - linkedit.fileoff
            let symbolData = try read(address: symbolAddress, size: symtab.nsyms * 16)
            let stringData = try read(address: stringAddress, size: symtab.strsize)
            for index in 0..<symtab.nsyms {
                let base = index * 16
                let strx = Int(MachOParser.readU32(symbolData, base))
                let type = symbolData[base + 4]
                let value = MachOParser.readU64(symbolData, base + 8)
                let name = MachOParser.readCString(stringData, strx, max(0, symtab.strsize - strx))
                symbols.append(MachOSymbol(name: name, value: value, type: type))
            }
        }

        return MachOImage(textStart: text.vmaddr, segments: segments, symbols: symbols)
    }

    private func loadMappings() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.lastPathComponent.hasPrefix("dyld_shared_cache_x86_64h") {
            if file.pathExtension == "map" || file.pathExtension == "atlas" { continue }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let header = try handle.read(upToCount: 0x68) ?? Data()
            guard header.count >= 0x68, String(data: header.prefix(8), encoding: .ascii)?.hasPrefix("dyld_v1") == true else {
                try? handle.close()
                continue
            }
            let mappingOffset = Int(MachOParser.readU32(header, 16))
            let mappingCount = Int(MachOParser.readU32(header, 20))
            try handle.seek(toOffset: UInt64(mappingOffset))
            let raw = try handle.read(upToCount: mappingCount * 32) ?? Data()
            guard raw.count == mappingCount * 32 else {
                try? handle.close()
                continue
            }
            handles.append(handle)
            for index in 0..<mappingCount {
                let base = index * 32
                let address = MachOParser.readU64(raw, base)
                let size = MachOParser.readU64(raw, base + 8)
                let fileOffset = MachOParser.readU64(raw, base + 16)
                mappings.append(DyldCacheMapping(address: address, size: size, fileOffset: fileOffset, handle: handle))
            }
        }
        guard !mappings.isEmpty else { throw CacheError.noMappings }
    }
}

enum CacheError: LocalizedError {
    case noMappings
    case unmapped
    case truncated
    case imageNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noMappings: return "没有找到 dyld shared cache mapping"
        case .unmapped: return "地址不在 dyld shared cache 中"
        case .truncated: return "dyld shared cache 读取不完整"
        case .imageNotFound(let suffix): return "未在 cache map 中找到 \(suffix)"
        }
    }
}
