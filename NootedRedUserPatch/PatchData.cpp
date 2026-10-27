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

#include <PatchData.hpp>
#include <PatchDataBlob.hpp>

#include <Headers/kern_util.hpp>
#include <IOKit/IORegistryEntry.h>
#include <IOKit/IOService.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSIterator.h>
#include <libkern/c++/OSMetaClass.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/libkern.h>
#include <libkern/sysctl.h>
#include <string.h>

// XNU exports the boot-supplied build string (`kern.osversion`) through this global.  Lilu's
// kern_version.hpp already conflicts with the rest of <libkern/version.h>, so declare only this.
extern "C" char osversion[];

namespace
{

    // Property published by the main NootedRed kext once VCNBridge::loadReady() is true.

    // Magic bytes of manifest.bin.
    const UInt8 kManifestMagic[4] = {'N', 'R', 'P', 'D'};

    // Recognised iGPU device IDs and the conservatively accepted apuMask bits.  The mask is only a
    // coarse selector: the complete 4 KiB page compare is the actual safety gate.  Raven2/Picasso and
    // Renoir/RenoirE cannot be told apart without extra register reads, so all acceptable bits are
    // listed and a manifest matching any of them is accepted.  Unknown device IDs fail closed.
    struct ApuMatch
    {
        UInt16 deviceID;
        UInt32 mask;
    };

    constexpr ApuMatch kApuMatches[] = {
        {0x15DD, UserPatchData::kApuRaven},
        {0x15D8, UserPatchData::kApuRaven2 | UserPatchData::kApuPicasso},
        {0x1636, UserPatchData::kApuRenoir | UserPatchData::kApuRenoirE},
        {0x164C, UserPatchData::kApuRenoir | UserPatchData::kApuRenoirE},
        {0x15E7, UserPatchData::kApuGreenSardine | UserPatchData::kApuRenoir},
        {0x1638, UserPatchData::kApuGreenSardine | UserPatchData::kApuRenoir},
    };

    // Embedded build-key characters accepted by format v1 (single index key, no traversal).
    bool isBuildCharacter(const char character)
    {
        return (character >= '0' && character <= '9') || (character >= 'A' && character <= 'Z')
               || (character >= 'a' && character <= 'z') || character == '.' || character == '_'
               || character == '-';
    }

    // Build families are the leading "24H", "24I", ... prefix.  Patch data remains
    // exact-page data; a family match only allows the loader to try it, while the
    // validation page/site match stays the final gate.
    bool sameBuildFamily(const char* const runtime, const char* const data)
    {
        if (runtime == nullptr || data == nullptr) { return false; }
        if (strlen(runtime) < 3 || strlen(data) < 3) { return false; }
        return strncmp(runtime, data, 3) == 0;
    }

    // Reads a 32-bit little-endian PCI property (vendor-id, device-id, class-code, ...).
    UInt32 readPciProperty(IORegistryEntry* const entry, const char* const key)
    {
        if (entry == nullptr) { return 0xFFFFFFFFU; }

        auto* const property = entry->getProperty(key);
        auto* const data     = OSDynamicCast(OSData, property);
        if (data == nullptr || data->getLength() < sizeof(UInt32)) { return 0xFFFFFFFFU; }

        UInt32 value = 0;
        memcpy(&value, data->getBytesNoCopy(), sizeof(value));
        return value;
    }

}    // namespace

UserPatchData& UserPatchData::singleton()
{
    static UserPatchData instance;
    return instance;
}

bool UserPatchData::load()
{
    if (this->state_ == State::kLoaded) { return true; }

    // A permanent failure is never retried: the same embedded data cannot become valid later.
    if (this->state_ == State::kNoOp && !this->transient_) { return false; }

    return this->loadLocked();
}

bool UserPatchData::loadLocked()
{
    this->resetAttempt();

    // Best-effort identity is diagnostic only; it is not a load gate.
    KernelIdentity identity{};
    readKernelIdentity(identity);

    // Lean path: only one embedded set exists.  The page image remains the final match key.  The
    // build family (24H**) only permits an attempt; a security-update build can still use the same
    // exact pages, and a changed page is rejected by the validator's full-page/site check.
    const auto* const embedded = NRedUserPatchData::kBuildCount > 0 ? &NRedUserPatchData::kBuilds[0] : nullptr;
    if (embedded == nullptr) {
        this->setNoOp(Reason::kBuildUnsupported, "no embedded PatchData set is compiled in", false);
        return false;
    }

    const char* const embeddedBuild = embedded->build != nullptr ? embedded->build : "unknown";
    if (identity.buildValid && identity.build[0] != '\0' && !sameBuildFamily(identity.build, embeddedBuild)) {
        this->setNoOp(Reason::kBuildUnsupported, "running build is not in the embedded 24H build family", false);
        return false;
    }

    strlcpy(this->build_, identity.buildValid && identity.build[0] != '\0' ? identity.build : embeddedBuild,
            sizeof(this->build_));
    this->buildSource_ = identity.buildSource != nullptr ? identity.buildSource : "embedded";
    this->apuMask_ = detectApuMask(this->deviceID_);    // diagnostic only; not a gate

    // The generated index metadata is a non-authoritative early filter/diagnostic mirror; the embedded
    // bytes below are still parsed and validated exactly as v1.
    DBGLOG("UserPatchData",
           "embedded index %s: darwin %u.%u.%u apuMask=0x%X tables=%u pages=%u sites=%u pagesChecksum=0x%X",
           embeddedBuild, static_cast<unsigned>(embedded->darwinMajor), static_cast<unsigned>(embedded->darwinMinor),
           static_cast<unsigned>(embedded->darwinPatch), static_cast<unsigned>(embedded->apuMask),
           static_cast<unsigned>(embedded->tableCount), static_cast<unsigned>(embedded->pageCount),
           static_cast<unsigned>(embedded->siteCount), static_cast<unsigned>(embedded->pagesChecksum));
    this->manifestBuf_  = embedded->manifest;
    this->manifestSize_ = embedded->manifestSize;
    this->pagesBuf_     = embedded->pages;
    this->pagesSize_    = embedded->pagesSize;
    snprintf(this->dataSource_, sizeof(this->dataSource_), "embedded-family:%s", embeddedBuild);

    if (this->manifestBuf_ == nullptr || this->manifestSize_ < sizeof(ManifestHeader)) {
        this->setNoOp(Reason::kManifestInvalid, "embedded manifest is empty or shorter than its header", false);
        return false;
    }
    if (this->manifestSize_ > kMaxManifestSize) {
        this->setNoOp(Reason::kManifestTooLarge, "embedded manifest exceeds the v1 size ceiling", false);
        return false;
    }

    const auto* const header = reinterpret_cast<const ManifestHeader*>(this->manifestBuf_);
    if (memcmp(header->magic, kManifestMagic, sizeof(kManifestMagic)) != 0) {
        this->setNoOp(Reason::kManifestInvalid, "embedded manifest magic is not NRPD", false);
        return false;
    }
    if (header->version != kSchemaVersion) {
        this->setNoOp(Reason::kManifestInvalid, "unsupported manifest schema version", false);
        return false;
    }
    if (header->headerSize != kHeaderSize) {
        this->setNoOp(Reason::kManifestInvalid, "unexpected manifest header size", false);
        return false;
    }
    if (header->reserved != 0 || header->reserved2 != 0) {
        this->setNoOp(Reason::kManifestInvalid, "manifest header reserved fields are not zero", false);
        return false;
    }
    if (header->manifestSize != this->manifestSize_) {
        this->setNoOp(Reason::kManifestInvalid, "manifestSize does not match the embedded blob length", false);
        return false;
    }

    const UInt64 computedManifestChecksum =
        fnv1a64Zeroed(this->manifestBuf_, this->manifestSize_, offsetof(ManifestHeader, manifestChecksum),
                      sizeof(UInt64));
    if (computedManifestChecksum != header->manifestChecksum) {
        this->setNoOp(Reason::kManifestChecksumMismatch, "manifest FNV-1a 64 checksum mismatch", false);
        return false;
    }

    if (header->tableCount == 0 || header->tableCount > kMaxTables || header->pageCount == 0
        || header->pageCount > kMaxPages || header->siteCount == 0 || header->siteCount > kMaxSites)
    {
        this->setNoOp(Reason::kLimitExceeded, "manifest table/page/site counts are outside the v1 limits", false);
        return false;
    }

    const UInt64 expectedManifestSize = static_cast<UInt64>(kHeaderSize)
                                        + static_cast<UInt64>(header->tableCount) * sizeof(TableRecord)
                                        + static_cast<UInt64>(header->pageCount) * sizeof(PageRecord)
                                        + static_cast<UInt64>(header->siteCount) * sizeof(SiteRecord);
    if (expectedManifestSize != this->manifestSize_) {
        this->setNoOp(Reason::kManifestInvalid, "manifest record arrays do not fill the embedded blob exactly", false);
        return false;
    }

    // Build selection: the embedded entry and the manifest header must agree exactly with the running
    // build.  The fixed-width build field must be NUL padded with valid characters.
    char manifestBuild[kMaxBuildSize]{};
    {
        size_t buildLength = 0;
        while (buildLength < sizeof(header->build) && header->build[buildLength] != '\0') {
            if (!isBuildCharacter(static_cast<char>(header->build[buildLength]))) {
                this->setNoOp(Reason::kManifestInvalid, "manifest build field has invalid characters", false);
                return false;
            }
            buildLength++;
        }
        if (buildLength == 0 || buildLength >= sizeof(header->build)) {
            this->setNoOp(Reason::kManifestInvalid, "manifest build field has no NUL terminator", false);
            return false;
        }
        for (size_t padding = buildLength; padding < sizeof(header->build); padding++) {
            if (header->build[padding] != 0) {
                this->setNoOp(Reason::kManifestInvalid, "manifest build field is not NUL padded", false);
                return false;
            }
        }
        strlcpy(manifestBuild, header->build, sizeof(manifestBuild));
    }
    // The embedded pages blob must be the declared size and match its checksum before any byte is trusted.
    if (this->pagesBuf_ == nullptr || this->pagesSize_ == 0) {
        this->setNoOp(Reason::kPagesSizeMismatch, "embedded pages blob is missing or empty", false);
        return false;
    }
    if (header->pagesSize == 0) {
        this->setNoOp(Reason::kPagesSizeMismatch, "manifest declares an empty pages blob", false);
        return false;
    }
    if (header->pagesSize > kMaxPagesBlobSize
        || header->pagesSize > static_cast<UInt64>(header->pageCount) * kPageSize)
    {
        this->setNoOp(Reason::kPagesTooLarge, "declared pages size is outside the v1 limit", false);
        return false;
    }
    if (this->pagesSize_ != header->pagesSize) {
        this->setNoOp(Reason::kPagesSizeMismatch, "embedded pages length does not match the manifest", false);
        return false;
    }
    if (fnv1a32(this->pagesBuf_, this->pagesSize_) != header->pagesChecksum) {
        this->setNoOp(Reason::kPagesChecksumMismatch, "pages FNV-1a 32 checksum mismatch", false);
        return false;
    }

    if (!this->parseManifest()) {
        // parseManifest already recorded the specific reason.
        this->freeRuntimeTables();
        return false;
    }

    if (!this->buildRuntimeTables()) {
        this->setNoOp(Reason::kMemoryFailure, "failed to allocate the runtime page/site tables", false);
        return false;
    }

    this->state_     = State::kLoaded;
    this->reason_    = Reason::kNone;
    this->transient_ = false;
    this->detail_[0] = '\0';

    // Publishing point for the code-signing hooks: everything above happens-before this store, and the
    // embedded data plus the runtime tables are immutable for the rest of the boot.
    __atomic_store_n(&this->loadedFlag_, 1, __ATOMIC_RELEASE);

    SYSLOG("UserPatchData", "loaded %s (tables=%u pages=%u sites=%u apuMask=0x%X matched=0x%X device=0x%04X)",
           this->dataSource_, static_cast<unsigned>(this->tableCount_), static_cast<unsigned>(this->pageCount_),
           static_cast<unsigned>(this->siteCount_), static_cast<unsigned>(header->apuMask),
           static_cast<unsigned>(this->matchedApuMask_), static_cast<unsigned>(this->deviceID_));

    return true;
}

bool UserPatchData::parseManifest()
{
    const auto* const header = reinterpret_cast<const ManifestHeader*>(this->manifestBuf_);
    const auto* const tables = reinterpret_cast<const TableRecord*>(this->manifestBuf_ + kHeaderSize);
    const auto* const pages  = reinterpret_cast<const PageRecord*>(tables + header->tableCount);
    const auto* const sites  = reinterpret_cast<const SiteRecord*>(pages + header->pageCount);

    // Tables: known kinds, strictly ascending, page/site ranges contiguous and covering the arrays.
    UInt32 expectedPage = 0;
    UInt32 expectedSite = 0;
    UInt32 previousKind = 0;
    for (UInt32 tableIndex = 0; tableIndex < header->tableCount; tableIndex++) {
        const auto& table = tables[tableIndex];

        if (table.kind < kTableGL || table.kind > kTableVDAGVA) {
            SYSLOG("UserPatchData", "table %u has unknown kind %u", static_cast<unsigned>(tableIndex),
                   static_cast<unsigned>(table.kind));
            this->setNoOp(Reason::kManifestInvalid, "table kind is not 1..4", false);
            return false;
        }
        if (table.kind <= previousKind) {
            this->setNoOp(Reason::kManifestInvalid, "table kinds are not strictly ascending", false);
            return false;
        }
        previousKind = table.kind;

        if (table.reserved != 0) {
            this->setNoOp(Reason::kManifestInvalid, "table record reserved field is not zero", false);
            return false;
        }
        if (table.pageCount == 0 || table.siteCount == 0) {
            this->setNoOp(Reason::kManifestInvalid, "table has no pages or no sites", false);
            return false;
        }
        if (table.pageIndex != expectedPage || table.siteIndex != expectedSite) {
            this->setNoOp(Reason::kManifestInvalid, "table page/site ranges are not contiguous", false);
            return false;
        }
        if (table.pageIndex > header->pageCount || table.pageCount > header->pageCount - table.pageIndex
            || table.siteIndex > header->siteCount || table.siteCount > header->siteCount - table.siteIndex)
        {
            this->setNoOp(Reason::kManifestInvalid, "table range exceeds the page/site arrays", false);
            return false;
        }

        expectedPage += table.pageCount;
        expectedSite += table.siteCount;
    }

    if (expectedPage != header->pageCount || expectedSite != header->siteCount) {
        this->setNoOp(Reason::kManifestInvalid, "table ranges do not cover every page/site", false);
        return false;
    }

    // Pages: exactly one 4 KiB image per record, 4 KiB aligned inside pages.bin.
    for (UInt32 pageIndex = 0; pageIndex < header->pageCount; pageIndex++) {
        const auto& page = pages[pageIndex];

        if (page.reserved[0] != 0 || page.reserved[1] != 0) {
            this->setNoOp(Reason::kManifestInvalid, "page record reserved fields are not zero", false);
            return false;
        }
        if (page.dataSize != kPageSize) {
            this->setNoOp(Reason::kManifestInvalid, "page record dataSize is not 4096", false);
            return false;
        }
        if ((page.dataOffset % kPageSize) != 0) {
            this->setNoOp(Reason::kManifestInvalid, "page record dataOffset is not 4 KiB aligned", false);
            return false;
        }
        if (page.dataOffset > this->pagesSize_ || page.dataSize > this->pagesSize_ - page.dataOffset) {
            this->setNoOp(Reason::kManifestInvalid, "page record points outside the pages blob", false);
            return false;
        }
    }

    // Sites: inside their table's page range, inside the 4 KiB page, find bytes verified verbatim at
    // the declared offset (the offset is authoritative; `find` is never scanned for), replace bytes
    // zero-padded, and no two sites may write the same bytes.
    for (UInt32 tableIndex = 0; tableIndex < header->tableCount; tableIndex++) {
        const auto& table = tables[tableIndex];

        for (UInt32 siteOffset = 0; siteOffset < table.siteCount; siteOffset++) {
            const auto& site = sites[table.siteIndex + siteOffset];

            if (site.size == 0 || site.size > 32) {
                this->setNoOp(Reason::kSiteInvalid, "site size is outside 1..32", false);
                return false;
            }
            if (site.reserved[0] != 0 || site.reserved[1] != 0 || site.reserved[2] != 0) {
                this->setNoOp(Reason::kSiteInvalid, "site reserved bytes are not zero", false);
                return false;
            }
            if (site.pageIndex < table.pageIndex || site.pageIndex - table.pageIndex >= table.pageCount) {
                this->setNoOp(Reason::kSiteInvalid, "site page is outside its table's page range", false);
                return false;
            }
            if (site.offset > kPageSize || site.size > kPageSize - site.offset) {
                this->setNoOp(Reason::kSiteInvalid, "site range is outside its 4 KiB page", false);
                return false;
            }

            const auto& pageRecord = pages[site.pageIndex];
            const auto* const image = this->pagesBuf_ + pageRecord.dataOffset;
            if (memcmp(image + site.offset, site.find, site.size) != 0) {
                this->setNoOp(Reason::kSiteInvalid, "site find bytes do not match the page image", false);
                return false;
            }

            for (size_t padding = site.size; padding < sizeof(site.replace); padding++) {
                if (site.find[padding] != 0 || site.replace[padding] != 0) {
                    this->setNoOp(Reason::kSiteInvalid, "site find/replace bytes are not zero padded", false);
                    return false;
                }
            }
            if (memcmp(site.find, site.replace, site.size) == 0) {
                this->setNoOp(Reason::kSiteInvalid, "site replace bytes equal its find bytes", false);
                return false;
            }
        }
    }

    // Reject conflicting writes: overlapping site ranges on the same page would make the result depend
    // on record order.  The v1 limits keep this quadratic check bounded (<= 1024 sites in total).
    for (UInt32 first = 0; first < header->siteCount; first++) {
        for (UInt32 second = first + 1; second < header->siteCount; second++) {
            const auto& a = sites[first];
            const auto& b = sites[second];
            if (a.pageIndex != b.pageIndex) { continue; }

            const UInt32 aEnd = a.offset + a.size;
            const UInt32 bEnd = b.offset + b.size;
            if (a.offset < bEnd && b.offset < aEnd) {
                this->setNoOp(Reason::kSiteInvalid, "two sites write overlapping bytes on one page", false);
                return false;
            }
        }
    }

    this->tableCount_ = header->tableCount;
    this->pageCount_  = header->pageCount;
    this->siteCount_  = header->siteCount;
    return true;
}

bool UserPatchData::buildRuntimeTables()
{
    auto* const runtimePages = Buffer::create<Page>(this->pageCount_);
    if (runtimePages == nullptr) { return false; }

    auto* const runtimeSites = Buffer::create<Site>(this->siteCount_);
    if (runtimeSites == nullptr) {
        Buffer::deleter(runtimePages);
        return false;
    }

    const auto* const header = reinterpret_cast<const ManifestHeader*>(this->manifestBuf_);
    const auto* const tables = reinterpret_cast<const TableRecord*>(this->manifestBuf_ + kHeaderSize);
    const auto* const pageRecords = reinterpret_cast<const PageRecord*>(tables + header->tableCount);
    const auto* const siteRecords = reinterpret_cast<const SiteRecord*>(pageRecords + header->pageCount);

    // Count and prefix-sum sites per page, so each Page gets a contiguous slice of the site array.
    UInt32 sitesPerPage[kMaxPages]{};
    for (UInt32 siteIndex = 0; siteIndex < header->siteCount; siteIndex++) {
        sitesPerPage[siteRecords[siteIndex].pageIndex] += 1;
    }

    UInt32 nextSite = 0;
    for (UInt32 pageIndex = 0; pageIndex < header->pageCount; pageIndex++) {
        auto& page = runtimePages[pageIndex];
        page       = Page{};
        page.image         = this->pagesBuf_ + pageRecords[pageIndex].dataOffset;
        page.siteIndex     = nextSite;
        page.siteCount     = sitesPerPage[pageIndex];
        page.tableKind     = 0;
        page.isVda         = 0;
        nextSite += sitesPerPage[pageIndex];

        // Cheap first-word fingerprints for the validation hot path.
        memcpy(&page.head, page.image, sizeof(page.head));
        UInt8 patchedHead[sizeof(page.patchedHead)]{};
        memcpy(patchedHead, page.image, sizeof(patchedHead));
        for (UInt32 siteIndex = 0; siteIndex < page.siteCount; siteIndex++) {
            const auto& record = siteRecords[page.siteIndex + siteIndex];
            if (record.offset >= sizeof(patchedHead)) { continue; }
            const size_t available = sizeof(patchedHead) - record.offset;
            const size_t toCopy    = record.size < available ? record.size : available;
            memcpy(patchedHead + record.offset, record.replace, toCopy);
        }
        memcpy(&page.patchedHead, patchedHead, sizeof(page.patchedHead));
    }

    // Table kind per page (tables cover page ranges contiguously).
    for (UInt32 tableIndex = 0; tableIndex < header->tableCount; tableIndex++) {
        const auto& table = tables[tableIndex];
        for (UInt32 offset = 0; offset < table.pageCount; offset++) {
            auto& page     = runtimePages[table.pageIndex + offset];
            page.tableKind = static_cast<UInt8>(table.kind);
            page.isVda     = static_cast<UInt8>(table.kind == kTableVDAVA || table.kind == kTableVDAGVA);
        }
    }

    // Place the sites in per-page order (find/replace pointers stay inside the retained manifest buffer).
    UInt32 cursors[kMaxPages]{};
    for (UInt32 pageIndex = 0; pageIndex < header->pageCount; pageIndex++) {
        cursors[pageIndex] = runtimePages[pageIndex].siteIndex;
    }
    for (UInt32 siteIndex = 0; siteIndex < header->siteCount; siteIndex++) {
        const auto& record = siteRecords[siteIndex];
        auto& destination  = runtimeSites[cursors[record.pageIndex]];
        cursors[record.pageIndex] += 1;

        destination.offset   = record.offset;
        destination.size     = record.size;
        destination.find     = record.find;
        destination.replace  = record.replace;
    }

    this->pages_ = runtimePages;
    this->sites_ = runtimeSites;
    return true;
}

void UserPatchData::resetAttempt()
{
    // Only reachable before the first successful load: the runtime tables are never freed or replaced
    // after loadedFlag_ is published.  The embedded manifest/pages arrays are read-only blob memory and
    // are never owned or freed by this class.
    this->freeRuntimeTables();
    this->tableCount_      = 0;
    this->pageCount_       = 0;
    this->siteCount_       = 0;
    this->matchedApuMask_  = 0;
    this->manifestBuf_     = nullptr;
    this->manifestSize_    = 0;
    this->pagesBuf_        = nullptr;
    this->pagesSize_       = 0;
    this->dataSource_[0]   = '\0';
}

void UserPatchData::freeRuntimeTables()
{
    if (this->pages_ != nullptr) {
        Buffer::deleter(this->pages_);
        this->pages_ = nullptr;
    }
    if (this->sites_ != nullptr) {
        Buffer::deleter(this->sites_);
        this->sites_ = nullptr;
    }
}

void UserPatchData::setNoOp(const Reason reason, const char* const detail, const bool transient)
{
    this->freeRuntimeTables();
    this->state_     = State::kNoOp;
    this->reason_    = reason;
    this->transient_ = transient;
    strlcpy(this->detail_, detail != nullptr ? detail : "", sizeof(this->detail_));

    SYSLOG("UserPatchData", "no-op: %s (%s)%s", this->reasonName(), this->detail_,
           transient ? " [will retry]" : "");
}

bool UserPatchData::readKernelIdentity(KernelIdentity& identity)
{
    identity             = KernelIdentity{};
    identity.buildSource = "none";

    // Build identity comes from the kernel only (no filesystem, no plist parsing):
    //   1. sysctl `kern.osversion` (exact kernel build string, when the BSD layer is available);
    //   2. XNU's `osversion` global (populated by the kernel from the booter-supplied build string).
    // The loader performs no file I/O at any point; these two sources plus the bounded retry are the
    // whole identity path.  A generously sized raw buffer is read first, the length is validated, and
    // only then is the value copied into the 16-byte embedded-data key, so an over-long string can never
    // be silently truncated into a different key (review D11).
    char        rawBuild[64]{};
    size_t      rawSize  = sizeof(rawBuild);
    bool        haveBuild = false;
    const char* source    = "none";
    if (sysctlbyname("kern.osversion", rawBuild, &rawSize, nullptr, 0) == 0 && rawBuild[0] != '\0') {
        rawBuild[sizeof(rawBuild) - 1] = '\0';
        haveBuild                     = true;
        source                        = "sysctl:kern.osversion";
    }
    if (!haveBuild && osversion[0] != '\0') {
        strlcpy(rawBuild, osversion, sizeof(rawBuild));
        haveBuild = true;
        source    = "xnu:osversion";
    }
    if (!haveBuild) {
        // Called from the runtime's locked load path, so a plain one-shot diagnostic flag is safe.
        static bool loggedUnavailable = false;
        if (!loggedUnavailable) {
            loggedUnavailable = true;
            SYSLOG("UserPatchData",
                   "build identity unavailable (kern.osversion sysctl and XNU osversion empty); staying retryable");
        }
    }
    if (haveBuild) {
        if (isValidBuildString(rawBuild)) {
            strlcpy(identity.build, rawBuild, sizeof(identity.build));
            identity.buildValid = true;
        }
        else {
            // A populated but unusable build string is deterministic: report it as invalid, not retryable.
            identity.buildValid = false;
        }
    }
    identity.buildSource = source;

    // Darwin major/minor are kernel globals; the patch level comes from `kern.osrelease` when available.
    identity.darwinMajor = static_cast<UInt16>(version_major);
    identity.darwinMinor = static_cast<UInt16>(version_minor);
    identity.darwinPatch = 0;

    char   release[32]{};
    size_t releaseSize = sizeof(release);
    if (sysctlbyname("kern.osrelease", release, &releaseSize, nullptr, 0) == 0) {
        unsigned major = 0;
        unsigned minor = 0;
        unsigned patch = 0;
        if (sscanf(release, "%u.%u.%u", &major, &minor, &patch) == 3) {
            identity.darwinMajor = static_cast<UInt16>(major);
            identity.darwinMinor = static_cast<UInt16>(minor);
            identity.darwinPatch = static_cast<UInt16>(patch);
            identity.patchValid  = true;
        }
    }

    return haveBuild;
}

bool UserPatchData::isValidBuildString(const char* const build)
{
    if (build == nullptr) { return false; }

    size_t length = 0;
    while (build[length] != '\0') {
        if (!isBuildCharacter(build[length])) { return false; }
        length++;
        if (length >= kMaxBuildSize) { return false; }
    }

    // A single embedded-data key; never a path or traversal name.
    if (length == 0) { return false; }
    if (length == 1 && build[0] == '.') { return false; }
    if (length == 2 && build[0] == '.' && build[1] == '.') { return false; }

    return true;
}

UInt32 UserPatchData::detectApuMask(UInt16& deviceID)
{
    deviceID = 0;

    auto* const matching = IOService::serviceMatching("IOPCIDevice");
    if (matching == nullptr) { return 0; }

    // getMatchingServices consumes the matching dictionary reference.
    auto* const iterator = IOService::getMatchingServices(matching);
    if (iterator == nullptr) { return 0; }

    UInt32 mask = 0;
    while (auto* const object = iterator->getNextObject()) {
        auto* const service = OSDynamicCast(IOService, object);
        if (service == nullptr) { continue; }

        const UInt32 vendor = readPciProperty(service, "vendor-id");
        if (vendor != 0x1002) { continue; }

        const UInt32 classCode = readPciProperty(service, "class-code");
        if (classCode != 0xFFFFFFFFU && ((classCode >> 16) & 0xFFU) != 0x03U) { continue; }

        const UInt32 runningDevice = readPciProperty(service, "device-id");
        if (runningDevice == 0xFFFFFFFFU || runningDevice > 0xFFFFU) { continue; }

        for (const auto& candidate : kApuMatches) {
            if (candidate.deviceID != runningDevice) { continue; }
            mask     = candidate.mask;
            deviceID = static_cast<UInt16>(runningDevice);
            break;
        }

        if (mask != 0) { break; }
    }

    iterator->release();
    return mask;
}

UInt32 UserPatchData::fnv1a32(const UInt8* const data, const size_t size)
{
    UInt32 hash = 0x811C9DC5U;
    for (size_t index = 0; index < size; index++) {
        hash ^= data[index];
        hash *= 0x01000193U;
    }
    return hash;
}

UInt64 UserPatchData::fnv1a64Zeroed(const UInt8* const data, const size_t size, const size_t zeroOffset,
                                   const size_t zeroSize)
{
    UInt64 hash = 0xCBF29CE484222325ULL;
    for (size_t index = 0; index < size; index++) {
        const UInt8 byte = (index >= zeroOffset && index < zeroOffset + zeroSize) ? 0 : data[index];
        hash ^= byte;
        hash *= 0x100000001B3ULL;
    }
    return hash;
}

bool UserPatchData::loaded() const { return __atomic_load_n(&this->loadedFlag_, __ATOMIC_ACQUIRE) != 0; }

bool UserPatchData::retryable() const { return this->state_ == State::kNoOp && this->transient_; }

UserPatchData::State UserPatchData::state() const { return this->state_; }

UserPatchData::Reason UserPatchData::reason() const { return this->reason_; }

const char* UserPatchData::stateName() const { return stateName(this->state_); }

const char* UserPatchData::reasonName() const { return reasonName(this->reason_); }

const char* UserPatchData::stateName(const State state)
{
    switch (state) {
        case State::kIdle: return "Idle";
        case State::kLoaded: return "Loaded";
        case State::kNoOp: return "NoOp";
        default: return "Unknown";
    }
}

const char* UserPatchData::reasonName(const Reason reason)
{
    switch (reason) {
        case Reason::kNone: return "None";
        case Reason::kBuildUnavailable: return "BuildUnavailable";
        case Reason::kBuildInvalid: return "BuildInvalid";
        case Reason::kApuUnknown: return "ApuUnknown";
        case Reason::kBuildUnsupported: return "BuildUnsupported";
        case Reason::kManifestTooLarge: return "ManifestTooLarge";
        case Reason::kManifestInvalid: return "ManifestInvalid";
        case Reason::kManifestChecksumMismatch: return "ManifestChecksumMismatch";
        case Reason::kBuildMismatch: return "BuildMismatch";
        case Reason::kDarwinMismatch: return "DarwinMismatch";
        case Reason::kApuMismatch: return "ApuMismatch";
        case Reason::kPagesTooLarge: return "PagesTooLarge";
        case Reason::kPagesSizeMismatch: return "PagesSizeMismatch";
        case Reason::kPagesChecksumMismatch: return "PagesChecksumMismatch";
        case Reason::kSiteInvalid: return "SiteInvalid";
        case Reason::kLimitExceeded: return "LimitExceeded";
        case Reason::kMemoryFailure: return "MemoryFailure";
        default: return "Unknown";
    }
}

const char* UserPatchData::tableName(const UInt32 kind)
{
    switch (kind) {
        case kTableGL: return "GL";
        case kTableMetal: return "Metal";
        case kTableVDAVA: return "VDA/VA";
        case kTableVDAGVA: return "VDA/AppleGVA";
        default: return "Unknown";
    }
}

const char* UserPatchData::buildString() const { return this->build_; }

const char* UserPatchData::buildSource() const
{
    return this->buildSource_ != nullptr ? this->buildSource_ : "none";
}

UInt32 UserPatchData::apuMask() const { return this->apuMask_; }

UInt16 UserPatchData::apuDeviceID() const { return this->deviceID_; }

UInt32 UserPatchData::matchedApuMask() const { return this->matchedApuMask_; }

const char* UserPatchData::dataSource() const { return this->dataSource_; }

UInt32 UserPatchData::tableCount() const { return this->tableCount_; }

UInt32 UserPatchData::pageCount() const { return this->pageCount_; }

UInt32 UserPatchData::siteCount() const { return this->siteCount_; }

const UserPatchData::Page* UserPatchData::pages() const { return this->pages_; }

const UserPatchData::Site* UserPatchData::sites() const { return this->sites_; }
