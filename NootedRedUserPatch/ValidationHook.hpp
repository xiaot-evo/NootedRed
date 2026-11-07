// NootedRedUserPatch code-signing validation hook
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
#include <stddef.h>

namespace NRedUserPatch
{

    // Routes _cs_validate_page.  The original validator always runs first and its result is never
    // changed; only an accepted page is handed to SiteSet::apply.  The hook performs no allocation,
    // no file I/O and no sleeping; the only VFS-adjacent call is the pre-resolved vnode name lookup.
    class ValidationHook
    {
    public:
        static auto singleton() -> ValidationHook&;

        void install(KernelPatcher& patcher);
        auto installed() const -> bool;
        auto hasNameResolver() const -> bool;

    private:
        ValidationHook()  = default;
        ~ValidationHook() = default;
        ValidationHook(const ValidationHook&) = delete;
        auto operator=(const ValidationHook&) -> ValidationHook& = delete;

        using tCsValidatePage = void (*)(void*, void*, UInt64, const void*, int*, int*, int*);
        using tVnodeGetname   = const char* (*)(void*);
        using tVnodePutname   = void (*)(const char*);
        using tVnGetpath      = int (*)(void*, char*, int*);

        static void wrapCsValidatePage(void* vnode, void* pager, UInt64 pageOffset, const void* data, int* validated,
                                       int* tainted, int* nx);
        static auto beginWrite(void* context) -> bool;
        static void endWrite(void* context);
        auto nameForVnode(void* vnode, char* out, size_t size) -> bool;
        auto takeLogBudget() -> bool;

        mach_vm_address_t orgCsValidatePage_{0};
        mach_vm_address_t orgVnodeGetname_{0};
        mach_vm_address_t orgVnodePutname_{0};
        mach_vm_address_t orgVnGetpath_{0};
        bool              installed_{false};
        volatile UInt32   logBudget_{32};
    };

}    // namespace NRedUserPatch
