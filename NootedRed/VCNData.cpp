// VCN kernel bridge data selection
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

#include <VCNData.hpp>
#include <VCNData/14_7.hpp>
#include <VCNData/23J631.hpp>
#include <VCNData/24H32.hpp>
#include <VCNData/25G241.hpp>
#include <VCNData/families.hpp>

namespace
{

    const VCNData::Variant* const kVariants[] = {
        &VCNData::Build23J631::kData,
        &VCNData::Build23J::kData,
        &VCNData::Build23H::kData,
        &VCNData::Build23G::kData,
        &VCNData::Build24H32::kData,
        &VCNData::Build24H::kData,
        &VCNData::Build25G241::kData,
        &VCNData::Build25G::kData,
    };

    bool buildMatches(const char* const osversion, const char* const build, const bool prefix)
    {
        if (osversion == nullptr || osversion[0] == '\0' || build == nullptr || build[0] == '\0') {
            return false;
        }

        size_t i = 0;
        for (; build[i] != '\0'; ++i) {
            if (osversion[i] != build[i]) { return false; }
        }

        // Prefix variants are only used for explicitly declared patch-release families; everything else
        // is an exact build token and rejects trailing characters.
        return prefix || osversion[i] == '\0';
    }

}    // namespace

namespace VCNData
{

    const Variant* findVariant(const char* const osversion, const UInt32 darwinMajor, const UInt32 darwinMinor)
    {
        for (const auto* const variant : kVariants) {
            if (variant->darwinMajor == darwinMajor && variant->darwinMinor == darwinMinor
                && buildMatches(osversion, variant->build, variant->buildPrefix))
            {
                return variant;
            }
        }

        return nullptr;
    }

    const Variant* variantForDarwin(const UInt32 darwinMajor, const UInt32 darwinMinor)
    {
        for (const auto* const variant : kVariants) {
            if (variant->darwinMajor == darwinMajor && variant->darwinMinor == darwinMinor) { return variant; }
        }

        return nullptr;
    }

    bool hasVariantForDarwin(const UInt32 darwinMajor, const UInt32 darwinMinor)
    {
        return variantForDarwin(darwinMajor, darwinMinor) != nullptr;
    }

}    // namespace VCNData
