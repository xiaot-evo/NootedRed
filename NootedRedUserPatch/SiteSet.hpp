// NootedRedUserPatch resolved site set
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
#include <Analyzer/AnalyzerTypes.hpp>
#include <stddef.h>
#include <stdint.h>

namespace NRedUserPatch
{

    // Immutable after publish().  The analyzer thread fills a local array and publishes it with a
    // release store; the validation hook reads only after an acquire load of `ready()`.  The apply
    // path is freestanding (no Lilu/kernel headers) so the host test exercises the real code; the
    // kernel write lock is injected through the writer callbacks.
    class SiteSet
    {
    public:
        static constexpr uint32_t kMaxSites = 32U;

        using WriteBeginFn = bool (*)(void* context);
        using WriteEndFn   = void (*)(void* context);

        static auto singleton() -> SiteSet&;

        void publish(const ResolvedSite* sites, uint32_t count);
        auto ready() const -> bool;
        auto count() const -> uint32_t;
        auto sites() const -> const ResolvedSite*;

        // Called by the kernel hook once at install time.  Without a writer, apply fails closed.
        void setWriter(WriteBeginFn begin, WriteEndFn end, void* context);
        void setDryRun(bool dryRun);
        auto dryRun() const -> bool;

        // Hook path.  `chunkOffset`/`data`/`size` are the validated chunk delivered by the kernel;
        // `vnodeName` is the delivered vnode basename.  Returns the number of sites written.
        auto apply(const char* vnodeName, uint64_t chunkOffset, const uint8_t* data, size_t size) -> uint32_t;

        auto applied() const -> uint32_t;
        auto alreadyPatched() const -> uint32_t;
        auto foreign() const -> uint32_t;
        auto writeFailures() const -> uint32_t;
        auto verifyFailures() const -> uint32_t;
        auto planned() const -> uint32_t;

    private:
        SiteSet()  = default;
        ~SiteSet() = default;
        SiteSet(const SiteSet&) = delete;
        auto operator=(const SiteSet&) -> SiteSet& = delete;

        ResolvedSite      sites_[kMaxSites]{};
        volatile uint32_t count_{0};
        volatile uint8_t  ready_{0};

        WriteBeginFn begin_{nullptr};
        WriteEndFn   end_{nullptr};
        void*        writerContext_{nullptr};
        volatile uint8_t dryRun_{0};

        volatile uint32_t applied_{0};
        volatile uint32_t already_{0};
        volatile uint32_t foreign_{0};
        volatile uint32_t writeFailures_{0};
        volatile uint32_t verifyFailures_{0};
        volatile uint32_t planned_{0};
    };

}    // namespace NRedUserPatch
