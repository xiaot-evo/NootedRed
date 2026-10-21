// VCN kernel bridge data for macOS 14.7.x (Sonoma, Darwin 23.6)
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
//
// The 14.7.x releases use the same X6000 VCN2 bridge shape as 14.8.9.  Reuse the 23J631 tables with a
// build-prefix gate; every guard/getter and original call-site byte is still verified against the live
// kernel before a write, so a genuinely different 14.7.x kernel remains a no-op.
//
// This is an experimental compatibility path: no 14.7.x kernel collection is stored in this repository.

#pragma once
#include <VCNData.hpp>
#include <VCNData/23J631.hpp>

namespace VCNData::Build23H
{
    inline constexpr char Build[] = "23H";
    inline constexpr char SourceDescription[] =
        "macOS 14.7.x (Darwin 23.6); reuses the imported 23J631 byte tables, exact build prefix, not locally verified";
    inline constexpr char KernelCollectionUUID[] = "";
    inline constexpr char DriverUUID5000[] = "";
    inline constexpr char DriverUUID6000[] = "";
    inline constexpr char DriverVersion5000[] = "";
    inline constexpr char DriverVersion6000[] = "";
    inline constexpr char DriverSHA256_5000[] = "";
    inline constexpr char DriverSHA256_6000[] = "";

    inline constexpr Variant kData = {
        4,
        Build,
        23,
        6,
        SourceDescription,
        Build23J631::CallPatches,
        Build23J631::kCallPatchCount,
        Build23J631::Guards5000,
        sizeof(Build23J631::Guards5000) / sizeof(Build23J631::Guards5000[0]),
        Build23J631::Guards6000,
        sizeof(Build23J631::Guards6000) / sizeof(Build23J631::Guards6000[0]),
        Build23J631::Table5000,
        Build23J631::Table6000,
        Build23J631::SignalSymbol,
        true,
        false,
        KernelCollectionUUID,
        DriverUUID5000,
        DriverUUID6000,
        DriverVersion5000,
        DriverVersion6000,
        DriverSHA256_5000,
        DriverSHA256_6000,
    };
}    // namespace VCNData::Build23H

namespace VCNData::Build23G
{
    inline constexpr char Build[] = "23G";
    inline constexpr char SourceDescription[] =
        "macOS 14.7.x (Darwin 23.6); reuses the imported 23J631 byte tables, exact build prefix, not locally verified";
    inline constexpr char KernelCollectionUUID[] = "";
    inline constexpr char DriverUUID5000[] = "";
    inline constexpr char DriverUUID6000[] = "";
    inline constexpr char DriverVersion5000[] = "";
    inline constexpr char DriverVersion6000[] = "";
    inline constexpr char DriverSHA256_5000[] = "";
    inline constexpr char DriverSHA256_6000[] = "";

    inline constexpr Variant kData = {
        5,
        Build,
        23,
        6,
        SourceDescription,
        Build23J631::CallPatches,
        Build23J631::kCallPatchCount,
        Build23J631::Guards5000,
        sizeof(Build23J631::Guards5000) / sizeof(Build23J631::Guards5000[0]),
        Build23J631::Guards6000,
        sizeof(Build23J631::Guards6000) / sizeof(Build23J631::Guards6000[0]),
        Build23J631::Table5000,
        Build23J631::Table6000,
        Build23J631::SignalSymbol,
        true,
        false,
        KernelCollectionUUID,
        DriverUUID5000,
        DriverUUID6000,
        DriverVersion5000,
        DriverVersion6000,
        DriverSHA256_5000,
        DriverSHA256_6000,
    };
}    // namespace VCNData::Build23G
