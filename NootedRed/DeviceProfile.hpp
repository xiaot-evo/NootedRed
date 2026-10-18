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
// Media is intentionally a placeholder for future VCN/UVD/VDA support: the fields default to disabled,
// so adding a media engine later does not require a second device-selection path.
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

    struct MediaPolicy
    {
        // Current NootedRed behaviour: all media engines are disabled.  These fields are the future
        // VCN/UVD/VDA capability surface; keep them false until the engine init is implemented.
        bool      hasUVD0{false};
        bool      hasVCE{false};
        bool      hasVCN0{false};
        UInt8     vcnGeneration{0};
        const char* vcnFirmware{nullptr};
        UInt32    vcnRingSize{0};
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
