// VDA / Hardware Video Decode Policy
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
#include <Headers/kern_util.hpp>
#include <NRed.hpp>
#include <VDA.hpp>
#include <libkern/OSTypes.h>

static VDA moduleInstance;

namespace
{

    const char* const kBootArgVDA = "-NRedVDA";
    const char* const kBootArgAVC = "-NRedAVC";

}    // namespace

VDA& VDA::singleton() { return moduleInstance; }

void VDA::init()
{
    const bool vdaRequested = checkKernelArgument(kBootArgVDA);
    const bool avcRequested = checkKernelArgument(kBootArgAVC);

    this->requested = vdaRequested || avcRequested;
    this->avcOnly   = avcRequested;

    if (!this->requested) {
        DBGLOG("VDA", "Hardware video decode is disabled; add -NRedVDA or -NRedAVC to opt in (experimental)");
        return;
    }

    if (this->avcOnly) {
        DBGLOG("VDA", "-NRedAVC is set: hardware AVC/H.264 only, HEVC falls back to software");
    }
    else {
        DBGLOG("VDA", "-NRedVDA is set: hardware AVC + HEVC decode");
    }
}

void VDA::processPatcher()
{
    // Never null: DeviceProfile::current() falls back to the generic profile for unknown devices.
    const auto* const profile = DeviceProfile::current();

    const auto& media         = profile->media;
    const auto  vcnGeneration = static_cast<UInt32>(media.vcnGeneration);

    DBGLOG("VDA", "%s: VCN %u.%u, firmware %s, ring 0x%X, fence 0x%X, H.264=%u HEVC=%u AV1=%u", profile->name,
           vcnGeneration >> 8, vcnGeneration & 0xFF, media.vcnFirmware != nullptr ? media.vcnFirmware : "none",
           media.vcnRingSize, media.vcnFenceSize, static_cast<UInt32>(media.decode.h264),
           static_cast<UInt32>(this->avcOnly ? false : media.decode.hevc), static_cast<UInt32>(media.decode.av1));

    if (!this->requested) { return; }

    // The bridge reports its own readiness under the VCN tag; VDA only publishes the requested profile and
    // generation here.  If the bridge fails, software decode stays in use.
    DBGLOG("VDA", "%s requested for %s; VCN bridge readiness is reported by the VCN module",
           this->avcOnly ? "-NRedAVC" : "-NRedVDA", profile->name);

    NRed::singleton().setProp32("NRedVDARequested", static_cast<UInt32>(this->requested));
    NRed::singleton().setProp32("NRedVDAAVCOnly", static_cast<UInt32>(this->avcOnly));
    // The VCN bridge owns the effective enablement and updates this property after engine allocation.
    NRed::singleton().setProp32("NRedVDAMediaEnabled", 0);
    NRed::singleton().setProp32("NRedVCNGeneration", vcnGeneration);
}
