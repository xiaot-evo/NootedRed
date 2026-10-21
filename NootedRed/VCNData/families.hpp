// VCN kernel bridge data for nearby macOS patch releases
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
// These are family-prefix adapters: they reuse a locally generated table for nearby patch releases
// that have not been separately collected.  The bridge still verifies every vtable guard/getter and
// every original call-site byte, so a kernel whose text differs remains untouched.  They are not a
// substitute for a build-specific table on a validated target.

#pragma once
#include <VCNData.hpp>
#include <VCNData/23J631.hpp>
#include <VCNData/24H32.hpp>
#include <VCNData/25G241.hpp>

namespace VCNData::Build23J
{
    inline constexpr char Build[] = "23J";
    inline constexpr char SourceDescription[] =
        "macOS 14.8.x family prefix; reuses the imported 23J631 byte tables, not locally verified";
    inline constexpr char KernelCollectionUUID[] = "";
    inline constexpr char DriverUUID5000[] = "";
    inline constexpr char DriverUUID6000[] = "";
    inline constexpr char DriverVersion5000[] = "";
    inline constexpr char DriverVersion6000[] = "";
    inline constexpr char DriverSHA256_5000[] = "";
    inline constexpr char DriverSHA256_6000[] = "";

    inline constexpr Variant kData = {
        6,
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
}    // namespace VCNData::Build23J

namespace VCNData::Build24H
{
    inline constexpr char Build[] = "24H";
    inline constexpr char SourceDescription[] =
        "macOS 15.8.x family prefix; reuses the locally generated 24H32 byte tables, not separately verified";
    inline constexpr char KernelCollectionUUID[] = "";
    inline constexpr char DriverUUID5000[] = "";
    inline constexpr char DriverUUID6000[] = "";
    inline constexpr char DriverVersion5000[] = "";
    inline constexpr char DriverVersion6000[] = "";
    inline constexpr char DriverSHA256_5000[] = "";
    inline constexpr char DriverSHA256_6000[] = "";

    inline constexpr Variant kData = {
        7,
        Build,
        24,
        6,
        SourceDescription,
        Build24H32::CallPatches,
        Build24H32::kCallPatchCount,
        Build24H32::Guards5000,
        sizeof(Build24H32::Guards5000) / sizeof(Build24H32::Guards5000[0]),
        Build24H32::Guards6000,
        sizeof(Build24H32::Guards6000) / sizeof(Build24H32::Guards6000[0]),
        Build24H32::Table5000,
        Build24H32::Table6000,
        Build24H32::SignalSymbol,
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
}    // namespace VCNData::Build24H

namespace VCNData::Build25G
{
    inline constexpr char Build[] = "25G";
    inline constexpr char SourceDescription[] =
        "macOS 26.7.x family prefix; reuses the imported 25G241 byte tables, not separately verified";
    inline constexpr char KernelCollectionUUID[] = "";
    inline constexpr char DriverUUID5000[] = "";
    inline constexpr char DriverUUID6000[] = "";
    inline constexpr char DriverVersion5000[] = "";
    inline constexpr char DriverVersion6000[] = "";
    inline constexpr char DriverSHA256_5000[] = "";
    inline constexpr char DriverSHA256_6000[] = "";

    inline constexpr Variant kData = {
        8,
        Build,
        25,
        6,
        SourceDescription,
        Build25G241::CallPatches,
        Build25G241::kCallPatchCount,
        Build25G241::Guards5000,
        sizeof(Build25G241::Guards5000) / sizeof(Build25G241::Guards5000[0]),
        Build25G241::Guards6000,
        sizeof(Build25G241::Guards6000) / sizeof(Build25G241::Guards6000[0]),
        Build25G241::Table5000,
        Build25G241::Table6000,
        Build25G241::SignalSymbol,
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
}    // namespace VCNData::Build25G
