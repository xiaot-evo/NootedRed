// Unified Device and Media Capability Profiles
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
#include <PenguinWizardry/KernelVersion.hpp>
#include <libkern/OSTypes.h>

// A single source of truth for per-device graphics and media capabilities.
//
// Graphics uses this profile to decide whether the Chromium dual-quad policy should be installed.
// Media describes the VCN/UVD/VDA capabilities of the device (generation, firmware, ring sizes, decode
// formats).  The engine enablement flags stay false until the bring-up exists, so populating the media
// data does not change the current behaviour or require a second device-selection path.
class DeviceProfile
{
public:
    enum ApuFamily : UInt8 {
        kUnknown = 0,
        kRaven,
        kRaven2,
        kPicasso,
        kRenoir,
        kRenoirE,
        kGreenSardine,
    };

    struct GraphicsPolicy
    {
        // Install the conditional dual-quad fix (normal pipelines keep RB+, dual-source disables it).
        bool conditionalDualQuad{true};

        // Whether the existing HwInfo/CU corrections for this family should be applied.
        bool correctHwInfo{true};
    };

    // VCN IP generation, encoded as major << 8 | minor so it can double as the `ipVersion` handed to the
    // firmware loader.  Raven/Picasso/Raven2 are VCN 1.0-class, Renoir/Cezanne/Barcelo are VCN 2.2.
    enum VcnGeneration : UInt32 {
        kVcnNone = 0,
        kVcn1_0 = 0x0100,
        kVcn2_2 = 0x0202,
    };

    // Formats the VCN generation can decode.  Hardware capabilities, not enablement.
    struct DecodeCaps
    {
        bool h264{false};
        bool hevc{false};
        bool av1{false};
    };

    struct MediaPolicy
    {
        // Current NootedRed behaviour: all media engines are disabled.  These fields are the future
        // VCN/UVD/VDA capability surface; keep them false until the engine init is implemented.
        bool hasUVD0{false};
        bool hasVCE{false};
        bool hasVCN0{false};

        // VCN generation of this device.  kVcnNone means the media policy has no VCN data (fallback).
        VcnGeneration vcnGeneration{kVcnNone};

        // Name of the VCN firmware blob embedded by `HWLibs.cpp` (`Firmware/`), or nullptr.  The actual
        // firmware load/PSP bring-up is a later phase; this only records which blob belongs to the device.
        const char* vcnFirmware{nullptr};

        // Ring and fence allocation sizes for the future VCN submission path, in bytes.
        UInt32 vcnRingSize{0};
        UInt32 vcnFenceSize{0};

        // Decode formats available on this VCN generation.
        DecodeCaps decode{};
    };

    struct Profile
    {
        const char*                     name;
        UInt16                          deviceID;
        ApuFamily                       family;
        PenguinWizardry::KernelVersion  minVersion;
        PenguinWizardry::KernelVersion  maxVersion;
        GraphicsPolicy                  graphics;
        MediaPolicy                     media;
    };

    // Returns the profile for the running device, or the generic fallback when the device is not known
    // yet.  The fallback keeps the current graphics policy and disables all media engines.
    static const Profile* current();

    // Returns nullptr for an unsupported device ID.
    static const Profile* forDevice(UInt16 deviceID);

    static const char* familyName(ApuFamily family);
};
