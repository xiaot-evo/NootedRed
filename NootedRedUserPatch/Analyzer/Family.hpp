// NootedRedUserPatch device family map
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
#include <stdint.h>

namespace NRedUserPatch
{

    // Device-ID to rule-family bits.  Bit 3 is the VCN2 group used by every shipped rule; bits 4
    // and 5 distinguish the two VCN2.2 silicon groups for future per-family rules.
    constexpr auto familyForDeviceID(const uint16_t deviceID) -> uint32_t
    {
        switch (deviceID) {
            case 0x15DD:    // Raven
                return 1U << 0;
            case 0x15D8:    // Raven2 / Picasso
                return (1U << 1) | (1U << 2);
            case 0x1636:    // Renoir
            case 0x164C:    // Cezanne
                return (1U << 3) | (1U << 4);
            case 0x15E7:    // Barcelo
            case 0x1638:    // Renoir / Green Sardine
                return (1U << 3) | (1U << 5);
            default:
                return 0;
        }
    }

}    // namespace NRedUserPatch
