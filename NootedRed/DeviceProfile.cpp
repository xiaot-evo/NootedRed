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

    // Phase 2 records the VCN capability data for each APU family.  The engine enablement flag is only set
    // on the already-validated profile: 0x1638.  Everything else stays disabled until its own hardware
    // validation (Phase 3/5).
    //
    // The ring/fence sizes are the allocation sizes the future VCN submission path will request.  They are
    // carried in the profile now so Phase 3 has a single source of truth; nothing uses them yet.
    constexpr auto makeVcnMedia(const DeviceProfile::VcnGeneration generation, const char* const firmware,
                                const bool enableVcn0 = false) -> DeviceProfile::MediaPolicy
    {
        DeviceProfile::MediaPolicy media{};
        media.hasVCN0        = enableVcn0;
        media.vcnGeneration = generation;
        media.vcnFirmware   = firmware;
        media.vcnRingSize   = 0x10000;    // 64 KiB, planning default until Phase 3 validates the real size
        media.vcnFenceSize  = 0x1000;     // 4 KiB, planning default until Phase 3 validates the real size
        media.decode.h264   = true;
        media.decode.hevc   = true;
        media.decode.av1    = false;    // AV1 decode starts with VCN 4.0.
        return media;
    }

    // HWLibs embeds `Firmware/ativvaxy_rv.dat` for VCN 1.0 and `Firmware/ativvaxy_nv.dat` for VCN 2.2.
    constexpr auto kVcn1Media     = makeVcnMedia(DeviceProfile::kVcn1_0, "ativvaxy_rv.dat");
    constexpr auto kVcn2Media     = makeVcnMedia(DeviceProfile::kVcn2_2, "ativvaxy_nv.dat");
    constexpr auto kVcn2MediaVcn0 = makeVcnMedia(DeviceProfile::kVcn2_2, "ativvaxy_nv.dat", true);

    // Graphics profiles for the APUs NootedRed supports today.  Only Renoir/Green Sardine 0x1638 (the
    // hardware-validated VDA target) advertises VCN0; the other VCN 2.2 APUs keep it off until validated.
    constexpr DeviceProfile::Profile kProfiles[] = {
        {"Renoir", 0x1636, DeviceProfile::kRenoir, kProfileMinVersion, kProfileMaxVersion, {}, kVcn2Media},
        {"Renoir/Green Sardine", 0x1638, DeviceProfile::kGreenSardine, kProfileMinVersion, kProfileMaxVersion, {},
         kVcn2MediaVcn0},
        {"Cezanne", 0x164C, DeviceProfile::kRenoir, kProfileMinVersion, kProfileMaxVersion, {}, kVcn2Media},
        {"Barcelo", 0x15E7, DeviceProfile::kGreenSardine, kProfileMinVersion, kProfileMaxVersion, {}, kVcn2Media},
        {"Raven", 0x15DD, DeviceProfile::kRaven, kProfileMinVersion, kProfileMaxVersion, {}, kVcn1Media},
        {"Raven2/Picasso", 0x15D8, DeviceProfile::kPicasso, kProfileMinVersion, kProfileMaxVersion, {}, kVcn1Media},
    };

    constexpr const DeviceProfile::Profile kFallbackProfile = {
        "unknown/fallback", 0, DeviceProfile::kUnknown, kProfileMinVersion, kProfileMaxVersion, {}, {}};

    constexpr auto mediaDisabled(const DeviceProfile::MediaPolicy& media) -> bool
    {
        return !media.hasUVD0 && !media.hasVCE && !media.hasVCN0;
    }

    template<size_t N>
    constexpr auto onlyValidatedProfileEnabled(const DeviceProfile::Profile (&profiles)[N]) -> bool
    {
        for (const auto& profile : profiles) {
            const auto enabled = !mediaDisabled(profile.media);
            if (enabled != (profile.deviceID == 0x1638)) { return false; }
        }

        return true;
    }

    template<size_t N>
    constexpr auto allVcnDataPresent(const DeviceProfile::Profile (&profiles)[N]) -> bool
    {
        for (const auto& profile : profiles) {
            const auto& media = profile.media;
            if (media.vcnGeneration == DeviceProfile::kVcnNone || media.vcnFirmware == nullptr
                || media.vcnRingSize == 0 || media.vcnFenceSize == 0 || !media.decode.h264 || !media.decode.hevc
                || media.decode.av1)
            {
                return false;
            }
        }

        return true;
    }

    static_assert(sizeof(kProfiles) / sizeof(kProfiles[0]) == 6, "Update the profile tests when adding a device");
    static_assert(kProfiles[0].graphics.conditionalDualQuad, "Current profiles must keep the rendering fix enabled");
    static_assert(onlyValidatedProfileEnabled(kProfiles),
                  "Only the hardware-validated 0x1638 profile may enable VCN0 until the others are tested");
    static_assert(allVcnDataPresent(kProfiles),
                  "Every profile needs VCN data, H.264/HEVC decode and no AV1 before media can be enabled");
    static_assert(mediaDisabled(kFallbackProfile.media), "The fallback profile must not enable any media engine");

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
