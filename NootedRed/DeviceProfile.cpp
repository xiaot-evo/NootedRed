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

#include <DeviceProfile.hpp>
#include <NRed.hpp>

namespace
{

    constexpr auto kProfileMinVersion = MACOS_10_4_X;
    constexpr auto kProfileMaxVersion = MACOS_26_X;

    // Graphics-only profiles for the APUs NootedRed supports today.  Media stays disabled until the
    // VCN/UVD engine bring-up is implemented; the fields are already in the profile so that work can be
    // added without introducing a second device table.
    constexpr DeviceProfile::Profile kProfiles[] = {
        {"Renoir", 0x1636, DeviceProfile::kRenoir, kProfileMinVersion, kProfileMaxVersion, {}, {}},
        {"Renoir/Green Sardine", 0x1638, DeviceProfile::kGreenSardine, kProfileMinVersion, kProfileMaxVersion, {}, {}},
        {"Cezanne", 0x164C, DeviceProfile::kRenoir, kProfileMinVersion, kProfileMaxVersion, {}, {}},
        {"Barcelo", 0x15E7, DeviceProfile::kGreenSardine, kProfileMinVersion, kProfileMaxVersion, {}, {}},
        {"Raven", 0x15DD, DeviceProfile::kRaven, kProfileMinVersion, kProfileMaxVersion, {}, {}},
        {"Raven2/Picasso", 0x15D8, DeviceProfile::kPicasso, kProfileMinVersion, kProfileMaxVersion, {}, {}},
    };

    constexpr const DeviceProfile::Profile kFallbackProfile = {
        "unknown/fallback", 0, DeviceProfile::kUnknown, kProfileMinVersion, kProfileMaxVersion, {}, {}};

    static_assert(sizeof(kProfiles) / sizeof(kProfiles[0]) == 6, "Update the profile tests when adding a device");
    static_assert(kProfiles[0].graphics.conditionalDualQuad, "Current profiles must keep the rendering fix enabled");
    static_assert(!kProfiles[0].media.hasUVD0, "Media remains disabled until VCN/UVD bring-up exists");
    static_assert(!kProfiles[0].media.hasVCE, "Media remains disabled until VCN/UVD bring-up exists");
    static_assert(!kProfiles[0].media.hasVCN0, "Media remains disabled until VCN/UVD bring-up exists");

}    // namespace

const DeviceProfile::Profile* DeviceProfile::current()
{
    const auto deviceID = NRed::singleton().getDeviceID();
    if (deviceID == 0) { return &kFallbackProfile; }

    const auto* const profile = forDevice(deviceID);
    return profile != nullptr ? profile : &kFallbackProfile;
}

const DeviceProfile::Profile* DeviceProfile::forDevice(const UInt16 deviceID)
{
    for (const auto& profile : kProfiles) {
        if (profile.deviceID == deviceID) { return &profile; }
    }

    return nullptr;
}

const char* DeviceProfile::familyName(const ApuFamily family)
{
    switch (family) {
        case kRaven: return "Raven";
        case kRaven2: return "Raven2";
        case kPicasso: return "Picasso";
        case kRenoir: return "Renoir";
        case kRenoirE: return "RenoirE";
        case kGreenSardine: return "Green Sardine";
        case kUnknown: return "unknown";
    }

    return "unknown";
}
