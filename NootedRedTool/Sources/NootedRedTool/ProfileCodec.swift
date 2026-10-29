import Foundation

// MARK: - NRPT v2 binary patch profile
//
// Pure host-side codec for the binary profile defined in docs/PatchProfile-Spec.md.
// Foundation only: no file I/O, no environment access, no hardcoded patch data.
// Every model value is supplied by the caller; encoders derive counts, table sizes and
// the payload checksum from the arrays so a profile can never be internally inconsistent.
//
// Layout (little-endian, packed, no implicit padding):
//   Header 64 B | PageTable pageCount*32 B | SiteTable siteCount*40 B | ImageTable imageTableSize B
//
// v2 adds the target-image metadata required by the direct-patch path: each page record names
// its image (index into the image table), the segment and section inside that image and the
// 4 KiB page index inside the segment. The image table carries the image path and kind
// (standalone file-backed Mach-O or dyld shared cache image). All values are produced by the
// generator from the parsed target image; none are baked into the consumer.
//
// Fail-closed contract: `decode` rejects the whole byte string with a typed
// ProfileCodecError for any rule violation; `encode` refuses any invalid model.
// Nothing is partially accepted.

// MARK: - Format constants

enum NRPTFormat {
    /// ASCII "NRPT".
    static let magic: [UInt8] = [0x4E, 0x52, 0x50, 0x54]

    static let version: UInt16 = 2
    static let headerSize = 64
    static let pageRecordSize = 32
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

    /// Target image table (v2).
    static let maxImages = 16
    static let maxImagePathLength = 200
    static let imageEntryHeaderSize = 20
    static let maxSegmentsPerImage = 16
    static let maxSectionsPerImage = 16
    static let segmentNameSize = 16
    static let sectionNameSize = 16
    /// Image table entries carry their own size; bound the whole table defensively.
    static let maxImageTableSize = maxImages * (imageEntryHeaderSize
        + roundUp4(maxImagePathLength + 1)
        + maxSegmentsPerImage * segmentNameSize
        + maxSectionsPerImage * sectionNameSize)

    /// APU family bits defined for the profile identity gate (Raven .. Green Sardine).
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
        static let imageCount = 52
        static let imageTableSize = 54
        static let reserved = 58
        static let reservedSize = 6
    }

    /// Page record field offsets (v2, 32 bytes).
    enum PageRecord {
        static let pageFileOffset = 0
        static let pageHash = 8
        static let firstSite = 16
        static let siteCount = 20
        static let matchFlags = 22
        static let imageIndex = 24
        static let reserved = 26
        static let pageVmOffset = 28
    }

    /// Image table entry (v2, 20-byte header then variable tables):
    ///   kind u8, flags u8 (bit0 = match path by suffix), pathLength u16,
    ///   imageUnslidVmaddr u64, imageVmSize u32, segmentCount u8, sectionCount u8,
    ///   reserved u16,
    ///   path bytes (NUL-terminated, padded to 4-byte alignment),
    ///   segmentCount * 16-byte segment names, sectionCount * 16-byte section names.
    enum ImageEntry {
        static let kind = 0
        static let flags = 1
        static let pathLength = 2
        static let imageUnslidVmaddr = 4
        static let imageVmSize = 12
        static let segmentCount = 16
        static let sectionCount = 17
        static let reserved = 18
        static let headerSize = 20

        /// Path is matched by suffix (absolute installed path vs. the running map path).
        static let flagSuffixMatch: UInt8 = 1 << 0
        static let allKnownFlags: UInt8 = flagSuffixMatch
    }

    static func pageTableOffset(pageIndex: Int) -> Int {
        headerSize + pageIndex * pageRecordSize
    }

    /// Wire size of one image table entry: fixed header, NUL-terminated path padded to
    /// 4-byte alignment, then the fixed-width segment and section name tables.
    static func imageEntrySize(pathLength: Int, segmentCount: Int, sectionCount: Int) -> Int {
        imageEntryHeaderSize + roundUp4(pathLength + 1)
            + segmentCount * segmentNameSize + sectionCount * sectionNameSize
    }

    static func roundUp4(_ value: Int) -> Int {
        (value + 3) & ~3
    }

    static func encodedSize(pageCount: Int, siteCount: Int, imageTableSize: Int) -> Int {
        headerSize + pageCount * pageRecordSize + siteCount * siteRecordSize + imageTableSize
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

/// Target image kind for the direct-patch locator.
enum NRPTImageKind: UInt8, Equatable {
    /// Standalone, file-backed Mach-O (e.g. the GL driver bundle executable).
    case standaloneFile = 0
    /// Image inside the split dyld shared cache.
    case dyldSharedCache = 1
}

/// One target image referenced by page records (v2 image table entry).
struct NRPTImage: Equatable {
    /// Standalone file-backed image or dyld shared cache image.
    var kind: NRPTImageKind
    /// Canonical image path derived from the parsed target, e.g.
    /// "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2".
    /// Always starts with "/"; the generator strips fixture-root prefixes so the bytes are
    /// independent of where the fixture was extracted.
    var path: String
    /// Unslid VM address of the image's mach header (`__TEXT` vmaddr) as parsed from the
    /// image. For a dyld shared cache image this is the cache's unslid address, so the
    /// consumer can derive slide = imageLoadAddress - imageUnslidVmaddr. Standalone dylibs
    /// use 0 here and are located by path suffix instead.
    var unslidVMAddress: UInt64
    /// Total mapped image extent used to bound `pageVmOffset` before any user-map read.
    var vmSize: UInt32
    /// Segment names of the parsed image (evidence/metadata, 1...16).
    var segmentNames: [String]
    /// Section names of the parsed image (evidence/metadata, 0...16).
    var sectionNames: [String]

    init(kind: NRPTImageKind, path: String, unslidVMAddress: UInt64, vmSize: UInt32,
         segmentNames: [String], sectionNames: [String]) {
        self.kind = kind
        self.path = path
        self.unslidVMAddress = unslidVMAddress
        self.vmSize = vmSize
        self.segmentNames = segmentNames
        self.sectionNames = sectionNames
    }

    var pathBytes: [UInt8] { Array(path.utf8) }

    /// Encoded size of this image's table entry.
    var entrySize: Int {
        NRPTFormat.imageEntrySize(pathLength: pathBytes.count,
                                  segmentCount: segmentNames.count,
                                  sectionCount: sectionNames.count)
    }
}

/// One page record (64 bytes on the wire) plus the sites it owns and the target-image
/// metadata used by the direct-patch path.
struct NRPTPage: Equatable {
    /// Page base offset in the target image namespace; must be 4096-aligned.
    var pageFileOffset: UInt64
    /// FNV-1a-64 over the complete 4096-byte clean page.
    var pageHash: UInt64
    /// Identity rules; defaults to offset + hash + sites.
    var matchFlags: NRPTMatchFlags
    /// Sites in site-table order; 1...64 entries.
    var sites: [NRPTSite]
    /// Index into `NRPTProfile.images` (v2).
    var imageIndex: UInt16
    /// 4096-aligned offset of the page from the image's unslid mach-header VM address
    /// (v2): `pageStartVA - image.unslidVMAddress`. The consumer computes the live page
    /// address as `imageLoadAddress + pageVmOffset`.
    var pageVmOffset: UInt32

    init(pageFileOffset: UInt64, pageHash: UInt64, matchFlags: NRPTMatchFlags = .defaultV1,
         sites: [NRPTSite], imageIndex: UInt16, pageVmOffset: UInt32) {
        self.pageFileOffset = pageFileOffset
        self.pageHash = pageHash
        self.matchFlags = matchFlags
        self.sites = sites
        self.imageIndex = imageIndex
        self.pageVmOffset = pageVmOffset
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

/// A complete NRPT v2 profile: header identity, target image table and canonical page/site
/// tables.
struct NRPTProfile: Equatable {
    var header: NRPTHeader
    /// Target image table; page records index into this array (v2).
    var images: [NRPTImage]
    var pages: [NRPTPage]

    init(header: NRPTHeader, images: [NRPTImage], pages: [NRPTPage]) {
        self.header = header
        self.images = images
        self.pages = pages
    }

    var pageCount: Int { pages.count }
    var siteCount: Int { pages.reduce(0) { $0 + $1.sites.count } }
    var imageTableSize: Int { images.reduce(0) { $0 + $1.entrySize } }
    var encodedSize: Int {
        NRPTFormat.encodedSize(pageCount: pageCount, siteCount: siteCount,
                               imageTableSize: imageTableSize)
    }
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
    /// E034: `imageCount` outside 1...64.
    case invalidImageCount(Int)
    /// E035: an image table entry is malformed (kind, reserved byte or pathLength).
    case invalidImageEntry(imageIndex: Int, reason: String)
    /// E036: `imageTableSize` differs from the size derived from the entries.
    case imageTableSizeMismatch(stored: UInt32, derived: UInt32)
    /// E037: an image path is empty, too long, non-printable or not absolute.
    case invalidImagePath(imageIndex: Int)
    /// E038: page metadata is invalid (image index, reserved bytes, empty/invalid segment or
    /// section name).
    case invalidPageMetadata(pageIndex: Int)
    /// E039: two image table entries have the same kind and path.
    case duplicateImagePath(imageIndex: Int, duplicateOf: Int)
    /// E040: `pageVmOffset` is not 4 KiB aligned or the page leaves the image extent.
    case invalidPageVmOffset(pageIndex: Int)
    /// E041: an image's `imageUnslidVmaddr`/`imageVmSize` geometry is invalid.
    case invalidImageGeometry(imageIndex: Int)

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
        case .invalidImageCount: return "E034"
        case .invalidImageEntry: return "E035"
        case .imageTableSizeMismatch: return "E036"
        case .invalidImagePath: return "E037"
        case .invalidPageMetadata: return "E038"
        case .duplicateImagePath: return "E039"
        case .invalidPageVmOffset: return "E040"
        case .invalidImageGeometry: return "E041"
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
        case let .invalidImageCount(count):
            return "\(code): imageCount \(count) outside 1...\(NRPTFormat.maxImages)"
        case let .invalidImageEntry(imageIndex, reason):
            return "\(code): image \(imageIndex) entry is invalid: \(reason)"
        case let .imageTableSizeMismatch(stored, derived):
            return "\(code): imageTableSize \(stored), derived \(derived)"
        case let .invalidImagePath(imageIndex):
            return "\(code): image \(imageIndex) path is invalid"
        case let .invalidPageMetadata(pageIndex):
            return "\(code): page \(pageIndex) target-image metadata is invalid"
        case let .duplicateImagePath(imageIndex, duplicateOf):
            return "\(code): image \(imageIndex) duplicates image \(duplicateOf) path"
        case let .invalidPageVmOffset(pageIndex):
            return "\(code): page \(pageIndex) pageVmOffset is unaligned or outside the image extent"
        case let .invalidImageGeometry(imageIndex):
            return "\(code): image \(imageIndex) unslid address/extent is invalid"
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

        // Target image table (v2).
        guard !profile.images.isEmpty, profile.images.count <= NRPTFormat.maxImages else {
            throw ProfileCodecError.invalidImageCount(profile.images.count)
        }
        for (imageIndex, image) in profile.images.enumerated() {
            let pathBytes = image.pathBytes
            guard pathBytes.count >= 1, pathBytes.count <= NRPTFormat.maxImagePathLength,
                  pathBytes.allSatisfy(isAllowedImagePathByte),
                  pathBytes.first == UInt8(ascii: "/") else {
                throw ProfileCodecError.invalidImagePath(imageIndex: imageIndex)
            }
            guard image.vmSize > 0, image.vmSize <= 0xFFFF_F000 else {
                throw ProfileCodecError.invalidImageGeometry(imageIndex: imageIndex)
            }
            switch image.kind {
            case .dyldSharedCache:
                guard image.unslidVMAddress != 0 else {
                    throw ProfileCodecError.invalidImageGeometry(imageIndex: imageIndex)
                }
            case .standaloneFile:
                break
            }
            guard !image.segmentNames.isEmpty,
                  image.segmentNames.count <= NRPTFormat.maxSegmentsPerImage,
                  image.sectionNames.count <= NRPTFormat.maxSectionsPerImage else {
                throw ProfileCodecError.invalidImageGeometry(imageIndex: imageIndex)
            }
            var seenNames: Set<String> = []
            for name in image.segmentNames {
                guard isValidImageName(name, capacity: NRPTFormat.segmentNameSize),
                      seenNames.insert(name).inserted else {
                    throw ProfileCodecError.invalidImageGeometry(imageIndex: imageIndex)
                }
            }
            seenNames.removeAll()
            for name in image.sectionNames {
                guard isValidImageName(name, capacity: NRPTFormat.sectionNameSize),
                      seenNames.insert(name).inserted else {
                    throw ProfileCodecError.invalidImageGeometry(imageIndex: imageIndex)
                }
            }
            for otherIndex in 0 ..< imageIndex {
                let other = profile.images[otherIndex]
                guard other.kind == image.kind, other.path == image.path else { continue }
                throw ProfileCodecError.duplicateImagePath(imageIndex: imageIndex,
                                                           duplicateOf: otherIndex)
            }
        }
        let imageTableSize = profile.imageTableSize
        guard imageTableSize <= NRPTFormat.maxImageTableSize else {
            throw ProfileCodecError.invalidImageCount(profile.images.count)
        }
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
            guard Int(page.imageIndex) < profile.images.count else {
                throw ProfileCodecError.invalidPageMetadata(pageIndex: pageIndex)
            }
            let targetImage = profile.images[Int(page.imageIndex)]
            guard page.pageVmOffset & 0x0FFF == 0,
                  UInt64(page.pageVmOffset) + UInt64(NRPTFormat.pageSize) <= UInt64(targetImage.vmSize) else {
                throw ProfileCodecError.invalidPageVmOffset(pageIndex: pageIndex)
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
        assert(imageTableSize >= profile.images.count * NRPTFormat.imageEntryHeaderSize)

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

    /// Image paths use printable ASCII only; the leading '/' is checked separately.
    private static func isAllowedImagePathByte(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte <= 0x7E
    }

    /// A fixed-width NUL-padded segment/section name: 1...capacity printable ASCII bytes.
    private static func isValidImageName(_ name: String, capacity: Int) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count >= 1, bytes.count < capacity else { return false }
        return bytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
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

    /// Serializes a valid profile into canonical NRPT v2 bytes.
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
            appendLE(page.imageIndex, to: &pageTable)
            appendLE(UInt16(0), to: &pageTable) // reserved
            appendLE(page.pageVmOffset, to: &pageTable)
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

        var imageTable = Data()
        imageTable.reserveCapacity(profile.imageTableSize)
        for image in profile.images {
            let pathBytes = image.pathBytes
            let entrySize = image.entrySize
            imageTable.append(image.kind.rawValue)
            imageTable.append(NRPTFormat.ImageEntry.flagSuffixMatch)
            appendLE(UInt16(pathBytes.count), to: &imageTable)
            appendLE(image.unslidVMAddress, to: &imageTable)
            appendLE(image.vmSize, to: &imageTable)
            imageTable.append(UInt8(image.segmentNames.count))
            imageTable.append(UInt8(image.sectionNames.count))
            appendLE(UInt16(0), to: &imageTable) // reserved
            imageTable.append(contentsOf: pathBytes)
            let pathFieldSize = NRPTFormat.roundUp4(pathBytes.count + 1)
            imageTable.append(contentsOf: [UInt8](repeating: 0, count: pathFieldSize - pathBytes.count))
            for name in image.segmentNames {
                appendFixedName(name, capacity: NRPTFormat.segmentNameSize, to: &imageTable)
            }
            for name in image.sectionNames {
                appendFixedName(name, capacity: NRPTFormat.sectionNameSize, to: &imageTable)
            }
            assert(imageTable.count % 4 == 0)
            assert(imageTable.count >= entrySize)
        }

        var payload = Data()
        payload.append(pageTable)
        payload.append(siteTable)
        payload.append(imageTable)
        let checksum = payloadChecksum(payload)

        var buildField = [UInt8](repeating: 0, count: NRPTFormat.buildFieldSize)
        let buildBytes = Array(profile.header.build.utf8)
        for (index, byte) in buildBytes.enumerated() {
            buildField[index] = byte
        }

        var output = Data()
        output.reserveCapacity(profile.encodedSize)
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
        appendLE(UInt16(profile.images.count), to: &output)
        appendLE(UInt32(imageTable.count), to: &output)
        output.append(contentsOf: [UInt8](repeating: 0, count: NRPTFormat.Header.reservedSize))
        output.append(pageTable)
        output.append(siteTable)
        output.append(imageTable)

        assert(output.count == profile.encodedSize)
        return output
    }

    /// Appends a fixed-width NUL-padded segment/section name.
    private static func appendFixedName(_ name: String, capacity: Int, to data: inout Data) {
        let bytes = Array(name.utf8)
        data.append(contentsOf: bytes)
        if bytes.count < capacity {
            data.append(contentsOf: [UInt8](repeating: 0, count: capacity - bytes.count))
        }
    }

    // MARK: Decode

    /// Parses and validates a complete NRPT v2 byte string.
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
        let imageCount = Int(leU16(bytes, NRPTFormat.Header.imageCount))
        guard pageCount >= 1 else { throw ProfileCodecError.emptyProfile }
        guard pageCount <= NRPTFormat.maxPages else {
            throw ProfileCodecError.pageCountOutOfRange(pageCount)
        }
        guard siteCount >= 1 else { throw ProfileCodecError.siteCountOutOfRange(siteCount) }
        guard siteCount <= NRPTFormat.maxSites else {
            throw ProfileCodecError.siteCountOutOfRange(siteCount)
        }
        guard imageCount >= 1, imageCount <= NRPTFormat.maxImages else {
            throw ProfileCodecError.invalidImageCount(imageCount)
        }
        let storedImageTableSize = Int(leU32(bytes, NRPTFormat.Header.imageTableSize))
        guard storedImageTableSize >= imageCount * NRPTFormat.imageEntryHeaderSize,
              storedImageTableSize <= NRPTFormat.maxImageTableSize else {
            throw ProfileCodecError.invalidImageEntry(imageIndex: 0,
                                                      reason: "implausible image table size")
        }

        let encodedSize = NRPTFormat.encodedSize(pageCount: pageCount, siteCount: siteCount,
                                                 imageTableSize: storedImageTableSize)
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

        // Payload checksum covers the page table, the site table and the image table.
        let payload = Data(bytes[NRPTFormat.headerSize...])
        let storedChecksum = leU32(bytes, NRPTFormat.Header.payloadChecksum)
        let computedChecksum = payloadChecksum(payload)
        guard storedChecksum == computedChecksum else {
            throw ProfileCodecError.payloadChecksumMismatch(stored: storedChecksum,
                                                            computed: computedChecksum)
        }

        let pageTableBase = NRPTFormat.headerSize
        let siteTableBase = pageTableBase + Int(storedPageTableSize)
        let imageTableBase = siteTableBase + Int(storedSiteTableSize)

        // Image table (v2).
        var images: [NRPTImage] = []
        images.reserveCapacity(imageCount)
        var imageCursor = imageTableBase
        for imageIndex in 0 ..< imageCount {
            guard imageCursor + NRPTFormat.ImageEntry.headerSize <= bytes.count else {
                throw ProfileCodecError.invalidImageEntry(imageIndex: imageIndex,
                                                          reason: "truncated header")
            }
            let kindByte = bytes[imageCursor + NRPTFormat.ImageEntry.kind]
            let flagsByte = bytes[imageCursor + NRPTFormat.ImageEntry.flags]
            let pathLength = Int(leU16(bytes, imageCursor + NRPTFormat.ImageEntry.pathLength))
            let unslidVmaddr = leU64(bytes, imageCursor + NRPTFormat.ImageEntry.imageUnslidVmaddr)
            let imageVmSize = leU32(bytes, imageCursor + NRPTFormat.ImageEntry.imageVmSize)
            let segmentCount = Int(bytes[imageCursor + NRPTFormat.ImageEntry.segmentCount])
            let sectionCount = Int(bytes[imageCursor + NRPTFormat.ImageEntry.sectionCount])
            let reservedImage = leU16(bytes, imageCursor + NRPTFormat.ImageEntry.reserved)
            guard reservedImage == 0 else {
                throw ProfileCodecError.invalidImageEntry(imageIndex: imageIndex,
                                                          reason: "reserved bytes set")
            }
            guard flagsByte & ~NRPTFormat.ImageEntry.allKnownFlags == 0,
                  flagsByte & NRPTFormat.ImageEntry.flagSuffixMatch != 0 else {
                throw ProfileCodecError.invalidImageEntry(imageIndex: imageIndex,
                                                          reason: "invalid flags \(flagsByte)")
            }
            guard let kind = NRPTImageKind(rawValue: kindByte) else {
                throw ProfileCodecError.invalidImageEntry(imageIndex: imageIndex,
                                                          reason: "unknown image kind \(kindByte)")
            }
            guard pathLength >= 1, pathLength <= NRPTFormat.maxImagePathLength,
                  segmentCount >= 1, segmentCount <= NRPTFormat.maxSegmentsPerImage,
                  sectionCount >= 0, sectionCount <= NRPTFormat.maxSectionsPerImage else {
                throw ProfileCodecError.invalidImageEntry(imageIndex: imageIndex,
                                                          reason: "invalid path/name counts")
            }
            let entrySize = NRPTFormat.imageEntrySize(pathLength: pathLength,
                                                      segmentCount: segmentCount,
                                                      sectionCount: sectionCount)
            guard imageCursor + entrySize <= bytes.count else {
                throw ProfileCodecError.invalidImageEntry(imageIndex: imageIndex,
                                                          reason: "entry exceeds profile")
            }
            let pathBase = imageCursor + NRPTFormat.ImageEntry.headerSize
            let pathFieldSize = NRPTFormat.roundUp4(pathLength + 1)
            let pathBytes = Array(bytes[pathBase ..< pathBase + pathLength])
            let terminator = bytes[pathBase + pathLength]
            let trailing = bytes[(pathBase + pathLength + 1) ..< (pathBase + pathFieldSize)]
            guard terminator == 0, trailing.allSatisfy({ $0 == 0 }) else {
                throw ProfileCodecError.invalidImageEntry(imageIndex: imageIndex,
                                                          reason: "path not NUL padded")
            }
            guard pathBytes.first == UInt8(ascii: "/"),
                  pathBytes.allSatisfy(isAllowedImagePathByte) else {
                throw ProfileCodecError.invalidImagePath(imageIndex: imageIndex)
            }
            let path = String(decoding: pathBytes, as: UTF8.self)
            guard !path.isEmpty else {
                throw ProfileCodecError.invalidImagePath(imageIndex: imageIndex)
            }
            var nameCursor = pathBase + pathFieldSize
            var segmentNames: [String] = []
            segmentNames.reserveCapacity(segmentCount)
            for _ in 0 ..< segmentCount {
                segmentNames.append(try decodeFixedName(bytes, nameCursor,
                                                        capacity: NRPTFormat.segmentNameSize,
                                                        pageIndex: -1))
                nameCursor += NRPTFormat.segmentNameSize
            }
            var sectionNames: [String] = []
            sectionNames.reserveCapacity(sectionCount)
            for _ in 0 ..< sectionCount {
                sectionNames.append(try decodeFixedName(bytes, nameCursor,
                                                        capacity: NRPTFormat.sectionNameSize,
                                                        pageIndex: -1))
                nameCursor += NRPTFormat.sectionNameSize
            }
            guard imageVmSize > 0, imageVmSize <= 0xFFFF_F000,
                  kind != .dyldSharedCache || unslidVmaddr != 0 else {
                throw ProfileCodecError.invalidImageGeometry(imageIndex: imageIndex)
            }
            for (otherIndex, other) in images.enumerated()
                where other.kind == kind && other.path == path {
                throw ProfileCodecError.duplicateImagePath(imageIndex: imageIndex,
                                                           duplicateOf: otherIndex)
            }
            images.append(NRPTImage(kind: kind, path: path, unslidVMAddress: unslidVmaddr,
                                    vmSize: imageVmSize, segmentNames: segmentNames,
                                    sectionNames: sectionNames))
            imageCursor += entrySize
        }
        let derivedImageTableSize = imageCursor - imageTableBase
        guard derivedImageTableSize == storedImageTableSize else {
            throw ProfileCodecError.imageTableSizeMismatch(stored: UInt32(storedImageTableSize),
                                                           derived: UInt32(derivedImageTableSize))
        }

        var pages: [NRPTPage] = []
        pages.reserveCapacity(pageCount)
        var runningFirstSite = 0
        for pageIndex in 0 ..< pageCount {
            let recordBase = pageTableBase + pageIndex * NRPTFormat.pageRecordSize
            let pageFileOffset = leU64(bytes, recordBase + NRPTFormat.PageRecord.pageFileOffset)
            let pageHash = leU64(bytes, recordBase + NRPTFormat.PageRecord.pageHash)
            let firstSite = leU32(bytes, recordBase + NRPTFormat.PageRecord.firstSite)
            let pageSites = Int(leU16(bytes, recordBase + NRPTFormat.PageRecord.siteCount))
            let matchFlagsRaw = leU16(bytes, recordBase + NRPTFormat.PageRecord.matchFlags)

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

            // Target-image metadata (v2).
            let imageIndex = leU16(bytes, recordBase + NRPTFormat.PageRecord.imageIndex)
            let reservedPageBytes = leU16(bytes, recordBase + NRPTFormat.PageRecord.reserved)
            let pageVmOffset = leU32(bytes, recordBase + NRPTFormat.PageRecord.pageVmOffset)
            guard reservedPageBytes == 0 else {
                throw ProfileCodecError.invalidPageMetadata(pageIndex: pageIndex)
            }
            guard Int(imageIndex) < imageCount else {
                throw ProfileCodecError.invalidPageMetadata(pageIndex: pageIndex)
            }
            let targetImage = images[Int(imageIndex)]
            guard pageVmOffset & 0x0FFF == 0,
                  UInt64(pageVmOffset) + UInt64(NRPTFormat.pageSize) <= UInt64(targetImage.vmSize) else {
                throw ProfileCodecError.invalidPageVmOffset(pageIndex: pageIndex)
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
                                  matchFlags: matchFlags, sites: sites,
                                  imageIndex: imageIndex,
                                  pageVmOffset: pageVmOffset))
            runningFirstSite += pageSites
        }
        guard runningFirstSite == siteCount else {
            throw ProfileCodecError.siteCountSumMismatch(declared: siteCount,
                                                         summed: runningFirstSite)
        }

        let profile = NRPTProfile(
            header: NRPTHeader(build: build, apuMask: apuMask, deviceID: deviceID,
                               flags: headerFlags),
            images: images,
            pages: pages)

        // Re-run the model validation as a single source of truth for the remaining rules
        // (site overlap, identity uniqueness, empty profile, limits, metadata bounds).
        try validate(profile)
        return profile
    }

    /// Decodes a fixed-width NUL-padded segment/section name. `imageIndex` and `pageIndex`
    /// select the error context: image-table names pass `pageIndex = -1` and use
    /// `imageIndex`, page-level names are no longer stored on the wire in v2.
    private static func decodeFixedName(_ bytes: [UInt8], _ offset: Int, capacity: Int,
                                        imageIndex: Int = -1, pageIndex: Int = -1) throws -> String {
        func contextError() -> ProfileCodecError {
            pageIndex >= 0
                ? ProfileCodecError.invalidPageMetadata(pageIndex: pageIndex)
                : ProfileCodecError.invalidImageEntry(imageIndex: max(imageIndex, 0),
                                                      reason: "invalid name table")
        }
        guard offset + capacity <= bytes.count else {
            throw contextError()
        }
        let field = bytes[offset ..< offset + capacity]
        guard let terminator = field.firstIndex(of: 0) else {
            throw contextError()
        }
        let nameBytes = Array(field[..<terminator])
        guard !nameBytes.isEmpty, nameBytes.count < capacity,
              nameBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
              field[terminator...].allSatisfy({ $0 == 0 }) else {
            throw contextError()
        }
        return String(decoding: nameBytes, as: UTF8.self)
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
