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

#pragma once
#include <Headers/kern_patcher.hpp>
#include <Headers/kern_util.hpp>
#include <PatchData.hpp>

// Code-signing validation backend.
//
// Big Sur+ only:
//   - route _cs_validate_page;
//   - after the original validator accepts the page, patch the pager data in
//     place with MachInfo::setKernelWriting.
//
// No task map, no process path, no slide, no range route.  The pager data is
// shared by every mapping of the page, so one write is global.
class UserPatchBackend
{
public:
    static UserPatchBackend& singleton();

    // Installs the page-only validation route.
    bool install(KernelPatcher& patcher);

    // Parses the profile supplied by the injected Info.plist personality
    // property.  Only memory is inspected; no VFS or thread is used.
    bool loadProfileFromData(const void* data, size_t size);

    bool   pageHookInstalled() const;
    bool   rangeHookInstalled() const;
    UInt32 appliedPageCount() const;
    bool   profileLoaded() const;
    UInt32 profileFailureStage() const;

private:
    UserPatchBackend() = default;
    ~UserPatchBackend() = default;
    UserPatchBackend(const UserPatchBackend&) = delete;
    UserPatchBackend& operator=(const UserPatchBackend&) = delete;
    UserPatchBackend(UserPatchBackend&&) = delete;
    UserPatchBackend& operator=(UserPatchBackend&&) = delete;

    // Parsed-offset performPagePatch: pageOffset selects the profile, fixed siteInPage writes.
    void performPagePatch(const UInt8* data, size_t dataSize, UInt64 pageOffset);

    // Big Sur+ page validator with explicit result pointers.
    static void wrapCsValidatePage(void* blobs, void* pager, UInt64 pageOffset, const void* data, int* validated,
                                   int* tainted, int* nx);

    mach_vm_address_t orgCsValidatePage_{0};

    bool profileLoaded_{false};
    volatile UInt32 profileFailureStage_{0};

    bool installAttempted_{false};
    bool pageHookInstalled_{false};

    volatile UInt64 appliedPages_{0};
    volatile UInt32 appliedPageCount_{0};
};
