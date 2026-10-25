// NootedRedUserPatch exact-page code-signing backend
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

UserPatchBackend& UserPatchBackend::singleton()
{
    static UserPatchBackend instance;
    return instance;
}

bool UserPatchBackend::install(KernelPatcher& patcher)
{
    if (this->installAttempted_) { return this->pageHookInstalled_; }
    this->installAttempted_ = true;

    // The hooks are installed unconditionally (review D2): validated data gates the page write path only,
    // so an unreadable data volume can never delay or reorder kernel-text routing.  The spinlock must
    // exist before any routed callback can run.
    this->writeLock_ = IOSimpleLockAlloc();
    if (this->writeLock_ == nullptr) {
        SYSLOG("UserPatch", "failed to allocate the page-write spinlock; not installing the exact-page hooks");
        return false;
    }

    KernelPatcher::RouteRequest pageRequest{"_cs_validate_page", wrapCsValidatePage, this->orgCsValidatePage_};
    if (!patcher.routeMultipleLong(KernelPatcher::KernelID, &pageRequest, 1)) {
        SYSLOG("UserPatch", "failed to route _cs_validate_page (%d)", static_cast<int>(patcher.getError()));
        patcher.clearError();
        return false;
    }
    this->pageHookInstalled_ = true;

    // The range variant sees shared-cache and protected-pager ranges.  It is an optional extra; the page
    // hook is the primary backend, so a missing _cs_validate_range is not fatal.
    KernelPatcher::RouteRequest rangeRequest{"_cs_validate_range", wrapCsValidateRange, this->orgCsValidateRange_};
    if (!patcher.routeMultipleLong(KernelPatcher::KernelID, &rangeRequest, 1)) {
        SYSLOG("UserPatch", "failed to route _cs_validate_range; continuing with _cs_validate_page only (%d)",
               static_cast<int>(patcher.getError()));
        patcher.clearError();
    }
    else {
        this->rangeHookInstalled_ = true;
    }

    SYSLOG("UserPatch", "installed exact-page routes (page=%s range=%s); page writes stay gated by validated data",
           this->pageHookInstalled_ ? "yes" : "no", this->rangeHookInstalled_ ? "yes" : "no");

    return true;
}

void UserPatchBackend::setVdaReady(const bool ready)
{
    const bool previous = __atomic_exchange_n(&this->vdaReady_, ready, __ATOMIC_ACQ_REL);
    if (previous == ready) { return; }

    if (ready) {
        SYSLOG("UserPatch", "NRedVCNBridgeReady is set; VDA/AppleGVA pages are now eligible");
    }
    else {
        SYSLOG("UserPatch", "NRedVCNBridgeReady is absent or zero; VDA/AppleGVA pages remain unpatched");
    }
}

bool UserPatchBackend::vdaReady() const { return __atomic_load_n(&this->vdaReady_, __ATOMIC_ACQUIRE); }

void UserPatchBackend::processPage(const UInt8* const data)
{
    // No IOKit, no VFS, no runtime lock: this runs inside the code-signing validator.
    const auto& patchData = UserPatchData::singleton();
    if (data == nullptr || !patchData.loaded()) { return; }

    const auto* const pages = patchData.pages();
    if (pages == nullptr) { return; }

    const UInt32 pageCount = patchData.pageCount();
    const bool   vdaReady  = __atomic_load_n(&this->vdaReady_, __ATOMIC_ACQUIRE);

    // Cheap first-word pre-filter: the validation callback runs for every signed page.
    UInt64 head = 0;
    memcpy(&head, data, sizeof(head));

    for (UInt32 pageIndex = 0; pageIndex < pageCount; pageIndex++) {
        const auto& page = pages[pageIndex];

        if (page.head == head && memcmp(page.image, data, UserPatchData::kPageSize) == 0) {
            if (page.isVda != 0 && !vdaReady) {
                if (!__atomic_exchange_n(&this->vdaGateLogged_, true, __ATOMIC_RELAXED)) {
                    SYSLOG("UserPatch", "VDA page matched but NRedVCNBridgeReady is not set; leaving it unpatched");
                }
                continue;
            }

            bool             restoreFailed = false;
            ApplyResult      result        = ApplyResult::kSiteMismatch;
            IOSimpleLockLock(this->writeLock_);
            result = this->applyPage(page, const_cast<UInt8*>(data), restoreFailed);
            IOSimpleLockUnlock(this->writeLock_);

            // No logging while the spinlock is held: report the outcome now.
            if (restoreFailed) {
                SYSLOG("UserPatch", "failed to restore kernel write protection after applying page %u",
                       static_cast<unsigned>(pageIndex));
            }

            if (result == ApplyResult::kApplied || result == ApplyResult::kAlreadyPatched) {
                const UInt64 bit      = 1ULL << pageIndex;
                const UInt64 previous = __atomic_fetch_or(&this->appliedPages_, bit, __ATOMIC_RELAXED);
                if ((previous & bit) == 0) {
                    __atomic_fetch_add(&this->appliedPageCount_, 1, __ATOMIC_RELAXED);
                    SYSLOG("UserPatch", "applied %s exact-page patch: %u site(s) on page %u",
                           UserPatchData::tableName(page.tableKind), static_cast<unsigned>(page.siteCount),
                           static_cast<unsigned>(pageIndex));
                }
            }
            else if (result == ApplyResult::kSiteMismatch) {
                SYSLOG("UserPatch", "page matched but a patch site did not; leaving the page unpatched");
            }
            else {
                SYSLOG("UserPatch", "failed to disable kernel write protection; leaving the page unpatched");
            }
            return;
        }

        // The page may already carry our replacement bytes from an earlier validation (page caches are
        // shared between processes); never rewrite it then.
        if (page.patchedHead == head && this->isPatchedPage(page, data)) { return; }
    }
}

UserPatchBackend::ApplyResult UserPatchBackend::applyPage(const UserPatchData::Page& page, UInt8* const data,
                                                           bool& writeProtectRestoreFailed) const
{
    writeProtectRestoreFailed = false;

    const auto& patchData = UserPatchData::singleton();
    const auto* const sites = patchData.sites();
    if (sites == nullptr) { return ApplyResult::kSiteMismatch; }

    // Verify every site verbatim at its authoritative offset before writing anything, so a partially
    // matching page is never modified.
    for (UInt32 siteIndex = 0; siteIndex < page.siteCount; siteIndex++) {
        const auto& site = sites[page.siteIndex + siteIndex];
        if (memcmp(data + site.offset, site.find, site.size) != 0) {
            // Two CPUs can validate the same shared page concurrently: the other one may have applied the
            // sites between our page compare and this lock.  That is already the desired end state.
            if (this->isPatchedPage(page, data)) { return ApplyResult::kAlreadyPatched; }

            return ApplyResult::kSiteMismatch;
        }
    }

    if (MachInfo::setKernelWriting(true, KernelPatcher::kernelWriteLock) != KERN_SUCCESS) {
        return ApplyResult::kWriteProtectFailure;
    }

    for (UInt32 siteIndex = 0; siteIndex < page.siteCount; siteIndex++) {
        const auto& site = sites[page.siteIndex + siteIndex];
        memcpy(data + site.offset, site.replace, site.size);
    }

    if (MachInfo::setKernelWriting(false, KernelPatcher::kernelWriteLock) != KERN_SUCCESS) {
        writeProtectRestoreFailed = true;
    }

    return ApplyResult::kApplied;
}

bool UserPatchBackend::isPatchedPage(const UserPatchData::Page& page, const UInt8* const data) const
{
    const auto& patchData = UserPatchData::singleton();
    const auto* const sites = patchData.sites();
    if (sites == nullptr) { return false; }

    for (size_t pageOffset = 0; pageOffset < UserPatchData::kPageSize; pageOffset++) {
        const UserPatchData::Site* site = nullptr;
        for (UInt32 siteIndex = 0; siteIndex < page.siteCount; siteIndex++) {
            const auto& candidate = sites[page.siteIndex + siteIndex];
            if (pageOffset >= candidate.offset
                && pageOffset < static_cast<size_t>(candidate.offset) + static_cast<size_t>(candidate.size))
            {
                site = &candidate;
                break;
            }
        }

        if (site != nullptr) {
            if (data[pageOffset] != site->replace[pageOffset - site->offset]) { return false; }
        }
        else if (data[pageOffset] != page.image[pageOffset]) {
            return false;
        }
    }

    return true;
}

void UserPatchBackend::wrapCsValidatePage(void* const vnode, void* const pager, const UInt64 pageOffset,
                                          const void* const data, int* const validated, int* const tainted,
                                          int* const nx)
{
    auto& self = singleton();
    FunctionCast(wrapCsValidatePage, self.orgCsValidatePage_)(vnode, pager, pageOffset, data, validated, tainted, nx);

    // Only patch a page the original validator accepted: a rejected page must not become valid-looking.
    if (validated == nullptr || *validated == 0 || data == nullptr) { return; }
    self.processPage(static_cast<const UInt8*>(data));
}

boolean_t UserPatchBackend::wrapCsValidateRange(void* const vnode, void* const pager, const UInt64 pageOffset,
                                                const void* const data, const UInt64 dataSize,
                                                unsigned* const tainted)
{
    auto& self = singleton();
    const auto result =
        FunctionCast(wrapCsValidateRange, self.orgCsValidateRange_)(vnode, pager, pageOffset, data, dataSize, tainted);

    if (result == 0 || data == nullptr) { return result; }

    const auto* const bytes = static_cast<const UInt8*>(data);
    for (UInt64 offset = 0; offset + UserPatchData::kPageSize <= dataSize; offset += UserPatchData::kPageSize) {
        self.processPage(bytes + offset);
    }

    return result;
}

bool UserPatchBackend::pageHookInstalled() const { return this->pageHookInstalled_; }

bool UserPatchBackend::rangeHookInstalled() const { return this->rangeHookInstalled_; }

UInt32 UserPatchBackend::appliedPageCount() const
{
    return __atomic_load_n(&this->appliedPageCount_, __ATOMIC_RELAXED);
}
