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
#include <stdint.h>

namespace NRedUserPatch
{

    // Immutable after publish().  The analyzer thread fills a local array and publishes it with a
    // release store; the validation hook reads only after an acquire load of `ready()`.  No
    // allocation, no locks and no file access on the hook path.
    class SiteSet
    {
    public:
        static constexpr uint32_t kMaxSites = 32U;

        static auto singleton() -> SiteSet&;

        void publish(const ResolvedSite* sites, uint32_t count);
        auto ready() const -> bool;
        auto count() const -> uint32_t;
        auto sites() const -> const ResolvedSite*;

    private:
        SiteSet()  = default;
        ~SiteSet() = default;
        SiteSet(const SiteSet&) = delete;
        auto operator=(const SiteSet&) -> SiteSet& = delete;

        ResolvedSite    sites_[kMaxSites]{};
        volatile uint32_t count_{0};
        volatile uint8_t  ready_{0};
    };

}    // namespace NRedUserPatch
