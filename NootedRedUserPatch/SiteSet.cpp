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

#include <SiteSet.hpp>

#include <string.h>

namespace NRedUserPatch
{

    auto SiteSet::singleton() -> SiteSet&
    {
        static SiteSet instance;
        return instance;
    }

    void SiteSet::publish(const ResolvedSite* const sites, const uint32_t count)
    {
        const uint32_t bounded = count < kMaxSites ? count : kMaxSites;
        if (sites != nullptr && bounded != 0U) { memcpy(this->sites_, sites, bounded * sizeof(ResolvedSite)); }
        __atomic_store_n(&this->count_, bounded, __ATOMIC_RELEASE);
        __atomic_store_n(&this->ready_, 1U, __ATOMIC_RELEASE);
    }

    auto SiteSet::ready() const -> bool
    {
        return __atomic_load_n(&this->ready_, __ATOMIC_ACQUIRE) != 0U;
    }

    auto SiteSet::count() const -> uint32_t
    {
        return __atomic_load_n(&this->count_, __ATOMIC_ACQUIRE);
    }

    auto SiteSet::sites() const -> const ResolvedSite*
    {
        return this->sites_;
    }

}    // namespace NRedUserPatch
