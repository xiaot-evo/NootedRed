// NootedRedUserPatch code-signing backend
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

#include <UserPatchBackend.hpp>

#include <Headers/kern_mach.hpp>
#include <string.h>

using tCsValidatePage = void (*)(void*, void*, UInt64, const void*, int*, int*, int*);
using tVnodeLookup = int (*)(const char*, int, void**, void*);
using tVnodePut = int (*)(void*);
using tVnRdwr = int (*)(int, void*, char*, int, int64_t, int, int, void*, int*, void*);
using tVfsContextCurrent = void* (*)(void);
using tKauthCredGet = void* (*)(void);
using tCurrentProc = void* (*)(void);

namespace
{

    constexpr char kProfileMagic[4] = {'N', 'R', 'P', 'F'};
    constexpr UInt32 kProfileVersion = 1;
    constexpr size_t kProfileHeaderSize = 32;
    constexpr const char* kProfilePath = "/var/db/nootedred/offset-profile.bin";

    // Embedded 24H32 fallback.  The user-space profile generator can replace
    // these page offsets with a build-specific set via /var/db/nootedred.
    UInt64 gPageFileOffsets[] = {
        0x0000E000,    // GL HwInfo
        0x00008000,    // GL DualQuad
        0x087B3000,    // MTLControl
        0x087EF000,    // MTL HwInfo
        0x08606000,    // VDA page 0
        0x08608000,    // VDA page 1
        0x0860F000,    // VDA page 2
        0x0864D000,    // VDA page 3
        0x0864F000,    // VDA page 4
        0x08650000,    // VDA page 5
        0x08667000,    // VDA page 6
        0x0867D000,    // VDA page 7
        0x06692000,    // AppleGVA
    };

    static_assert(sizeof(gPageFileOffsets) / sizeof(gPageFileOffsets[0]) <= UserPatchData::kMaxPages,
                  "page offset table must fit the embedded page limit");

    UInt32 fnv1a32(const UInt8* data, size_t size)
    {
        UInt32 hash = 2166136261U;
        for (size_t i = 0; i < size; i++) {
            hash ^= data[i];
            hash *= 16777619U;
        }
        return hash;
    }

    bool sitesFitAtOffsets(const UInt8* const ptr, const UserPatchData::Page& page,
                           const UserPatchData::Site* const sites)
    {
        for (UInt32 i = 0; i < page.siteCount; i++) {
            const auto& site = sites[page.siteIndex + i];
            if (site.offset + site.size > UserPatchData::kPageSize) { return false; }
            if (memcmp(ptr + site.offset, site.find, site.size) != 0) { return false; }
        }
        return true;
    }

}    // namespace

UserPatchBackend& UserPatchBackend::singleton()
{
    static UserPatchBackend instance;
    return instance;
}

bool UserPatchBackend::install(KernelPatcher& patcher)
{
    if (this->installAttempted_) { return this->pageHookInstalled_; }
    this->installAttempted_ = true;

    if (getKernelVersion() < KernelVersion::BigSur) {
        SYSLOG("UserPatch", "kernel is older than Big Sur; page backend not installed");
        return false;
    }

    KernelPatcher::RouteRequest pageRequest{"_cs_validate_page", wrapCsValidatePage, this->orgCsValidatePage_};
    if (!patcher.routeMultipleLong(KernelPatcher::KernelID, &pageRequest, 1)) {
        patcher.clearError();
        return false;
    }
    this->pageHookInstalled_ = true;

    auto solve = [&patcher](const char* name) -> mach_vm_address_t {
        auto address = patcher.solveSymbol(KernelPatcher::KernelID, name);
        if (patcher.getError() != KernelPatcher::Error::NoError) {
            patcher.clearError();
            return 0;
        }
        return address;
    };

    this->orgVnodeLookup_ = solve("_vnode_lookup");
    this->orgVnodePut_ = solve("_vnode_put");
    this->orgVnRdwr_ = solve("_vn_rdwr");
    this->orgVfsContextCurrent_ = solve("_vfs_context_current");
    this->orgKauthCredGet_ = solve("_kauth_cred_get");
    this->orgCurrentProc_ = solve("_current_proc");

    SYSLOG("UserPatch", "installed _cs_validate_page backend (profile=%s)",
           this->orgVnodeLookup_ != 0 ? "vfs" : "embedded");
    return true;
}

bool UserPatchBackend::loadExternalProfile()
{
    if (this->profileLoaded_) { return true; }
    if (this->orgVnodeLookup_ == 0 || this->orgVnodePut_ == 0 || this->orgVnRdwr_ == 0
        || this->orgVfsContextCurrent_ == 0 || this->orgKauthCredGet_ == 0 || this->orgCurrentProc_ == 0)
    {
        return false;
    }

    auto lookup = reinterpret_cast<tVnodeLookup>(this->orgVnodeLookup_);
    auto put = reinterpret_cast<tVnodePut>(this->orgVnodePut_);
    auto rdwr = reinterpret_cast<tVnRdwr>(this->orgVnRdwr_);
    auto context = reinterpret_cast<tVfsContextCurrent>(this->orgVfsContextCurrent_)();
    auto cred = reinterpret_cast<tKauthCredGet>(this->orgKauthCredGet_)();
    auto proc = reinterpret_cast<tCurrentProc>(this->orgCurrentProc_)();

    void* vnode = nullptr;
    if (lookup(kProfilePath, 0, &vnode, context) != 0 || vnode == nullptr) { return false; }

    UInt8 buffer[512]{};
    int residual = 0;
    const auto readResult = rdwr(0, vnode, reinterpret_cast<char*>(buffer), sizeof(buffer), 0, 1, 0, cred, &residual,
                                 proc);
    put(vnode);
    if (readResult != 0 || residual < 0) { return false; }

    const size_t available = sizeof(buffer) - static_cast<size_t>(residual);
    if (available < kProfileHeaderSize || memcmp(buffer, kProfileMagic, sizeof(kProfileMagic)) != 0) { return false; }

    const auto version = static_cast<UInt16>(buffer[4] | (buffer[5] << 8));
    const auto headerSize = static_cast<UInt16>(buffer[6] | (buffer[7] << 8));
    const auto pageCount = static_cast<UInt16>(buffer[8] | (buffer[9] << 8));
    if (version != kProfileVersion || headerSize != kProfileHeaderSize
        || pageCount != UserPatchData::singleton().pageCount()
        || pageCount > sizeof(gPageFileOffsets) / sizeof(gPageFileOffsets[0]))
    {
        return false;
    }

    const size_t offsetsSize = static_cast<size_t>(pageCount) * sizeof(UInt64);
    if (available < kProfileHeaderSize + offsetsSize) { return false; }

    char profileBuild[17]{};
    memcpy(profileBuild, buffer + 12, 16);
    const char* const runtimeBuild = UserPatchData::singleton().buildString();
    if (runtimeBuild == nullptr || strncmp(profileBuild, runtimeBuild, 3) != 0) { return false; }

    const auto expectedChecksum = static_cast<UInt32>(buffer[28])
                                  | (static_cast<UInt32>(buffer[29]) << 8)
                                  | (static_cast<UInt32>(buffer[30]) << 16)
                                  | (static_cast<UInt32>(buffer[31]) << 24);
    if (fnv1a32(buffer + kProfileHeaderSize, offsetsSize) != expectedChecksum) { return false; }

    for (UInt16 i = 0; i < pageCount; i++) {
        UInt64 offset = 0;
        memcpy(&offset, buffer + kProfileHeaderSize + static_cast<size_t>(i) * sizeof(UInt64), sizeof(offset));
        if (offset == 0) { return false; }
        gPageFileOffsets[i] = offset;
    }

    this->profileLoaded_ = true;
    this->profileAttempted_ = true;
    SYSLOG("UserPatch", "loaded external offset profile for build %s (%u pages)", profileBuild,
           static_cast<unsigned>(pageCount));
    return true;
}

void UserPatchBackend::performPagePatch(const UInt8* data, size_t dataSize, UInt64 pageOffset)
{
    // Runs inside the code-signing validator; no IOKit, no VFS, no allocation.
    const auto& patchData = UserPatchData::singleton();
    if (data == nullptr || !patchData.loaded()) { return; }

    const auto* const pages = patchData.pages();
    const auto* const sites = patchData.sites();
    if (pages == nullptr || sites == nullptr) { return; }

    const UInt32 pageCount = patchData.pageCount();
    if (pageCount > sizeof(gPageFileOffsets) / sizeof(gPageFileOffsets[0])) { return; }

    for (size_t dataOffset = 0; dataOffset + UserPatchData::kPageSize <= dataSize;
         dataOffset += UserPatchData::kPageSize)
    {
        const UInt64 currentPageOffset = pageOffset + dataOffset;

        for (UInt32 pageIndex = 0; pageIndex < pageCount; pageIndex++) {
            if (gPageFileOffsets[pageIndex] != currentPageOffset) { continue; }

            const auto& page = pages[pageIndex];
            const UInt64 bit = 1ULL << (pageIndex & 63U);
            if ((__atomic_load_n(&this->appliedPages_, __ATOMIC_RELAXED) & bit) != 0) { return; }

            auto* const ptr = const_cast<UInt8*>(data + dataOffset);
            if (!sitesFitAtOffsets(ptr, page, sites)) {
                DBGLOG("UserPatch", "page %u offset 0x%llX: find mismatch", static_cast<unsigned>(pageIndex),
                       static_cast<unsigned long long>(currentPageOffset));
                return;
            }

            if (MachInfo::setKernelWriting(true, KernelPatcher::kernelWriteLock) != KERN_SUCCESS) {
                SYSLOG("UserPatch", "failed to disable kernel write protection");
                return;
            }

            for (UInt32 siteIndex = 0; siteIndex < page.siteCount; siteIndex++) {
                const auto& site = sites[page.siteIndex + siteIndex];
                memcpy(ptr + site.offset, site.replace, site.size);
            }

            if (MachInfo::setKernelWriting(false, KernelPatcher::kernelWriteLock) != KERN_SUCCESS) {
                SYSLOG("UserPatch", "failed to restore kernel write protection");
                return;
            }

            __atomic_fetch_or(&this->appliedPages_, bit, __ATOMIC_RELAXED);
            __atomic_fetch_add(&this->appliedPageCount_, 1, __ATOMIC_RELAXED);
            DBGLOG("UserPatch", "applied %s page %u: %u site(s) at offset 0x%llX",
                   UserPatchData::tableName(page.tableKind), static_cast<unsigned>(pageIndex),
                   static_cast<unsigned>(page.siteCount), static_cast<unsigned long long>(currentPageOffset));
            return;
        }
    }
}

void UserPatchBackend::wrapCsValidatePage(void* blobs, void* pager, UInt64 pageOffset, const void* data,
                                          int* validated, int* tainted, int* nx)
{
    auto& self     = singleton();
    auto  original = reinterpret_cast<tCsValidatePage>(self.orgCsValidatePage_);
    FunctionCast(wrapCsValidatePage, reinterpret_cast<mach_vm_address_t>(original))(
        blobs, pager, pageOffset, data, validated, tainted, nx);

    if (validated != nullptr && *validated != 0 && data != nullptr) {
        self.performPagePatch(static_cast<const UInt8*>(data), UserPatchData::kPageSize, pageOffset);
    }
}

bool UserPatchBackend::pageHookInstalled() const { return this->pageHookInstalled_; }

bool UserPatchBackend::rangeHookInstalled() const { return false; }

UInt32 UserPatchBackend::appliedPageCount() const
{
    return __atomic_load_n(&this->appliedPageCount_, __ATOMIC_RELAXED);
}
