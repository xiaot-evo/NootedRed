// VCN kernel bridge data types and build selection
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
#include <IOKit/IOTypes.h>

// Per-build VCN kernel bridge data.
//
// Each supported macOS build has its own self-contained header under VCNData/.  A header contains the
// exact X6000 call sites, X5000/X6000 vtable guards, and source identity for that build.  There is no
// generic fallback: a build either has a complete data set or the bridge stays disabled.
namespace VCNData
{
    struct CallPatch
    {
        const char* symbol;
        UInt32      offset;
        UInt8       original[6];
        UInt32      newSlot;
    };

    static_assert(sizeof(CallPatch::original) == 6, "CallPatch original must be the six-byte callq form");

    struct SlotGuard
    {
        UInt32      slot;
        const char* methodSymbol;
        const UInt8* getter;
        UInt32      getterSize;
    };

    // Upper bound for the bridge's fixed address array.  Every variant asserts its own count against it.
    inline constexpr UInt32 kMaxCallPatches = 20;

    struct Variant
    {
        // Stable numeric identifier for diagnostics (1 = 23J631, 2 = 24H32, 3 = 25G241,
        // 4 = 23H prefix, 5 = 23G prefix, 6 = 23J prefix, 7 = 24H prefix, 8 = 25G prefix).
        UInt32 id;
        const char* build;
        UInt32      darwinMajor;
        UInt32      darwinMinor;
        const char* sourceDescription;

        const CallPatch* callPatches;
        UInt32           callPatchCount;

        const SlotGuard* guards5000;
        UInt32           guard5000Count;
        const SlotGuard* guards6000;
        UInt32           guard6000Count;

        const char* table5000;
        const char* table6000;
        const char* signalSymbol;

        // Exact build strings are the default.  Prefix variants reuse an existing byte table for a
        // nearby patch release (e.g. 14.7.x "23H"/"23G" reusing the 14.8.9 tables) and still verify every
        // guard and call-site byte before writing.
        bool buildPrefix;

        // Identity is only available when the data was generated from a locally verified kernel
        // collection.  Imported or reconstructed data deliberately carries empty strings.
        bool        hasKernelIdentity;
        const char* kernelCollectionUUID;
        const char* driverUUID5000;
        const char* driverUUID6000;
        const char* driverVersion5000;
        const char* driverVersion6000;
        const char* driverSHA256_5000;
        const char* driverSHA256_6000;
    };

    // Exact build lookup.  osversion must be populated and match the variant's build string exactly.
    const Variant* findVariant(const char* osversion, UInt32 darwinMajor, UInt32 darwinMinor);

    // Darwin-only lookup for the early X5000 verification path, before osversion may be populated.
    // Callers must still use findVariant() before writing any X6000 patch.
    const Variant* variantForDarwin(UInt32 darwinMajor, UInt32 darwinMinor);

    // True when at least one data variant exists for the Darwin version.
    bool hasVariantForDarwin(UInt32 darwinMajor, UInt32 darwinMinor);
}    // namespace VCNData
