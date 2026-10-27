import Foundation

struct MachOSegment {
    let name: String
    let vmaddr: UInt64
    let vmsize: UInt64
    let fileoff: UInt64
    let filesize: UInt64
}

struct MachOSymbol {
    let name: String
    let value: UInt64
    let type: UInt8
}

struct MachOImage {
    let textStart: UInt64
    let segments: [MachOSegment]
    let symbols: [MachOSymbol]

    func symbol(containing address: UInt64) -> MachOSymbol? {
        symbols
            .filter { $0.value <= address && $0.type & 0x0e != 0 }
            .max { $0.value < $1.value }
    }
}

enum MachOError: LocalizedError {
    case badMagic
    case truncated
    case missingText
    case missingLinkedit
    case missingSymtab

    var errorDescription: String? {
        switch self {
        case .badMagic: return "不是 64 位 Mach-O"
        case .truncated: return "Mach-O 数据被截断"
        case .missingText: return "缺少 __TEXT segment"
        case .missingLinkedit: return "缺少 __LINKEDIT segment"
        case .missingSymtab: return "缺少 LC_SYMTAB"
        }
    }
}

enum MachOParser {
    static func parseFile(at url: URL) throws -> MachOImage {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> MachOImage {
        guard data.count >= 32 else { throw MachOError.truncated }
        let magic = readU32(data, 0)
        guard magic == 0xfeedfacf else { throw MachOError.badMagic }

        let ncmds = Int(readU32(data, 16))
        let sizeofcmds = Int(readU32(data, 20))
        guard 32 + sizeofcmds <= data.count else { throw MachOError.truncated }

        var segments: [MachOSegment] = []
        var symtab: (symoff: Int, nsyms: Int, stroff: Int, strsize: Int)?
        var offset = 32

        for _ in 0..<ncmds {
            guard offset + 8 <= data.count else { throw MachOError.truncated }
            let cmd = readU32(data, offset)
            let size = Int(readU32(data, offset + 4))
            guard size >= 8, offset + size <= data.count else { throw MachOError.truncated }

            if cmd == 0x19 {
                let name = readCString(data, offset + 8, 16)
                let segment = MachOSegment(
                    name: name,
                    vmaddr: readU64(data, offset + 24),
                    vmsize: readU64(data, offset + 32),
                    fileoff: readU64(data, offset + 40),
                    filesize: readU64(data, offset + 48)
                )
                segments.append(segment)
            } else if cmd == 0x2 {
                symtab = (Int(readU32(data, offset + 8)),
                           Int(readU32(data, offset + 12)),
                           Int(readU32(data, offset + 16)),
                           Int(readU32(data, offset + 20)))
            }
            offset += size
        }

        guard let text = segments.first(where: { $0.name == "__TEXT" }) else { throw MachOError.missingText }
        guard let linkedit = segments.first(where: { $0.name == "__LINKEDIT" }) else { throw MachOError.missingLinkedit }
        guard let symtab else { throw MachOError.missingSymtab }

        var symbols: [MachOSymbol] = []
        if symtab.nsyms > 0,
           symtab.symoff + symtab.nsyms * 16 <= data.count,
           symtab.stroff + symtab.strsize <= data.count
        {
            for index in 0..<symtab.nsyms {
                let base = symtab.symoff + index * 16
                let strx = Int(readU32(data, base))
                let type = data[base + 4]
                let value = readU64(data, base + 8)
                let name = readCString(data, symtab.stroff + strx, max(0, symtab.strsize - strx))
                symbols.append(MachOSymbol(name: name, value: value, type: type))
            }
        }

        return MachOImage(textStart: text.vmaddr, segments: segments, symbols: symbols)
    }

    static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { pointer in
            pointer.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        return data.withUnsafeBytes { pointer in
            pointer.load(fromByteOffset: offset, as: UInt64.self).littleEndian
        }
    }

    static func readCString(_ data: Data, _ offset: Int, _ maxLength: Int) -> String {
        guard offset < data.count, maxLength > 0 else { return "" }
        let end = min(data.count, offset + maxLength)
        let slice = data[offset..<end]
        if let zero = slice.firstIndex(of: 0) {
            return String(data: data[offset..<zero], encoding: .utf8) ?? ""
        }
        return String(data: slice, encoding: .utf8) ?? ""
    }
}
