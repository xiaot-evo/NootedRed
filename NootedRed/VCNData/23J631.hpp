// VCN kernel bridge data for macOS 14.8.9 (Sonoma, 23J631)
//
// Copyright (C) 2022-2026  ChefKiss.
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
// Imported from the multi-OS fork weachy/NootedRed.  This build has not been hardware-validated by this
// project and has no locally generated kernel-collection identity; the bridge therefore requires the
// exact build string and verifies every guard/getter/call-site byte before writing.

#pragma once
#include <VCNData.hpp>

namespace VCNData::Build23J631
{
    inline constexpr char Build[] = "23J631";
    inline constexpr UInt32 DarwinMajor = 23;
    inline constexpr UInt32 DarwinMinor = 6;

    inline constexpr UInt8 Getter5000_1[] = {
        0x55, 0x48, 0x89, 0xE5, 0x8A, 0x87, 0x0E, 0x03,
        0x00, 0x00, 0x5D, 0xC3,
    };

    inline constexpr UInt8 Getter5000_2[] = {
        0x55, 0x48, 0x89, 0xE5, 0x48, 0x8B, 0x87, 0x40,
        0x06, 0x02, 0x00, 0x5D, 0xC3,
    };

    inline constexpr UInt8 Getter5000_3[] = {
        0x55, 0x48, 0x89, 0xE5, 0x8B, 0x87, 0x50, 0x05,
        0x02, 0x00, 0x5D, 0xC3,
    };

    inline constexpr UInt8 Getter6000_1[] = {
        0x55, 0x48, 0x89, 0xE5, 0x8A, 0x87, 0x0E, 0x03,
        0x00, 0x00, 0x5D, 0xC3,
    };

    inline constexpr UInt8 Getter6000_2[] = {
        0x55, 0x48, 0x89, 0xE5, 0x48, 0x8B, 0x87, 0x48,
        0x06, 0x02, 0x00, 0x5D, 0xC3,
    };

    inline constexpr UInt8 Getter6000_3[] = {
        0x55, 0x48, 0x89, 0xE5, 0x8B, 0x87, 0x48, 0x05,
        0x02, 0x00, 0x5D, 0xC3,
    };

    inline constexpr char Table5000[] = "__ZTV32AMDRadeonX5000_AMDVega10Hardware";
    inline constexpr char Table6000[] = "__ZTV32AMDRadeonX6000_AMDNavi10Hardware";

    inline constexpr SlotGuard Guards5000[] = {
        { 0x298, "__ZN26AMDRadeonX5000_AMDHardware13isDeviceValidEv", nullptr, 0 },
        { 0x2A8, nullptr, Getter5000_1, 12 },
        { 0x3B8, nullptr, Getter5000_2, 13 },
        { 0x3C8, nullptr, Getter5000_3, 12 },
        { 0x3E8, "__ZN28AMDRadeonX5000_AMDRTHardware13disableGfxOffEv", nullptr, 0 },
        { 0x3F0, "__ZN28AMDRadeonX5000_AMDRTHardware12enableGfxOffEv", nullptr, 0 },
    };

    inline constexpr SlotGuard Guards6000[] = {
        { 0x2A0, "__ZN26AMDRadeonX6000_AMDHardware13isDeviceValidEv", nullptr, 0 },
        { 0x2B0, nullptr, Getter6000_1, 12 },
        { 0x3B0, nullptr, Getter6000_2, 13 },
        { 0x3C0, nullptr, Getter6000_3, 12 },
        { 0x3E0, "__ZN28AMDRadeonX6000_AMDRTHardware13disableGfxOffEv", nullptr, 0 },
        { 0x3E8, "__ZN28AMDRadeonX6000_AMDRTHardware12enableGfxOffEv", nullptr, 0 },
    };

    // Original bytes are `callq *slot(%rax)`; newSlot == 0 means the call is
    // replaced by `call SignalSymbol` (E8 rel32) plus a NOP at runtime.
    inline constexpr CallPatch CallPatches[] = {
        {
            "__ZN26AMDRadeonX6000_AMDHWEngine11waitForIdleEj",
            0x1A,
            { 0xFF, 0x90, 0xE0, 0x03, 0x00, 0x00 },
            0x3E8,
        },
        {
            "__ZN26AMDRadeonX6000_AMDHWEngine11waitForIdleEj",
            0x84,
            { 0xFF, 0x90, 0xE8, 0x03, 0x00, 0x00 },
            0x3F0,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel11waitForIdleEj",
            0x1A,
            { 0xFF, 0x90, 0xE0, 0x03, 0x00, 0x00 },
            0x3E8,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel11waitForIdleEj",
            0xF2,
            { 0xFF, 0x90, 0xE8, 0x03, 0x00, 0x00 },
            0x3F0,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel14waitForHwStampEj",
            0xB2,
            { 0xFF, 0x90, 0xA0, 0x02, 0x00, 0x00 },
            0x298,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel16timestampUpdatedEv",
            0x1A,
            { 0xFF, 0x90, 0xB0, 0x03, 0x00, 0x00 },
            0x3B8,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel19submitCommandBufferEP30AMD_SUBMIT_COMMAND_BUFFER_INFO",
            0x153,
            { 0xFF, 0x90, 0x30, 0x02, 0x00, 0x00 },
            0x0,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel20writeDiagnosisReportERPcRj",
            0x538,
            { 0xFF, 0x90, 0xB0, 0x03, 0x00, 0x00 },
            0x3B8,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel20writeDiagnosisReportERPcRj",
            0x7B6,
            { 0xFF, 0x90, 0xB0, 0x03, 0x00, 0x00 },
            0x3B8,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel20writeDiagnosisReportERPcRj",
            0x9D1,
            { 0xFF, 0x90, 0xC0, 0x03, 0x00, 0x00 },
            0x3C8,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel24enableTimestampInterruptEv",
            0x74,
            { 0xFF, 0x90, 0xA0, 0x02, 0x00, 0x00 },
            0x298,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel4initEiP30AMDRadeonX6000_IAMDHWInterfaceP27AMDRadeonX6000_IAMDHWEngineP25AMDRadeonX6000_IAMDHWRingPKc",
            0x1F5,
            { 0xFF, 0x90, 0xB0, 0x03, 0x00, 0x00 },
            0x3B8,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel4initEiP30AMDRadeonX6000_IAMDHWInterfaceP27AMDRadeonX6000_IAMDHWEngineP25AMDRadeonX6000_IAMDHWRingPKc",
            0x2AD,
            { 0xFF, 0x90, 0xC0, 0x03, 0x00, 0x00 },
            0x3C8,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel4initEiP30AMDRadeonX6000_IAMDHWInterfaceP27AMDRadeonX6000_IAMDHWEngineP25AMDRadeonX6000_IAMDHWRingPKc",
            0x2CF,
            { 0xFF, 0x90, 0xC0, 0x03, 0x00, 0x00 },
            0x3C8,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel4initEiP30AMDRadeonX6000_IAMDHWInterfaceP27AMDRadeonX6000_IAMDHWEngineP25AMDRadeonX6000_IAMDHWRingPKc",
            0x2F1,
            { 0xFF, 0x90, 0xC0, 0x03, 0x00, 0x00 },
            0x3C8,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel4initEiP30AMDRadeonX6000_IAMDHWInterfaceP27AMDRadeonX6000_IAMDHWEngineP25AMDRadeonX6000_IAMDHWRingPKc",
            0x315,
            { 0xFF, 0x90, 0xC0, 0x03, 0x00, 0x00 },
            0x3C8,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel4initEiP30AMDRadeonX6000_IAMDHWInterfaceP27AMDRadeonX6000_IAMDHWEngineP25AMDRadeonX6000_IAMDHWRingPKc",
            0x339,
            { 0xFF, 0x90, 0xC0, 0x03, 0x00, 0x00 },
            0x3C8,
        },
        {
            "__ZN27AMDRadeonX6000_AMDHWChannel5resetEv",
            0x5A,
            { 0xFF, 0x90, 0xB0, 0x03, 0x00, 0x00 },
            0x3B8,
        },
        {
            "__ZN30AMDRadeonX6000_AMDVCN2HWEngine6isIdleEv",
            0x33,
            { 0xFF, 0x90, 0xA0, 0x02, 0x00, 0x00 },
            0x298,
        },
        {
            "__ZN36AMDRadeonX6000_AMDNavi10VideoContext21setSuspendResumeStateEb",
            0x27,
            { 0xFF, 0x90, 0xB0, 0x02, 0x00, 0x00 },
            0x2A8,
        },
    };

    inline constexpr char SignalSymbol[] = "__ZN26AMDRadeonX6000_AMDHardware22signalGPUWorkSubmittedEv";

    inline constexpr UInt32 kCallPatchCount = sizeof(CallPatches) / sizeof(CallPatches[0]);
    static_assert(kCallPatchCount <= kMaxCallPatches, "23J631 call-site table must fit the bridge array");
    static_assert(sizeof(Guards5000) / sizeof(Guards5000[0]) == 6, "23J631 X5000 guard table must contain 6 entries");
    static_assert(sizeof(Guards6000) / sizeof(Guards6000[0]) == 6, "23J631 X6000 guard table must contain 6 entries");

    inline constexpr char SourceDescription[] =
        "macOS 14.8.9 (23J631) x86_64, Darwin 23.6.0; 20 X6000 call-site patches imported from the "
        "multi-OS fork weachy/NootedRed; vtable guards/getters shared with the 15.8.1 data";

    // No locally generated identity for this imported build; exact build plus runtime byte checks are the gate.
    inline constexpr char KernelCollectionUUID[] = "";
    inline constexpr char DriverUUID5000[] = "";
    inline constexpr char DriverUUID6000[] = "";
    inline constexpr char DriverVersion5000[] = "";
    inline constexpr char DriverVersion6000[] = "";
    inline constexpr char DriverSHA256_5000[] = "";
    inline constexpr char DriverSHA256_6000[] = "";

    inline constexpr Variant kData = {
        1,
        Build,
        DarwinMajor,
        DarwinMinor,
        SourceDescription,
        CallPatches,
        kCallPatchCount,
        Guards5000,
        sizeof(Guards5000) / sizeof(Guards5000[0]),
        Guards6000,
        sizeof(Guards6000) / sizeof(Guards6000[0]),
        Table5000,
        Table6000,
        SignalSymbol,
        false,
        false,
        KernelCollectionUUID,
        DriverUUID5000,
        DriverUUID6000,
        DriverVersion5000,
        DriverVersion6000,
        DriverSHA256_5000,
        DriverSHA256_6000,
    };
}    // namespace VCNData::Build23J631
