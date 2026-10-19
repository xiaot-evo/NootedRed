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

#pragma once

// Runtime policy layer for the VDA/VCN hardware video decode work.
//
// `init()` records the opt-in `-NRedVDA` boot argument and `processPatcher()` logs the media capability of
// the running device's `DeviceProfile`.  The actual engine/bridge readiness lives in `VCNBridge`; this class
// only keeps the user intent and the profile view, and remains inert when the boot argument is absent.
class VDA
{
    bool requested{false};

public:
    static VDA& singleton();

    // Parses the -NRedVDA boot argument.  Called from `NRed::init()`, before the device is known.
    void init();

    // Resolves the running device profile and logs the media policy.  Called from `NRed::processPatcher()`
    // once the device ID is known.
    void processPatcher();

    // True when the user explicitly opted in with -NRedVDA.
    bool isRequested() const { return this->requested; }

};
