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

#pragma once
#include <Headers/kern_patcher.hpp>
#include <Headers/kern_util.hpp>
#include <IOKit/IOLocks.h>
#include <PatchData.hpp>

// Exact 4 KiB page backend for `_cs_validate_page` and `_cs_validate_range`.
//
// The two routes are installed unconditionally from the Lilu patcher-load callback (review D2).  Data
// availability gates page writes only: `processPage` returns immediately until validated data is
// published by `UserPatchData` (release/acquire on its `loaded` flag).  The hook never performs an
// IOKit lookup: VDA readiness is a cached boolean (`vdaReady_`) refreshed from a safe context by the
// runtime state machine (review D5).  Hook-side bookkeeping is atomic, and page writes are serialised
// with a per-backend spinlock; no page/vnode/pager pointer is ever retained.
class UserPatchBackend
{
public:
    static UserPatchBackend& singleton();

    // Installs `_cs_validate_page` and (optionally) `_cs_validate_range`.  Called exactly once from the
    // Lilu patcher-load callback while the runtime lock is held.  Unconditional on data: the hooks are
    // safe no-ops until data is published.  Returns true when the primary page hook is installed.
    bool install(KernelPatcher& patcher);

    // Readiness cache.  Called from a safe context (patcher load / IOService start / delayed retry);
    // never from the validation hooks.  Logs readiness transitions.
    void setVdaReady(bool ready);
    bool vdaReady() const;

    bool   pageHookInstalled() const;
    bool   rangeHookInstalled() const;
    UInt32 appliedPageCount() const;

private:
    UserPatchBackend() = default;
    ~UserPatchBackend() = default;
    UserPatchBackend(const UserPatchBackend&) = delete;
    UserPatchBackend& operator=(const UserPatchBackend&) = delete;
    UserPatchBackend(UserPatchBackend&&) = delete;
    UserPatchBackend& operator=(UserPatchBackend&&) = delete;

    // Called for one exact 4 KiB page in a code-signing validation callback.
    void processPage(const UInt8* data);

    // Outcome of one page application attempt.
    enum class ApplyResult : UInt8
    {
        kApplied = 0,          // sites were written by this call
        kAlreadyPatched,       // another CPU applied the same sites first
        kSiteMismatch,         // a find byte did not match and the page is not patched
        kWriteProtectFailure,  // could not disable kernel write protection
    };

    // Verifies every site's find bytes, then writes every replace under the kernel write lock.  Must be
    // called with `writeLock_` held, and it must not log or sleep while the spinlock is held; the caller
    // reports the result after unlocking.  `writeProtectRestoreFailed` is set when the writes happened
    // but kernel write protection could not be restored.
    ApplyResult applyPage(const UserPatchData::Page& page, UInt8* data, bool& writeProtectRestoreFailed) const;

    // True when `data` is the page image with this page's replacements already applied.
    bool isPatchedPage(const UserPatchData::Page& page, const UInt8* data) const;

    static void wrapCsValidatePage(void* vnode, void* pager, UInt64 pageOffset, const void* data,
                                   int* validated, int* tainted, int* nx);
    static boolean_t wrapCsValidateRange(void* vnode, void* pager, UInt64 pageOffset, const void* data,
                                         UInt64 dataSize, unsigned* tainted);

    mach_vm_address_t orgCsValidatePage_{0};
    mach_vm_address_t orgCsValidateRange_{0};

    // Serialises the write-protection toggle and the site writes between validation callbacks.  Unlike
    // the runtime IOLock this is a spinlock: it must never sleep and is only held for a bounded memcpy.
    IOSimpleLock* writeLock_{nullptr};

    bool installAttempted_{false};
    bool pageHookInstalled_{false};
    bool rangeHookInstalled_{false};

    // Hook-side state.  Read/written with __atomic builtins because several CPUs can run page validation
    // concurrently; no lock is taken in the callback for these.
    volatile bool   vdaReady_{false};
    volatile bool   vdaGateLogged_{false};
    volatile UInt64 appliedPages_{0};    // bit per page index (pageCount <= 64)
    volatile UInt32 appliedPageCount_{0};
};
