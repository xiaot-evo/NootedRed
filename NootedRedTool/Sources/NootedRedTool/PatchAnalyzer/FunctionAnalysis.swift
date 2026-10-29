import Foundation

// MARK: - Basic blocks and function analysis

struct BasicBlock {
    let index: Int
    let start: UInt64
    let instructionRange: Range<Int>
    let successors: [Int]

    var end: UInt64 {
        instructionRange.isEmpty ? start : start
    }
}

/// A fully decoded, CFG-validated function. `instructions` cover every byte of
/// `[start, end)` with no gaps; every direct intra-function branch target is an
/// instruction boundary. Any violation throws instead of degrading.
struct FunctionAnalysis {
    let imageLabel: String
    let functionName: String
    let start: UInt64
    let end: UInt64
    let extentSource: String
    let instructions: [DecodedInstruction]
    let blocks: [BasicBlock]
    let reachableBlocks: Set<Int>
    private let instructionIndexByAddress: [UInt64: Int]
    private let blockIndexByStart: [UInt64: Int]
    private let blockIndexByInstruction: [Int]

    init(imageLabel: String, functionName: String, start: UInt64, end: UInt64,
         extentSource: String, instructions: [DecodedInstruction], blocks: [BasicBlock],
         reachableBlocks: Set<Int>) {
        self.imageLabel = imageLabel
        self.functionName = functionName
        self.start = start
        self.end = end
        self.extentSource = extentSource
        self.instructions = instructions
        self.blocks = blocks
        self.reachableBlocks = reachableBlocks
        var byAddress: [UInt64: Int] = [:]
        byAddress.reserveCapacity(instructions.count)
        for (index, instruction) in instructions.enumerated() {
            byAddress[instruction.address] = index
        }
        self.instructionIndexByAddress = byAddress
        var byBlockStart: [UInt64: Int] = [:]
        var byInstruction: [Int] = Array(repeating: -1, count: instructions.count)
        for block in blocks {
            byBlockStart[block.start] = block.index
            for index in block.instructionRange {
                byInstruction[index] = block.index
            }
        }
        self.blockIndexByStart = byBlockStart
        self.blockIndexByInstruction = byInstruction
    }

    var instructionCount: Int { instructions.count }

    func instructionIndex(at address: UInt64) -> Int? { instructionIndexByAddress[address] }

    func instruction(at address: UInt64) -> DecodedInstruction? {
        instructionIndexByAddress[address].map { instructions[$0] }
    }

    func blockIndex(forStart start: UInt64) -> Int? { blockIndexByStart[start] }

    func blockIndex(containing address: UInt64) -> Int? {
        guard let index = instructionIndexByAddress[address] else { return nil }
        let block = blockIndexByInstruction[index]
        return block >= 0 ? block : nil
    }

    func block(containing address: UInt64) -> BasicBlock? {
        blockIndex(containing: address).map { blocks[$0] }
    }

    func block(at index: Int) -> BasicBlock { blocks[index] }

    func instructions(inBlock index: Int) -> ArraySlice<DecodedInstruction> {
        let block = blocks[index]
        return instructions[block.instructionRange]
    }

    func predecessors(ofBlock index: Int) -> [Int] {
        blocks.filter { $0.successors.contains(index) }.map(\.index)
    }

    func nextInstruction(after instruction: DecodedInstruction) -> DecodedInstruction? {
        guard let index = instructionIndexByAddress[instruction.address], index + 1 < instructions.count else {
            return nil
        }
        return instructions[index + 1]
    }

    func previousInstruction(before instruction: DecodedInstruction) -> DecodedInstruction? {
        guard let index = instructionIndexByAddress[instruction.address], index > 0 else { return nil }
        return instructions[index - 1]
    }

    func isReachable(_ address: UInt64) -> Bool {
        guard let blockIndex = blockIndex(containing: address) else { return false }
        return reachableBlocks.contains(blockIndex)
    }

    /// The conditional branch whose fall-through block starts with `address`, if any.
    func controllingConditionalBranch(fallingThroughTo address: UInt64) -> DecodedInstruction? {
        guard let blockIndex = blockIndex(forStart: address) else { return nil }
        for predecessor in predecessors(ofBlock: blockIndex) {
            let block = blocks[predecessor]
            guard let last = instructions(inBlock: predecessor).last, last.isConditionalBranch else { continue }
            guard let target = last.directBranchTarget else { continue }
            if target != address {
                return last
            }
        }
        return nil
    }

    func evidenceSummary() -> [String: Any] {
        var dictionary: [String: Any] = [
            "image": imageLabel,
            "function": functionName,
            "start": Hex.value(start),
            "end": Hex.value(end),
            "extentSource": extentSource,
            "instructions": instructions.count,
            "blocks": blocks.count
        ]
        dictionary["reachableBlocks"] = reachableBlocks.count
        return dictionary
    }
}

// MARK: - CFG builder

enum FunctionAnalyzer {
    /// Largest function body the analyzer will decode. Anything bigger is a
    /// symbol/bounds problem, not a legitimate patch target.
    static let maximumExtent: UInt64 = 0x40000

    static func analyze(image: AnalyzedImage, symbol: AnalyzedSymbol, decoder: X86Decoder) throws -> FunctionAnalysis {
        try analyze(image: image, name: symbol.name, address: symbol.value, decoder: decoder)
    }

    static func analyze(image: AnalyzedImage, name: String, address: UInt64, decoder: X86Decoder) throws -> FunctionAnalysis {
        let extent = try image.functionExtent(symbolAddress: address, functionName: name)
        guard extent.end > extent.start else {
            throw AnalyzerError.malformed("\(image.label): empty function extent for \(name)")
        }
        guard extent.end - extent.start <= maximumExtent else {
            throw AnalyzerError.malformed(
                "\(image.label): function \(name) extent \(Hex.value(extent.end - extent.start)) exceeds analyzer limit")
        }
        let size = Int(extent.end - extent.start)
        let bytes = [UInt8](try image.read(address: extent.start, size: size))
        let instructions = try decoder.decode(bytes: bytes, address: extent.start)
        guard !instructions.isEmpty else {
            throw AnalyzerError.malformed("\(image.label): no instructions decoded for \(name)")
        }
        // Full coverage: every byte of the extent belongs to exactly one decoded
        // instruction. A gap means the body contains data/undecodable bytes; the
        // function cannot be used as semantic evidence.
        var cursor = extent.start
        for instruction in instructions {
            guard instruction.address == cursor else {
                throw AnalyzerError.malformed(
                    "\(image.label): \(name) instruction stream gap/overlap at \(Hex.value(cursor))")
            }
            cursor = instruction.endAddress
        }
        guard cursor == extent.end else {
            throw AnalyzerError.malformed(
                "\(image.label): \(name) function body not fully decodable: \(Hex.value(cursor))..\(Hex.value(extent.end))")
        }

        var instructionIndexByAddress: [UInt64: Int] = [:]
        for (index, instruction) in instructions.enumerated() {
            instructionIndexByAddress[instruction.address] = index
        }
        func isBoundary(_ address: UInt64) -> Bool {
            instructionIndexByAddress[address] != nil
        }

        // Leaders: entry, branch targets, and instructions after control-transfer
        // instructions (which cannot be fall-through code).
        var fallOffBlockLeaders: Set<UInt64> = []
        var leaders: Set<UInt64> = [extent.start]
        for instruction in instructions {
            if instruction.isConditionalBranch || instruction.isJump {
                guard let target = instruction.directBranchTarget else { continue }
                if target >= extent.start, target < extent.end {
                    guard isBoundary(target) else {
                        throw AnalyzerError.malformed(
                            "\(image.label): \(name) branch target \(Hex.value(target)) is not an instruction boundary")
                    }
                    leaders.insert(target)
                }
            }
            if instruction.isConditionalBranch || instruction.isJump || instruction.isReturn
                || instruction.isInterrupt || instruction.isHalt {
                let next = instruction.endAddress
                if next < extent.end {
                    guard isBoundary(next) else {
                        throw AnalyzerError.malformed(
                            "\(image.label): \(name) no instruction boundary after \(Hex.value(instruction.address))")
                    }
                    leaders.insert(next)
                }
            }
        }
        let sortedLeaders = leaders.sorted()
        var blocks: [BasicBlock] = []
        for (blockIndex, leader) in sortedLeaders.enumerated() {
            guard let firstInstruction = instructionIndexByAddress[leader] else {
                throw AnalyzerError.malformed("\(image.label): \(name) block leader \(Hex.value(leader)) is not decoded")
            }
            let nextLeader = blockIndex + 1 < sortedLeaders.count ? sortedLeaders[blockIndex + 1] : extent.end
            guard firstInstruction < instructions.count else {
                throw AnalyzerError.malformed("\(image.label): \(name) malformed block leader table")
            }
            var endIndex = firstInstruction
            while endIndex < instructions.count, instructions[endIndex].address < nextLeader {
                endIndex += 1
            }
            guard endIndex > firstInstruction,
                  instructions[endIndex - 1].endAddress == nextLeader else {
                throw AnalyzerError.malformed("\(image.label): \(name) block ended mid-instruction")
            }
            var successors: [Int] = []
            let range = firstInstruction..<endIndex
            let terminator = instructions[endIndex - 1]
            if terminator.isConditionalBranch {
                if let target = terminator.directBranchTarget, target >= extent.start, target < extent.end {
                    guard let targetBlock = indexForLeader(target, in: sortedLeaders) else {
                        throw AnalyzerError.malformed("\(image.label): \(name) missing block for target")
                    }
                    successors.append(targetBlock)
                } else if terminator.directBranchTarget != nil {
                    throw AnalyzerError.malformed(
                        "\(image.label): \(name) conditional branch leaves function at \(Hex.value(terminator.address))")
                }
                if nextLeader < extent.end {
                    guard let fallthroughBlock = indexForLeader(nextLeader, in: sortedLeaders) else {
                        throw AnalyzerError.malformed("\(image.label): \(name) missing fall-through block")
                    }
                    successors.append(fallthroughBlock)
                } else {
                    fallOffBlockLeaders.insert(leader)
                }
            } else if terminator.isJump {
                if let target = terminator.directBranchTarget, target >= extent.start, target < extent.end {
                    guard let targetBlock = indexForLeader(target, in: sortedLeaders) else {
                        throw AnalyzerError.malformed("\(image.label): \(name) missing jump block")
                    }
                    successors.append(targetBlock)
                }
                // Direct jump outside the extent is a tail call; indirect jump is a
                // computed transfer. Both terminate the block.
            } else if terminator.isReturn || terminator.isInterrupt || terminator.isHalt {
                // Terminal.
            } else if terminator.isCall && nextLeader >= extent.end {
                // A function may legitimately end with a call to a noreturn helper
                // (assert/abort/throw); there is no fall-through into the next
                // function in that case.
            } else if terminator.isPadding && nextLeader >= extent.end {
                // Trailing alignment padding inside the reported function extent.
            } else {
                // Implicit fall-through.
                if nextLeader < extent.end {
                    guard blockIndex + 1 < sortedLeaders.count,
                          let fallthroughBlock = indexForLeader(nextLeader, in: sortedLeaders) else {
                        throw AnalyzerError.malformed("\(image.label): \(name) missing fall-through block")
                    }
                    successors.append(fallthroughBlock)
                } else {
                    // Trailing padding after a terminator is unreachable; only a
                    // reachable block falling off the end is a CFG error. The
                    // reachability check happens after all blocks are built.
                    fallOffBlockLeaders.insert(leader)
                }
            }
            blocks.append(BasicBlock(index: blockIndex, start: leader, instructionRange: range,
                                     successors: successors))
        }

        // Reachability from the entry block.
        var reachable: Set<Int> = []
        var work: [Int] = [0]
        while let index = work.popLast() {
            guard index < blocks.count, reachable.insert(index).inserted else { continue }
            work.append(contentsOf: blocks[index].successors)
        }
        for leader in fallOffBlockLeaders {
            guard let index = blocks.firstIndex(where: { $0.start == leader }), reachable.contains(index) else {
                continue
            }
            let last = instructions[blocks[index].instructionRange].last
            let lastText = last.map { "\(Hex.value($0.address)): \($0.text)" } ?? "none"
            throw AnalyzerError.malformed(
                "\(image.label): \(name) control falls off the end of the function; "
                    + "extent \(Hex.value(extent.start))..\(Hex.value(extent.end)) via \(extent.source), "
                    + "last instruction \(lastText)")
        }

        return FunctionAnalysis(imageLabel: image.label, functionName: name,
                                start: extent.start, end: extent.end,
                                extentSource: extent.source,
                                instructions: instructions, blocks: blocks,
                                reachableBlocks: reachable)
    }

    private static func indexForLeader(_ address: UInt64, in leaders: [UInt64]) -> Int? {
        var low = 0
        var high = leaders.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if leaders[middle] == address { return middle }
            if leaders[middle] < address { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }
}

// MARK: - Objective-C metadata

struct ObjCMethod {
    let className: String
    let selector: String
    let types: String
    let imp: UInt64
}

/// Parses `__objc_classlist`/class_ro/method lists so ObjC method implementations
/// can be resolved without a symbol name. Used as a resolution fallback and as
/// cross-validation evidence; a malformed metadata graph never aborts image
/// analysis by itself, but a rule that depends on an ObjC method fails closed if
/// the method cannot be resolved.
enum ObjectiveCMetadata {
    static func methods(in image: AnalyzedImage) -> [ObjCMethod] {
        guard let store = cacheStore(of: image), let base = cacheBase(of: store) else { return [] }
        guard let classList = classListAddresses(in: image, decoder: pointerDecoder(base: base, image: image)) else {
            return []
        }
        let decode = pointerDecoder(base: base, image: image)
        var methods: [ObjCMethod] = []
        for classAddress in classList {
            guard let classBits = try? readU64(image: image, address: classAddress + 32),
                  let classRO = decode(classBits & ~UInt64(7)),
                  let namePointer = try? readU64(image: image, address: classRO + 24),
                  let nameAddress = decode(namePointer),
                  let name = try? readCString(image: image, address: nameAddress),
                  !name.isEmpty else { continue }
            guard let methodsPointer = try? readU64(image: image, address: classRO + 32),
                  let methodsAddress = decode(methodsPointer) else { continue }
            guard let methodList = try? readMethodList(image: image, address: methodsAddress, decode: decode) else {
                continue
            }
            for method in methodList where !method.selector.isEmpty {
                methods.append(ObjCMethod(className: name, selector: method.selector,
                                          types: method.types, imp: method.imp))
            }
        }
        return methods
    }

    static func method(in image: AnalyzedImage, className: String, selector: String) -> ObjCMethod? {
        let all = methods(in: image)
        let exact = all.filter { $0.className == className && $0.selector == selector }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        let bySelector = all.filter { $0.selector == selector }
        return bySelector.count == 1 ? bySelector[0] : nil
    }

    // MARK: internals

    private static func cacheStore(of image: AnalyzedImage) -> DyldCacheStore? {
        if case let .cache(store) = image.backing { return store }
        return nil
    }

    private static func cacheBase(of store: DyldCacheStore) -> UInt64? {
        store.mappings.first?.address
    }

    private static func classListAddresses(in image: AnalyzedImage,
                                           decoder: (UInt64) -> UInt64?) -> [UInt64]? {
        guard let section = image.section(seg: "__DATA_CONST", sect: "__objc_classlist")
                ?? image.section(seg: "__DATA", sect: "__objc_classlist") else { return nil }
        guard section.size > 0, section.size % 8 == 0, section.size <= 0x100000 else { return nil }
        var classes: [UInt64] = []
        var offset: UInt64 = 0
        while offset < section.size {
            guard let raw = try? readU64(image: image, address: section.addr + offset) else { return nil }
            if let address = decoder(raw) {
                classes.append(address)
            }
            offset += 8
        }
        return classes
    }

    /// The shared cache stores rebased pointers in a compact form on some builds.
    /// The decoder candidate that resolves the class list consistently is chosen;
    /// if none resolves, the ObjC graph is treated as unavailable.
    private static func pointerDecoder(base: UInt64, image: AnalyzedImage) -> (UInt64) -> UInt64? {
        func direct(_ value: UInt64) -> UInt64? {
            value >= image.text.vmaddr ? value : nil
        }
        func offset43(_ value: UInt64) -> UInt64? {
            base &+ (value & 0x0000_07FF_FFFF_FFFF)
        }
        func offset44(_ value: UInt64) -> UInt64? {
            base &+ (value & 0x0000_0FFF_FFFF_FFFF)
        }
        guard let section = image.section(seg: "__DATA_CONST", sect: "__objc_classlist")
                ?? image.section(seg: "__DATA", sect: "__objc_classlist"),
              let raw = try? readU64(image: image, address: section.addr) else {
            return direct
        }
        let candidates: [(UInt64) -> UInt64?] = [direct, offset43, offset44]
        for candidate in candidates {
            guard let classAddress = candidate(raw),
                  let bits = try? readU64(image: image, address: classAddress + 32) else { continue }
            if candidate(bits & ~UInt64(7)) != nil {
                return candidate
            }
        }
        return offset43
    }

    private static func readMethodList(image: AnalyzedImage, address: UInt64,
                                       decode: (UInt64) -> UInt64?) throws -> [(selector: String, types: String, imp: UInt64)] {
        let header = try readBytes(image: image, address: address, size: 8)
        let buffer = ByteBuffer(header)
        let entsizeAndFlags = try buffer.u32(0)
        let count = Int(try buffer.u32(4))
        guard count > 0, count < 0x20000 else { return [] }
        let relative = entsizeAndFlags & 0x8000_0000 != 0
        let entsize = Int(entsizeAndFlags & 0xffff)
        if relative {
            guard entsize == 12 else { return [] }
            var result: [(String, String, UInt64)] = []
            for index in 0..<count {
                let entryAddress = address + 8 + UInt64(index * entsize)
                let entry = try readBytes(image: image, address: entryAddress, size: 12)
                let fields = ByteBuffer(entry)
                let nameOffset = Int64(Int32(bitPattern: try fields.u32(0)))
                let typesOffset = Int64(Int32(bitPattern: try fields.u32(4)))
                let impOffset = Int64(Int32(bitPattern: try fields.u32(8)))
                _ = typesOffset
                let nameAddress = UInt64(bitPattern: Int64(entryAddress) &+ nameOffset)
                let typesAddress = UInt64(bitPattern: Int64(entryAddress + 4) &+ typesOffset)
                let impAddress = UInt64(bitPattern: Int64(entryAddress + 8) &+ impOffset)
                guard let selector = try? readCString(image: image, address: nameAddress), !selector.isEmpty else {
                    continue
                }
                let types = (try? readCString(image: image, address: typesAddress)) ?? ""
                guard image.text.contains(impAddress) else { continue }
                result.append((selector, types, impAddress))
            }
            return result
        }
        guard entsize >= 24, entsize <= 64 else { return [] }
        var result: [(String, String, UInt64)] = []
        for index in 0..<count {
            let entryAddress = address + 8 + UInt64(index * entsize)
            let entry = try readBytes(image: image, address: entryAddress, size: 24)
            let fields = ByteBuffer(entry)
            let nameField = try fields.u64(0)
            let typesField = try fields.u64(8)
            let impField = try fields.u64(16)
            guard let nameAddress = decode(nameField),
                  let selector = try? readCString(image: image, address: nameAddress), !selector.isEmpty else {
                continue
            }
            let types = decode(typesField).flatMap { try? readCString(image: image, address: $0) } ?? ""
            guard let imp = decode(impField), image.text.contains(imp) else { continue }
            result.append((selector, types, imp))
        }
        return result
    }

    private static func readU64(image: AnalyzedImage, address: UInt64) throws -> UInt64 {
        try ByteBuffer(try readBytes(image: image, address: address, size: 8)).u64(0)
    }

    private static func readBytes(image: AnalyzedImage, address: UInt64, size: Int) throws -> Data {
        try image.read(address: address, size: size)
    }

    private static func readCString(image: AnalyzedImage, address: UInt64) throws -> String {
        let data = try image.read(address: address, size: 512)
        return try ByteBuffer(data).cString(0, limit: 512)
    }
}

private extension AnalyzedImage {
    func contains(_ address: UInt64) -> Bool {
        address >= text.vmaddr && address < text.vmaddr + text.vmsize
    }
}
