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

#include <ValidationHook.hpp>

#include <AnalyzerRuntime.hpp>
#include <Headers/kern_mach.hpp>
#include <IOKit/IOLib.h>
#include <SiteSet.hpp>

#include <stdint.h>
#include <string.h>

namespace
{

    auto copyText(char* const destination, const size_t capacity, const char* const source) -> void
    {
        if (destination == nullptr || capacity == 0U) { return; }
        size_t index = 0;
        if (source != nullptr) {
            for (; source[index] != '\0' && index + 1U < capacity; index++) { destination[index] = source[index]; }
        }
        destination[index] = '\0';
    }

    auto basenameOf(const char* const path) -> const char*
    {
        if (path == nullptr) { return ""; }
        const char* base = path;
        for (const char* cursor = path; *cursor != '\0'; cursor++) {
            if (*cursor == '/') { base = cursor + 1; }
        }
        return base;
    }

}    // namespace

namespace NRedUserPatch
{

    auto ValidationHook::singleton() -> ValidationHook&
    {
        static ValidationHook instance;
        return instance;
    }

    void ValidationHook::install(KernelPatcher& patcher)
    {
        if (this->installed_) { return; }

        this->orgVnodeGetname_ = patcher.solveSymbol(KernelPatcher::KernelID, "_vnode_getname");
        patcher.clearError();
        this->orgVnodePutname_ = patcher.solveSymbol(KernelPatcher::KernelID, "_vnode_putname");
        patcher.clearError();
        this->orgVnGetpath_ = patcher.solveSymbol(KernelPatcher::KernelID, "_vn_getpath");
        patcher.clearError();

        // vnode_getname returns a borrowed string that must be released with vnode_putname; without
        // both symbols the pair is unusable and the path fallback is the only safe resolver.
        if (this->orgVnodeGetname_ == 0 || this->orgVnodePutname_ == 0) {
            this->orgVnodeGetname_ = 0;
            this->orgVnodePutname_ = 0;
        }
        if (this->orgVnodeGetname_ == 0 && this->orgVnGetpath_ == 0) {
            SYSLOG("UserPatch", "no vnode name resolver; hook matches nothing (fail closed)");
        }
        SYSLOG("UserPatch", "name resolver: getname %u putname %u getpath %u",
               static_cast<unsigned>(this->orgVnodeGetname_ != 0), static_cast<unsigned>(this->orgVnodePutname_ != 0),
               static_cast<unsigned>(this->orgVnGetpath_ != 0));
        IOLog("NootedRedUserPatch: name resolver getname=%u putname=%u getpath=%u\n",
              static_cast<unsigned>(this->orgVnodeGetname_ != 0), static_cast<unsigned>(this->orgVnodePutname_ != 0),
              static_cast<unsigned>(this->orgVnGetpath_ != 0));

        SiteSet::singleton().setWriter(&ValidationHook::beginWrite, &ValidationHook::endWrite, nullptr);

        KernelPatcher::RouteRequest request{"_cs_validate_page", wrapCsValidatePage, this->orgCsValidatePage_};
        if (patcher.routeMultipleLong(KernelPatcher::KernelID, &request, 1)) {
            this->installed_ = true;
            SYSLOG("UserPatch", "installed _cs_validate_page route");
            IOLog("NootedRedUserPatch: installed _cs_validate_page route\n");
        }
        else {
            patcher.clearError();
            SYSLOG("UserPatch", "_cs_validate_page route unavailable; no writes");
            IOLog("NootedRedUserPatch: _cs_validate_page route unavailable\n");
        }
    }

    auto ValidationHook::installed() const -> bool { return this->installed_; }

    auto ValidationHook::hasNameResolver() const -> bool
    {
        return this->orgVnodeGetname_ != 0 || this->orgVnGetpath_ != 0;
    }

    auto ValidationHook::takeLogBudget() -> bool
    {
        if (__atomic_load_n(&this->logBudget_, __ATOMIC_RELAXED) == 0U) { return false; }
        return __atomic_fetch_sub(&this->logBudget_, 1U, __ATOMIC_RELAXED) > 0U;
    }

    void ValidationHook::wrapCsValidatePage(void* const vnode, void* const pager, const UInt64 pageOffset,
                                            const void* const data, int* const validated, int* const tainted,
                                            int* const nx)
    {
        auto& self = singleton();
        auto  original = reinterpret_cast<tCsValidatePage>(self.orgCsValidatePage_);
        FunctionCast(wrapCsValidatePage, reinterpret_cast<mach_vm_address_t>(original))(
            vnode, pager, pageOffset, data, validated, tainted, nx);

        if (validated == nullptr || *validated == 0 || data == nullptr) { return; }

        char name[64]{};
        const bool named = self.nameForVnode(vnode, name, sizeof(name));
        if (__atomic_exchange_n(&self.firstCallLogged_, 1U, __ATOMIC_RELAXED) == 0U) {
            DBGLOG("UserPatch", "hook: first validation named=%u name='%s' offset=0x%llx", named ? 1U : 0U,
                   named ? name : "", static_cast<unsigned long long>(pageOffset));
        }
        if (!named) { return; }

        // The first dyld shared-cache validation is the earliest safe point for the analyzer's VFS
        // phase: user space is up and the Cryptex volume is mounted.  Setting the flag is a single
        // atomic store; the worker (not this hook) does every namei/vnode read.
        if (!SiteSet::singleton().ready() && AnalyzerRuntime::isTriggerVnode(name)) {
            AnalyzerRuntime::singleton().noteTrigger();
            if (self.takeLogBudget()) {
                DBGLOG("UserPatch", "hook: analyzer trigger from '%s' page 0x%llx", name,
                       static_cast<unsigned long long>(pageOffset));
            }
        }

        const uint32_t written = SiteSet::singleton().apply(name, pageOffset, static_cast<const uint8_t*>(data), 0x1000U);
        if (written != 0U && self.takeLogBudget()) {
            DBGLOG("UserPatch", "hook: wrote %u site(s) in '%s' at 0x%llx", static_cast<unsigned>(written), name,
                   static_cast<unsigned long long>(pageOffset));
        }
    }

    auto ValidationHook::nameForVnode(void* const vnode, char* const out, const size_t size) -> bool
    {
        if (vnode == nullptr) { return false; }

        if (this->orgVnodeGetname_ != 0 && this->orgVnodePutname_ != 0) {
            auto getname = reinterpret_cast<tVnodeGetname>(this->orgVnodeGetname_);
            auto putname = reinterpret_cast<tVnodePutname>(this->orgVnodePutname_);
            const char* const name = getname(vnode);
            if (name != nullptr) {
                copyText(out, size, name);
                putname(name);
                return true;
            }
        }

        if (this->orgVnGetpath_ != 0) {
            char       path[256]{};
            int        length = sizeof(path);
            auto       getpath = reinterpret_cast<tVnGetpath>(this->orgVnGetpath_);
            if (getpath(vnode, path, &length) == 0) {
                copyText(out, size, basenameOf(path));
                return true;
            }
        }
        return false;
    }

    auto ValidationHook::beginWrite(void*) -> bool
    {
        return MachInfo::setKernelWriting(true, KernelPatcher::kernelWriteLock) == KERN_SUCCESS;
    }

    void ValidationHook::endWrite(void*) { MachInfo::setKernelWriting(false, KernelPatcher::kernelWriteLock); }

}    // namespace NRedUserPatch
