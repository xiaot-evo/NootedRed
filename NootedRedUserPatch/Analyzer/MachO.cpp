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
                        parsed.linkeditVmAddr     = vmaddr;
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

namespace
{

    auto readUleb(const ByteSource& source, uint64_t& cursor, const uint64_t end, uint64_t& value) -> bool
    {
        value = 0;
        uint32_t shift = 0;
        for (uint32_t index = 0; index < 10U; index++) {
            if (cursor >= end) { return false; }
            uint8_t byte = 0;
            if (!source.readAt(cursor, &byte, 1)) { return false; }
            cursor += 1U;
            value |= static_cast<uint64_t>(byte & 0x7FU) << shift;
            if ((byte & 0x80U) == 0U) { return true; }
            shift += 7U;
        }
        return false;
    }

    auto readCString(const ByteSource& source, uint64_t& cursor, const uint64_t end, char* const out,
                     const size_t capacity, size_t& length) -> bool
    {
        length = 0;
        while (cursor < end) {
            if (length + 1U >= capacity) { return false; }
            uint8_t byte = 0;
            if (!source.readAt(cursor, &byte, 1)) { return false; }
            cursor += 1U;
            if (byte == 0U) {
                out[length] = '\0';
                return true;
            }
            out[length++] = static_cast<char>(byte);
        }
        return false;
    }

    // Reads a NUL-terminated symbol name from the shared string table in bounded chunks.  The table
    // can be tens of MB; reading 64 bytes at a time keeps the common case cheap and never runs past
    // the caller's buffer.
    auto readName(const ByteSource& source, const uint64_t offset, char* const out, const size_t capacity) -> bool
    {
        size_t written = 0;
        while (written + 1U < capacity) {
            uint8_t chunk[64]{};
            const size_t want = (capacity - 1U - written) < sizeof(chunk) ? capacity - 1U - written : sizeof(chunk);
            if (!source.readAt(offset + written, chunk, want)) { return false; }
            for (size_t index = 0; index < want; index++) {
                if (chunk[index] == 0U) {
                    out[written + index] = '\0';
                    return true;
                }
                out[written + index] = static_cast<char>(chunk[index]);
            }
            written += want;
        }
        return false;
    }

    struct TrieSearch
    {
        const ByteSource& source;
        uint64_t          trieBase;
        uint64_t          trieEnd;
        const char*       target;
        size_t            targetLength;
        uint64_t          imageBase;
        uint64_t          address{0};
        bool              found{false};
        uint32_t          nodes{0};
    };

    static constexpr uint32_t kMaxTrieDepth = 64U;
    static constexpr uint32_t kMaxTrieNodes = 1U << 20U;

    auto walkTrie(TrieSearch& search, const uint64_t nodeOffset, char* const prefix, const size_t prefixLength,
                  const uint32_t depth) -> bool
    {
        if (depth > kMaxTrieDepth || search.nodes >= kMaxTrieNodes) { return false; }
        const uint64_t cursor = search.trieBase + nodeOffset;
        if (cursor < search.trieBase || cursor >= search.trieEnd) { return false; }
        search.nodes += 1U;

        uint64_t position = cursor;
        uint64_t terminalSize = 0;
        if (!readUleb(search.source, position, search.trieEnd, terminalSize)) { return false; }
        if (terminalSize != 0U) {
            uint64_t flags = 0;
            uint64_t address = 0;
            if (!readUleb(search.source, position, search.trieEnd, flags)) { return false; }
            if (!readUleb(search.source, position, search.trieEnd, address)) { return false; }
            if (prefixLength == search.targetLength && memcmp(prefix, search.target, search.targetLength) == 0) {
                search.address = address;
                search.found = true;
                return true;
            }
        }

        uint64_t childCount = 0;
        if (!readUleb(search.source, position, search.trieEnd, childCount)) { return false; }
        if (childCount > 4096U) { return false; }

        for (uint64_t index = 0; index < childCount; index++) {
            char edge[256]{};
            size_t edgeLength = 0;
            if (!readCString(search.source, position, search.trieEnd, edge, sizeof(edge), edgeLength)) { return false; }
            if (prefixLength + edgeLength + 1U > 256U) { return false; }
            memcpy(prefix + prefixLength, edge, edgeLength);
            uint64_t childOffset = 0;
            if (!readUleb(search.source, position, search.trieEnd, childOffset)) { return false; }
            if (walkTrie(search, childOffset, prefix, prefixLength + edgeLength, depth + 1U)) { return true; }
        }
        return false;
    }

}    // namespace

auto findSymbol(const ByteSource& linkedit, const MachOImage& image, const char* const name, uint64_t& outVa)
    -> bool
{
    if (name == nullptr) { return false; }
    const size_t nameLength = strlen(name);
    if (nameLength == 0U || nameLength >= 256U) { return false; }

    if (image.exportTrieSize != 0U) {
        const uint64_t trieEnd = image.exportTrieOffset + image.exportTrieSize;
        if (trieEnd > image.exportTrieOffset) {
            TrieSearch search{linkedit, image.exportTrieOffset, trieEnd, name, nameLength, image.loadAddress};
            char       prefix[256]{};
            if (walkTrie(search, 0, prefix, 0, 0) && search.found) {
                outVa = image.loadAddress + search.address;
                return true;
            }
        }
    }

    if (image.nsyms == 0U || image.symoff == 0U || image.stroff == 0U || image.strsize == 0U) { return false; }
    const uint64_t nlistEnd = image.symoff + static_cast<uint64_t>(image.nsyms) * 16U;
    if (nlistEnd < image.symoff) { return false; }

    bool     haveMatch = false;
    uint64_t matchValue = 0;
    uint64_t cursor = image.symoff;
    while (cursor < nlistEnd) {
        uint8_t       entries[64U * 16U]{};
        const size_t  remaining = static_cast<size_t>((nlistEnd - cursor) / 16U);
        const size_t  count = remaining < 64U ? remaining : 64U;
        const size_t  bytes = count * 16U;
        if (!linkedit.readAt(cursor, entries, bytes)) { return false; }

        for (size_t index = 0; index < count; index++) {
            const uint8_t* const entry = entries + index * 16U;
            const uint32_t       strx = readU32(entry);
            const uint64_t       value = readU64(entry + 8);
            if (value < image.loadAddress || value >= image.imageVaEnd) { continue; }
            if (strx >= image.strsize) { continue; }

            char symbolName[256]{};
            if (!readName(linkedit, static_cast<uint64_t>(image.stroff) + strx, symbolName, sizeof(symbolName))) {
                continue;
            }
            if (strcmp(symbolName, name) != 0) { continue; }
            if (haveMatch && matchValue != value) { return false; }
            haveMatch = true;
            matchValue = value;
        }
        cursor += bytes;
    }

    if (!haveMatch) { return false; }
    outVa = matchValue;
    return true;
}

auto functionRange(const ByteSource& linkedit, const MachOImage& image, const uint64_t va, uint64_t& start,
                   uint64_t& end) -> bool
{
    if (image.functionStartsSize == 0U || image.functionStartsOffset == 0U) { return false; }

    const uint64_t fileEnd = image.functionStartsOffset + image.functionStartsSize;
    if (fileEnd < image.functionStartsOffset) { return false; }

    uint64_t cursor = image.functionStartsOffset;
    uint64_t current = image.textVmAddr;
    uint64_t previousStart = 0;
    uint64_t nextStart = 0;
    bool     havePrevious = false;
    bool     done = false;
    uint64_t value = 0;
    uint32_t shift = 0;
    bool     active = false;

    while (cursor < fileEnd && !done) {
        uint8_t      chunk[256]{};
        const size_t amount = (fileEnd - cursor) < sizeof(chunk) ? static_cast<size_t>(fileEnd - cursor)
                                                                 : sizeof(chunk);
        if (!linkedit.readAt(cursor, chunk, amount)) { return false; }
        for (size_t index = 0; index < amount; index++) {
            const uint8_t byte = chunk[index];
            if (!active) {
                value = 0;
                shift = 0;
                active = true;
            }
            value |= static_cast<uint64_t>(byte & 0x7FU) << shift;
            if ((byte & 0x80U) != 0U) {
                shift += 7U;
                if (shift > 63U) { return false; }
                continue;
            }

            active = false;
            const uint64_t delta = value;
            if (delta == 0U) {
                done = true;
                break;
            }
            current += delta;
            if (current <= va) {
                previousStart = current;
                havePrevious = true;
            }
            else {
                nextStart = current;
                done = true;
                break;
            }
        }
        cursor += amount;
    }

    if (!havePrevious) { return false; }
    start = previousStart;
    end = nextStart != 0U ? nextStart : image.imageVaEnd;
    return end > start;
}

}    // namespace NRedUserPatch
