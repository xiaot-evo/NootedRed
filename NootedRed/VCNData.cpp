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
#include <VCNData/24H32.hpp>
#include <VCNData/24H232.hpp>

namespace
{

    const VCNData::Variant* const kVariants[] = {
        &VCNData::Build24H232::kData,
        &VCNData::Build24H32::kData,
    };

    bool buildMatches(const char* const osversion, const char* const build)
    {
        if (osversion == nullptr || osversion[0] == '\0' || build == nullptr || build[0] == '\0') {
            return false;
        }

        size_t i = 0;
        for (; build[i] != '\0'; ++i) {
            if (osversion[i] != build[i]) { return false; }
        }

        return osversion[i] == '\0';
    }

}    // namespace

namespace VCNData
{

    const Variant* findVariant(const char* const osversion, const UInt32 darwinMajor, const UInt32 darwinMinor)
    {
        for (const auto* const variant : kVariants) {
            if (variant->darwinMajor == darwinMajor && variant->darwinMinor == darwinMinor
                && buildMatches(osversion, variant->build))
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
