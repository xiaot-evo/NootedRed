import Darwin
import Foundation

// MARK: - Decoded instruction model

struct Register: Equatable {
    let name: String
    let width: Int
    let code: Int

    private static let table: [String: (Int, Int)] = {
        var result: [String: (Int, Int)] = [:]
        let bases = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi"]
        let wordNames = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"]
        let byteNames = ["al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil"]
        let highNames: [String?] = ["ah", "ch", "dh", "bh", nil, nil, nil, nil]
        for index in 0..<bases.count {
            result[bases[index]] = (64, index)
            result["e" + wordNames[index]] = (32, index)
            result[wordNames[index]] = (16, index)
            result[byteNames[index]] = (8, index)
            if let high = highNames[index] {
                result[high] = (8, index)
            }
        }
        let extended = ["r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
        for (index, name) in extended.enumerated() {
            let code = 8 + index
            result[name] = (64, code)
            result[name + "d"] = (32, code)
            result[name + "w"] = (16, code)
            result[name + "b"] = (8, code)
        }
        result["rip"] = (64, -1)
        result["eip"] = (32, -1)
        return result
    }()

    static func parse(_ token: String) -> Register? {
        let lower = token.lowercased()
        if let (width, code) = table[lower] {
            return Register(name: lower, width: width, code: code)
        }
        return nil
    }

    var isGeneralPurpose: Bool { code >= 0 }
}

struct MemoryOperand: Equatable {
    let size: Int?
    let base: Register?
    let index: Register?
    let scale: Int
    let displacement: Int64
    let ripRelative: Bool
    let relativeTarget: UInt64?
    let text: String

    /// Value of a plain `[base + displacement]` memory operand with no index.
    var baseAndDisplacement: (Register, Int64)? {
        guard index == nil, !ripRelative, let base else { return nil }
        return (base, displacement)
    }
}

enum Operand: Equatable {
    case register(Register)
    case immediate(Int64)
    case memory(MemoryOperand)
    case raw(String)

    var register: Register? {
        if case let .register(register) = self { return register }
        return nil
    }

    var immediate: Int64? {
        if case let .immediate(value) = self { return value }
        return nil
    }

    var memory: MemoryOperand? {
        if case let .memory(operand) = self { return operand }
        return nil
    }

    var describe: String {
        switch self {
        case let .register(register): return register.name
        case let .immediate(value): return value < 0 ? "-\(Hex.value(UInt64(-value)))" : Hex.value(UInt64(value))
        case let .memory(operand): return operand.text
        case let .raw(text): return text
        }
    }
}

struct ParsedInstruction {
    let mnemonic: String
    let operands: [Operand]

    var operand0: Operand? { operands.count > 0 ? operands[0] : nil }
    var operand1: Operand? { operands.count > 1 ? operands[1] : nil }
}

struct DecodedInstruction {
    let address: UInt64
    let bytes: [UInt8]
    let mnemonic: String
    let operandsText: String
    let decoderID: UInt32

    var length: Int { bytes.count }
    var endAddress: UInt64 { address &+ UInt64(bytes.count) }
    var text: String { operandsText.isEmpty ? mnemonic : "\(mnemonic) \(operandsText)" }
    var parsed: ParsedInstruction? { IntelSyntax.parse(mnemonic: mnemonic, operandsText: operandsText) }

    var isConditionalBranch: Bool {
        guard mnemonic.hasPrefix("j"), mnemonic != "jmp", mnemonic != "jrcxz", mnemonic != "jecxz" else {
            return mnemonic == "jrcxz" || mnemonic == "jecxz"
        }
        return true
    }

    var isJump: Bool { mnemonic == "jmp" }
    var isCall: Bool { mnemonic.hasPrefix("call") }
    var isReturn: Bool { mnemonic == "ret" || mnemonic == "retf" || mnemonic == "iret" || mnemonic == "iretq" }
    var isInterrupt: Bool { mnemonic == "int3" || mnemonic == "int" || mnemonic == "ud2" || mnemonic == "ud1" }
    var isHalt: Bool { mnemonic == "hlt" }
    var isNoOp: Bool { mnemonic == "nop" || mnemonic.hasPrefix("nop ") }
    var isPadding: Bool { isNoOp || isInterrupt || isHalt }

    var isUnconditionalControlTransfer: Bool {
        isJump || isReturn || isInterrupt || isHalt
    }

    /// Target of a direct branch/call/jump, if the operand is a resolved address.
    var directBranchTarget: UInt64? {
        guard isConditionalBranch || isJump || isCall else { return nil }
        guard let first = parsed?.operand0 else { return nil }
        switch first {
        case let .immediate(value):
            return value >= 0 ? UInt64(value) : nil
        case let .memory(operand):
            return operand.relativeTarget
        default:
            return nil
        }
    }
}

// MARK: - Strict Intel-syntax operand parser

enum IntelSyntax {
    static func parse(mnemonic: String, operandsText: String) -> ParsedInstruction? {
        let lowered = mnemonic.lowercased()
        let text = operandsText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            return ParsedInstruction(mnemonic: lowered, operands: [])
        }
        let parts = splitOperands(text)
        guard !parts.isEmpty else { return nil }
        var operands: [Operand] = []
        for part in parts {
            guard let operand = parseOperand(part) else { return nil }
            operands.append(operand)
        }
        return ParsedInstruction(mnemonic: lowered, operands: operands)
    }

    private static func splitOperands(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "[" { depth += 1 }
            if character == "]" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }

    private static func parseOperand(_ text: String) -> Operand? {
        let lowered = text.lowercased()
        if let open = lowered.firstIndex(of: "["), let close = lowered.lastIndex(of: "]") {
            guard open < close else { return nil }
            let prefix = String(lowered[lowered.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            let size = memorySize(prefix: prefix)
            let inner = String(text[text.index(open, offsetBy: 1)..<close])
            return parseMemory(inner: inner, size: size, original: text)
        }
        if let register = Register.parse(lowered) {
            return .register(register)
        }
        if let immediate = parseImmediate(lowered) {
            return .immediate(immediate)
        }
        return .raw(lowered)
    }

    private static func memorySize(prefix: String) -> Int? {
        switch prefix {
        case "byte ptr": return 8
        case "word ptr": return 16
        case "dword ptr": return 32
        case "qword ptr": return 64
        case "xmmword ptr": return 128
        case "ymmword ptr": return 256
        case "zmmword ptr": return 512
        case "tbyte ptr": return 80
        default: return nil
        }
    }

    private static func parseMemory(inner: String, size: Int?, original: String) -> Operand? {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        var base: Register?
        var index: Register?
        var scale = 1
        var displacement: Int64 = 0
        var relativeTarget: UInt64?
        var ripRelative = false

        var sign: Int64 = 1
        var token = ""
        var tokens: [(sign: Int64, text: String)] = []
        let characters = Array(trimmed)
        var position = 0
        while position < characters.count {
            let character = characters[position]
            if character == "+" || character == "-" {
                if !token.isEmpty {
                    tokens.append((sign, token.trimmingCharacters(in: .whitespaces)))
                    token = ""
                }
                sign = character == "-" ? -1 : 1
            } else {
                token.append(character)
            }
            position += 1
        }
        if !token.isEmpty {
            tokens.append((sign, token.trimmingCharacters(in: .whitespaces)))
        }
        guard !tokens.isEmpty else { return nil }

        for entry in tokens {
            let term = entry.text.lowercased()
            if term.isEmpty { continue }
            if term.hasPrefix("*") && term.count > 1 {
                guard let factor = Int64(term.dropFirst()) else { return nil }
                scale = Int(factor)
                continue
            }
            if term.contains("*") {
                let factors = term.split(separator: "*").map { String($0).trimmingCharacters(in: .whitespaces) }
                for factor in factors {
                    if let register = Register.parse(factor) {
                        index = register
                    } else if let value = Int64(factor) {
                        scale = Int(value)
                    } else {
                        return nil
                    }
                }
                continue
            }
            if let register = Register.parse(term) {
                if register.name == "rip" {
                    ripRelative = true
                    continue
                }
                if base == nil {
                    base = register
                } else if index == nil {
                    index = register
                } else {
                    return nil
                }
                continue
            }
            if let value = parseInt64(term) {
                displacement &+= entry.sign &* value
                continue
            }
            return nil
        }
        if ripRelative {
            // Capstone leaves the resolved target in the operand text for rip-relative
            // memory? It does not; the caller must not depend on a target here.
            relativeTarget = nil
        }
        let description = original.trimmingCharacters(in: .whitespaces)
        return .memory(MemoryOperand(size: size, base: base, index: index, scale: scale,
                                     displacement: displacement, ripRelative: ripRelative,
                                     relativeTarget: relativeTarget, text: description))
    }

    private static func parseImmediate(_ token: String) -> Int64? {
        var text = token
        var negative = false
        if text.hasPrefix("-") {
            negative = true
            text.removeFirst()
        } else if text.hasPrefix("+") {
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }
        let value: Int64?
        if text.hasPrefix("0x") {
            value = Int64(text.dropFirst(2), radix: 16)
        } else if let decimal = Int64(text) {
            value = decimal
        } else {
            value = nil
        }
        guard let value else { return nil }
        return negative ? -value : value
    }

    private static func parseInt64(_ token: String) -> Int64? {
        parseImmediate(token)
    }
}

// MARK: - Capstone-backed x86_64 decoder

/// A real x86_64 disassembler. Capstone 5 is loaded dynamically
/// (`libcapstone.5.dylib`, overridable with `NRED_CAPSTONE_LIBRARY`); the loader
/// verifies the C `cs_insn` layout with a known-byte self-test before the decoder
/// is used. If Capstone is unavailable or the self-test fails, decoding fails
/// closed: the generator refuses to run instead of falling back to byte scans.
final class X86Decoder {
    private typealias CSOpen = @convention(c) (Int32, Int32, UnsafeMutablePointer<Int>) -> Int32
    private typealias CSOption = @convention(c) (Int, Int32, Int) -> Int32
    private typealias CSDisasm = @convention(c) (Int, UnsafePointer<UInt8>, Int, UInt64, Int,
                                                UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?) -> Int
    private typealias CSFree = @convention(c) (UnsafeMutablePointer<UInt8>?, Int) -> Void
    private typealias CSClose = @convention(c) (UnsafeMutablePointer<Int>) -> Int32

    static let shared: X86Decoder = {
        do {
            return try X86Decoder()
        } catch {
            return X86Decoder(failure: error)
        }
    }()

    private let csOpen: CSOpen?
    private let csOption: CSOption?
    private let csDisasm: CSDisasm?
    private let csFree: CSFree?
    private let csClose: CSClose?
    private var handle: Int = 0
    private(set) var loadError: Error? = nil
    private(set) var libraryPath: String? = nil

    /// sizeof(cs_insn) for Capstone 5 on x86_64: id(4)+pad(4)+address(8)+size(2)+
    /// bytes(24)+mnemonic(32)+op_str(160)+pad(6)+detail(8) = 248.
    private static let instructionSize = 248

    // cs_insn field offsets (validated by the self-test in `init`).
    private static let offsetID = 0
    private static let offsetAddress = 8
    private static let offsetSize = 16
    private static let offsetBytes = 18
    private static let offsetMnemonic = 42
    private static let offsetOpStr = 74
    private static let mnemonicCapacity = 32
    private static let opStrCapacity = 160

    // CS_ARCH_X86 = 3, CS_MODE_64 = 8, CS_OPT_SYNTAX = 1, CS_OPT_SYNTAX_INTEL = 1.
    private static let archX86: Int32 = 3
    private static let mode64: Int32 = 8
    private static let optionSyntax: Int32 = 1
    private static let syntaxIntel = 1

    init() throws {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["NRED_CAPSTONE_LIBRARY"], !override.isEmpty {
            paths.append(override)
        }
        paths.append(contentsOf: [
            "/usr/local/lib/libcapstone.5.dylib",
            "/usr/local/lib/libcapstone.dylib",
            "/opt/homebrew/lib/libcapstone.5.dylib",
            "/opt/homebrew/lib/libcapstone.dylib",
            "/usr/lib/libcapstone.dylib"
        ])
        var library: UnsafeMutableRawPointer?
        var usedPath: String?
        for path in paths {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                library = handle
                usedPath = path
                break
            }
        }
        guard let library else {
            throw AnalyzerError.unsupported(
                "cannot load Capstone x86_64 decoder; install capstone (brew install capstone) "
                    + "or set NRED_CAPSTONE_LIBRARY")
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let open = symbol("cs_open", as: CSOpen.self),
              let option = symbol("cs_option", as: CSOption.self),
              let disasm = symbol("cs_disasm", as: CSDisasm.self),
              let free = symbol("cs_free", as: CSFree.self),
              let close = symbol("cs_close", as: CSClose.self) else {
            throw AnalyzerError.unsupported("Capstone library at \(usedPath ?? "?") lacks the expected C API")
        }
        self.csOpen = open
        self.csOption = option
        self.csDisasm = disasm
        self.csFree = free
        self.csClose = close
        self.libraryPath = usedPath
        var newHandle = 0
        guard open(Self.archX86, Self.mode64, &newHandle) == 0, newHandle != 0 else {
            throw AnalyzerError.unsupported("Capstone cs_open(CS_ARCH_X86, CS_MODE_64) failed")
        }
        guard option(newHandle, Self.optionSyntax, Self.syntaxIntel) == 0 else {
            close(&newHandle)
            throw AnalyzerError.unsupported("Capstone Intel syntax option failed")
        }
        self.handle = newHandle
        do {
            try selfSelfTest()
        } catch {
            close(&newHandle)
            self.handle = 0
            throw error
        }
    }

    private init(failure: Error) {
        self.csOpen = nil
        self.csOption = nil
        self.csDisasm = nil
        self.csFree = nil
        self.csClose = nil
        self.loadError = failure
        self.libraryPath = nil
    }

    deinit {
        if handle != 0, let csClose {
            var local = handle
            _ = csClose(&local)
        }
    }

    var isAvailable: Bool { loadError == nil && handle != 0 }

    func requireAvailable() throws {
        if let loadError { throw loadError }
        guard handle != 0 else {
            throw AnalyzerError.unsupported("Capstone decoder is not initialized")
        }
    }

    private func selfSelfTest() throws {
        let instructions = try decode(bytes: [0x55, 0x48, 0x89, 0xe5, 0xc3], address: 0x1000)
        guard instructions.count == 3,
              instructions[0].mnemonic == "push", instructions[0].length == 1,
              instructions[1].mnemonic == "mov", instructions[1].length == 3,
              instructions[2].mnemonic == "ret", instructions[2].length == 1,
              instructions[0].address == 0x1000,
              instructions[1].address == 0x1001,
              instructions[2].address == 0x1004 else {
            throw AnalyzerError.unsupported("Capstone loader self-test failed (cs_insn layout mismatch)")
        }
    }

    /// Decodes as many instructions as possible from `bytes` starting at `address`.
    /// The caller is responsible for checking that the decoded instructions cover
    /// the whole requested range; a decode that stops early is a hard failure
    /// because it means the function body contains undecodable bytes.
    func decode(bytes: [UInt8], address: UInt64) throws -> [DecodedInstruction] {
        try requireAvailable()
        guard !bytes.isEmpty else { return [] }
        guard let csDisasm, let csFree, handle != 0 else {
            throw AnalyzerError.unsupported("Capstone decoder is not initialized")
        }
        var raw: UnsafeMutablePointer<UInt8>?
        let count = bytes.withUnsafeBufferPointer { buffer -> Int in
            csDisasm(handle, buffer.baseAddress!, Int(buffer.count), address, 0, &raw)
        }
        guard let raw, count > 0 else {
            throw AnalyzerError.malformed("Capstone could not decode bytes at \(Hex.value(address))")
        }
        defer { csFree(raw, count) }
        var instructions: [DecodedInstruction] = []
        instructions.reserveCapacity(count)
        for index in 0..<count {
            let base = raw.advanced(by: index * Self.instructionSize)
            let id = UnsafeRawPointer(base).load(fromByteOffset: Self.offsetID, as: UInt32.self)
            let instructionAddress = UnsafeRawPointer(base).load(fromByteOffset: Self.offsetAddress, as: UInt64.self)
            let length = Int(UnsafeRawPointer(base).load(fromByteOffset: Self.offsetSize, as: UInt16.self))
            guard length > 0, length <= 24 else {
                throw AnalyzerError.malformed("Capstone returned invalid instruction length \(length) at \(Hex.value(address))")
            }
            var instructionBytes: [UInt8] = []
            instructionBytes.reserveCapacity(length)
            for byteIndex in 0..<length {
                instructionBytes.append(UnsafeRawPointer(base).load(fromByteOffset: Self.offsetBytes + byteIndex, as: UInt8.self))
            }
            let mnemonic = Self.readString(base: base, offset: Self.offsetMnemonic, capacity: Self.mnemonicCapacity)
            let operands = Self.readString(base: base, offset: Self.offsetOpStr, capacity: Self.opStrCapacity)
            instructions.append(DecodedInstruction(address: instructionAddress, bytes: instructionBytes,
                                                   mnemonic: mnemonic, operandsText: operands,
                                                   decoderID: id))
        }
        return instructions
    }

    private static func readString(base: UnsafeMutablePointer<UInt8>, offset: Int, capacity: Int) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(capacity)
        for index in 0..<capacity {
            let byte = UnsafeRawPointer(base).load(fromByteOffset: offset + index, as: UInt8.self)
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
