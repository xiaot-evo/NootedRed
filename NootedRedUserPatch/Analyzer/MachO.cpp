// NootedRedUserPatch minimal Mach-O parser
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

#include <Analyzer/MachO.hpp>

#include <string.h>

namespace
{

    static constexpr uint32_t kMachMagic64        = 0xFEEDFACFU;
    static constexpr uint32_t kLcSegment64       = 0x19U;
    static constexpr uint32_t kLcSymtab          = 0x02U;
    static constexpr uint32_t kLcFunctionStarts  = 0x26U;
    static constexpr uint32_t kLcDyldInfoOnly    = 0x80000022U;
    static constexpr uint32_t kLcDyldExportsTrie = 0x80000033U;

    static constexpr uint32_t kMaxLoadCommands     = 256U;
    static constexpr uint32_t kMaxLoadCommandBytes = 0x8000U;
    static constexpr uint32_t kMaxSymbols          = 1U << 20U;
    static constexpr uint32_t kMaxStringBytes      = 1U << 28U;

    auto readU32(const uint8_t* const bytes) -> uint32_t
    {
        uint32_t value = 0;
        memcpy(&value, bytes, sizeof(value));
        return value;
    }

    auto readU64(const uint8_t* const bytes) -> uint64_t
    {
        uint64_t value = 0;
        memcpy(&value, bytes, sizeof(value));
        return value;
    }

    auto segmentNameIs(const uint8_t* const segment, const char* const name) -> bool
    {
        return memcmp(segment, name, strlen(name) + 1U) == 0;
    }

}    // namespace

namespace NRedUserPatch
{

    auto parseMachO(const ByteSource& source, const uint64_t imageFileBase, const uint64_t loadAddress,
                    const uint64_t textSize, MachOImage& out) -> bool
    {
        uint8_t header[32]{};
        if (!source.readAt(imageFileBase, header, sizeof(header))) { return false; }
        if (readU32(header) != kMachMagic64) { return false; }

        const uint32_t ncmds      = readU32(header + 16);
        const uint32_t sizeofcmds = readU32(header + 20);
        if (ncmds == 0U || ncmds > kMaxLoadCommands) { return false; }
        if (sizeofcmds == 0U || sizeofcmds > kMaxLoadCommandBytes) { return false; }

        MachOImage parsed{};
        parsed.fileBase    = imageFileBase;
        parsed.loadAddress = loadAddress;

        uint64_t cursor = imageFileBase + sizeof(header);
        const uint64_t end = cursor + sizeofcmds;
        if (end < cursor) { return false; }

        bool haveText = false;
        for (uint32_t index = 0; index < ncmds; index++) {
            uint8_t command[8]{};
            if (!source.readAt(cursor, command, sizeof(command))) { return false; }
            const uint32_t cmd     = readU32(command);
            const uint32_t cmdsize = readU32(command + 4);
            if (cmdsize < 8U || cmdsize > kMaxLoadCommandBytes) { return false; }
            if (cursor + cmdsize > end || cursor + cmdsize < cursor) { return false; }

            uint8_t body[96]{};
            const size_t bodySize = cmdsize < sizeof(body) ? cmdsize : sizeof(body);
            if (!source.readAt(cursor, body, bodySize)) { return false; }

            switch (cmd) {
                case kLcSegment64: {
                    if (cmdsize < 72U) { return false; }
                    const uint8_t* const name    = body + 8;
                    const uint64_t       vmaddr  = readU64(body + 24);
                    const uint64_t       vmsize  = readU64(body + 32);
                    const uint64_t       fileoff = readU64(body + 40);
                    if (segmentNameIs(name, "__TEXT")) {
                        parsed.textVmAddr     = vmaddr;
                        parsed.textFileOffset = fileoff;
                        parsed.textSize       = textSize != 0U ? textSize : vmsize;
                        haveText              = true;
                    }
                    else if (segmentNameIs(name, "__LINKEDIT")) {
                        parsed.linkeditFileOffset = fileoff;
                    }
                    break;
                }
                case kLcSymtab: {
                    if (cmdsize < 24U) { return false; }
                    parsed.symoff  = readU32(body + 8);
                    parsed.nsyms   = readU32(body + 12);
                    parsed.stroff  = readU32(body + 16);
                    parsed.strsize = readU32(body + 20);
                    if (parsed.nsyms > kMaxSymbols || parsed.strsize > kMaxStringBytes) { return false; }
                    break;
                }
                case kLcFunctionStarts: {
                    if (cmdsize < 16U) { return false; }
                    parsed.functionStartsOffset = readU32(body + 8);
                    parsed.functionStartsSize   = readU32(body + 12);
                    break;
                }
                case kLcDyldExportsTrie: {
                    if (cmdsize < 16U) { return false; }
                    parsed.exportTrieOffset = readU32(body + 8);
                    parsed.exportTrieSize   = readU32(body + 12);
                    break;
                }
                case kLcDyldInfoOnly: {
                    if (cmdsize < 48U) { return false; }
                    parsed.exportTrieOffset = readU32(body + 40);
                    parsed.exportTrieSize   = readU32(body + 44);
                    break;
                }
                default:
                    break;
            }

            cursor += cmdsize;
        }

        if (!haveText) { return false; }

        parsed.imageVaEnd = loadAddress + parsed.textSize;
        if (parsed.imageVaEnd < loadAddress) { return false; }

        out = parsed;
        return true;
    }

}    // namespace NRedUserPatch
