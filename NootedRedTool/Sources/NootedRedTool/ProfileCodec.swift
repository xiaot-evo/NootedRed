import Foundation

// MARK: - NRPT v3 patch profile
//
// Pure host-side codec for the binary profile and the `NRedProfiles` bundle defined in
// docs/PatchProfile-Spec.md (NRPT v3). Foundation only: no file I/O, no environment access,
// no hardcoded patch data. Every model value is supplied by the caller; encoders derive counts,
// table sizes and the payload checksum from the arrays so a profile can never be internally
// inconsistent.
//
// NRPT v3 replaces v1/v2 entirely: there is no v1/v2 compatibility mode, no per-page matchFlags
// and no offset comparison. A page's identity is the FNV-1a-64 hash of the complete 4096-byte
// page plus every site `find` byte. Each page carries a mode (PAGE = standalone `_cs_validate_page`,
// DYLD = dyld-shared-cache `_cs_validate_range`, RESOLVER reserved) and an image index for routing
// and evidence. Multiple profiles coexist in one `NRedProfiles` Info.plist array, selected by exact
// build + APU mask intersection + optional exact device ID.
//
// Layout (little-endian, packed, no implicit padding):
//   Header 64 B | PageTable pageCount*32 B | SiteTable siteCount*40 B | ImageTable imageTableSize B
//
// Fail-closed contract: `decode` rejects the whole byte string with a typed ProfileCodecError for
// any rule violation; `encode` refuses any invalid model. Nothing is partially accepted.

// MARK: - Format constants

enum NRPTFormat {
    /// ASCII "NRPT".
    static let magic: [UInt8] = [0x4E, 0x52, 0x50, 0x54]

    /// NRPT v3 only; every other version is rejected with E003.
    static let version: UInt16 = 3
    static let headerSize = 64
    static let pageRecordSize = 32
    static let siteRecordSize = 40
    static let imageEntryHeaderSize = 16

    /// Page unit hashed by `pageHash` and written by page patches.
    static let pageSize = 4096

    static let buildFieldSize = 16
    static let maxBuildBytes = 15

    static let maxProfileSize = 64 * 1024
    static let maxPages = 256
    static let maxSites = 1024
    static let maxSitesPerPage = 64
    static let maxSitePatchSize = 16

    /// Target image table (v3: simple kind/path + evidence geometry, no name tables).
    static let maxImages = 16
    static let maxImagePathLength = 200
    static let maxImageTableSize = 16 * (imageEntryHeaderSize + 204)
    static let maxImageVmSize: UInt32 = 0xFFFFF000

    /// `NRedProfiles` Info.plist array bounds.
    static let maxBundleEntries = 16

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
        static let reserved0 = 48
        static let imageCount = 52
        static let imageTableSize = 54
        static let reserved1 = 58
        static let reserved1Size = 6
    }

    /// Page record field offsets (32 bytes).
    enum PageRecord {
        static let pageFileOffset = 0
        static let pageHash = 8
        static let firstSite = 16
        static let siteCount = 20
        static let mode = 22
        static let flags = 23
        static let imageIndex = 24
        static let reserved = 26
        static let pageVmOffset = 28
    }

    /// Image table entry offsets (16-byte header, then NUL-padded path).
    enum ImageEntry {
        static let kind = 0
        static let reserved = 1
        static let pathLength = 2
        static let imageUnslidVmaddr = 4
        static let imageVmSize = 12
        static let headerSize = 16
    }

    /// Exact `NRedProfiles` Info.plist key names.
    enum Bundle {
        static let rootKey = "NRedProfiles"
        static let buildKey = "Build"
        static let apuMaskKey = "APUMask"
        static let deviceIDKey = "DeviceID"
        static let profileKey = "Profile"
        static let knownKeys: Set<String> = [buildKey, apuMaskKey, deviceIDKey, profileKey]
    }

    static func pageTableOffset(pageIndex: Int) -> Int {
        headerSize + pageIndex * pageRecordSize
    }

    static func siteTableOffset(pageCount: Int) -> Int {
        headerSize + pageCount * pageRecordSize
    }

    static func imageTableOffset(pageCount: Int, siteCount: Int) -> Int {
        headerSize + pageCount * pageRecordSize + siteCount * siteRecordSize
    }

    /// Wire size of one image table entry: 16-byte header, path bytes, NUL, 4-byte padding.
    static func imageEntrySize(pathLength: Int) -> Int {
        imageEntryHeaderSize + roundUp4(pathLength + 1)
    }

    static func roundUp4(_ value: Int) -> Int {
        (value + 3) & ~3
    }

    static func encodedSize(pageCount: Int, siteCount: Int, imageTableSize: Int) -> Int {
        headerSize + pageCount * pageRecordSize + siteCount * siteRecordSize + imageTableSize
    }
}

// MARK: - Modes and image kinds

/// Patch mode of one page record (wire u8 at page-record offset 22).
enum NRPTPageMode: UInt8, Equatable, Hashable, CaseIterable {
    /// Standalone file-backed vnode; applied from `_cs_validate_page` only.
    case page = 1
    /// dyld shared cache image; applied from `_cs_validate_range` only.
    case dyld = 2
    /// Reserved for a future resolver path. A v3 encoder never emits it and a v3 decoder rejects it.
    case resolver = 3
}

/// Target image kind (wire u8 at image-entry offset 0).
enum NRPTImageKind: UInt8, Equatable, Hashable, CaseIterable {
    /// Standalone, file-backed Mach-O (e.g. the GL driver bundle executable).
    case standaloneFile = 0
    /// Image inside the split dyld shared cache.
    case dyldSharedCache = 1
}

// MARK: - Model

/// One site record (40 bytes on the wire). Unchanged from the frozen site contract.
struct NRPTSite: Equatable {
    /// Byte offset from the page base. `siteInPage + size <= 4096`.
    var siteInPage: UInt16
    /// Expected current bytes. Length is `findSize` on the wire; 1...16 bytes.
    var find: [UInt8]
    /// Bytes to write. Length is `replaceSize` on the wire; must equal `find.count`.
    var replace: [UInt8]
    /// Reserved in v3: must be 0.
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

/// One target image referenced by page records (v3 image table entry).
struct NRPTImage: Equatable {
    /// Standalone file-backed image or dyld shared cache image.
    var kind: NRPTImageKind
    /// Canonical installed path derived from the parsed target, e.g.
    /// "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2".
    /// Always starts with "/"; the generator strips fixture-root prefixes so the bytes are
    /// independent of where the fixture was extracted.
    var path: String
    /// Evidence: unslid VM address of the image's mach header (`__TEXT` vmaddr). For a dyld shared
    /// cache image this is the cache's unslid address (non-zero); standalone images normally use 0.
    var unslidVMAddress: UInt64
    /// `__TEXT` vmsize: bound for the diagnostic `pageVmOffset`.
    var vmSize: UInt32

    init(kind: NRPTImageKind, path: String, unslidVMAddress: UInt64, vmSize: UInt32) {
        self.kind = kind
        self.path = path
        self.unslidVMAddress = unslidVMAddress
        self.vmSize = vmSize
    }

    var pathBytes: [UInt8] { Array(path.utf8) }

    /// Encoded size of this image's table entry.
    var entrySize: Int { NRPTFormat.imageEntrySize(pathLength: pathBytes.count) }
}

/// One page record (32 bytes on the wire) plus the sites it owns.
struct NRPTPage: Equatable {
    /// Diagnostic pager/file offset; 4 KiB aligned. Never used for matching.
    var pageFileOffset: UInt64
    /// FNV-1a-64 over the complete 4096-byte clean page. Identity.
    var pageHash: UInt64
    /// Patch mode: PAGE (page hook) or DYLD (range hook).
    var mode: NRPTPageMode
    /// Index into `NRPTProfile.images`; also selects the vnode gate target.
    var imageIndex: UInt16
    /// Diagnostic evidence: page start VA minus `image.unslidVMAddress`, 4 KiB aligned.
    var pageVmOffset: UInt32
    /// Sites in site-table order; 1...64 entries.
    var sites: [NRPTSite]

    init(pageFileOffset: UInt64, pageHash: UInt64, mode: NRPTPageMode, imageIndex: UInt16,
         pageVmOffset: UInt32, sites: [NRPTSite]) {
        self.pageFileOffset = pageFileOffset
        self.pageHash = pageHash
        self.mode = mode
        self.imageIndex = imageIndex
        self.pageVmOffset = pageVmOffset
        self.sites = sites
    }
}

/// Header identity fields. Counts, table sizes and checksum are derived by the encoder.
struct NRPTHeader: Equatable {
    /// Exact expected `kern.osversion`, 1...15 characters from `[0-9A-Za-z._-]`.
    var build: String
    /// Non-zero APU family mask, subset of `NRPTFormat.knownApuMask`.
    var apuMask: UInt32
    /// `0` = no device gate; `1...0xFFFF` = exact PCI device ID gate.
    var deviceID: UInt32

    init(build: String, apuMask: UInt32, deviceID: UInt32 = 0) {
        self.build = build
        self.apuMask = apuMask
        self.deviceID = deviceID
    }
}

/// A complete NRPT v3 profile: header identity + page/site/image tables.
struct NRPTProfile: Equatable {
    var header: NRPTHeader
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

/// One `NRedProfiles` Info.plist entry: profile bytes plus the metadata used to select them.
struct NRedProfilesEntry: Equatable {
    var build: String
    var apuMask: UInt32
    var deviceID: UInt32
    var profile: NRPTProfile

    init(build: String, apuMask: UInt32, deviceID: UInt32, profile: NRPTProfile) {
        self.build = build
        self.apuMask = apuMask
        self.deviceID = deviceID
        self.profile = profile
    }
}

/// The complete `NRedProfiles` property: multiple profiles coexisting in one Info.plist array.
struct NRedProfilesBundle: Equatable {
    var entries: [NRedProfilesEntry]

    init(entries: [NRedProfilesEntry]) {
        self.entries = entries
    }
}

/// Result of querying a bundle for the running machine identity.
enum NRedProfilesSelection: Equatable {
    /// Exactly one entry matched; use `profile`. `index` is the bundle array index.
    case selected(index: Int, profile: NRPTProfile)
    /// No entry has the exact running build (no cross-build fallback).
    case unsupportedBuild
    /// The exact-build entry's APU mask does not intersect the running family mask.
    case apuMismatch
    /// The exact-build entry requires an exact device ID that does not match the running GPU.
    case deviceMismatch
}

/// Result of the pure page-application simulation (`ProfileCodec.applyPage`).
enum NRPTPageApplication: Equatable {
    /// No page record in the requested mode matched the supplied page.
    case noMatch
    /// A record identity matched but a site `find` did not; no bytes were written.
    case siteFindMismatch(pageIndex: Int, siteIndex: Int)
    /// A record identity matched and its sites were applied; `data` is the patched 4 KiB page.
    case applied(pageIndex: Int, data: Data)
    /// The delivered page already carries every `replace` byte of a record (shared page cache
    /// delivery after an earlier patch); mark applied, never write.
    case alreadyPatched(pageIndex: Int)
}

// MARK: - Errors

/// Stable validation errors. `code` (E001...E041, E050...E053) is the stable diagnostic identity;
/// associated values carry the field context used in logs.
enum ProfileCodecError: Error, Equatable, CustomStringConvertible {
    case truncated(actual: Int, minimum: Int)
    case badMagic([UInt8])
    case unsupportedVersion(UInt16)
    case invalidHeaderSize(UInt16)
    case invalidBuild([UInt8])
    case invalidApuMask(UInt32)
    case invalidDeviceID(UInt32)
    case reservedHeaderFieldNotZero(UInt32)
    case reservedHeaderBytesNotZero
    case profileTooLarge(Int)
    case pageTableSizeMismatch(stored: UInt32, expected: UInt32)
    case siteTableSizeMismatch(stored: UInt32, expected: UInt32)
    case totalSizeMismatch(declared: Int, actual: Int)
    case payloadChecksumMismatch(stored: UInt32, computed: UInt32)
    case pageCountOutOfRange(Int)
    case siteCountOutOfRange(Int)
    case pageFileOffsetMisaligned(pageIndex: Int, offset: UInt64)
    case unsupportedPageMode(pageIndex: Int, mode: UInt8)
    case pageModeImageKindMismatch(pageIndex: Int, mode: NRPTPageMode, kind: NRPTImageKind)
    case pageSiteRangeInvalid(pageIndex: Int, firstSite: UInt32, siteCount: Int,
                              headerSiteCount: Int)
    case nonCanonicalSiteRange(pageIndex: Int, expectedFirstSite: UInt32,
                               actualFirstSite: UInt32)
    case siteCountSumMismatch(declared: Int, summed: Int)
    case sitesPerPageExceeded(pageIndex: Int, count: Int)
    case invalidSitePatchSize(siteIndex: Int, findSize: Int, replaceSize: Int)
    case findReplaceSizeMismatch(siteIndex: Int, findSize: Int, replaceSize: Int)
    case siteOutOfPageBounds(siteIndex: Int, siteInPage: Int, size: Int)
    case sitePaddingNotZero(siteIndex: Int)
    case noOpSite(siteIndex: Int)
    case unsupportedSiteFlags(siteIndex: Int, flags: UInt32)
    case overlappingSiteWrites(pageIndex: Int, firstSite: Int, secondSite: Int)
    case duplicatePageIdentity(pageIndex: Int, duplicateOf: Int)
    case emptyProfile
    /// Codec-helper precondition, not a wire rule: `pageHash` input is not exactly 4096 bytes.
    case invalidPageSize(actual: Int)
    case invalidImageCount(Int)
    case invalidImageEntry(imageIndex: Int)
    case imageTableSizeMismatch(stored: UInt32, expected: UInt32)
    case invalidImagePath(imageIndex: Int)
    case invalidPageMetadata(pageIndex: Int)
    case duplicateImagePath(imageIndex: Int, duplicateOf: Int)
    case invalidPageVmOffset(pageIndex: Int, value: UInt32)
    case invalidImageGeometry(imageIndex: Int)
    case bundleCountOutOfRange(Int)
    case duplicateBundleBuild(String)
    case bundleEntryProfileMismatch(entryIndex: Int, field: String)
    case invalidBundleEntry(entryIndex: Int, reason: String)

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
        case .reservedHeaderFieldNotZero: return "E008"
        case .reservedHeaderBytesNotZero: return "E009"
        case .profileTooLarge: return "E010"
        case .pageTableSizeMismatch: return "E011"
        case .siteTableSizeMismatch: return "E012"
        case .totalSizeMismatch: return "E013"
        case .payloadChecksumMismatch: return "E014"
        case .pageCountOutOfRange: return "E015"
        case .siteCountOutOfRange: return "E016"
        case .pageFileOffsetMisaligned: return "E017"
        case .unsupportedPageMode: return "E018"
        case .pageModeImageKindMismatch: return "E019"
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
        case .bundleCountOutOfRange: return "E050"
        case .duplicateBundleBuild: return "E051"
        case .bundleEntryProfileMismatch: return "E052"
        case .invalidBundleEntry: return "E053"
        }
    }

    var description: String {
        switch self {
        case let .truncated(actual, minimum):
            return "\(code): profile is \(actual) bytes, header needs at least \(minimum)"
        case let .badMagic(bytes):
            return "\(code): magic is \(hex(bytes)), expected 'NRPT'"
        case let .unsupportedVersion(version):
            return "\(code): unsupported profile version \(version), v3 required"
        case let .invalidHeaderSize(size):
            return "\(code): headerSize \(size), expected \(NRPTFormat.headerSize)"
        case let .invalidBuild(bytes):
            return "\(code): invalid build field \(hex(bytes))"
        case let .invalidApuMask(mask):
            return "\(code): invalid APU mask \(hex(mask))"
        case let .invalidDeviceID(deviceID):
            return "\(code): invalid deviceID \(hex(deviceID)) (0 or 1...0xFFFF)"
        case let .reservedHeaderFieldNotZero(value):
            return "\(code): header bytes 48-51 are reserved, found \(hex(value))"
        case .reservedHeaderBytesNotZero:
            return "\(code): header bytes 58-63 are reserved and must be zero"
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
        case let .pageFileOffsetMisaligned(pageIndex, offset):
            return "\(code): page \(pageIndex) pageFileOffset \(hex(offset)) is not 4 KiB aligned"
        case let .unsupportedPageMode(pageIndex, mode):
            return "\(code): page \(pageIndex) mode \(mode) is not supported by v3"
        case let .pageModeImageKindMismatch(pageIndex, mode, kind):
            return "\(code): page \(pageIndex) mode \(mode) does not match image kind \(kind)"
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
            return "\(code): site \(siteIndex) flags \(hex(flags)) are reserved in v3"
        case let .overlappingSiteWrites(pageIndex, firstSite, secondSite):
            return "\(code): page \(pageIndex) sites \(firstSite)/\(secondSite) overlap"
        case let .duplicatePageIdentity(pageIndex, duplicateOf):
            return "\(code): page \(pageIndex) duplicates page \(duplicateOf) identity"
        case .emptyProfile:
            return "\(code): profile has no pages"
        case let .invalidPageSize(actual):
            return "\(code): page is \(actual) bytes, expected \(NRPTFormat.pageSize)"
        case let .invalidImageCount(count):
            return "\(code): imageCount \(count) outside 1...\(NRPTFormat.maxImages) "
                + "or image table out of bounds"
        case let .invalidImageEntry(imageIndex):
            return "\(code): image table entry \(imageIndex) is malformed"
        case let .imageTableSizeMismatch(stored, expected):
            return "\(code): imageTableSize \(stored), expected \(expected)"
        case let .invalidImagePath(imageIndex):
            return "\(code): image \(imageIndex) path is empty, >200, non-printable or relative"
        case let .invalidPageMetadata(pageIndex):
            return "\(code): page \(pageIndex) flags/reserved/imageIndex are invalid"
        case let .duplicateImagePath(imageIndex, duplicateOf):
            return "\(code): image \(imageIndex) duplicates image \(duplicateOf) (kind, path)"
        case let .invalidPageVmOffset(pageIndex, value):
            return "\(code): page \(pageIndex) pageVmOffset \(hex(value)) is unaligned "
                + "or leaves the image"
        case let .invalidImageGeometry(imageIndex):
            return "\(code): image \(imageIndex) geometry is invalid"
        case let .bundleCountOutOfRange(count):
            return "\(code): bundle has \(count) entries, allowed 1..."
                + "\(NRPTFormat.maxBundleEntries)"
        case let .duplicateBundleBuild(build):
            return "\(code): bundle has more than one entry for build '\(build)'"
        case let .bundleEntryProfileMismatch(entryIndex, field):
            return "\(code): bundle entry \(entryIndex) \(field) differs from its profile header"
        case let .invalidBundleEntry(entryIndex, reason):
            return "\(code): bundle entry \(entryIndex): \(reason)"
        }
    }

    private func hex<T: FixedWidthInteger>(_ value: T) -> String {
        String(format: "0x%llX", UInt64(truncatingIfNeeded: value))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
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

    /// FNV-1a-32 over the payload: page-table, site-table, then image-table bytes.
    static func payloadChecksum(pageTable: Data, siteTable: Data, imageTable: Data) -> UInt32 {
        var hash: UInt32 = 0x811C9DC5
        for byte in pageTable {
            hash = (hash ^ UInt32(byte)) &* 0x01000193
        }
        for byte in siteTable {
            hash = (hash ^ UInt32(byte)) &* 0x01000193
        }
        for byte in imageTable {
            hash = (hash ^ UInt32(byte)) &* 0x01000193
        }
        return hash
    }

    /// FNV-1a-32 over a raw payload byte string (all bytes after the 64-byte header).
    static func payloadChecksum(_ payload: Data) -> UInt32 {
        payloadChecksum(pageTable: payload, siteTable: Data(), imageTable: Data())
    }

    // MARK: Model validation

    /// Validates every model-level rule of docs/PatchProfile-Spec.md. Throws the first violation.
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

        guard !profile.images.isEmpty, profile.images.count <= NRPTFormat.maxImages else {
            throw ProfileCodecError.invalidImageCount(profile.images.count)
        }
        for (imageIndex, image) in profile.images.enumerated() {
            try validateImage(image, index: imageIndex)
        }
        for imageIndex in 0 ..< profile.images.count {
            for otherIndex in 0 ..< imageIndex {
                let image = profile.images[imageIndex]
                let other = profile.images[otherIndex]
                if image.kind == other.kind, image.path == other.path {
                    throw ProfileCodecError.duplicateImagePath(imageIndex: imageIndex,
                                                               duplicateOf: otherIndex)
                }
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
            guard Int(page.imageIndex) < profile.images.count else {
                throw ProfileCodecError.invalidPageMetadata(pageIndex: pageIndex)
            }
            let image = profile.images[Int(page.imageIndex)]

            switch page.mode {
            case .resolver:
                throw ProfileCodecError.unsupportedPageMode(pageIndex: pageIndex,
                                                             mode: page.mode.rawValue)
            case .page:
                guard image.kind == .standaloneFile else {
                    throw ProfileCodecError.pageModeImageKindMismatch(pageIndex: pageIndex,
                                                                      mode: page.mode,
                                                                      kind: image.kind)
                }
            case .dyld:
                guard image.kind == .dyldSharedCache else {
                    throw ProfileCodecError.pageModeImageKindMismatch(pageIndex: pageIndex,
                                                                      mode: page.mode,
                                                                      kind: image.kind)
                }
            }

            guard page.pageFileOffset & 0x0FFF == 0 else {
                throw ProfileCodecError.pageFileOffsetMisaligned(
                    pageIndex: pageIndex, offset: page.pageFileOffset)
            }
            let vmOffset = UInt64(page.pageVmOffset)
            guard vmOffset & 0xFFF == 0,
                  vmOffset + UInt64(NRPTFormat.pageSize) <= UInt64(image.vmSize) else {
                throw ProfileCodecError.invalidPageVmOffset(pageIndex: pageIndex,
                                                            value: page.pageVmOffset)
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
                guard inPage + findSize <= NRPTFormat.pageSize else {
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

            let ordered = writes.sorted { lhs, rhs in
                lhs.start != rhs.start ? lhs.start < rhs.start : lhs.siteIndex < rhs.siteIndex
            }
            if ordered.count > 1 {
                for index in 1 ..< ordered.count where ordered[index].start < ordered[index - 1].end {
                    throw ProfileCodecError.overlappingSiteWrites(
                        pageIndex: pageIndex,
                        firstSite: ordered[index - 1].siteIndex,
                        secondSite: ordered[index].siteIndex)
                }
            }

            globalSiteIndex += page.sites.count
        }
        assert(globalSiteIndex == totalSites)

        // Identity uniqueness is per (pageHash, mode): PAGE and DYLD are disjoint matching domains.
        for pageIndex in 0 ..< profile.pages.count {
            for otherIndex in 0 ..< pageIndex {
                let page = profile.pages[pageIndex]
                let other = profile.pages[otherIndex]
                if page.pageHash == other.pageHash, page.mode == other.mode {
                    throw ProfileCodecError.duplicatePageIdentity(pageIndex: pageIndex,
                                                                  duplicateOf: otherIndex)
                }
            }
        }
    }

    /// Validates header identity fields (shared by encode, decode and the bundle checks).
    static func validateHeader(_ header: NRPTHeader) throws {
        let buildBytes = Array(header.build.utf8)
        guard isValidBuild(buildBytes) else {
            throw ProfileCodecError.invalidBuild(buildBytes)
        }
        guard header.apuMask != 0, header.apuMask & ~NRPTFormat.knownApuMask == 0 else {
            throw ProfileCodecError.invalidApuMask(header.apuMask)
        }
        guard header.deviceID <= 0xFFFF else {
            throw ProfileCodecError.invalidDeviceID(header.deviceID)
        }
    }

    private static func validateImage(_ image: NRPTImage, index: Int) throws {
        let pathBytes = image.pathBytes
        guard pathBytes.count >= 1, pathBytes.count <= NRPTFormat.maxImagePathLength,
              pathBytes.first == UInt8(ascii: "/"),
              pathBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
            throw ProfileCodecError.invalidImagePath(imageIndex: index)
        }
        guard image.vmSize >= 1, image.vmSize <= NRPTFormat.maxImageVmSize else {
            throw ProfileCodecError.invalidImageGeometry(imageIndex: index)
        }
        if image.kind == .dyldSharedCache, image.unslidVMAddress == 0 {
            throw ProfileCodecError.invalidImageGeometry(imageIndex: index)
        }
    }

    // MARK: Bundle validation and selection

    /// Validates the whole `NRedProfiles` bundle: count, per-entry metadata, embedded profiles and
    /// the entry↔profile-header identity agreement.
    static func validateBundle(_ bundle: NRedProfilesBundle) throws {
        guard !bundle.entries.isEmpty, bundle.entries.count <= NRPTFormat.maxBundleEntries else {
            throw ProfileCodecError.bundleCountOutOfRange(bundle.entries.count)
        }

        for (entryIndex, entry) in bundle.entries.enumerated() {
            try validateHeader(NRPTHeader(build: entry.build, apuMask: entry.apuMask,
                                          deviceID: entry.deviceID))
            try validate(entry.profile)

            guard entry.profile.header.build == entry.build else {
                throw ProfileCodecError.bundleEntryProfileMismatch(entryIndex: entryIndex,
                                                                   field: "Build")
            }
            guard entry.profile.header.apuMask == entry.apuMask else {
                throw ProfileCodecError.bundleEntryProfileMismatch(entryIndex: entryIndex,
                                                                   field: "APUMask")
            }
            guard entry.profile.header.deviceID == entry.deviceID else {
                throw ProfileCodecError.bundleEntryProfileMismatch(entryIndex: entryIndex,
                                                                   field: "DeviceID")
            }
        }

        for entryIndex in 0 ..< bundle.entries.count {
            for otherIndex in 0 ..< entryIndex
                where bundle.entries[entryIndex].build == bundle.entries[otherIndex].build {
                throw ProfileCodecError.duplicateBundleBuild(bundle.entries[entryIndex].build)
            }
        }
    }

    /// Exact selector semantics (spec §8.1): unique exact build, then APU intersection, then the
    /// optional exact device-ID gate. No cross-build/device fallback and no ambiguity rule.
    static func select(from bundle: NRedProfilesBundle, build: String,
                       runningApuMask: UInt32,
                       runningDeviceID: UInt16) throws -> NRedProfilesSelection {
        try validateBundle(bundle)

        guard let index = bundle.entries.firstIndex(where: { $0.build == build }) else {
            return .unsupportedBuild
        }
        let entry = bundle.entries[index]

        guard (entry.apuMask & runningApuMask) != 0 else { return .apuMismatch }
        guard entry.deviceID == 0 || entry.deviceID == UInt32(runningDeviceID) else {
            return .deviceMismatch
        }
        return .selected(index: index, profile: entry.profile)
    }

    /// Provisional-candidate query used while the running `kern.osversion` is not yet readable
    /// (spec §8.2). Returns the single entry whose APU/device gates pass ignoring build, or nil
    /// when zero or more than one entry qualifies (never a guess). The caller MUST confirm with
    /// `select` once the actual build is readable and stop writes on a mismatch.
    static func provisionalCandidate(from bundle: NRedProfilesBundle, runningApuMask: UInt32,
                                     runningDeviceID: UInt16) throws -> NRedProfilesSelection? {
        try validateBundle(bundle)
        let candidates = bundle.entries.enumerated().filter { _, entry in
            (entry.apuMask & runningApuMask) != 0
                && (entry.deviceID == 0 || entry.deviceID == UInt32(runningDeviceID))
        }
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        return .selected(index: candidate.offset, profile: candidate.element.profile)
    }

    // MARK: Bundle plist conversion

    /// Property-list representation of the `NRedProfiles` array: dictionaries with the exact keys
    /// `Build` (String), `APUMask` (integer), `DeviceID` (integer) and `Profile` (Data).
    static func nredProfilesArray(_ bundle: NRedProfilesBundle) throws -> [[String: Any]] {
        try validateBundle(bundle)
        return try bundle.entries.map { entry in
            [
                NRPTFormat.Bundle.buildKey: entry.build,
                NRPTFormat.Bundle.apuMaskKey: Int(entry.apuMask),
                NRPTFormat.Bundle.deviceIDKey: Int(entry.deviceID),
                NRPTFormat.Bundle.profileKey: try encode(entry.profile),
            ]
        }
    }

    /// Builds a validated bundle from the property-list `NRedProfiles` array.
    static func bundle(fromNRedProfilesArray array: [[String: Any]]) throws -> NRedProfilesBundle {
        var entries: [NRedProfilesEntry] = []
        entries.reserveCapacity(array.count)

        for (entryIndex, dictionary) in array.enumerated() {
            let keys = Set(dictionary.keys)
            guard keys == NRPTFormat.Bundle.knownKeys else {
                throw ProfileCodecError.invalidBundleEntry(
                    entryIndex: entryIndex,
                    reason: "keys must be exactly Build, APUMask, DeviceID, Profile")
            }
            guard let build = dictionary[NRPTFormat.Bundle.buildKey] as? String else {
                throw ProfileCodecError.invalidBundleEntry(entryIndex: entryIndex,
                                                           reason: "Build is not a String")
            }
            guard let apuMask = unsigned32(dictionary[NRPTFormat.Bundle.apuMaskKey]) else {
                throw ProfileCodecError.invalidBundleEntry(entryIndex: entryIndex,
                                                           reason: "APUMask is not a u32")
            }
            guard let deviceID = unsigned32(dictionary[NRPTFormat.Bundle.deviceIDKey]) else {
                throw ProfileCodecError.invalidBundleEntry(entryIndex: entryIndex,
                                                           reason: "DeviceID is not a u32")
            }
            guard let profileData = dictionary[NRPTFormat.Bundle.profileKey] as? Data else {
                throw ProfileCodecError.invalidBundleEntry(entryIndex: entryIndex,
                                                           reason: "Profile is not Data")
            }
            let profile = try decode(profileData)
            entries.append(NRedProfilesEntry(build: build, apuMask: apuMask,
                                             deviceID: deviceID, profile: profile))
        }

        let bundle = NRedProfilesBundle(entries: entries)
        try validateBundle(bundle)
        return bundle
    }

    /// Encodes the bundle as a deterministic XML property list whose root dictionary contains only
    /// the `NRedProfiles` array. Tools embed the same array into `Info.plist` via
    /// `nredProfilesArray(_:)`.
    ///
    /// The XML is generated directly (fixed declaration/indentation/key order) because Foundation's
    /// plist writer does not order dictionary keys deterministically; identical bundles must produce
    /// byte-identical output. Values are escaped, integers are decimal and `Profile` is base64.
    static func encodeBundlePlist(_ bundle: NRedProfilesBundle) throws -> Data {
        try validateBundle(bundle)
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>NRedProfiles</key>
        \t<array>

        """
        for entry in bundle.entries {
            let profileData = try encode(entry.profile)
            xml += "\t\t<dict>\n"
            xml += "\t\t\t<key>Build</key>\n"
            xml += "\t\t\t<string>\(xmlEscape(entry.build))</string>\n"
            xml += "\t\t\t<key>APUMask</key>\n"
            xml += "\t\t\t<integer>\(entry.apuMask)</integer>\n"
            xml += "\t\t\t<key>DeviceID</key>\n"
            xml += "\t\t\t<integer>\(entry.deviceID)</integer>\n"
            xml += "\t\t\t<key>Profile</key>\n"
            xml += "\t\t\t<data>\(profileData.base64EncodedString())</data>\n"
            xml += "\t\t</dict>\n"
        }
        xml += """
        \t</array>
        </dict>
        </plist>

        """
        return Data(xml.utf8)
    }

    /// Decodes a property list (typically an `Info.plist` or a bundle document) and extracts the
    /// `NRedProfiles` array. Other root keys are allowed because this may be a full `Info.plist`.
    static func decodeBundlePlist(_ data: Data) throws -> NRedProfilesBundle {
        let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = root as? [String: Any] else {
            throw ProfileCodecError.invalidBundleEntry(entryIndex: -1,
                                                       reason: "root is not a dictionary")
        }
        guard let rawArray = dictionary[NRPTFormat.Bundle.rootKey] as? [Any] else {
            throw ProfileCodecError.invalidBundleEntry(entryIndex: -1,
                                                       reason: "missing NRedProfiles array")
        }
        var array: [[String: Any]] = []
        array.reserveCapacity(rawArray.count)
        for (entryIndex, element) in rawArray.enumerated() {
            guard let entry = element as? [String: Any] else {
                throw ProfileCodecError.invalidBundleEntry(entryIndex: entryIndex,
                                                           reason: "entry is not a dictionary")
            }
            array.append(entry)
        }
        return try bundle(fromNRedProfilesArray: array)
    }

    // MARK: Encode

    /// Serializes a valid profile into canonical NRPT v3 bytes.
    /// Throws a ProfileCodecError and produces no bytes if any model rule is violated.
    static func encode(_ profile: NRPTProfile) throws -> Data {
        try validate(profile)

        var pageTable = Data()
        pageTable.reserveCapacity(profile.pageCount * NRPTFormat.pageRecordSize)
        var siteTable = Data()
        siteTable.reserveCapacity(profile.siteCount * NRPTFormat.siteRecordSize)
        var imageTable = Data()

        var firstSite = 0
        for page in profile.pages {
            appendLE(page.pageFileOffset, to: &pageTable)
            appendLE(page.pageHash, to: &pageTable)
            appendLE(UInt32(firstSite), to: &pageTable)
            appendLE(UInt16(page.sites.count), to: &pageTable)
            pageTable.append(page.mode.rawValue)
            pageTable.append(0)    // flags: reserved in v3
            appendLE(page.imageIndex, to: &pageTable)
            appendLE(UInt16(0), to: &pageTable)    // reserved
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

        for image in profile.images {
            let pathBytes = image.pathBytes
            imageTable.append(image.kind.rawValue)
            imageTable.append(0)    // reserved
            appendLE(UInt16(pathBytes.count), to: &imageTable)
            appendLE(image.unslidVMAddress, to: &imageTable)
            appendLE(image.vmSize, to: &imageTable)
            imageTable.append(contentsOf: pathBytes)
            let pathFieldSize = NRPTFormat.roundUp4(pathBytes.count + 1)
            imageTable.append(contentsOf: [UInt8](repeating: 0, count: pathFieldSize - pathBytes.count))
        }

        let checksum = payloadChecksum(pageTable: pageTable, siteTable: siteTable,
                                       imageTable: imageTable)

        var buildField = [UInt8](repeating: 0, count: NRPTFormat.buildFieldSize)
        for (index, byte) in Array(profile.header.build.utf8).enumerated() {
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
        appendLE(UInt32(0), to: &output)    // reserved0 (header flags removed in v3)
        appendLE(UInt16(profile.images.count), to: &output)
        appendLE(UInt32(imageTable.count), to: &output)
        output.append(contentsOf: [UInt8](repeating: 0, count: NRPTFormat.Header.reserved1Size))
        output.append(pageTable)
        output.append(siteTable)
        output.append(imageTable)

        assert(output.count == profile.encodedSize)
        return output
    }

    // MARK: Decode

    /// Parses and validates a complete NRPT v3 byte string.
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

        let magic = Array(bytes[NRPTFormat.Header.magic ..< NRPTFormat.Header.magic + 4])
        guard magic == NRPTFormat.magic else { throw ProfileCodecError.badMagic(magic) }

        let version = leU16(bytes, NRPTFormat.Header.version)
        guard version == NRPTFormat.version else {
            throw ProfileCodecError.unsupportedVersion(version)
        }
        let headerSize = leU16(bytes, NRPTFormat.Header.headerSize)
        guard Int(headerSize) == NRPTFormat.headerSize else {
            throw ProfileCodecError.invalidHeaderSize(headerSize)
        }

        let buildField = Array(bytes[NRPTFormat.Header.build
                                      ..< NRPTFormat.Header.build + NRPTFormat.buildFieldSize])
        let build = try decodeBuild(buildField)

        let apuMask = leU32(bytes, NRPTFormat.Header.apuMask)
        guard apuMask != 0, apuMask & ~NRPTFormat.knownApuMask == 0 else {
            throw ProfileCodecError.invalidApuMask(apuMask)
        }
        let deviceID = leU32(bytes, NRPTFormat.Header.deviceID)
        guard deviceID <= 0xFFFF else { throw ProfileCodecError.invalidDeviceID(deviceID) }

        let reserved0 = leU32(bytes, NRPTFormat.Header.reserved0)
        guard reserved0 == 0 else {
            throw ProfileCodecError.reservedHeaderFieldNotZero(reserved0)
        }
        let reserved1 = bytes[NRPTFormat.Header.reserved1
                              ..< NRPTFormat.Header.reserved1 + NRPTFormat.Header.reserved1Size]
        guard reserved1.allSatisfy({ $0 == 0 }) else {
            throw ProfileCodecError.reservedHeaderBytesNotZero
        }

        let pageCount = Int(leU16(bytes, NRPTFormat.Header.pageCount))
        let siteCount = Int(leU16(bytes, NRPTFormat.Header.siteCount))
        let imageCount = Int(leU16(bytes, NRPTFormat.Header.imageCount))
        guard pageCount >= 1 else { throw ProfileCodecError.emptyProfile }
        guard pageCount <= NRPTFormat.maxPages else {
            throw ProfileCodecError.pageCountOutOfRange(pageCount)
        }
        guard siteCount >= 1, siteCount <= NRPTFormat.maxSites else {
            throw ProfileCodecError.siteCountOutOfRange(siteCount)
        }
        guard imageCount >= 1, imageCount <= NRPTFormat.maxImages else {
            throw ProfileCodecError.invalidImageCount(imageCount)
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
        let storedImageTableSize = leU32(bytes, NRPTFormat.Header.imageTableSize)
        guard storedImageTableSize >= UInt32(imageCount * 20),
              storedImageTableSize <= UInt32(NRPTFormat.maxImageTableSize) else {
            throw ProfileCodecError.invalidImageCount(imageCount)
        }

        let encodedSize = NRPTFormat.encodedSize(pageCount: pageCount, siteCount: siteCount,
                                                 imageTableSize: Int(storedImageTableSize))
        guard encodedSize <= NRPTFormat.maxProfileSize else {
            throw ProfileCodecError.profileTooLarge(encodedSize)
        }
        guard bytes.count == encodedSize else {
            throw ProfileCodecError.totalSizeMismatch(declared: encodedSize, actual: bytes.count)
        }

        let payload = Data(bytes[NRPTFormat.headerSize...])
        let storedChecksum = leU32(bytes, NRPTFormat.Header.payloadChecksum)
        let computedChecksum = payloadChecksum(payload)
        guard storedChecksum == computedChecksum else {
            throw ProfileCodecError.payloadChecksumMismatch(stored: storedChecksum,
                                                            computed: computedChecksum)
        }

        // Image table (last table in the profile).
        let imageTableBase = NRPTFormat.imageTableOffset(pageCount: pageCount, siteCount: siteCount)
        let imageTableEnd = imageTableBase + Int(storedImageTableSize)
        var images: [NRPTImage] = []
        images.reserveCapacity(imageCount)
        var cursor = imageTableBase
        for imageIndex in 0 ..< imageCount {
            guard cursor + NRPTFormat.imageEntryHeaderSize <= imageTableEnd else {
                throw ProfileCodecError.invalidImageEntry(imageIndex: imageIndex)
            }
            let rawKind = bytes[cursor + NRPTFormat.ImageEntry.kind]
            let reserved = bytes[cursor + NRPTFormat.ImageEntry.reserved]
            let pathLength = Int(leU16(bytes, cursor + NRPTFormat.ImageEntry.pathLength))
            let unslid = leU64(bytes, cursor + NRPTFormat.ImageEntry.imageUnslidVmaddr)
            let vmSize = leU32(bytes, cursor + NRPTFormat.ImageEntry.imageVmSize)

            guard let kind = NRPTImageKind(rawValue: rawKind) else {
                throw ProfileCodecError.invalidImageGeometry(imageIndex: imageIndex)
            }
            guard reserved == 0, pathLength >= 1,
                  pathLength <= NRPTFormat.maxImagePathLength else {
                throw ProfileCodecError.invalidImageEntry(imageIndex: imageIndex)
            }
            let pathFieldSize = NRPTFormat.roundUp4(pathLength + 1)
            guard cursor + NRPTFormat.imageEntryHeaderSize + pathFieldSize <= imageTableEnd else {
                throw ProfileCodecError.invalidImageEntry(imageIndex: imageIndex)
            }
            let pathBase = cursor + NRPTFormat.imageEntryHeaderSize
            let pathBytes = Array(bytes[pathBase ..< pathBase + pathLength])
            guard pathBytes.first == UInt8(ascii: "/"),
                  pathBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
                throw ProfileCodecError.invalidImagePath(imageIndex: imageIndex)
            }
            let padding = bytes[(pathBase + pathLength) ..< (pathBase + pathFieldSize)]
            guard padding.allSatisfy({ $0 == 0 }) else {
                throw ProfileCodecError.invalidImageEntry(imageIndex: imageIndex)
            }
            guard vmSize >= 1, vmSize <= NRPTFormat.maxImageVmSize else {
                throw ProfileCodecError.invalidImageGeometry(imageIndex: imageIndex)
            }
            if kind == .dyldSharedCache, unslid == 0 {
                throw ProfileCodecError.invalidImageGeometry(imageIndex: imageIndex)
            }

            images.append(NRPTImage(kind: kind,
                                    path: String(decoding: pathBytes, as: UTF8.self),
                                    unslidVMAddress: unslid, vmSize: vmSize))
            cursor += NRPTFormat.imageEntryHeaderSize + pathFieldSize
        }
        guard cursor == imageTableEnd else {
            throw ProfileCodecError.imageTableSizeMismatch(stored: storedImageTableSize,
                                                           expected: UInt32(cursor - imageTableBase))
        }

        // Page table.
        let pageTableBase = NRPTFormat.headerSize
        let siteTableBase = pageTableBase + Int(storedPageTableSize)
        var pages: [NRPTPage] = []
        pages.reserveCapacity(pageCount)
        var runningFirstSite = 0

        for pageIndex in 0 ..< pageCount {
            let recordBase = pageTableBase + pageIndex * NRPTFormat.pageRecordSize
            let pageFileOffset = leU64(bytes, recordBase + NRPTFormat.PageRecord.pageFileOffset)
            let pageHash = leU64(bytes, recordBase + NRPTFormat.PageRecord.pageHash)
            let firstSite = leU32(bytes, recordBase + NRPTFormat.PageRecord.firstSite)
            let pageSites = Int(leU16(bytes, recordBase + NRPTFormat.PageRecord.siteCount))
            let rawMode = bytes[recordBase + NRPTFormat.PageRecord.mode]
            let flags = bytes[recordBase + NRPTFormat.PageRecord.flags]
            let imageIndex = leU16(bytes, recordBase + NRPTFormat.PageRecord.imageIndex)
            let recordReserved = leU16(bytes, recordBase + NRPTFormat.PageRecord.reserved)
            let pageVmOffset = leU32(bytes, recordBase + NRPTFormat.PageRecord.pageVmOffset)

            guard let mode = NRPTPageMode(rawValue: rawMode), mode != .resolver else {
                throw ProfileCodecError.unsupportedPageMode(pageIndex: pageIndex, mode: rawMode)
            }
            guard flags == 0, recordReserved == 0,
                  Int(imageIndex) < images.count else {
                throw ProfileCodecError.invalidPageMetadata(pageIndex: pageIndex)
            }
            let image = images[Int(imageIndex)]
            switch mode {
            case .page:
                guard image.kind == .standaloneFile else {
                    throw ProfileCodecError.pageModeImageKindMismatch(pageIndex: pageIndex,
                                                                      mode: mode,
                                                                      kind: image.kind)
                }
            case .dyld:
                guard image.kind == .dyldSharedCache else {
                    throw ProfileCodecError.pageModeImageKindMismatch(pageIndex: pageIndex,
                                                                      mode: mode,
                                                                      kind: image.kind)
                }
            case .resolver:
                throw ProfileCodecError.unsupportedPageMode(pageIndex: pageIndex, mode: rawMode)
            }
            guard pageFileOffset & 0x0FFF == 0 else {
                throw ProfileCodecError.pageFileOffsetMisaligned(pageIndex: pageIndex,
                                                                 offset: pageFileOffset)
            }
            let vmOffset = UInt64(pageVmOffset)
            guard vmOffset & 0xFFF == 0,
                  vmOffset + UInt64(NRPTFormat.pageSize) <= UInt64(image.vmSize) else {
                throw ProfileCodecError.invalidPageVmOffset(pageIndex: pageIndex,
                                                            value: pageVmOffset)
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
                                  mode: mode, imageIndex: imageIndex,
                                  pageVmOffset: pageVmOffset, sites: sites))
            runningFirstSite += pageSites
        }
        guard runningFirstSite == siteCount else {
            throw ProfileCodecError.siteCountSumMismatch(declared: siteCount,
                                                         summed: runningFirstSite)
        }

        let profile = NRPTProfile(
            header: NRPTHeader(build: build, apuMask: apuMask, deviceID: deviceID),
            images: images,
            pages: pages)

        // Single source of truth for the remaining model rules (duplicate identity/mode,
        // duplicate image path, site overlap, geometry and limits).
        try validate(profile)
        return profile
    }

    // MARK: Pure page simulation

    /// True when the record matches completely: full-page FNV-1a-64 equals `pageHash` and every
    /// site `find` matches. `data` must be exactly one 4096-byte page; any other length returns
    /// false (fail closed). Mode/route filtering is the caller's job (`applyPage` takes a mode).
    static func pageMatches(_ page: NRPTPage, data: Data) -> Bool {
        guard data.count == NRPTFormat.pageSize else { return false }
        guard fnv1a64(data) == page.pageHash else { return false }
        let bytes = [UInt8](data)
        return firstMismatchingSiteIndex(page, bytes: bytes) == nil
    }

    /// Returns `data` with all `replace` bytes of `page` written, or `data` unchanged if any site
    /// would leave the page (validated profiles never reach that branch).
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

    /// Stateless simulation of the kernel matcher for one hook route (`mode`).
    ///
    /// Only records whose `mode` equals the parameter are considered, mirroring the mandatory
    /// PAGE/DYLD matching-domain split. The first record whose content identity matches is
    /// authoritative (a site find failure means zero writes). If no original page matches, an
    /// already-patched delivery is recognised without writing. The per-boot applied bitmap is
    /// consumer state and is not modelled here.
    static func applyPage(_ profile: NRPTProfile, data: Data,
                          mode: NRPTPageMode) -> NRPTPageApplication {
        guard mode == .page || mode == .dyld else { return .noMatch }
        guard data.count == NRPTFormat.pageSize else { return .noMatch }
        let bytes = [UInt8](data)
        let hash = fnv1a64(data)

        for (pageIndex, page) in profile.pages.enumerated() where page.mode == mode {
            guard hash == page.pageHash else { continue }

            // Identity matched: authoritative for this page. Any site mismatch means zero writes.
            if let siteIndex = firstMismatchingSiteIndex(page, bytes: bytes) {
                return .siteFindMismatch(pageIndex: pageIndex, siteIndex: siteIndex)
            }
            return .applied(pageIndex: pageIndex, data: applySites(page, to: data))
        }

        for (pageIndex, page) in profile.pages.enumerated() where page.mode == mode {
            if isAlreadyPatched(page, bytes: bytes) {
                return .alreadyPatched(pageIndex: pageIndex)
            }
        }
        return .noMatch
    }

    /// FNV-1a-64 identity only (no site bytes). Used to report a matched/hash-mismatched page.
    static func contentMatches(_ page: NRPTPage, data: Data) -> Bool {
        data.count == NRPTFormat.pageSize && fnv1a64(data) == page.pageHash
    }

    private static func firstMismatchingSiteIndex(_ page: NRPTPage, bytes: [UInt8]) -> Int? {
        for (siteIndex, site) in page.sites.enumerated() {
            let start = Int(site.siteInPage)
            let size = site.findSize
            guard size >= 1, start + size <= NRPTFormat.pageSize else { return siteIndex }
            guard bytes[start ..< start + size].elementsEqual(site.find) else { return siteIndex }
        }
        return nil
    }

    private static func isAlreadyPatched(_ page: NRPTPage, bytes: [UInt8]) -> Bool {
        guard !page.sites.isEmpty else { return false }
        for site in page.sites {
            let start = Int(site.siteInPage)
            let size = site.replaceSize
            guard size >= 1, start + size <= NRPTFormat.pageSize else { return false }
            guard bytes[start ..< start + size].elementsEqual(site.replace) else { return false }
        }
        return true
    }

    // MARK: Validation helpers

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

    /// Extracts an unsigned 32-bit value from a property-list number, rejecting booleans,
    /// negative values and out-of-range values.
    private static func unsigned32(_ value: Any?) -> UInt32? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            // Property-list booleans are NSNumber too; reject them explicitly instead of
            // treating `true`/`false` as 1/0.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let int64 = number.int64Value
            guard int64 >= 0, int64 <= Int64(UInt32.max) else { return nil }
            return UInt32(int64)
        }
        if let int = value as? Int {
            guard int >= 0, int <= Int(UInt32.max) else { return nil }
            return UInt32(int)
        }
        if let uint = value as? UInt32 { return uint }
        return nil
    }

    // MARK: Property-list text helpers

    private static func xmlEscape(_ string: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
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
}
