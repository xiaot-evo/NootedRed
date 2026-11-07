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

#pragma once
#include <Analyzer/ByteSource.hpp>
#include <Analyzer/RuleResolver.hpp>
#include <Headers/kern_patcher.hpp>
#include <KernelFileSource.hpp>
#include <SiteSet.hpp>
#include <kern/thread_call.h>
#include <stdint.h>

namespace NRedUserPatch
{

    // One-shot boot analyzer.  Opens the live dyld cache and the target images through VFS, resolves
    // the compiled rule table against the running build and publishes the immutable SiteSet.  Runs
    // in a sleepable, pre-allocated thread call; the validation hook never calls into this class.
    class AnalyzerRuntime
    {
    public:
        static auto singleton() -> AnalyzerRuntime&;

        void start(KernelPatcher& patcher);
        void stop();
        auto ready() const -> bool;

    private:
        static constexpr uint32_t kMaxFiles       = 10U;
        static constexpr uint32_t kMaxRetries     = 10U;
        static constexpr uint32_t kRetryDelayMs   = 500U;

        AnalyzerRuntime()  = default;
        ~AnalyzerRuntime() = default;
        AnalyzerRuntime(const AnalyzerRuntime&) = delete;
        auto operator=(const AnalyzerRuntime&) -> AnalyzerRuntime& = delete;

        static void callback(thread_call_param_t param0, thread_call_param_t param1);
        void process();
        void detectFamily();
        void scheduleRetry();

        static auto openCacheThunk(void* context, const char* name, ByteSource& out) -> bool;
        static auto openImageThunk(void* context, const char* imagePath, ByteSource& out) -> bool;
        auto findOrOpen(const char* path) -> KernelFile*;
        static auto familyForDeviceID(uint16_t deviceID) -> uint32_t;

        thread_call_t call_{nullptr};
        KernelFile    files_[kMaxFiles]{};
        ResolvedSite  pending_[SiteSet::kMaxSites]{};
        uint32_t      fileCount_{0};
        uint32_t      runningFamily_{0};
        bool          vdaEnabled_{false};
        uint32_t      retries_{0};
        volatile uint8_t started_{0};
    };

}    // namespace NRedUserPatch
