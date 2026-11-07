// NootedRedUserPatch rule resolver
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
#include <Analyzer/ByteSource.hpp>
#include <Analyzer/CacheLocator.hpp>
#include <stdint.h>

namespace NRedUserPatch
{

    using OpenImageFn = bool (*)(void* context, const char* imagePath, ByteSource& out);

    struct ResolveContext
    {
        const ByteSource* mainCache{nullptr};  // required for shared-cache rules
        OpenCacheFn       openCache{nullptr};  // opens dyld subcache files
        OpenImageFn       openImage{nullptr};  // opens a standalone image
        void*             openContext{nullptr};
        uint32_t          runningFamily{0};    // kFamilyVCN2 for the shipped rules
        bool              vdaEnabled{false};
    };

    // True when the rule's family and VDA gates allow it on this boot.
    auto ruleEnabled(const Rule& rule, uint32_t runningFamily, bool vdaEnabled) -> bool;

    // Resolves one rule into an absolute site inside the delivered vnode.  Returns false on a gate,
    // a missing/ambiguous symbol, no policy-valid local match, or a find mismatch.  `reason` points
    // to a static string suitable for a bounded log.
    auto resolveRule(const ResolveContext& context, const Rule& rule, ResolvedSite& out, const char** reason) -> bool;

}    // namespace NRedUserPatch
