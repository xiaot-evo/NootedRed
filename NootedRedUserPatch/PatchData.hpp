// NootedRedUserPatch external patch data loader
//
// Copyright (C) 2026  ChefKiss.
//
// Licensed under the ChefKiss Open Knowledge License version 1.
//
// This work is licensed to you under the terms of the ChefKiss Open Knowledge
// License, either version 1 of the License, or (at your option) any later
// version published by ChefKiss.
//
// This work may not be used to train or develop artificial intelligence,
// and may not be used with artificial intelligence in any other way. See
// the ChefKiss Open Knowledge License for details.
//
// This work is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// ChefKiss Open Knowledge License for more details.
//
// You should have received a copy of the ChefKiss Open Knowledge License
// along with this work.  If not, see https://git.chefkiss.dev/ChefKiss/OpenKnowledge/raw/branch/master/LICENSE-v1.md.

#pragma once
#include <Headers/kern_util.hpp>
#include <libkern/OSTypes.h>
#include <stddef.h>
#include <stdint.h>

class IORegistryEntry;

// Selects and validates the per-build exact-page patch data embedded in the kext (generated from the
// repo-root PatchData/ tree by tools/embed_patchdata.py as NootedRedUserPatch/PatchDataBlob.*).
//
// The satellite never reads files at runtime: external PatchData is generator input only.  This class
// selects the embedded build table entry whose `build` exactly equals the running `kern.osversion`/XNU
// osversion, then validates every manifest field (magic, schema version, header/table/page/site sizes,
// build, Darwin version, APU mask, FNV-1a checksums and site/page consistency) and only then reports
// `State::Loaded`.  A mismatch is a fail-closed no-op: there is no fallback to another build, another
// page, a filesystem copy or a heuristic byte scan.  Boot-timing identity/IOKit failures stay retryable
// for the runtime's bounded retry timer; deterministic failures are terminal.
//
// Adding a build now requires regenerating PatchDataBlob.* and rebuilding/re-signing the kext (the
// approved stability tradeoff).  All parsing happens in kernel-thread contexts (Lilu patcher load /
// IOService start / delayed retry), never in the code-signing hooks; the hooks only compare against the
// already-published embedded page images and never touch the filesystem or the IORegistry.
class UserPatchData
{
public:
    // Exact-page unit.  Every PageRecord image is exactly this size.
    static constexpr size_t kPageSize = 0x1000U;

    // Manifest format constants (v1, packed little-endian).  See the data format document.
    static constexpr UInt32 kSchemaVersion = 1;
    static constexpr UInt32 kHeaderSize    = 72;
    static constexpr UInt32 kMaxTables     = 16;
    static constexpr UInt32 kMaxPages      = 64;
    static constexpr UInt32 kMaxSites      = 1024;
    // Validation ceilings from the v1 contract (the embedded generator output is checked against them).
    static constexpr size_t kMaxManifestSize  = 131072U;
    static constexpr size_t kMaxPagesBlobSize = 262144U;
    static constexpr size_t kMaxBuildSize  = 16;

    // TableRecord.kind values.
    enum TableKind : UInt32 {
        kTableGL     = 1,
        kTableMetal  = 2,
        kTableVDAVA  = 3,
        kTableVDAGVA = 4,
    };

    // ManifestHeader.apuMask bits.
    enum ApuBit : UInt32 {
        kApuRaven        = 1U << 0,
        kApuRaven2       = 1U << 1,
        kApuPicasso      = 1U << 2,
        kApuRenoir       = 1U << 3,
        kApuRenoirE      = 1U << 4,
        kApuGreenSardine = 1U << 5,
    };

    // Feature state.  `kNoOp` is a safe, expected state: the kext stays loaded but installs nothing.
    enum class State : UInt8 {
        kIdle   = 0,
        kLoaded = 1,
        kNoOp   = 2,
    };

    // Why the data was not loaded.  Every one of these is a fail-closed no-op.
    enum class Reason : UInt8 {
        kNone = 0,
        kBuildUnavailable,
        kBuildInvalid,
        kApuUnknown,
        kBuildUnsupported,
        kManifestTooLarge,
        kManifestInvalid,
        kManifestChecksumMismatch,
        kBuildMismatch,
        kDarwinMismatch,
        kApuMismatch,
        kPagesTooLarge,
        kPagesSizeMismatch,
        kPagesChecksumMismatch,
        kSiteInvalid,
        kLimitExceeded,
        kMemoryFailure,
    };

    // One validated site on one validated 4 KiB page.  `find`/`replace` point into the retained
    // manifest buffer, `offset` is authoritative (the find bytes are verified there, not scanned for).
    struct Site
    {
        UInt32      offset;
        UInt8       size;
        UInt8       reserved[3];
        const UInt8* find;
        const UInt8* replace;
    };

    // One validated page image from pages.bin.  `sites` indexes into `sites()`.
    struct Page
    {
        const UInt8* image;      // 4096-byte page image inside pages.bin
        UInt64       head;       // first 8 bytes of `image`, for a cheap pre-filter
        UInt64       patchedHead;  // first 8 bytes after applying this page's sites
        UInt32       siteIndex;  // first site in `sites()`
        UInt32       siteCount;
        UInt8        tableKind;
        UInt8        isVda;
        UInt8        reserved[2];
    };

    static UserPatchData& singleton();

    // Attempts (or retries) the load for the running build.  Returns true only when validated data is
    // available.  Not reentrant: the runtime calls it while holding its single state lock.  A transient
    // failure (kernel build string, IOKit or the data volume not ready yet) stays retryable; a permanent
    // one becomes a logged terminal no-op.
    bool load();

    // Acquire-load of the published data flag.  Safe to call from the code-signing hooks; after it
    // returns true the page/site tables are immutable for the rest of the boot.
    bool        loaded() const;
    State       state() const;
    Reason      reason() const;
    const char* stateName() const;
    const char* reasonName() const;
    static const char* stateName(State state);
    static const char* reasonName(Reason reason);
    static const char* tableName(UInt32 kind);

    const char* buildString() const;
    // Where the running build string came from ("sysctl:kern.osversion" or "xnu:osversion"), or "none"
    // before a source has produced one.  Diagnostics only; no filesystem source exists.
    const char* buildSource() const;
    UInt32      apuMask() const;
    UInt16      apuDeviceID() const;
    UInt32      matchedApuMask() const;
    // "embedded:<build>" after a successful selection, empty before it.  Diagnostics only: the plugin
    // never opens a file, so this is not a filesystem path.
    const char* dataSource() const;
    UInt32      tableCount() const;
    UInt32      pageCount() const;
    UInt32      siteCount() const;
    const Page* pages() const;
    const Site* sites() const;

    // True when the last load failure was transient (retryable) rather than terminal.  Call while
    // holding the runtime state lock.
    bool retryable() const;

private:
    // On-disk v1 structures.  Packed, little-endian; the build is x86_64 only, but the layout and
    // sizes are asserted so a compiler change cannot silently alter the on-disk contract.
    struct ManifestHeader
    {
        char   magic[4];
        UInt16 version;
        UInt16 headerSize;
        char   build[16];
        UInt16 darwinMajor;
        UInt16 darwinMinor;
        UInt16 darwinPatch;
        UInt16 reserved;
        UInt32 apuMask;
        UInt32 tableCount;
        UInt32 pageCount;
        UInt32 siteCount;
        UInt32 manifestSize;
        UInt32 pagesSize;
        UInt32 pagesChecksum;
        UInt32 reserved2;
        UInt64 manifestChecksum;
    } __attribute__((packed));

    struct TableRecord
    {
        UInt32 kind;
        UInt32 pageIndex;
        UInt32 pageCount;
        UInt32 siteIndex;
        UInt32 siteCount;
        UInt32 reserved;
    } __attribute__((packed));

    struct PageRecord
    {
        UInt32 dataOffset;
        UInt32 dataSize;
        UInt32 reserved[2];
    } __attribute__((packed));

    struct SiteRecord
    {
        UInt32 pageIndex;
        UInt32 offset;
        UInt8  find[32];
        UInt8  replace[32];
        UInt8  size;
        UInt8  reserved[3];
    } __attribute__((packed));

    static_assert(sizeof(ManifestHeader) == 72, "ManifestHeader must stay 72 bytes");
    static_assert(sizeof(TableRecord) == 24, "TableRecord must stay 24 bytes");
    static_assert(sizeof(PageRecord) == 16, "PageRecord must stay 16 bytes");
    static_assert(sizeof(SiteRecord) == 76, "SiteRecord must stay 76 bytes");
    static_assert(kHeaderSize == sizeof(ManifestHeader), "kHeaderSize must match the header layout");

    // Running kernel identity.
    struct KernelIdentity
    {
        char        build[kMaxBuildSize];
        const char* buildSource;
        UInt16      darwinMajor;
        UInt16      darwinMinor;
        UInt16      darwinPatch;
        bool        buildValid;
        bool        patchValid;
    };

    UserPatchData() = default;
    ~UserPatchData() = default;
    UserPatchData(const UserPatchData&) = delete;
    UserPatchData& operator=(const UserPatchData&) = delete;
    UserPatchData(UserPatchData&&) = delete;
    UserPatchData& operator=(UserPatchData&&) = delete;

    void resetAttempt();
    void setNoOp(Reason reason, const char* detail, bool transient);
    void freeRuntimeTables();
    bool parseManifest();
    bool buildRuntimeTables();
    bool loadLocked();

    static bool readKernelIdentity(KernelIdentity& identity);
    static bool isValidBuildString(const char* build);
    static UInt32 detectApuMask(UInt16& deviceID);
    static UInt32 fnv1a32(const UInt8* data, size_t size);
    static UInt64 fnv1a64Zeroed(const UInt8* data, size_t size, size_t zeroOffset, size_t zeroSize);

    // Published with release semantics after the runtime tables are complete; the validation hooks use an
    // acquire load.  Buffers are never freed or replaced after this becomes 1.
    volatile UInt8 loadedFlag_{0};

    State  state_{State::kIdle};
    Reason reason_{Reason::kNone};
    bool   transient_{false};
    char   detail_[96]{};
    char   build_[kMaxBuildSize]{};
    const char* buildSource_{nullptr};
    char   dataSource_[48]{};
    UInt32 apuMask_{0};
    UInt32 matchedApuMask_{0};
    UInt16 deviceID_{0};
    UInt32 tableCount_{0};
    UInt32 pageCount_{0};
    UInt32 siteCount_{0};
    Page*  pages_{nullptr};
    Site*  sites_{nullptr};
    // Non-owning pointers into the generated `NRedUserPatchData` arrays; never freed by this class.
    const UInt8* manifestBuf_{nullptr};
    size_t       manifestSize_{0};
    const UInt8* pagesBuf_{nullptr};
    size_t       pagesSize_{0};
};
