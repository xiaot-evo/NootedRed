// NootedRedUserPatch code-signing validation backend
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
#include <mach/boolean.h>

// Code-signing validation routing for the generic NRPT profile engine.
//
// The backend only owns the routes and the hook wrappers: every matching and writing decision is made
// by PatchProfile, which consumes the injected NRPT profile.  Both routes are installed from the Lilu
// patcher-load callback, before any page-validation hook can run, and are safe no-ops until the
// profile engine published a validated profile (so a missing or rejected profile never delays boot or
// leaves kernel text routed conditionally).
//
// Hook ABI (macOS 11+ / 24H232, see analysis/xnu-lilu-page-validation.md):
//   _cs_validate_page:  void (blobs, pager, page_offset, data, int *validated, int *tainted, int *nx)
//   _cs_validate_range: boolean_t (blobs, pager, range_offset, data, data_size, unsigned *tainted)
//
// Validation hooks must never allocate, touch IOKit/VFS or sleep.  Hardware identity is detected once
// from the sleepable patcher-load context instead.
class UserPatchBackend
{
public:
    static UserPatchBackend& singleton();

    // Installs _cs_validate_page (page path) and _cs_validate_range (range/shared-cache path).  Each
    // route is independent: a missing symbol disables that path only and is reported through the
    // diagnostics properties.  Called once from the Lilu patcher-load callback.
    void install(KernelPatcher& patcher);

    // Detects the running AMD iGPU identity through Lilu's cached DeviceInfo and forwards it to the
    // profile engine.  Must run in a sleepable IOKit-safe context (the patcher-load callback), never
    // in a validation hook.
    void detectHardwareIdentity();

    bool pageHookInstalled() const;
    bool rangeHookInstalled() const;

private:
    UserPatchBackend()  = default;
    ~UserPatchBackend() = default;
    UserPatchBackend(const UserPatchBackend&) = delete;
    UserPatchBackend& operator=(const UserPatchBackend&) = delete;
    UserPatchBackend(UserPatchBackend&&) = delete;
    UserPatchBackend& operator=(UserPatchBackend&&) = delete;

    // 7-argument `void` page validator on macOS 11+ (confirmed for 24H232).
    static void wrapCsValidatePage(void* blobs, void* pager, UInt64 pageOffset, const void* data, int* validated,
                                   int* tainted, int* nx);

    // 6-argument `boolean_t` range validator.
    static boolean_t wrapCsValidateRange(void* blobs, void* pager, UInt64 rangeOffset, const void* data,
                                         UInt64 dataSize, unsigned* tainted);

    mach_vm_address_t orgCsValidatePage_{0};
    mach_vm_address_t orgCsValidateRange_{0};

    bool installAttempted_{false};
    bool pageHookInstalled_{false};
    bool rangeHookInstalled_{false};
};
