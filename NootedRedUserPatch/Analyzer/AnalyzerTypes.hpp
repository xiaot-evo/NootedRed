// NootedRedUserPatch runtime analyzer types
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
#include <stddef.h>
#include <stdint.h>

// The analyzer core is freestanding: it includes no Lilu or kernel headers and is compiled both for
// the host fixture test and into the satellite.  All interfaces use fixed-width integers; the
// kernel adapter converts vnode file reads into a ByteSource.
namespace NRedUserPatch
{

    enum class ImageKind : uint8_t {
        kStandalone  = 0,
        kSharedCache = 1,
    };

    enum class AnchorKind : uint8_t {
        kSymbol             = 0,
        kFunctionFingerprint = 1,
        kImageUnique        = 2,
    };

    enum class LocalKind : uint8_t {
        kOffset  = 0,
        kPattern = 1,
    };

    enum class MatchPolicy : uint8_t {
        kUnique = 0,
        kAll    = 1,
        kNth    = 2,
    };

    // Rule flags.  VDA rules are enabled only with -NRedUserPatchVDA; the default set stays at the
    // five GL/Metal sites shipped by the current release.
    static constexpr uint8_t  kRuleFlagVDA = 1U << 0U;
    static constexpr uint32_t kFamilyVCN2  = 0x28U;

    // One shape-specific locator and replacement.  A rule with a single variant is the common case;
    // MTL gate/allow carry two because Apple's code shape changed between 15.8.2 and 26.7.2.
    struct RuleVariant
    {
        LocalKind      localKind;
        uint32_t       localOffset;     // kOffset: function-relative offset
        const uint8_t* localPattern;    // kPattern: masked bytes, wildcard encoded by localMask
        const uint8_t* localMask;       // kPattern: 1 = must match
        uint8_t        localPatternSize;
        uint8_t        patchOffset;     // offset of `find` inside localPattern
        const uint8_t* find;
        const uint8_t* replace;
        uint8_t        patchSize;
    };

    struct Rule
    {
        uint16_t           id;
        ImageKind          imageKind;
        const char*        imagePath;
        uint32_t           familyMask;    // kFamilyVCN2 for the shipped rules
        uint8_t            flags;         // kRuleFlagVDA
        AnchorKind         anchorKind;
        const char*        symbol;        // kSymbol
        const uint8_t*     fingerprint;   // kFunctionFingerprint
        const uint8_t*     fingerprintMask;
        uint8_t            fingerprintSize;
        const RuleVariant* variants;
        uint8_t            variantCount;
        MatchPolicy        policy;
        uint8_t            localNth;
    };

    struct ResolvedSite
    {
        char           vnodeName[64];  // delivered vnode basename (subcache or standalone file)
        uint64_t       fileOffset;     // offset inside the delivered vnode
        const uint8_t* find;
        const uint8_t* replace;
        uint8_t        size;
        uint16_t       ruleId;
    };

}    // namespace NRedUserPatch
