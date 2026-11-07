// NootedRedUserPatch analyzer runtime
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

#include <AnalyzerRuntime.hpp>

#include <Analyzer/RuleTable.hpp>
#include <Headers/kern_devinfo.hpp>
#include <Headers/kern_util.hpp>
#include <SiteSet.hpp>

#include <kern/clock.h>
#include <libkern/libkern.h>
#include <string.h>

namespace
{

    constexpr char kLiveCacheDir[]   = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/";
    constexpr char kSystemCacheDir[] = "/System/Library/dyld/";
    constexpr char kMainCacheName[]  = "dyld_shared_cache_x86_64h";

    // Releases the Lilu DeviceInfo list on every return path.  Lilu's deleter is a deliberate no-op
    // for the global cached instance it owns, so this only frees a list this call created.
    struct DeviceInfoGuard
    {
        DeviceInfo* info{nullptr};

        ~DeviceInfoGuard()
        {
            if (this->info != nullptr) { DeviceInfo::deleter(this->info); }
        }
    };

}    // namespace

namespace NRedUserPatch
{

    auto AnalyzerRuntime::singleton() -> AnalyzerRuntime&
    {
        static AnalyzerRuntime instance;
        return instance;
    }

    void AnalyzerRuntime::start(KernelPatcher& patcher)
    {
        (void) patcher;
        if (__atomic_load_n(&this->started_, __ATOMIC_ACQUIRE) != 0U) { return; }
        __atomic_store_n(&this->started_, 1U, __ATOMIC_RELEASE);

        this->vdaEnabled_ = checkKernelArgument("-NRedUserPatchVDA");
        this->detectFamily();

        this->call_ = thread_call_allocate_with_options(callback, nullptr, THREAD_CALL_PRIORITY_KERNEL,
                                                        THREAD_CALL_OPTIONS_ONCE);
        if (this->call_ == nullptr) {
            SYSLOG("UserPatch", "analyzer: thread call unavailable");
            return;
        }
        thread_call_enter(this->call_);
    }

    void AnalyzerRuntime::stop()
    {
        if (this->call_ != nullptr) {
            thread_call_cancel(this->call_);
            thread_call_free(this->call_);
            this->call_ = nullptr;
        }
        for (uint32_t index = 0; index < this->fileCount_; index++) { this->files_[index].close(); }
        this->fileCount_ = 0;
    }

    auto AnalyzerRuntime::ready() const -> bool { return SiteSet::singleton().ready(); }

    void AnalyzerRuntime::detectFamily()
    {
        const DeviceInfoGuard guard{DeviceInfo::create()};
        auto* const           info = guard.info;
        if (info == nullptr || info->videoBuiltin == nullptr) {
            SYSLOG("UserPatch", "analyzer: no AMD iGPU detected; all rules gated");
            this->runningFamily_ = 0;
            return;
        }

        UInt32 deviceID = 0;
        if (!WIOKit::getOSDataValue(info->videoBuiltin, "device-id", deviceID)) {
            SYSLOG("UserPatch", "analyzer: iGPU device-id unavailable; all rules gated");
            this->runningFamily_ = 0;
            return;
        }

        this->runningFamily_ = familyForDeviceID(static_cast<uint16_t>(deviceID & 0xFFFFU));
        SYSLOG("UserPatch", "analyzer: iGPU 0x%04X family 0x%X", static_cast<unsigned>(deviceID & 0xFFFFU),
               static_cast<unsigned>(this->runningFamily_));
    }

    auto AnalyzerRuntime::familyForDeviceID(const uint16_t deviceID) -> uint32_t
    {
        switch (deviceID) {
            case 0x15DD:    // Raven
                return 1U << 0;
            case 0x15D8:    // Raven2 / Picasso
                return (1U << 1) | (1U << 2);
            case 0x1636:    // Renoir / Cezanne
            case 0x164C:
                return (1U << 3) | (1U << 4);
            case 0x15E7:    // Barcelo / Green Sardine
            case 0x1638:
                return (1U << 3) | (1U << 5);
            default:
                return 0;
        }
    }

    auto AnalyzerRuntime::findOrOpen(const char* const path) -> KernelFile*
    {
        if (path == nullptr) { return nullptr; }
        for (uint32_t index = 0; index < this->fileCount_; index++) {
            if (strcmp(this->files_[index].path(), path) == 0) { return &this->files_[index]; }
        }
        if (this->fileCount_ >= kMaxFiles) { return nullptr; }
        KernelFile& file = this->files_[this->fileCount_];
        if (!file.open(path)) { return nullptr; }
        this->fileCount_ += 1U;
        return &file;
    }

    auto AnalyzerRuntime::openCacheThunk(void* const context, const char* const name, ByteSource& out) -> bool
    {
        auto* const self = static_cast<AnalyzerRuntime*>(context);
        char        path[512]{};
        snprintf(path, sizeof(path), "%s%s", kLiveCacheDir, name);
        KernelFile* file = self->findOrOpen(path);
        if (file == nullptr) {
            snprintf(path, sizeof(path), "%s%s", kSystemCacheDir, name);
            file = self->findOrOpen(path);
        }
        if (file == nullptr) { return false; }
        out = file->source();
        return true;
    }

    auto AnalyzerRuntime::openImageThunk(void* const context, const char* const imagePath, ByteSource& out) -> bool
    {
        auto* const self = static_cast<AnalyzerRuntime*>(context);
        KernelFile* file = self->findOrOpen(imagePath);
        if (file == nullptr) { return false; }
        out = file->source();
        return true;
    }

    void AnalyzerRuntime::scheduleRetry()
    {
        if (this->call_ == nullptr) { return; }
        UInt64 deadline = 0;
        clock_interval_to_deadline(kRetryDelayMs, static_cast<uint32_t>(NSEC_PER_MSEC), &deadline);
        if (thread_call_enter_delayed(this->call_, deadline)) {
            SYSLOG("UserPatch", "analyzer: retry call was unexpectedly pending");
        }
    }

    void AnalyzerRuntime::callback(thread_call_param_t, thread_call_param_t) { singleton().process(); }

    void AnalyzerRuntime::process()
    {
        char path[512]{};
        snprintf(path, sizeof(path), "%s%s", kLiveCacheDir, kMainCacheName);
        KernelFile* mainFile = this->findOrOpen(path);
        if (mainFile == nullptr) {
            snprintf(path, sizeof(path), "%s%s", kSystemCacheDir, kMainCacheName);
            mainFile = this->findOrOpen(path);
        }
        if (mainFile == nullptr) {
            if (this->retries_ < kMaxRetries) {
                this->retries_ += 1U;
                SYSLOG("UserPatch", "analyzer: dyld cache not ready, retry %u/%u",
                       static_cast<unsigned>(this->retries_), static_cast<unsigned>(kMaxRetries));
                this->scheduleRetry();
            }
            else {
                SYSLOG("UserPatch", "analyzer: dyld cache unavailable; no sites resolved");
            }
            return;
        }

        ByteSource mainSource = mainFile->source();
        ResolveContext context{};
        context.mainCache     = &mainSource;
        context.openCache     = &AnalyzerRuntime::openCacheThunk;
        context.openImage     = &AnalyzerRuntime::openImageThunk;
        context.openContext   = this;
        context.runningFamily = this->runningFamily_;
        context.vdaEnabled    = this->vdaEnabled_;

        ResolvedSite* const sites = this->pending_;
        uint32_t            count = 0;
        uint32_t            enabled = 0;
        for (uint32_t index = 0; index < kRuleCount; index++) {
            const Rule& rule = kRules[index];
            if (!ruleEnabled(rule, context.runningFamily, context.vdaEnabled)) { continue; }
            enabled += 1U;

            ResolvedSite site{};
            const char*  reason = nullptr;
            if (!resolveRule(context, rule, site, &reason)) {
                SYSLOG("UserPatch", "analyzer: rule %u unresolved: %s", static_cast<unsigned>(rule.id),
                       reason != nullptr ? reason : "unknown");
                continue;
            }
            if (count < SiteSet::kMaxSites) {
                sites[count++] = site;
            }
            else {
                SYSLOG("UserPatch", "analyzer: site set full");
                break;
            }
        }

        SiteSet::singleton().publish(sites, count);
        SYSLOG("UserPatch", "analyzer: %u/%u rules resolved (family 0x%X, VDA %u)",
               static_cast<unsigned>(count), static_cast<unsigned>(enabled),
               static_cast<unsigned>(context.runningFamily), context.vdaEnabled ? 1U : 0U);

        for (uint32_t index = 0; index < this->fileCount_; index++) { this->files_[index].close(); }
        this->fileCount_ = 0;
    }

}    // namespace NRedUserPatch
