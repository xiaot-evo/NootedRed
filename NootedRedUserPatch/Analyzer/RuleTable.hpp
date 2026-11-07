// NootedRedUserPatch compiled rule table
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

    // 19 shipped rules: 5 default (GL/Metal) + 14 VDA (VADriver2).  The table is generated from the
    // clean 15.8.2 fixture and validated against 26.7.2 by the host test; it is not a per-build
    // profile.  Each rule carries at least one function-local masked pattern; the two MTL sites
    // carry a second shape variant for the 26.7.2 control-flow/register-allocation change.
    extern const Rule     kRules[];
    extern const uint32_t kRuleCount;

}    // namespace NRedUserPatch
