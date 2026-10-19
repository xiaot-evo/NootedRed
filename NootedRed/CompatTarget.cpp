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

#include <CompatTarget.hpp>
#include <Headers/kern_util.hpp>

namespace
{

    // Values from <mach-o/loader.h>; kept local so the header does not pull in the full Mach-O headers.
    constexpr UInt32 kMachMagic64      = 0xFEEDFACF;
    constexpr UInt32 kLoadCommandUuid  = 0x1B;
    constexpr size_t kMachHeader64Size = 32;
    constexpr size_t kMaxLoadCommands  = 0x1000;

}    // namespace

const char* CompatTarget::kindName(const Kind kind)
{
    switch (kind) {
        case kGLDriver: return "GLDriver";
        case kMetalDriver: return "MetalDriver";
        case kX5000Kext: return "X5000Kext";
        case kX6000Kext: return "X6000Kext";
        case kVADriver: return "VADriver";
        case kAppleGVA: return "AppleGVA";
        case kUnknown: return "unknown";
    }

    return "unknown";
}

auto CompatTarget::parseMachOIdentity(Identity& identity, const UInt8* const header, const size_t size) -> bool
{
    if (header == nullptr || size < kMachHeader64Size) { return false; }

    UInt32 magic{0};
    memcpy(&magic, header, sizeof(magic));
    if (magic != kMachMagic64) { return false; }

    // mach_header_64: magic, cputype, cpusubtype, filetype, ncmds (offset 0x10), sizeofcmds (offset 0x14).
    UInt32 commandCount{0};
    UInt32 commandsSize{0};
    memcpy(&commandCount, header + 0x10, sizeof(commandCount));
    memcpy(&commandsSize, header + 0x14, sizeof(commandsSize));

    if (commandCount == 0 || commandCount > kMaxLoadCommands) { return false; }
    if (commandsSize > size - kMachHeader64Size) { return false; }

    auto offset = kMachHeader64Size;
    for (UInt32 commandIndex = 0; commandIndex < commandCount; commandIndex++) {
        if (offset + 8 > size) { return false; }

        UInt32 command{0};
        UInt32 commandSize{0};
        memcpy(&command, header + offset, sizeof(command));
        memcpy(&commandSize, header + offset + 4, sizeof(commandSize));

        if (commandSize < 8 || offset + commandSize > size) { return false; }

        // struct uuid_command: cmd, cmdsize, uuid[16].
        if (command == kLoadCommandUuid && commandSize >= 24) {
            memcpy(identity.uuid, header + offset + 8, sizeof(identity.uuid));
            identity.valid = true;
            return true;
        }

        offset += commandSize;
    }

    return false;
}

void CompatTarget::logIdentity(const Identity& identity)
{
    static constexpr char kHexDigits[] = "0123456789ABCDEF";

    char uuidString[sizeof(identity.uuid) * 2 + 1]{};
    if (identity.valid) {
        for (size_t index = 0; index < sizeof(identity.uuid); index++) {
            uuidString[index * 2]     = kHexDigits[identity.uuid[index] >> 4];
            uuidString[index * 2 + 1] = kHexDigits[identity.uuid[index] & 0xF];
        }
    }

    SYSLOG("Compat", "target identity: kind=%s uuid=%s path=%s", kindName(identity.kind),
           identity.valid ? uuidString : "unknown", identity.path != nullptr ? identity.path : "unknown");
}
