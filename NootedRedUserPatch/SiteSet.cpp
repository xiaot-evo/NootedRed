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

#include <PatchPolicy.hpp>
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

    auto SiteSet::sites() const -> const ResolvedSite* { return this->sites_; }

    void SiteSet::setWriter(const WriteBeginFn begin, const WriteEndFn end, void* const context)
    {
        this->begin_         = begin;
        this->end_           = end;
        this->writerContext_ = context;
    }

    void SiteSet::setDryRun(const bool dryRun) { __atomic_store_n(&this->dryRun_, dryRun ? 1U : 0U, __ATOMIC_RELEASE); }

    auto SiteSet::dryRun() const -> bool { return __atomic_load_n(&this->dryRun_, __ATOMIC_ACQUIRE) != 0U; }

    auto SiteSet::apply(const char* const vnodeName, const uint64_t chunkOffset, const uint8_t* const data,
                        const size_t size) -> uint32_t
    {
        if (!this->ready() || vnodeName == nullptr || data == nullptr) { return 0U; }
        const uint32_t siteCount = this->count();
        if (siteCount == 0U) { return 0U; }

        uint32_t clean = 0;
        for (uint32_t index = 0; index < siteCount; index++) {
            const ResolvedSite& site = this->sites_[index];
            if (strcmp(site.vnodeName, vnodeName) != 0) { continue; }
            if (!PatchPolicy::siteFitsChunk(site.fileOffset, site.size, chunkOffset, size)) { continue; }

            const uint8_t* const at = data + (site.fileOffset - chunkOffset);
            if (memcmp(at, site.replace, site.size) == 0) {
                __atomic_fetch_add(&this->already_, 1U, __ATOMIC_RELAXED);
                continue;
            }
            if (memcmp(at, site.find, site.size) != 0) {
                __atomic_fetch_add(&this->foreign_, 1U, __ATOMIC_RELAXED);
                continue;
            }
            clean += 1U;
        }

        if (clean == 0U) { return 0U; }
        if (this->dryRun()) {
            __atomic_fetch_add(&this->planned_, clean, __ATOMIC_RELAXED);
            return 0U;
        }

        if (this->begin_ == nullptr || this->end_ == nullptr || !this->begin_(this->writerContext_)) {
            __atomic_fetch_add(&this->writeFailures_, 1U, __ATOMIC_RELAXED);
            return 0U;
        }

        uint32_t written = 0;
        for (uint32_t index = 0; index < siteCount; index++) {
            const ResolvedSite& site = this->sites_[index];
            if (strcmp(site.vnodeName, vnodeName) != 0) { continue; }
            if (!PatchPolicy::siteFitsChunk(site.fileOffset, site.size, chunkOffset, size)) { continue; }

            auto* const at = const_cast<uint8_t*>(data) + (site.fileOffset - chunkOffset);
            if (memcmp(at, site.replace, site.size) == 0) { continue; }
            if (memcmp(at, site.find, site.size) != 0) { continue; }
            memcpy(at, site.replace, site.size);
            written += 1U;
        }
        this->end_(this->writerContext_);

        for (uint32_t index = 0; index < siteCount; index++) {
            const ResolvedSite& site = this->sites_[index];
            if (strcmp(site.vnodeName, vnodeName) != 0) { continue; }
            if (!PatchPolicy::siteFitsChunk(site.fileOffset, site.size, chunkOffset, size)) { continue; }
            const uint8_t* const at = data + (site.fileOffset - chunkOffset);
            if (memcmp(at, site.replace, site.size) != 0) {
                __atomic_fetch_add(&this->verifyFailures_, 1U, __ATOMIC_RELAXED);
            }
        }

        __atomic_fetch_add(&this->applied_, written, __ATOMIC_RELAXED);
        return written;
    }

    auto SiteSet::applied() const -> uint32_t { return __atomic_load_n(&this->applied_, __ATOMIC_RELAXED); }

    auto SiteSet::alreadyPatched() const -> uint32_t { return __atomic_load_n(&this->already_, __ATOMIC_RELAXED); }

    auto SiteSet::foreign() const -> uint32_t { return __atomic_load_n(&this->foreign_, __ATOMIC_RELAXED); }

    auto SiteSet::writeFailures() const -> uint32_t
    {
        return __atomic_load_n(&this->writeFailures_, __ATOMIC_RELAXED);
    }

    auto SiteSet::verifyFailures() const -> uint32_t
    {
        return __atomic_load_n(&this->verifyFailures_, __ATOMIC_RELAXED);
    }

    auto SiteSet::planned() const -> uint32_t { return __atomic_load_n(&this->planned_, __ATOMIC_RELAXED); }

}    // namespace NRedUserPatch
