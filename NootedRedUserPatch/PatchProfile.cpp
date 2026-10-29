// NootedRedUserPatch generic NRPT profile engine
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

#include <PatchProfile.hpp>

#include <Headers/kern_mach.hpp>
#include <Headers/kern_patcher.hpp>
#include <string.h>

namespace
{

    // Little-endian wire readers.  The profile is byte-packed, so no alignment may be assumed.
    UInt16 readLe16(const UInt8* const ptr)
    {
        return static_cast<UInt16>(static_cast<UInt16>(ptr[0]) | (static_cast<UInt16>(ptr[1]) << 8));
    }

    UInt32 readLe32(const UInt8* const ptr)
    {
        return static_cast<UInt32>(ptr[0]) | (static_cast<UInt32>(ptr[1]) << 8) | (static_cast<UInt32>(ptr[2]) << 16)
               | (static_cast<UInt32>(ptr[3]) << 24);
    }

    UInt64 readLe64(const UInt8* const ptr)
    {
        return static_cast<UInt64>(readLe32(ptr)) | (static_cast<UInt64>(readLe32(ptr + 4)) << 32);
    }

    // FNV-1a-32 payload checksum (NRPT specification section 1.1).
    UInt32 fnv1a32(const UInt8* const data, const size_t size)
    {
        UInt32 hash = 0x811C9DC5U;
        for (size_t index = 0; index < size; index++) {
            hash ^= data[index];
            hash *= 0x01000193U;
        }
        return hash;
    }

    // FNV-1a-64 full-page identity hash (NRPT specification section 1.1).
    UInt64 fnv1a64(const UInt8* const data, const size_t size)
    {
        UInt64 hash = 0xCBF29CE484222325ULL;
        for (size_t index = 0; index < size; index++) {
            hash ^= data[index];
            hash *= 0x100000001B3ULL;
        }
        return hash;
    }

}    // namespace

PatchProfile& PatchProfile::singleton()
{
    static PatchProfile instance;
    return instance;
}

bool PatchProfile::loadFromData(const void* const data, const size_t size)
{
    // One shot: a rejected profile is never retried or replaced by a fallback.
    if (this->loadAttempted_) { return false; }
    this->loadAttempted_ = true;

    if (this->state_ == State::kNoOp) { return false; }

    if (data == nullptr || size < kHeaderSize) {
        return this->fail(Reason::kProfileInvalid, "E001", "truncated profile");
    }

    const auto* const bytes = static_cast<const UInt8*>(data);

    UInt32 pageCount      = 0;
    UInt32 siteCount      = 0;
    UInt32 imageTableSize = 0;
    UInt32 pageRecordSize = kPageRecordSize;
    UInt16 version        = 0;
    UInt16 imageCount     = 0;

    if (!this->loadHeader(bytes, size, pageCount, siteCount, version, imageCount, imageTableSize,
                          pageRecordSize)) {
        return false;
    }

    const UInt32 pageTableSize = pageCount * pageRecordSize;

    // Publish the parsed header identity before the tables are validated: the page parser bounds-checks
    // its imageIndex against the image count, and the image table itself was validated above.
    this->profileVersion_ = version;
    this->imageCount_     = imageCount;

    // The image table follows the page and site tables and must be parsed before the page records so
    // every page's imageIndex/pageVmOffset/mode can be validated against it (NRPT v3 layout).
    const auto* const imageTable = bytes + kHeaderSize + pageTableSize + siteCount * kSiteRecordSize;
    if (!this->loadImageTable(imageTable, imageCount, imageTableSize)) { return false; }

    if (!this->loadPageTable(bytes + kHeaderSize, pageCount, siteCount)) { return false; }
    if (!this->loadSiteTable(bytes + kHeaderSize + pageTableSize, siteCount, pageCount)) { return false; }

    this->pageCount_      = static_cast<UInt16>(pageCount);
    this->siteCount_      = static_cast<UInt16>(siteCount);
    this->profileVersion_ = version;
    this->imageCount_     = imageCount;
    this->profileParsed_  = true;

    SYSLOG("PatchEngine",
           "NRPT v%u profile parsed: build %s apuMask 0x%X device 0x%04X pages %u sites %u images %u", 
           static_cast<unsigned>(version), this->build_, static_cast<unsigned>(this->apuMask_),
           static_cast<unsigned>(this->deviceID_), static_cast<unsigned>(this->pageCount_),
           static_cast<unsigned>(this->siteCount_), static_cast<unsigned>(this->imageCount_));

    this->evaluateIdentity();
    return true;
}

bool PatchProfile::loadHeader(const UInt8* const data, const size_t size, UInt32& pageCount,
                              UInt32& siteCount, UInt16& version, UInt16& imageCount, UInt32& imageTableSize,
                              UInt32& pageRecordSize)
{
    if (size < kHeaderSize) { return this->fail(Reason::kProfileInvalid, "E001", "truncated profile"); }

    if (memcmp(data, "NRPT", 4) != 0) { return this->fail(Reason::kProfileInvalid, "E002", "bad magic"); }

    version = readLe16(data + 4);
    if (version != kVersionV3) {
        return this->fail(Reason::kProfileInvalid, "E003", "unsupported version (NRPT v3 only)");
    }

    if (readLe16(data + 6) != kHeaderSize) {
        return this->fail(Reason::kProfileInvalid, "E004", "invalid header size");
    }

    char profileBuild[kMaxBuildLength + 1]{};
    if (!parseBuildField(data + 8, profileBuild, sizeof(profileBuild))) {
        return this->fail(Reason::kProfileInvalid, "E005", "invalid build field");
    }

    const UInt32 apuMask = readLe32(data + 24);
    if (apuMask == 0 || (apuMask & ~kApuMaskKnown) != 0) {
        return this->fail(Reason::kProfileInvalid, "E006", "invalid apuMask");
    }

    const UInt32 deviceID = readLe32(data + 28);
    if (deviceID > 0xFFFFU) {
        return this->fail(Reason::kProfileInvalid, "E007", "invalid deviceID");
    }

    if (readLe32(data + 48) != 0) {
        return this->fail(Reason::kProfileInvalid, "E008", "reserved header field not zero");
    }

    imageCount     = readLe16(data + 52);
    imageTableSize = readLe32(data + 54);
    if (imageCount == 0 || imageCount > kMaxImages) {
        return this->fail(Reason::kProfileInvalid, "E034", "invalid image count");
    }
    if (imageTableSize < imageCount * kImageEntryHeaderSize || imageTableSize > kMaxImageTableSize) {
        return this->fail(Reason::kProfileInvalid, "E035", "invalid image table size");
    }

    for (size_t index = 58; index < kHeaderSize; index++) {
        if (data[index] != 0) {
            return this->fail(Reason::kProfileInvalid, "E009", "reserved header bytes not zero");
        }
    }

    pageCount = readLe16(data + 32);
    siteCount = readLe16(data + 34);

    if (pageCount == 0) { return this->fail(Reason::kProfileInvalid, "E032", "empty profile"); }
    if (pageCount > kMaxPages) { return this->fail(Reason::kProfileInvalid, "E015", "pageCount out of range"); }
    if (siteCount == 0 || siteCount > kMaxSites) {
        return this->fail(Reason::kProfileInvalid, "E016", "siteCount out of range");
    }

    pageRecordSize = kPageRecordSize;
    const UInt32 pageTableSize = readLe32(data + 36);
    const UInt32 siteTableSize = readLe32(data + 40);
    if (pageTableSize != pageCount * pageRecordSize) {
        return this->fail(Reason::kProfileInvalid, "E011", "pageTableSize mismatch");
    }
    if (siteTableSize != siteCount * kSiteRecordSize) {
        return this->fail(Reason::kProfileInvalid, "E012", "siteTableSize mismatch");
    }

    const UInt64 expectedSize =
        static_cast<UInt64>(kHeaderSize) + pageTableSize + siteTableSize + imageTableSize;
    if (expectedSize > kMaxProfileSize) {
        return this->fail(Reason::kProfileInvalid, "E010", "profile too large");
    }
    if (expectedSize != size) {
        return this->fail(Reason::kProfileInvalid, "E013", "total size mismatch");
    }

    const UInt32 payloadChecksum = readLe32(data + 44);
    if (fnv1a32(data + kHeaderSize, size - kHeaderSize) != payloadChecksum) {
        return this->fail(Reason::kProfileInvalid, "E014", "payload checksum mismatch");
    }

    strlcpy(this->build_, profileBuild, sizeof(this->build_));
    this->apuMask_        = apuMask;
    this->deviceID_       = deviceID;
    this->profileVersion_ = version;
    return true;
}

bool PatchProfile::loadImageTable(const UInt8* const table, const UInt32 imageCount, const UInt32 imageTableSize)
{
    const UInt8* cursor    = table;
    const UInt8* const end = table + imageTableSize;

    for (UInt32 imageIndex = 0; imageIndex < imageCount; imageIndex++) {
        if (static_cast<size_t>(end - cursor) < kImageEntryHeaderSize) {
            return this->fail(Reason::kProfileInvalid, "E035", "image entry exceeds image table");
        }

        const UInt32 kind          = cursor[0];
        const UInt32 reserved      = cursor[1];
        const UInt32 pathLength    = readLe16(cursor + 2);
        const UInt64 unslidVmaddr  = readLe64(cursor + 4);
        const UInt32 vmSize        = readLe32(cursor + 12);

        if (reserved != 0 || kind > kImageKindSharedCache || pathLength < 1 || pathLength > kMaxImagePathLength) {
            return this->fail(Reason::kProfileInvalid, "E035", "invalid image entry");
        }

        const UInt32 pathFieldSize = (pathLength + 1U + 3U) & ~3U;
        const UInt32 entrySize     = kImageEntryHeaderSize + pathFieldSize;
        if (static_cast<size_t>(end - cursor) < entrySize) {
            return this->fail(Reason::kProfileInvalid, "E035", "image entry exceeds image table");
        }

        const UInt8* const path = cursor + kImageEntryHeaderSize;
        if (path[pathLength] != 0 || path[0] != '/') {
            return this->fail(Reason::kProfileInvalid, "E037", "invalid image path");
        }
        for (UInt32 index = 0; index < pathLength; index++) {
            if (path[index] < 0x20 || path[index] > 0x7E) {
                return this->fail(Reason::kProfileInvalid, "E037", "invalid image path");
            }
        }
        for (UInt32 index = pathLength + 1; index < pathFieldSize; index++) {
            if (path[index] != 0) {
                return this->fail(Reason::kProfileInvalid, "E035", "image path not NUL padded");
            }
        }

        if (vmSize == 0 || vmSize > kMaxImageVmSize || (kind == kImageKindSharedCache && unslidVmaddr == 0)) {
            return this->fail(Reason::kProfileInvalid, "E041", "invalid image geometry");
        }

        for (UInt32 other = 0; other < imageIndex; other++) {
            if (this->images_[other].kind == kind
                && strcmp(this->images_[other].path, reinterpret_cast<const char*>(path)) == 0)
            {
                return this->fail(Reason::kProfileInvalid, "E039", "duplicate image path");
            }
        }

        auto& image            = this->images_[imageIndex];
        image.kind             = static_cast<UInt8>(kind);
        image.reserved         = 0;
        image.unslidVmaddr     = unslidVmaddr;
        image.vmSize           = vmSize;
        memcpy(image.path, path, pathLength);
        image.path[pathLength] = '\0';

        cursor += entrySize;
    }

    if (cursor != end) {
        return this->fail(Reason::kProfileInvalid, "E036", "imageTableSize does not match the entries");
    }

    return true;
}

bool PatchProfile::loadPageTable(const UInt8* const table, const UInt32 pageCount, const UInt32 siteCount)
{
    UInt32 expectedFirstSite = 0;

    for (UInt32 pageIndex = 0; pageIndex < pageCount; pageIndex++) {
        const UInt8* const record = table + static_cast<size_t>(pageIndex) * kPageRecordSize;

        const UInt64 pageFileOffset = readLe64(record + 0);
        const UInt64 pageHash       = readLe64(record + 8);
        const UInt32 firstSite      = readLe32(record + 16);
        const UInt32 sitesInPage    = readLe16(record + 20);
        const UInt32 mode           = record[22];
        const UInt32 flags          = record[23];
        const UInt32 imageIndex     = readLe16(record + 24);
        const UInt16 reserved       = readLe16(record + 26);
        const UInt32 pageVmOffset   = readLe32(record + 28);

        // pageFileOffset is diagnostic evidence only and is never part of page identity.
        if ((pageFileOffset & (kPageSize - 1U)) != 0) {
            return this->fail(Reason::kProfileInvalid, "E017", "page offset misaligned");
        }
        if (mode != static_cast<UInt32>(Mode::kPage) && mode != static_cast<UInt32>(Mode::kDyld)) {
            return this->fail(Reason::kProfileInvalid, "E018", "unsupported page mode");
        }
        if (flags != 0 || reserved != 0 || imageIndex >= this->imageCount_) {
            return this->fail(Reason::kProfileInvalid, "E038", "invalid page metadata");
        }
        const bool modeKindMatches =
            (mode == static_cast<UInt32>(Mode::kPage)
             && this->images_[imageIndex].kind == kImageKindStandalone)
            || (mode == static_cast<UInt32>(Mode::kDyld)
                && this->images_[imageIndex].kind == kImageKindSharedCache);
        if (!modeKindMatches) {
            return this->fail(Reason::kProfileInvalid, "E019", "page mode/image kind mismatch");
        }
        if (sitesInPage == 0 || sitesInPage > kMaxSitesPerPage) {
            return this->fail(Reason::kProfileInvalid, "E023", "sites per page out of range");
        }
        if (firstSite != expectedFirstSite) {
            return this->fail(Reason::kProfileInvalid, "E021", "non-canonical site range");
        }
        if (static_cast<UInt64>(firstSite) + sitesInPage > siteCount) {
            return this->fail(Reason::kProfileInvalid, "E020", "page site range exceeds site table");
        }
        if (reserved != 0 || imageIndex >= this->imageCount_) {
            return this->fail(Reason::kProfileInvalid, "E038", "invalid page image metadata");
        }
        if ((pageVmOffset & (kPageSize - 1U)) != 0
            || static_cast<UInt64>(pageVmOffset) + kPageSize > this->images_[imageIndex].vmSize)
        {
            return this->fail(Reason::kProfileInvalid, "E040", "invalid pageVmOffset");
        }

        // Duplicate page identity: the same full-page hash may not appear twice in one mode (two
        // records could both claim the same delivered content).
        for (UInt32 other = 0; other < pageIndex; other++) {
            if (this->pages_[other].mode == static_cast<UInt8>(mode)
                && this->pages_[other].pageHash == pageHash)
            {
                return this->fail(Reason::kProfileInvalid, "E031", "duplicate page identity");
            }
        }

        auto& page          = this->pages_[pageIndex];
        page.pageFileOffset = pageFileOffset;
        page.pageHash       = pageHash;
        page.firstSite      = firstSite;
        page.siteCount      = static_cast<UInt16>(sitesInPage);
        page.mode           = static_cast<UInt8>(mode);
        page.flags          = static_cast<UInt8>(flags);
        page.imageIndex     = static_cast<UInt16>(imageIndex);
        page.pageVmOffset   = pageVmOffset;

        expectedFirstSite += sitesInPage;
    }

    if (expectedFirstSite != siteCount) {
        return this->fail(Reason::kProfileInvalid, "E022", "page site count sum mismatch");
    }

    return true;
}

bool PatchProfile::loadSiteTable(const UInt8* const table, const UInt32 siteCount, const UInt32 pageCount)
{
    for (UInt32 siteIndex = 0; siteIndex < siteCount; siteIndex++) {
        const UInt8* const record = table + static_cast<size_t>(siteIndex) * kSiteRecordSize;

        const UInt32 siteInPage  = readLe16(record + 0);
        const UInt32 findSize    = record[2];
        const UInt32 replaceSize = record[3];
        const UInt32 siteFlags   = readLe32(record + 36);

        if (findSize == 0 || findSize > kMaxSitePatchSize || replaceSize == 0 || replaceSize > kMaxSitePatchSize) {
            return this->fail(Reason::kProfileInvalid, "E024", "invalid site patch size");
        }
        if (findSize != replaceSize) {
            return this->fail(Reason::kProfileInvalid, "E025", "find/replace size mismatch");
        }
        if (siteInPage + findSize > kPageSize) {
            return this->fail(Reason::kProfileInvalid, "E026", "site out of page bounds");
        }
        for (UInt32 padding = findSize; padding < kMaxSitePatchSize; padding++) {
            if (record[4 + padding] != 0 || record[20 + padding] != 0) {
                return this->fail(Reason::kProfileInvalid, "E027", "site padding not zero");
            }
        }
        if (memcmp(record + 4, record + 20, findSize) == 0) {
            return this->fail(Reason::kProfileInvalid, "E028", "no-op site");
        }
        if (siteFlags != 0) { return this->fail(Reason::kProfileInvalid, "E029", "unsupported site flags"); }

        auto& site       = this->sites_[siteIndex];
        site.siteInPage  = static_cast<UInt16>(siteInPage);
        site.size        = static_cast<UInt8>(findSize);
        memcpy(site.find, record + 4, findSize);
        memcpy(site.replace, record + 20, replaceSize);
    }

    // No two sites on one page may write overlapping bytes (specification section 5).
    for (UInt32 pageIndex = 0; pageIndex < pageCount; pageIndex++) {
        const auto& page = this->pages_[pageIndex];
        const UInt32 first = page.firstSite;
        const UInt32 last  = page.firstSite + page.siteCount;

        for (UInt32 a = first; a < last; a++) {
            const UInt32 aStart = this->sites_[a].siteInPage;
            const UInt32 aEnd   = aStart + this->sites_[a].size;
            for (UInt32 b = a + 1; b < last; b++) {
                const UInt32 bStart = this->sites_[b].siteInPage;
                const UInt32 bEnd   = bStart + this->sites_[b].size;
                if (aStart < bEnd && bStart < aEnd) {
                    return this->fail(Reason::kProfileInvalid, "E030", "overlapping site writes");
                }
            }
        }
    }

    return true;
}

void PatchProfile::failBundleSelection(const Reason reason, const char* const code, const char* const context)
{
    (void) this->fail(reason, code, context);
}

void PatchProfile::noteAbsentProfile()
{
    if (this->loadAttempted_) { return; }
    this->loadAttempted_ = true;

    if (this->state_ == State::kNoOp) { return; }

    this->state_        = State::kNoOp;
    this->reason_       = Reason::kProfileAbsent;
    this->errorContext_ = "NRedProfiles bundle absent";
    SYSLOG("PatchEngine", "no NRedProfiles bundle injected; page backend stays inert");
}

bool PatchProfile::setProvisionalBuild(const char* const injectedBuild)
{
    if (this->state_ == State::kNoOp || !this->profileParsed_) { return false; }

    // The hint may unblock early patching only when it is itself a valid build string and exactly
    // equals the parsed profile build.  Invalid, empty or mismatched hints are never stored.
    if (injectedBuild == nullptr || !isValidBuildString(injectedBuild)) { return false; }
    if (strcmp(injectedBuild, this->build_) != 0) { return false; }

    // A confirmed build is already authoritative; the hint has nothing left to decide.
    if (this->buildKnown_ && !this->buildProvisional_) { return true; }

    if (!this->buildKnown_) {
        strlcpy(this->actualBuild_, this->build_, sizeof(this->actualBuild_));
        this->buildKnown_       = true;
        this->buildProvisional_ = true;
        this->evaluateIdentity();
    }

    return this->state_ != State::kNoOp;
}

bool PatchProfile::confirmRunningBuild(const char* const actualBuild, const char* const injectedBuild)
{
    if (this->state_ == State::kNoOp) { return false; }
    if (actualBuild == nullptr || !isValidBuildString(actualBuild)) { return false; }

    // Once the actual build is readable it is the only acceptance input.  An injected hint that
    // disagrees with the actual build or with the profile is an injection inconsistency: hard error.
    if (injectedBuild != nullptr && injectedBuild[0] != '\0'
        && (strcmp(injectedBuild, actualBuild) != 0 || strcmp(injectedBuild, this->build_) != 0))
    {
        this->revokeBuild(Reason::kBuildMismatch, "NRedProfiles entry build differs from kern.osversion");
        return false;
    }

    if (strcmp(actualBuild, this->build_) != 0) {
        this->revokeBuild(Reason::kBuildMismatch, "profile build does not equal kern.osversion");
        return false;
    }

    strlcpy(this->actualBuild_, actualBuild, sizeof(this->actualBuild_));
    this->buildKnown_       = true;
    this->buildProvisional_ = false;

    if (this->identityEvaluated_) {
        if (this->state_ == State::kLoaded) {
            SYSLOG("PatchEngine", "provisional build confirmed by kern.osversion: %s", actualBuild);
        }
        return this->state_ == State::kLoaded;
    }

    this->evaluateIdentity();
    return this->state_ != State::kNoOp;
}

void PatchProfile::failUnconfirmedBuild()
{
    if (this->state_ == State::kNoOp) { return; }
    this->revokeBuild(Reason::kBuildUnavailable, "running kern.osversion not published before the discovery budget");
}

bool PatchProfile::setRunningApu(const UInt32 runningMask, const UInt16 runningDeviceID)
{
    if (this->state_ == State::kNoOp) { return false; }

    this->runningApuMask_  = runningMask & kApuMaskKnown;
    this->runningDeviceID_ = runningDeviceID;
    this->apuKnown_        = true;
    this->evaluateIdentity();
    return this->state_ != State::kNoOp;
}

void PatchProfile::evaluateIdentity()
{
    if (this->identityEvaluated_ || !this->profileParsed_ || !this->buildKnown_ || !this->apuKnown_) { return; }
    this->identityEvaluated_ = true;

    // The accepted build is authoritative: exact equality, no family or prefix matching.
    if (this->actualBuild_[0] == '\0' || strcmp(this->actualBuild_, this->build_) != 0) {
        this->revokeBuild(Reason::kBuildMismatch, "profile build does not equal the accepted build");
        return;
    }

    if (this->runningApuMask_ == 0) {
        this->revokeBuild(Reason::kApuUnavailable, "running APU family unknown");
        return;
    }

    if ((this->apuMask_ & this->runningApuMask_) == 0) {
        this->revokeBuild(Reason::kApuMismatch, "apuMask does not intersect running family");
        return;
    }

    if (this->deviceID_ != 0) {
        if (this->runningDeviceID_ == 0 || this->deviceID_ != this->runningDeviceID_) {
            this->revokeBuild(Reason::kDeviceMismatch, "required deviceID differs from running iGPU");
            return;
        }
    }

    this->state_  = State::kLoaded;
    this->reason_ = Reason::kNone;

    // Publishing point for the code-signing hooks: the tables above happen-before this release store.
    // If the build was only provisional this flag can be cleared again by a later hard mismatch.
    __atomic_store_n(&this->activeFlag_, 1, __ATOMIC_RELEASE);

    SYSLOG("PatchEngine", "NRPT profile active%s: build %s apuMask 0x%X running 0x%X device 0x%04X pages %u sites %u",
           this->buildProvisional_ ? " (provisional build from NRedProfiles entry)" : "", this->build_,
           static_cast<unsigned>(this->apuMask_), static_cast<unsigned>(this->runningApuMask_),
           static_cast<unsigned>(this->deviceID_), static_cast<unsigned>(this->pageCount_),
           static_cast<unsigned>(this->siteCount_));
}

void PatchProfile::applyChunk(const UInt8* const data, const size_t size, const UInt64 chunkBase,
                              const Mode route)
{
    if (data == nullptr || size < kPageSize) { return; }
    if (__atomic_load_n(&this->activeFlag_, __ATOMIC_ACQUIRE) == 0) { return; }

    for (size_t offset = 0; offset + kPageSize <= size; offset += kPageSize) {
        this->applyPage(data + offset, chunkBase + static_cast<UInt64>(offset), route);
    }
}

void PatchProfile::applyPage(const UInt8* const page, const UInt64 chunkBase, const Mode route)
{
    __atomic_fetch_add(&this->chunkCallCount_, 1, __ATOMIC_RELAXED);
    (void)chunkBase;    // pager offset is never part of page identity

    const UInt64 pageHash = fnv1a64(page, kPageSize);

    for (UInt32 pageIndex = 0; pageIndex < this->pageCount_; pageIndex++) {
        const auto& record = this->pages_[pageIndex];

        // Strict frozen-spec mode-domain routing: PAGE records are only considered by the page hook
        // (_cs_validate_page) and DYLD records only by the range hook (_cs_validate_range).
        if (record.mode != static_cast<UInt8>(route)) { continue; }
        if (pageHash != record.pageHash) { continue; }

        __atomic_fetch_add(&this->matchedPageCount_, 1, __ATOMIC_RELAXED);

        const UInt32 wordIndex = pageIndex / 64U;
        const UInt64 bit       = 1ULL << (pageIndex % 64U);
        if ((__atomic_load_n(&this->appliedBits_[wordIndex], __ATOMIC_RELAXED) & bit) != 0) {
            return;    // applied once this boot; never write twice
        }

        bool   sitesMatch = true;
        UInt32 badSite    = 0;
        for (UInt32 siteIndex = 0; siteIndex < record.siteCount; siteIndex++) {
            const auto& site = this->sites_[record.firstSite + siteIndex];
            if (memcmp(page + site.siteInPage, site.find, site.size) != 0) {
                sitesMatch = false;
                badSite    = siteIndex;
                break;
            }
        }
        if (!sitesMatch) {
            __atomic_fetch_add(&this->findMismatchCount_, 1, __ATOMIC_RELAXED);
            if (this->takeLogBudget()) {
                DBGLOG("UserPatch", "site find mismatch on profile page %u site %u (mode %s)",
                       static_cast<unsigned>(pageIndex), static_cast<unsigned>(badSite),
                       modeName(static_cast<Mode>(record.mode)));
            }
            (void)badSite;
            return;
        }

        if ((__atomic_fetch_or(&this->appliedBits_[wordIndex], bit, __ATOMIC_ACQ_REL) & bit) != 0) { return; }

        if (MachInfo::setKernelWriting(true, KernelPatcher::kernelWriteLock) != KERN_SUCCESS) {
            __atomic_fetch_and(&this->appliedBits_[wordIndex], ~bit, __ATOMIC_RELAXED);
            __atomic_fetch_add(&this->writeFailureCount_, 1, __ATOMIC_RELAXED);
            return;
        }

        auto* const writable = const_cast<UInt8*>(page);
        for (UInt32 siteIndex = 0; siteIndex < record.siteCount; siteIndex++) {
            const auto& site = this->sites_[record.firstSite + siteIndex];
            memcpy(writable + site.siteInPage, site.replace, site.size);
        }

        if (MachInfo::setKernelWriting(false, KernelPatcher::kernelWriteLock) != KERN_SUCCESS) {
            __atomic_fetch_add(&this->writeFailureCount_, 1, __ATOMIC_RELAXED);
        }

        __atomic_fetch_add(&this->appliedPageCount_, 1, __ATOMIC_RELAXED);
        if (this->takeLogBudget()) {
            DBGLOG("UserPatch", "applied profile page %u (%u site(s), %s route)",
                   static_cast<unsigned>(pageIndex), static_cast<unsigned>(record.siteCount),
                   modeName(static_cast<Mode>(record.mode)));
        }
        return;
    }

    // Already-patched pass: the shared page cache may already carry our replace bytes.  Mark the
    // record applied without writing; same strict mode-domain filter.
    for (UInt32 pageIndex = 0; pageIndex < this->pageCount_; pageIndex++) {
        if (this->pages_[pageIndex].mode != static_cast<UInt8>(route)) { continue; }
        if (this->markAlreadyPatched(pageIndex, page)) { return; }
    }
}

bool PatchProfile::markAlreadyPatched(const UInt32 pageIndex, const UInt8* const page)
{
    const auto& record = this->pages_[pageIndex];
    if (record.siteCount == 0) { return false; }

    for (UInt32 siteIndex = 0; siteIndex < record.siteCount; siteIndex++) {
        const auto& site = this->sites_[record.firstSite + siteIndex];
        if (memcmp(page + site.siteInPage, site.replace, site.size) != 0) { return false; }
    }

    const UInt32 wordIndex = pageIndex / 64U;
    const UInt64 bit       = 1ULL << (pageIndex % 64U);
    if ((__atomic_fetch_or(&this->appliedBits_[wordIndex], bit, __ATOMIC_ACQ_REL) & bit) != 0) { return true; }

    __atomic_fetch_or(&this->alreadyPatchedBits_[wordIndex], bit, __ATOMIC_RELAXED);
    __atomic_fetch_add(&this->alreadyPatchedCount_, 1, __ATOMIC_RELAXED);
    __atomic_fetch_add(&this->appliedPageCount_, 1, __ATOMIC_RELAXED);
    if (this->takeLogBudget()) {
        DBGLOG("UserPatch", "profile page %u already patched (all replace bytes present); no write",
               static_cast<unsigned>(pageIndex));
    }
    return true;
}

bool PatchProfile::fail(const Reason reason, const char* const code, const char* const context)
{
    this->state_        = State::kNoOp;
    this->reason_       = reason;
    this->errorCode_    = code;
    this->errorContext_ = context;
    this->profileParsed_  = false;
    this->profileVersion_ = 0;
    this->imageCount_     = 0;
    this->pageCount_      = 0;
    this->siteCount_      = 0;
    this->build_[0]       = '\0';

    SYSLOG("PatchEngine", "NRPT profile rejected: %s (%s); page backend stays inert", code, context);
    return false;
}

void PatchProfile::revokeBuild(const Reason reason, const char* const context)
{
    const bool wasActive = __atomic_load_n(&this->activeFlag_, __ATOMIC_ACQUIRE) != 0;

    this->state_        = State::kNoOp;
    this->reason_       = reason;
    this->errorContext_ = context;
    this->buildProvisional_ = false;
    __atomic_store_n(&this->activeFlag_, 0, __ATOMIC_RELEASE);

    if (wasActive) {
        SYSLOG("PatchEngine",
               "profile revoked (%s): %s; %u page(s) were already written and are NOT rolled back",
               reasonName(reason), context, static_cast<unsigned>(__atomic_load_n(&this->appliedPageCount_,
                                                                                  __ATOMIC_RELAXED)));
    }
    else {
        SYSLOG("PatchEngine", "NRPT identity gate failed (%s): %s; page backend stays inert", reasonName(reason),
               context);
    }
}

bool PatchProfile::takeLogBudget()
{
    UInt32 remaining = __atomic_load_n(&this->hookLogBudget_, __ATOMIC_RELAXED);
    while (remaining > 0) {
        if (__atomic_compare_exchange_n(&this->hookLogBudget_, &remaining, remaining - 1U, false, __ATOMIC_RELAXED,
                                        __ATOMIC_RELAXED))
        {
            return true;
        }
    }
    return false;
}

bool PatchProfile::isValidBuildString(const char* const build)
{
    if (build == nullptr) { return false; }

    size_t length = 0;
    while (build[length] != '\0') {
        if (length >= kMaxBuildLength) { return false; }
        const char character = build[length];
        const bool valid = (character >= '0' && character <= '9') || (character >= 'A' && character <= 'Z')
                           || (character >= 'a' && character <= 'z') || character == '.' || character == '_'
                           || character == '-';
        if (!valid) { return false; }
        length++;
    }
    return length >= 1;
}

bool PatchProfile::parseBuildField(const UInt8* const field, char* const out, const size_t outSize)
{
    size_t length = 0;
    while (length < 16 && field[length] != 0) {
        const char character = static_cast<char>(field[length]);
        const bool valid = (character >= '0' && character <= '9') || (character >= 'A' && character <= 'Z')
                           || (character >= 'a' && character <= 'z') || character == '.' || character == '_'
                           || character == '-';
        if (!valid || length >= kMaxBuildLength) { return false; }
        length++;
    }
    if (length == 0 || length >= outSize) { return false; }

    for (size_t padding = length; padding < 16; padding++) {
        if (field[padding] != 0) { return false; }
    }

    memcpy(out, field, length);
    out[length] = '\0';
    return true;
}

UInt32 PatchProfile::apuMaskForDeviceID(const UInt16 deviceID)
{
    // Candidate APU family mask per PCI device ID (NRPT specification section 3.2).  The mask is a
    // coarse selector only; the full-page hash plus every site find remain the actual patch identity.
    switch (deviceID) {
        case 0x15DD:    // Raven
            return 1U << 0;
        case 0x15D8:    // Raven2 / Picasso
            return (1U << 1) | (1U << 2);
        case 0x1636:    // Renoir / Cezanne
        case 0x164C:    // Renoir / Cezanne
            return (1U << 3) | (1U << 4);
        case 0x15E7:    // Barcelo / Green Sardine
        case 0x1638:    // Barcelo / Green Sardine
            return (1U << 3) | (1U << 5);
        default:
            return 0;
    }
}

bool PatchProfile::loaded() const
{
    return __atomic_load_n(&this->activeFlag_, __ATOMIC_ACQUIRE) != 0;
}

bool PatchProfile::provisionalBuild() const { return this->buildProvisional_; }

bool PatchProfile::pageApplied(const UInt32 pageIndex) const
{
    if (pageIndex >= this->pageCount_) { return false; }
    const UInt32 word = pageIndex / 64U;
    return (__atomic_load_n(&this->appliedBits_[word], __ATOMIC_RELAXED) & (1ULL << (pageIndex % 64U))) != 0;
}

UInt64 PatchProfile::appliedMaskWord(const UInt32 wordIndex) const
{
    if (wordIndex >= kAppliedMaskWords) { return 0; }
    return __atomic_load_n(&this->appliedBits_[wordIndex], __ATOMIC_RELAXED);
}

UInt16 PatchProfile::profileVersion() const { return this->profileVersion_; }

UInt32 PatchProfile::imageCount() const { return this->imageCount_; }

const char* PatchProfile::build() const { return this->build_; }

UInt32 PatchProfile::apuMask() const { return this->apuMask_; }

UInt32 PatchProfile::deviceID() const { return this->deviceID_; }

UInt32 PatchProfile::pageCount() const { return this->pageCount_; }

UInt32 PatchProfile::siteCount() const { return this->siteCount_; }

bool PatchProfile::parsed() const { return this->profileParsed_; }

UInt32 PatchProfile::appliedPages() const { return __atomic_load_n(&this->appliedPageCount_, __ATOMIC_RELAXED); }

UInt32 PatchProfile::findMismatches() const { return __atomic_load_n(&this->findMismatchCount_, __ATOMIC_RELAXED); }

UInt32 PatchProfile::matchedPages() const { return __atomic_load_n(&this->matchedPageCount_, __ATOMIC_RELAXED); }

UInt32 PatchProfile::chunkCalls() const { return __atomic_load_n(&this->chunkCallCount_, __ATOMIC_RELAXED); }

UInt32 PatchProfile::writeFailures() const { return __atomic_load_n(&this->writeFailureCount_, __ATOMIC_RELAXED); }

UInt32 PatchProfile::alreadyPatchedPages() const
{
    return __atomic_load_n(&this->alreadyPatchedCount_, __ATOMIC_RELAXED);
}

bool PatchProfile::alreadyPatched(const UInt32 pageIndex) const
{
    return pageIndex < this->pageCount_ && maskBitSet(this->alreadyPatchedBits_, pageIndex);
}

UInt64 PatchProfile::alreadyPatchedMaskWord(const UInt32 wordIndex) const
{
    if (wordIndex >= kAppliedMaskWords) { return 0; }
    return __atomic_load_n(&this->alreadyPatchedBits_[wordIndex], __ATOMIC_RELAXED);
}

bool PatchProfile::maskBitSet(const volatile UInt64* const bits, const UInt32 pageIndex)
{
    const UInt32 word = pageIndex / 64U;
    const UInt64 bit  = 1ULL << (pageIndex % 64U);
    return (__atomic_load_n(&bits[word], __ATOMIC_RELAXED) & bit) != 0;
}

const char* PatchProfile::modeName(const Mode mode)
{
    switch (mode) {
        case Mode::kPage: return "PAGE";
        case Mode::kDyld: return "DYLD";
        case Mode::kResolver: return "RESOLVER";
        default: return "invalid";
    }
}

UInt32 PatchProfile::pageModeCount(const Mode mode) const
{
    UInt32 count = 0;
    for (UInt32 pageIndex = 0; pageIndex < this->pageCount_; pageIndex++) {
        if (this->pages_[pageIndex].mode == static_cast<UInt8>(mode)) { count += 1; }
    }
    return count;
}

UInt32 PatchProfile::runningApuMask() const { return this->runningApuMask_; }
UInt32 PatchProfile::runningDeviceID() const { return this->runningDeviceID_; }
bool   PatchProfile::runningApuKnown() const { return this->apuKnown_; }

PatchProfile::State PatchProfile::state() const { return this->state_; }
PatchProfile::Reason PatchProfile::reason() const { return this->reason_; }
const char* PatchProfile::errorCode() const
{
    return this->errorCode_ != nullptr ? this->errorCode_ : "none";
}

const char* PatchProfile::errorContext() const
{
    return this->errorContext_ != nullptr ? this->errorContext_ : "none";
}

const char* PatchProfile::stateName() const { return stateName(this->state_); }

const char* PatchProfile::stateName(const State state)
{
    switch (state) {
        case State::kIdle: return "Idle";
        case State::kLoaded: return "Loaded";
        case State::kNoOp: return "NoOp";
        default: return "Unknown";
    }
}

const char* PatchProfile::reasonName() const { return reasonName(this->reason_); }

const char* PatchProfile::reasonName(const Reason reason)
{
    switch (reason) {
        case Reason::kNone: return "None";
        case Reason::kProfileAbsent: return "ProfileAbsent";
        case Reason::kProfileInvalid: return "ProfileInvalid";
        case Reason::kBuildUnavailable: return "BuildUnavailable";
        case Reason::kBuildMismatch: return "BuildMismatch";
        case Reason::kApuUnavailable: return "ApuUnavailable";
        case Reason::kApuMismatch: return "ApuMismatch";
        case Reason::kDeviceMismatch: return "DeviceMismatch";
        default: return "Unknown";
    }
}

