import Foundation

// MARK: - NRPT v1 binary patch profile
//
// Pure host-side codec for the binary profile defined in docs/PatchProfile-Spec.md.
// Foundation only: no file I/O, no environment access, no hardcoded patch data.
// Every model value is supplied by the caller; encoders derive counts, table sizes and
// the payload checksum from the arrays so a profile can never be internally inconsistent.
//
// Layout (little-endian, packed, no implicit padding):
//   Header 64 B | PageTable pageCount*24 B | SiteTable siteCount*40 B
//
// Fail-closed contract: `decode` rejects the whole byte string with a typed
// ProfileCodecError for any rule violation; `encode` refuses any invalid model.
// Nothing is partially accepted.

// MARK: - Format constants

enum NRPTFormat {
    /// ASCII "NRPT".
    static let magic: [UInt8] = [0x4E, 0x52, 0x50, 0x54]

    static let version: UInt16 = 1
    static let headerSize = 64
    static let pageRecordSize = 24
    static let siteRecordSize = 40

    /// Page unit hashed by `pageHash` and written by page patches.
    static let pageSize = 4096

    static let buildFieldSize = 16
    static let maxBuildBytes = 15

    static let maxProfileSize = 64 * 1024
    static let maxPages = 256
    static let maxSites = 1024
    static let maxSitesPerPage = 64
    static let maxSitePatchSize = 16

    /// APU family bits defined by v1 (Raven .. Green Sardine).
    static let knownApuMask: UInt32 = 0x3F

    /// Header field offsets, in bytes from the start of the profile.
    enum Header {
        static let magic = 0
        static let version = 4
        static let headerSize = 6
        static let build = 8
        static let apuMask = 24
        static let deviceID = 28
        static let pageCount = 32
        static let siteCount = 34
        static let pageTableSize = 36
        static let siteTableSize = 40
        static let payloadChecksum = 44
        static let flags = 48
        static let reserved = 52
        static let reservedSize = 12
    }

    static func pageTableOffset(pageIndex: Int) -> Int {
        headerSize + pageIndex * pageRecordSize
    }

    static func encodedSize(pageCount: Int, siteCount: Int) -> Int {
        headerSize + pageCount * pageRecordSize + siteCount * siteRecordSize
    }
}

// MARK: - Flags

/// Header `flags` (u32 at offset 48). Only bit 0 is defined in v1.
struct NRPTHeaderFlags: OptionSet, Equatable, Hashable {
    let rawValue: UInt32

    /// `deviceID` is part of profile identity. Without this flag `deviceID` must be 0.
    static let requireDeviceID = NRPTHeaderFlags(rawValue: 1 << 0)

    /// All bits defined by v1; every other bit is reserved and must be zero.
    static let allKnown: UInt32 = requireDeviceID.rawValue
}

/// Page `matchFlags` (u16 at page-record offset 22).
///
/// v1 always requires full-page hash + all site finds. `requireOffset` is optional and may only
/// be set when the producer proved the offset namespace matches the runtime one.
struct NRPTMatchFlags: OptionSet, Equatable, Hashable {
    let rawValue: UInt16

    /// `pageFileOffset` must equal the delivered 4 KiB chunk base offset.
    static let requireOffset = NRPTMatchFlags(rawValue: 1 << 0)
    /// Full-page FNV-1a-64 must equal `pageHash`.
    static let requireHash = NRPTMatchFlags(rawValue: 1 << 1)
    /// Every site `find` must match before any write.
    static let requireSites = NRPTMatchFlags(rawValue: 1 << 2)

    /// Default and safest encoding: offset + hash + sites.
    static let defaultV1: NRPTMatchFlags = [.requireOffset, .requireHash, .requireSites]

    /// Flags that are mandatory on every v1 page record.
    static let requiredV1: NRPTMatchFlags = [.requireHash, .requireSites]

    /// All bits defined by v1; every other bit is reserved and must be zero.
    static let allKnown: UInt16 = 0x0007
}

// MARK: - Model

/// One site record (40 bytes on the wire).
struct NRPTSite: Equatable {
    /// Byte offset from the page base. `siteInPage + size <= 4096`.
    var siteInPage: UInt16
    /// Expected current bytes. Length is `findSize` on the wire; 1...16 bytes.
    var find: [UInt8]
    /// Bytes to write. Length is `replaceSize` on the wire; must equal `find.count`.
    var replace: [UInt8]
    /// Reserved in v1: must be 0.
    var flags: UInt32

    init(siteInPage: UInt16, find: [UInt8], replace: [UInt8], flags: UInt32 = 0) {
        self.siteInPage = siteInPage
        self.find = find
        self.replace = replace
        self.flags = flags
    }

    var findSize: Int { find.count }
    var replaceSize: Int { replace.count }
}

/// One page record (24 bytes on the wire) plus the sites it owns.
struct NRPTPage: Equatable {
    /// Page base offset in the target image namespace; must be 4096-aligned.
    var pageFileOffset: UInt64
    /// FNV-1a-64 over the complete 4096-byte clean page.
    var pageHash: UInt64
    /// Identity rules; v1 defaults to offset + hash + sites.
    var matchFlags: NRPTMatchFlags
    /// Sites in site-table order; 1...64 entries.
    var sites: [NRPTSite]

    init(pageFileOffset: UInt64, pageHash: UInt64, matchFlags: NRPTMatchFlags = .defaultV1,
         sites: [NRPTSite]) {
        self.pageFileOffset = pageFileOffset
        self.pageHash = pageHash
        self.matchFlags = matchFlags
        self.sites = sites
    }
}

/// Header identity fields. Counts, table sizes and checksum are derived by the encoder.
struct NRPTHeader: Equatable {
    /// Exact expected `kern.osversion`, 1...15 characters from `[0-9A-Za-z._-]`.
    var build: String
    /// Non-zero APU family mask, subset of `NRPTFormat.knownApuMask`.
    var apuMask: UInt32
    /// PCI device ID (0...0xFFFF) when `flags` contains `.requireDeviceID`; otherwise 0.
    var deviceID: UInt32
    var flags: NRPTHeaderFlags

    init(build: String, apuMask: UInt32, deviceID: UInt32 = 0,
         flags: NRPTHeaderFlags = []) {
        self.build = build
        self.apuMask = apuMask
        self.deviceID = deviceID
        self.flags = flags
    }
}

/// A complete NRPT v1 profile: header identity + canonical page/site tables.
struct NRPTProfile: Equatable {
    var header: NRPTHeader
    var pages: [NRPTPage]

    init(header: NRPTHeader, pages: [NRPTPage]) {
        self.header = header
        self.pages = pages
    }

    var pageCount: Int { pages.count }
    var siteCount: Int { pages.reduce(0) { $0 + $1.sites.count } }
    var encodedSize: Int { NRPTFormat.encodedSize(pageCount: pageCount, siteCount: siteCount) }
}

// MARK: - Errors

/// Stable validation errors. The `code` value (E001...E033) is the stable diagnostic identity;
/// the associated values carry the field context used in logs.
enum ProfileCodecError: Error, Equatable, CustomStringConvertible {
    /// E001: profile shorter than the 64-byte header.
    case truncated(actual: Int, minimum: Int)
    /// E002: bytes 0-3 are not ASCII "NRPT".
    case badMagic([UInt8])
    /// E003: `version != 1`.
    case unsupportedVersion(UInt16)
    /// E004: `headerSize != 64`.
    case invalidHeaderSize(UInt16)
    /// E005: empty / too long / forbidden character / bad NUL padding.
    case invalidBuild([UInt8])
    /// E006: zero APU mask or a bit outside 0-5.
    case invalidApuMask(UInt32)
    /// E007: device ID / header-flag combination is invalid.
    case invalidDeviceID(UInt32)
    /// E008: a reserved header flag bit is set.
    case unsupportedHeaderFlags(UInt32)
    /// E009: any header reserved byte (52-63) is non-zero.
    case headerReservedNotZero
    /// E010: declared or actual profile size exceeds 64 KiB.
    case profileTooLarge(Int)
    /// E011: `pageTableSize != pageCount * 24`.
    case pageTableSizeMismatch(stored: UInt32, expected: UInt32)
    /// E012: `siteTableSize != siteCount * 40`.
    case siteTableSizeMismatch(stored: UInt32, expected: UInt32)
    /// E013: byte length differs from `64 + pageTableSize + siteTableSize`.
    case totalSizeMismatch(declared: Int, actual: Int)
    /// E014: FNV-1a-32 over bytes [64, size) differs from `payloadChecksum`.
    case payloadChecksumMismatch(stored: UInt32, computed: UInt32)
    /// E015: `pageCount` outside 1...256.
    case pageCountOutOfRange(Int)
    /// E016: `siteCount` outside 1...1024.
    case siteCountOutOfRange(Int)
    /// E017: a page `pageFileOffset` is not 4096-aligned.
    case pageOffsetMisaligned(pageIndex: Int, offset: UInt64)
    /// E018: a page `matchFlags` bit outside 0-2 is set.
    case unsupportedPageMatchFlags(pageIndex: Int, flags: UInt16)
    /// E019: a page does not set both REQUIRED_HASH and REQUIRE_SITES.
    case requiredPageMatchFlagMissing(pageIndex: Int, flags: UInt16)
    /// E020: a page's `firstSite + siteCount` exceeds the header `siteCount`.
    case pageSiteRangeInvalid(pageIndex: Int, firstSite: UInt32, siteCount: Int,
                              headerSiteCount: Int)
    /// E021: a page's `firstSite` is not the running sum of preceding page site counts.
    case nonCanonicalSiteRange(pageIndex: Int, expectedFirstSite: UInt32,
                               actualFirstSite: UInt32)
    /// E022: sum of page site counts differs from the header `siteCount`.
    case siteCountSumMismatch(declared: Int, summed: Int)
    /// E023: a page has 0 sites or more than 64 sites.
    case sitesPerPageExceeded(pageIndex: Int, count: Int)
    /// E024: `findSize` or `replaceSize` is 0 or greater than 16.
    case invalidSitePatchSize(siteIndex: Int, findSize: Int, replaceSize: Int)
    /// E025: `findSize != replaceSize`.
    case findReplaceSizeMismatch(siteIndex: Int, findSize: Int, replaceSize: Int)
    /// E026: `siteInPage + size > 4096`.
    case siteOutOfPageBounds(siteIndex: Int, siteInPage: Int, size: Int)
    /// E027: a `find`/`replace` byte after the declared size is non-zero.
    case sitePaddingNotZero(siteIndex: Int)
    /// E028: `find` is byte-identical to `replace` (no-op patch).
    case noOpSite(siteIndex: Int)
    /// E029: a site `flags` value is non-zero.
    case unsupportedSiteFlags(siteIndex: Int, flags: UInt32)
    /// E030: two sites on the same page have overlapping write ranges.
    case overlappingSiteWrites(pageIndex: Int, firstSite: Int, secondSite: Int)
    /// E031: two page records have an ambiguous identity.
    case duplicatePageIdentity(pageIndex: Int, duplicateOf: Int)
    /// E032: zero pages (an empty profile must not be injected).
    case emptyProfile
    /// E033: `pageHash` was called with an input that is not exactly 4096 bytes.
    /// This is a codec-helper precondition, not a rule of the wire format.
    case invalidPageSize(actual: Int)

    /// Stable `<E0xx>` diagnostic code from the spec.
    var code: String {
        switch self {
        case .truncated: return "E001"
        case .badMagic: return "E002"
        case .unsupportedVersion: return "E003"
        case .invalidHeaderSize: return "E004"
        case .invalidBuild: return "E005"
        case .invalidApuMask: return "E006"
        case .invalidDeviceID: return "E007"
        case .unsupportedHeaderFlags: return "E008"
        case .headerReservedNotZero: return "E009"
        case .profileTooLarge: return "E010"
        case .pageTableSizeMismatch: return "E011"
        case .siteTableSizeMismatch: return "E012"
        case .totalSizeMismatch: return "E013"
        case .payloadChecksumMismatch: return "E014"
        case .pageCountOutOfRange: return "E015"
        case .siteCountOutOfRange: return "E016"
        case .pageOffsetMisaligned: return "E017"
        case .unsupportedPageMatchFlags: return "E018"
        case .requiredPageMatchFlagMissing: return "E019"
        case .pageSiteRangeInvalid: return "E020"
        case .nonCanonicalSiteRange: return "E021"
        case .siteCountSumMismatch: return "E022"
        case .sitesPerPageExceeded: return "E023"
        case .invalidSitePatchSize: return "E024"
        case .findReplaceSizeMismatch: return "E025"
        case .siteOutOfPageBounds: return "E026"
        case .sitePaddingNotZero: return "E027"
        case .noOpSite: return "E028"
        case .unsupportedSiteFlags: return "E029"
        case .overlappingSiteWrites: return "E030"
        case .duplicatePageIdentity: return "E031"
        case .emptyProfile: return "E032"
        case .invalidPageSize: return "E033"
        }
    }

    var description: String {
        switch self {
        case let .truncated(actual, minimum):
            return "\(code): profile is \(actual) bytes, header needs at least \(minimum)"
        case let .badMagic(bytes):
            return "\(code): magic is \(hex(bytes)), expected 'NRPT'"
        case let .unsupportedVersion(version):
            return "\(code): unsupported profile version \(version)"
        case let .invalidHeaderSize(size):
            return "\(code): headerSize \(size), expected \(NRPTFormat.headerSize)"
        case let .invalidBuild(bytes):
            return "\(code): invalid build field \(hex(bytes))"
        case let .invalidApuMask(mask):
            return "\(code): invalid APU mask \(hex(mask))"
        case let .invalidDeviceID(deviceID):
            return "\(code): invalid deviceID \(hex(deviceID)) for header flags"
        case let .unsupportedHeaderFlags(flags):
            return "\(code): unsupported header flags \(hex(flags))"
        case .headerReservedNotZero:
            return "\(code): header reserved bytes are not zero"
        case let .profileTooLarge(size):
            return "\(code): profile size \(size) exceeds \(NRPTFormat.maxProfileSize)"
        case let .pageTableSizeMismatch(stored, expected):
            return "\(code): pageTableSize \(stored), expected \(expected)"
        case let .siteTableSizeMismatch(stored, expected):
            return "\(code): siteTableSize \(stored), expected \(expected)"
        case let .totalSizeMismatch(declared, actual):
            return "\(code): profile is \(actual) bytes, header declares \(declared)"
        case let .payloadChecksumMismatch(stored, computed):
            return "\(code): payload checksum \(hex(stored)), computed \(hex(computed))"
        case let .pageCountOutOfRange(count):
            return "\(code): pageCount \(count) outside 1...\(NRPTFormat.maxPages)"
        case let .siteCountOutOfRange(count):
            return "\(code): siteCount \(count) outside 1...\(NRPTFormat.maxSites)"
        case let .pageOffsetMisaligned(pageIndex, offset):
            return "\(code): page \(pageIndex) offset \(hex(offset)) is not 4 KiB aligned"
        case let .unsupportedPageMatchFlags(pageIndex, flags):
            return "\(code): page \(pageIndex) matchFlags \(hex(flags)) has reserved bits"
        case let .requiredPageMatchFlagMissing(pageIndex, flags):
            return "\(code): page \(pageIndex) matchFlags \(hex(flags)) miss required flags"
        case let .pageSiteRangeInvalid(pageIndex, firstSite, siteCount, headerSiteCount):
            return "\(code): page \(pageIndex) site range [\(firstSite), +\(siteCount)) "
                + "exceeds siteCount \(headerSiteCount)"
        case let .nonCanonicalSiteRange(pageIndex, expectedFirstSite, actualFirstSite):
            return "\(code): page \(pageIndex) firstSite \(actualFirstSite), "
                + "expected \(expectedFirstSite)"
        case let .siteCountSumMismatch(declared, summed):
            return "\(code): header siteCount \(declared), page sum \(summed)"
        case let .sitesPerPageExceeded(pageIndex, count):
            return "\(code): page \(pageIndex) has \(count) sites, allowed 1..."
                + "\(NRPTFormat.maxSitesPerPage)"
        case let .invalidSitePatchSize(siteIndex, findSize, replaceSize):
            return "\(code): site \(siteIndex) sizes \(findSize)/\(replaceSize), "
                + "allowed 1...\(NRPTFormat.maxSitePatchSize)"
        case let .findReplaceSizeMismatch(siteIndex, findSize, replaceSize):
            return "\(code): site \(siteIndex) findSize \(findSize) != replaceSize \(replaceSize)"
        case let .siteOutOfPageBounds(siteIndex, siteInPage, size):
            return "\(code): site \(siteIndex) at \(siteInPage) size \(size) leaves the page"
        case let .sitePaddingNotZero(siteIndex):
            return "\(code): site \(siteIndex) has non-zero find/replace padding"
        case let .noOpSite(siteIndex):
            return "\(code): site \(siteIndex) find equals replace"
        case let .unsupportedSiteFlags(siteIndex, flags):
            return "\(code): site \(siteIndex) flags \(hex(flags)) are reserved in v1"
        case let .overlappingSiteWrites(pageIndex, firstSite, secondSite):
            return "\(code): page \(pageIndex) sites \(firstSite)/\(secondSite) overlap"
        case let .duplicatePageIdentity(pageIndex, duplicateOf):
            return "\(code): page \(pageIndex) duplicates page \(duplicateOf) identity"
        case .emptyProfile:
            return "\(code): profile has no pages"
        case let .invalidPageSize(actual):
            return "\(code): page is \(actual) bytes, expected \(NRPTFormat.pageSize)"
        }
    }

    private func hex<T: FixedWidthInteger>(_ value: T) -> String {
        String(format: "0x%llX", UInt64(truncatingIfNeeded: value))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - Page application result

/// Result of the pure page-application simulation (`ProfileCodec.applyPage`).
enum NRPTPageApplication: Equatable {
    /// No page record identity matched the supplied page/offset.
    case noMatch
    /// A record identity matched but a site `find` did not; no bytes were written.
    case siteFindMismatch(pageIndex: Int, siteIndex: Int)
    /// Exactly one record matched and its sites were applied; `data` is the patched 4 KiB page.
    case applied(pageIndex: Int, data: Data)
}

// MARK: - Codec

enum ProfileCodec {
    // MARK: Hashing

    /// FNV-1a 32: offset basis 0x811C9DC5, prime 0x01000193.
    static func fnv1a32(_ data: Data) -> UInt32 {
        var hash: UInt32 = 0x811C9DC5
        for byte in data {
            hash = (hash ^ UInt32(byte)) &* 0x01000193
        }
        return hash
    }

    /// FNV-1a 64: offset basis 0xCBF29CE484222325, prime 0x100000001B3.
    static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xCBF29CE484222325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return hash
    }

    /// FNV-1a-64 over a complete page. Throws E033 unless `page` is exactly 4096 bytes.
    static func pageHash(_ page: Data) throws -> UInt64 {
        guard page.count == NRPTFormat.pageSize else {
            throw ProfileCodecError.invalidPageSize(actual: page.count)
        }
        return fnv1a64(page)
    }

    /// FNV-1a-32 over page-table bytes followed by site-table bytes.
    static func payloadChecksum(pageTable: Data, siteTable: Data) -> UInt32 {
        var hash: UInt32 = 0x811C9DC5
        for byte in pageTable {
            hash = (hash ^ UInt32(byte)) &* 0x01000193
        }
        for byte in siteTable {
            hash = (hash ^ UInt32(byte)) &* 0x01000193
        }
        return hash
    }

    /// FNV-1a-32 over a raw payload byte string (bytes after the 64-byte header).
    static func payloadChecksum(_ payload: Data) -> UInt32 {
        payloadChecksum(pageTable: payload, siteTable: Data())
    }

    // MARK: Validation (model)

    /// Validates every model-level rule of docs/PatchProfile-Spec.md.
    /// Throws the first violation; a valid model has no warnings to suppress.
    static func validate(_ profile: NRPTProfile) throws {
        try validateHeader(profile.header)

        guard !profile.pages.isEmpty else { throw ProfileCodecError.emptyProfile }
        guard profile.pageCount <= NRPTFormat.maxPages else {
            throw ProfileCodecError.pageCountOutOfRange(profile.pageCount)
        }
        let totalSites = profile.siteCount
        guard totalSites <= NRPTFormat.maxSites else {
            throw ProfileCodecError.siteCountOutOfRange(totalSites)
        }
        guard totalSites >= 1 else { throw ProfileCodecError.siteCountOutOfRange(0) }
        guard profile.encodedSize <= NRPTFormat.maxProfileSize else {
            throw ProfileCodecError.profileTooLarge(profile.encodedSize)
        }

        var globalSiteIndex = 0
        for (pageIndex, page) in profile.pages.enumerated() {
            guard page.pageFileOffset & 0x0FFF == 0 else {
                throw ProfileCodecError.pageOffsetMisaligned(pageIndex: pageIndex,
                                                             offset: page.pageFileOffset)
            }

            let rawMatchFlags = page.matchFlags.rawValue
            guard rawMatchFlags & ~NRPTMatchFlags.allKnown == 0 else {
                throw ProfileCodecError.unsupportedPageMatchFlags(pageIndex: pageIndex,
                                                                  flags: rawMatchFlags)
            }
            guard page.matchFlags.isSuperset(of: .requiredV1) else {
                throw ProfileCodecError.requiredPageMatchFlagMissing(pageIndex: pageIndex,
                                                                     flags: rawMatchFlags)
            }
            guard page.sites.count >= 1, page.sites.count <= NRPTFormat.maxSitesPerPage else {
                throw ProfileCodecError.sitesPerPageExceeded(pageIndex: pageIndex,
                                                             count: page.sites.count)
            }

            var writes: [(start: Int, end: Int, siteIndex: Int)] = []
            writes.reserveCapacity(page.sites.count)
            for (localSiteIndex, site) in page.sites.enumerated() {
                let siteIndex = globalSiteIndex + localSiteIndex
                let findSize = site.findSize
                let replaceSize = site.replaceSize
                guard findSize >= 1, findSize <= NRPTFormat.maxSitePatchSize,
                      replaceSize >= 1, replaceSize <= NRPTFormat.maxSitePatchSize else {
                    throw ProfileCodecError.invalidSitePatchSize(siteIndex: siteIndex,
                                                                 findSize: findSize,
                                                                 replaceSize: replaceSize)
                }
                guard findSize == replaceSize else {
                    throw ProfileCodecError.findReplaceSizeMismatch(siteIndex: siteIndex,
                                                                    findSize: findSize,
                                                                    replaceSize: replaceSize)
                }
                let inPage = Int(site.siteInPage)
                guard inPage + findSize <= NRPTFormat.pageSize,
                      inPage + replaceSize <= NRPTFormat.pageSize else {
                    throw ProfileCodecError.siteOutOfPageBounds(siteIndex: siteIndex,
                                                                siteInPage: inPage,
                                                                size: findSize)
                }
                guard site.find != site.replace else {
                    throw ProfileCodecError.noOpSite(siteIndex: siteIndex)
                }
                guard site.flags == 0 else {
                    throw ProfileCodecError.unsupportedSiteFlags(siteIndex: siteIndex,
                                                                 flags: site.flags)
                }
                writes.append((start: inPage, end: inPage + replaceSize, siteIndex: siteIndex))
            }

            // Overlapping write ranges inside one page are a producer error. The canonical
            // site order is preserved in the profile, so check all pairs without reordering
            // the table (reordering is only used to find the first overlap deterministically).
            let ordered = writes.sorted { lhs, rhs in
                lhs.start != rhs.start ? lhs.start < rhs.start : lhs.siteIndex < rhs.siteIndex
            }
            if ordered.count > 1 {
                for index in 1 ..< ordered.count
                    where ordered[index].start < ordered[index - 1].end {
                    throw ProfileCodecError.overlappingSiteWrites(
                        pageIndex: pageIndex,
                        firstSite: ordered[index - 1].siteIndex,
                        secondSite: ordered[index].siteIndex)
                }
            }

            globalSiteIndex += page.sites.count
        }
        assert(globalSiteIndex == totalSites)

        // Identity uniqueness (spec §6 rule 5).
        for pageIndex in 0 ..< profile.pages.count {
            for otherIndex in 0 ..< pageIndex {
                let page = profile.pages[pageIndex]
                let other = profile.pages[otherIndex]
                guard page.pageHash == other.pageHash else { continue }
                let bothRequireOffset = page.matchFlags.contains(.requireOffset)
                    && other.matchFlags.contains(.requireOffset)
                if page.pageFileOffset == other.pageFileOffset || !bothRequireOffset {
                    throw ProfileCodecError.duplicatePageIdentity(pageIndex: pageIndex,
                                                                  duplicateOf: otherIndex)
                }
            }
        }
    }

    /// Validates header identity fields (shared by encode, decode and caller-side checks).
    static func validateHeader(_ header: NRPTHeader) throws {
        let buildBytes = Array(header.build.utf8)
        guard isValidBuild(buildBytes) else {
            throw ProfileCodecError.invalidBuild(buildBytes)
        }
        guard header.apuMask != 0, header.apuMask & ~NRPTFormat.knownApuMask == 0 else {
            throw ProfileCodecError.invalidApuMask(header.apuMask)
        }
        guard header.flags.rawValue & ~NRPTHeaderFlags.allKnown == 0 else {
            throw ProfileCodecError.unsupportedHeaderFlags(header.flags.rawValue)
        }
        if header.flags.contains(.requireDeviceID) {
            guard header.deviceID >= 1, header.deviceID <= 0xFFFF else {
                throw ProfileCodecError.invalidDeviceID(header.deviceID)
            }
        } else {
            guard header.deviceID == 0 else {
                throw ProfileCodecError.invalidDeviceID(header.deviceID)
            }
        }
    }

    private static func isValidBuild(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 1, bytes.count <= NRPTFormat.maxBuildBytes else { return false }
        return bytes.allSatisfy(isAllowedBuildByte)
    }

    private static func isAllowedBuildByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            return true
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"):
            return true
        case UInt8(ascii: "a") ... UInt8(ascii: "z"):
            return true
        case UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }

    // MARK: Encode

    /// Serializes a valid profile into canonical NRPT v1 bytes.
    /// Throws a ProfileCodecError and produces no bytes if any model rule is violated.
    static func encode(_ profile: NRPTProfile) throws -> Data {
        try validate(profile)

        var pageTable = Data()
        pageTable.reserveCapacity(profile.pageCount * NRPTFormat.pageRecordSize)
        var siteTable = Data()
        siteTable.reserveCapacity(profile.siteCount * NRPTFormat.siteRecordSize)

        var firstSite = 0
        for page in profile.pages {
            appendLE(page.pageFileOffset, to: &pageTable)
            appendLE(page.pageHash, to: &pageTable)
            appendLE(UInt32(firstSite), to: &pageTable)
            appendLE(UInt16(page.sites.count), to: &pageTable)
            appendLE(page.matchFlags.rawValue, to: &pageTable)
            firstSite += page.sites.count

            for site in page.sites {
                appendLE(site.siteInPage, to: &siteTable)
                siteTable.append(UInt8(site.findSize))
                siteTable.append(UInt8(site.replaceSize))
                appendPadded(site.find, to: &siteTable)
                appendPadded(site.replace, to: &siteTable)
                appendLE(site.flags, to: &siteTable)
            }
        }

        let checksum = payloadChecksum(pageTable: pageTable, siteTable: siteTable)

        var buildField = [UInt8](repeating: 0, count: NRPTFormat.buildFieldSize)
        let buildBytes = Array(profile.header.build.utf8)
        for (index, byte) in buildBytes.enumerated() {
            buildField[index] = byte
        }

        var output = Data()
        output.reserveCapacity(NRPTFormat.encodedSize(pageCount: profile.pageCount,
                                                      siteCount: profile.siteCount))
        output.append(contentsOf: NRPTFormat.magic)
        appendLE(NRPTFormat.version, to: &output)
        appendLE(UInt16(NRPTFormat.headerSize), to: &output)
        output.append(contentsOf: buildField)
        appendLE(profile.header.apuMask, to: &output)
        appendLE(profile.header.deviceID, to: &output)
        appendLE(UInt16(profile.pageCount), to: &output)
        appendLE(UInt16(profile.siteCount), to: &output)
        appendLE(UInt32(pageTable.count), to: &output)
        appendLE(UInt32(siteTable.count), to: &output)
        appendLE(checksum, to: &output)
        appendLE(profile.header.flags.rawValue, to: &output)
        output.append(contentsOf: [UInt8](repeating: 0, count: NRPTFormat.Header.reservedSize))
        output.append(pageTable)
        output.append(siteTable)

        assert(output.count == profile.encodedSize)
        return output
    }

    // MARK: Decode

    /// Parses and validates a complete NRPT v1 byte string.
    /// Throws a ProfileCodecError on the first violation; never returns a partial profile.
    static func decode(_ data: Data) throws -> NRPTProfile {
        let bytes = [UInt8](data)

        guard bytes.count >= NRPTFormat.headerSize else {
            throw ProfileCodecError.truncated(actual: bytes.count,
                                              minimum: NRPTFormat.headerSize)
        }
        guard bytes.count <= NRPTFormat.maxProfileSize else {
            throw ProfileCodecError.profileTooLarge(bytes.count)
        }

        // Magic.
        let magic = Array(bytes[NRPTFormat.Header.magic ..< NRPTFormat.Header.magic + 4])
        guard magic == NRPTFormat.magic else { throw ProfileCodecError.badMagic(magic) }

        // Version and header size.
        let version = leU16(bytes, NRPTFormat.Header.version)
        guard version == NRPTFormat.version else {
            throw ProfileCodecError.unsupportedVersion(version)
        }
        let headerSize = leU16(bytes, NRPTFormat.Header.headerSize)
        guard Int(headerSize) == NRPTFormat.headerSize else {
            throw ProfileCodecError.invalidHeaderSize(headerSize)
        }

        // Build: exactly NUL padded ASCII; decode to the model string.
        let buildField = Array(bytes[NRPTFormat.Header.build
                                      ..< NRPTFormat.Header.build + NRPTFormat.buildFieldSize])
        let build = try decodeBuild(buildField)

        // Header identity.
        let apuMask = leU32(bytes, NRPTFormat.Header.apuMask)
        guard apuMask != 0, apuMask & ~NRPTFormat.knownApuMask == 0 else {
            throw ProfileCodecError.invalidApuMask(apuMask)
        }
        let headerFlagsRaw = leU32(bytes, NRPTFormat.Header.flags)
        guard headerFlagsRaw & ~NRPTHeaderFlags.allKnown == 0 else {
            throw ProfileCodecError.unsupportedHeaderFlags(headerFlagsRaw)
        }
        let deviceID = leU32(bytes, NRPTFormat.Header.deviceID)
        let headerFlags = NRPTHeaderFlags(rawValue: headerFlagsRaw)
        if headerFlags.contains(.requireDeviceID) {
            guard deviceID >= 1, deviceID <= 0xFFFF else {
                throw ProfileCodecError.invalidDeviceID(deviceID)
            }
        } else {
            guard deviceID == 0 else { throw ProfileCodecError.invalidDeviceID(deviceID) }
        }

        // Reserved header bytes must be zero.
        let reserved = bytes[NRPTFormat.Header.reserved
                             ..< NRPTFormat.Header.reserved + NRPTFormat.Header.reservedSize]
        guard reserved.allSatisfy({ $0 == 0 }) else {
            throw ProfileCodecError.headerReservedNotZero
        }

        // Counts and table sizes.
        let pageCount = Int(leU16(bytes, NRPTFormat.Header.pageCount))
        let siteCount = Int(leU16(bytes, NRPTFormat.Header.siteCount))
        guard pageCount >= 1 else { throw ProfileCodecError.emptyProfile }
        guard pageCount <= NRPTFormat.maxPages else {
            throw ProfileCodecError.pageCountOutOfRange(pageCount)
        }
        guard siteCount >= 1 else { throw ProfileCodecError.siteCountOutOfRange(siteCount) }
        guard siteCount <= NRPTFormat.maxSites else {
            throw ProfileCodecError.siteCountOutOfRange(siteCount)
        }

        let encodedSize = NRPTFormat.encodedSize(pageCount: pageCount, siteCount: siteCount)
        guard encodedSize <= NRPTFormat.maxProfileSize else {
            throw ProfileCodecError.profileTooLarge(encodedSize)
        }

        let storedPageTableSize = leU32(bytes, NRPTFormat.Header.pageTableSize)
        let expectedPageTableSize = UInt32(pageCount * NRPTFormat.pageRecordSize)
        guard storedPageTableSize == expectedPageTableSize else {
            throw ProfileCodecError.pageTableSizeMismatch(stored: storedPageTableSize,
                                                          expected: expectedPageTableSize)
        }
        let storedSiteTableSize = leU32(bytes, NRPTFormat.Header.siteTableSize)
        let expectedSiteTableSize = UInt32(siteCount * NRPTFormat.siteRecordSize)
        guard storedSiteTableSize == expectedSiteTableSize else {
            throw ProfileCodecError.siteTableSizeMismatch(stored: storedSiteTableSize,
                                                          expected: expectedSiteTableSize)
        }
        guard bytes.count == encodedSize else {
            throw ProfileCodecError.totalSizeMismatch(declared: encodedSize, actual: bytes.count)
        }

        // Payload checksum covers the page table followed by the site table.
        let payload = Data(bytes[NRPTFormat.headerSize...])
        let storedChecksum = leU32(bytes, NRPTFormat.Header.payloadChecksum)
        let computedChecksum = payloadChecksum(payload)
        guard storedChecksum == computedChecksum else {
            throw ProfileCodecError.payloadChecksumMismatch(stored: storedChecksum,
                                                            computed: computedChecksum)
        }

        let pageTableBase = NRPTFormat.headerSize
        let siteTableBase = pageTableBase + Int(storedPageTableSize)

        var pages: [NRPTPage] = []
        pages.reserveCapacity(pageCount)
        var runningFirstSite = 0
        for pageIndex in 0 ..< pageCount {
            let recordBase = pageTableBase + pageIndex * NRPTFormat.pageRecordSize
            let pageFileOffset = leU64(bytes, recordBase)
            let pageHash = leU64(bytes, recordBase + 8)
            let firstSite = leU32(bytes, recordBase + 16)
            let pageSites = Int(leU16(bytes, recordBase + 20))
            let matchFlagsRaw = leU16(bytes, recordBase + 22)

            guard pageFileOffset & 0x0FFF == 0 else {
                throw ProfileCodecError.pageOffsetMisaligned(pageIndex: pageIndex,
                                                             offset: pageFileOffset)
            }
            guard matchFlagsRaw & ~NRPTMatchFlags.allKnown == 0 else {
                throw ProfileCodecError.unsupportedPageMatchFlags(pageIndex: pageIndex,
                                                                  flags: matchFlagsRaw)
            }
            let matchFlags = NRPTMatchFlags(rawValue: matchFlagsRaw)
            guard matchFlags.isSuperset(of: .requiredV1) else {
                throw ProfileCodecError.requiredPageMatchFlagMissing(pageIndex: pageIndex,
                                                                     flags: matchFlagsRaw)
            }
            guard pageSites >= 1, pageSites <= NRPTFormat.maxSitesPerPage else {
                throw ProfileCodecError.sitesPerPageExceeded(pageIndex: pageIndex,
                                                             count: pageSites)
            }
            guard Int(firstSite) == runningFirstSite else {
                throw ProfileCodecError.nonCanonicalSiteRange(
                    pageIndex: pageIndex,
                    expectedFirstSite: UInt32(runningFirstSite),
                    actualFirstSite: firstSite)
            }
            guard Int(firstSite) + pageSites <= siteCount else {
                throw ProfileCodecError.pageSiteRangeInvalid(pageIndex: pageIndex,
                                                             firstSite: firstSite,
                                                             siteCount: pageSites,
                                                             headerSiteCount: siteCount)
            }

            var sites: [NRPTSite] = []
            sites.reserveCapacity(pageSites)
            for localSiteIndex in 0 ..< pageSites {
                let globalSiteIndex = runningFirstSite + localSiteIndex
                let siteBase = siteTableBase + globalSiteIndex * NRPTFormat.siteRecordSize
                let siteInPage = leU16(bytes, siteBase)
                let findSize = Int(bytes[siteBase + 2])
                let replaceSize = Int(bytes[siteBase + 3])

                guard findSize >= 1, findSize <= NRPTFormat.maxSitePatchSize,
                      replaceSize >= 1, replaceSize <= NRPTFormat.maxSitePatchSize else {
                    throw ProfileCodecError.invalidSitePatchSize(siteIndex: globalSiteIndex,
                                                                 findSize: findSize,
                                                                 replaceSize: replaceSize)
                }
                guard findSize == replaceSize else {
                    throw ProfileCodecError.findReplaceSizeMismatch(siteIndex: globalSiteIndex,
                                                                    findSize: findSize,
                                                                    replaceSize: replaceSize)
                }
                guard Int(siteInPage) + findSize <= NRPTFormat.pageSize else {
                    throw ProfileCodecError.siteOutOfPageBounds(siteIndex: globalSiteIndex,
                                                                siteInPage: Int(siteInPage),
                                                                size: findSize)
                }

                let findBase = siteBase + 4
                let replaceBase = findBase + NRPTFormat.maxSitePatchSize
                let findPadding = bytes[(findBase + findSize) ..< (findBase + NRPTFormat.maxSitePatchSize)]
                let replacePadding = bytes[(replaceBase + replaceSize)
                                           ..< (replaceBase + NRPTFormat.maxSitePatchSize)]
                guard findPadding.allSatisfy({ $0 == 0 }),
                      replacePadding.allSatisfy({ $0 == 0 }) else {
                    throw ProfileCodecError.sitePaddingNotZero(siteIndex: globalSiteIndex)
                }

                let find = Array(bytes[findBase ..< findBase + findSize])
                let replace = Array(bytes[replaceBase ..< replaceBase + replaceSize])
                guard find != replace else {
                    throw ProfileCodecError.noOpSite(siteIndex: globalSiteIndex)
                }
                let siteFlags = leU32(bytes, siteBase + 36)
                guard siteFlags == 0 else {
                    throw ProfileCodecError.unsupportedSiteFlags(siteIndex: globalSiteIndex,
                                                                 flags: siteFlags)
                }

                sites.append(NRPTSite(siteInPage: siteInPage, find: find,
                                      replace: replace, flags: siteFlags))
            }

            pages.append(NRPTPage(pageFileOffset: pageFileOffset, pageHash: pageHash,
                                  matchFlags: matchFlags, sites: sites))
            runningFirstSite += pageSites
        }
        guard runningFirstSite == siteCount else {
            throw ProfileCodecError.siteCountSumMismatch(declared: siteCount,
                                                         summed: runningFirstSite)
        }

        let profile = NRPTProfile(
            header: NRPTHeader(build: build, apuMask: apuMask, deviceID: deviceID,
                               flags: headerFlags),
            pages: pages)

        // Re-run the model validation as a single source of truth for the remaining rules
        // (site overlap, identity uniqueness, empty profile, limits).
        try validate(profile)
        return profile
    }

    // MARK: Pure page simulation

    /// True when the record matches completely: enabled identity gates (offset if required,
    /// full-page hash) and, when `REQUIRE_SITES` is set, every site `find`.
    /// `data` must be exactly one 4096-byte page; any other length returns false (fail closed).
    static func pageMatches(_ page: NRPTPage, data: Data, pageOffset: UInt64?) -> Bool {
        guard data.count == NRPTFormat.pageSize else { return false }
        let bytes = [UInt8](data)
        guard identityMatches(page, bytes: bytes, pageOffset: pageOffset) else { return false }
        return firstMismatchingSiteIndex(page, bytes: bytes) == nil
    }

    /// Identity gates only: offset (when required) and full-page hash (when required).
    /// Site `find` bytes are checked separately because the first identity-matching record is
    /// authoritative and a site failure must be reported, not silently skipped (spec §8).
    private static func identityMatches(_ page: NRPTPage, bytes: [UInt8],
                                        pageOffset: UInt64?) -> Bool {
        if page.matchFlags.contains(.requireOffset) {
            guard let pageOffset, pageOffset == page.pageFileOffset else { return false }
        }
        if page.matchFlags.contains(.requireHash) {
            guard fnv1a64(Data(bytes)) == page.pageHash else { return false }
        }
        return true
    }

    /// Index of the first site whose `find` does not match, or nil when all required sites match.
    private static func firstMismatchingSiteIndex(_ page: NRPTPage, bytes: [UInt8]) -> Int? {
        guard page.matchFlags.contains(.requireSites) else { return nil }
        for (siteIndex, site) in page.sites.enumerated() {
            let start = Int(site.siteInPage)
            let size = site.findSize
            guard size >= 1, start + size <= NRPTFormat.pageSize else { return siteIndex }
            guard bytes[start ..< start + size].elementsEqual(site.find) else { return siteIndex }
        }
        return nil
    }

    /// Returns `data` with all `replace` bytes of `page` written, or `data` unchanged if any
    /// site would leave the page (validated profiles never reach that branch).
    static func applySites(_ page: NRPTPage, to data: Data) -> Data {
        guard data.count == NRPTFormat.pageSize else { return data }
        var bytes = [UInt8](data)
        for site in page.sites {
            let start = Int(site.siteInPage)
            let size = site.replaceSize
            guard size >= 1, start + size <= NRPTFormat.pageSize else { return data }
            for (offset, byte) in site.replace.enumerated() {
                bytes[start + offset] = byte
            }
        }
        return Data(bytes)
    }

    /// Stateless simulation of the kernel matcher (docs/PatchProfile-Spec.md §8).
    ///
    /// This mirrors identity matching, the authoritative-first-record rule and the
    /// no-partial-page rule. It does not model the per-boot applied bitmap (the kernel
    /// consumer owns that state); offline validation applies each record to clean pages.
    static func applyPage(_ profile: NRPTProfile, data: Data, pageOffset: UInt64?) -> NRPTPageApplication {
        guard data.count == NRPTFormat.pageSize else { return .noMatch }
        let bytes = [UInt8](data)

        for (pageIndex, page) in profile.pages.enumerated() {
            guard identityMatches(page, bytes: bytes, pageOffset: pageOffset) else { continue }

            // Identity matched: authoritative for this page. Any site mismatch means zero writes.
            if let siteIndex = firstMismatchingSiteIndex(page, bytes: bytes) {
                return .siteFindMismatch(pageIndex: pageIndex, siteIndex: siteIndex)
            }

            return .applied(pageIndex: pageIndex, data: applySites(page, to: data))
        }
        return .noMatch
    }

    // MARK: Little-endian helpers

    private static func leU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func leU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func leU64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in (0 ..< 8).reversed() {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return value
    }

    private static func appendLE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendLE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendLE(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    private static func appendPadded(_ bytes: [UInt8], to data: inout Data) {
        data.append(contentsOf: bytes)
        let padding = NRPTFormat.maxSitePatchSize - bytes.count
        if padding > 0 {
            data.append(contentsOf: [UInt8](repeating: 0, count: padding))
        }
    }

    /// Decodes the fixed-width NUL-padded build field (rules from spec §3.1).
    private static func decodeBuild(_ field: [UInt8]) throws -> String {
        guard let terminator = field.firstIndex(of: 0) else {
            throw ProfileCodecError.invalidBuild(field)
        }
        guard terminator >= 1 else { throw ProfileCodecError.invalidBuild(field) }
        let buildBytes = Array(field[..<terminator])
        guard field[terminator...].allSatisfy({ $0 == 0 }), isValidBuild(buildBytes) else {
            throw ProfileCodecError.invalidBuild(field)
        }
        return String(decoding: buildBytes, as: UTF8.self)
    }
}
