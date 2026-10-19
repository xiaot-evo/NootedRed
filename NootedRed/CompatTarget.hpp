// Binary Target Identity
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
#include <libkern/OSTypes.h>
#include <sys/types.h>

// Identity of an Apple binary that NootedRed patches.
//
// This is the version-axis half of the compatibility model in docs/Compatibility-Architecture.md: patch
// data belongs to a binary build (Mach-O `LC_UUID`), not to a macOS version string.  The type and the
// parser are in place, but capture is deferred to the target-identity milestone: reading the driver file
// through the VFS during Lilu's patcher-load phase is not safe enough for the boot path, so the boot-time
// `readFileIdentity()` experiment was removed after it was suspected of stalling boot.  The capture will
// use the code-signing hook's in-memory page data (or vnode name resolution) instead.
class CompatTarget
{
public:
    enum Kind : UInt8 {
        kGLDriver = 0,
        kMetalDriver,
        kX5000Kext,
        kX6000Kext,
        kVADriver,
        kAppleGVA,
        kUnknown,
    };

    struct Identity
    {
        Kind        kind{kUnknown};
        bool        valid{false};
        UInt8       uuid[16]{};
        const char* path{nullptr};
    };

    static const char* kindName(Kind kind);

    // Parses `LC_UUID` from a thin 64-bit Mach-O header.  Read-only and bounds-checked; returns false for
    // fat binaries, non-Mach-O data and truncated buffers.
    static auto parseMachOIdentity(Identity& identity, const UInt8* header, size_t size) -> bool;

    // Emits the canonical identity line (the `Compat` log tag) used for field triage.
    static void logIdentity(const Identity& identity);
};
