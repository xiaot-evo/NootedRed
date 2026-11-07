// NootedRedUserPatch dyld shared-cache image locator
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

#include <Analyzer/CacheLocator.hpp>
#include <Analyzer/MachO.hpp>

#include <string.h>

namespace
{

    static constexpr const char* kMainCacheName  = "dyld_shared_cache_x86_64h";
    static constexpr uint32_t    kMaxImagesText  = 65536U;
    static constexpr uint32_t    kMaxSubcaches   = 8U;
    static constexpr uint32_t    kMaxMappings    = 16U;
    static constexpr uint32_t    kMaxPathLength  = 400U;
    static constexpr uint32_t    kSubcacheEntry  = 56U;
    static constexpr uint32_t    kMappingEntry   = 32U;

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

    auto copyText(char* const destination, const size_t capacity, const char* const source) -> void
    {
        if (destination == nullptr || capacity == 0U) { return; }
        size_t index = 0;
        if (source != nullptr) {
            for (; source[index] != '\0' && index + 1U < capacity; index++) { destination[index] = source[index]; }
        }
        destination[index] = '\0';
    }

    auto buildName(char* const destination, const size_t capacity, const char* const prefix,
                   const char* const suffix) -> bool
    {
        const size_t prefixLength = strlen(prefix);
        const size_t suffixLength = strlen(suffix);
        if (prefixLength + suffixLength + 1U > capacity) { return false; }
        memcpy(destination, prefix, prefixLength);
        memcpy(destination + prefixLength, suffix, suffixLength + 1U);
        return true;
    }

    auto buildProbeName(char* const destination, const size_t capacity, const char* const prefix,
                        const uint32_t index) -> bool
    {
        char suffix[4]{'.', static_cast<char>('0' + (index / 10U) % 10U),
                       static_cast<char>('0' + index % 10U), '\0'};
        return buildName(destination, capacity, prefix, suffix);
    }

    struct Candidate
    {
        char                    name[64]{};
        NRedUserPatch::ByteSource source{};
        uint32_t                mappingCount{0};
        uint64_t                addresses[kMaxMappings]{};
        uint64_t                sizes[kMaxMappings]{};
        uint64_t                fileOffsets[kMaxMappings]{};
    };

    auto addCandidate(Candidate* const candidates, uint32_t& candidateCount, const char* const name,
                      const NRedUserPatch::ByteSource& source) -> bool
    {
        if (candidateCount >= kMaxSubcaches) { return false; }

        uint8_t header[0x18]{};
        if (!source.readAt(0, header, sizeof(header))) { return false; }
        const uint32_t mappingOffset = readU32(header + 0x10);
        const uint32_t mappingCount  = readU32(header + 0x14);
        if (mappingCount == 0U || mappingCount > kMaxMappings) { return false; }

        Candidate& candidate = candidates[candidateCount];
        copyText(candidate.name, sizeof(candidate.name), name);
        candidate.source       = source;
        candidate.mappingCount = mappingCount;

        for (uint32_t index = 0; index < mappingCount; index++) {
            uint8_t mapping[kMappingEntry]{};
            if (!source.readAt(static_cast<uint64_t>(mappingOffset) + static_cast<uint64_t>(index) * kMappingEntry,
                               mapping, sizeof(mapping))) {
                return false;
            }
            candidate.addresses[index]   = readU64(mapping);
            candidate.sizes[index]       = readU64(mapping + 8);
            candidate.fileOffsets[index] = readU64(mapping + 16);
        }

        candidateCount += 1U;
        return true;
    }

    auto findMapping(const Candidate* const candidates, const uint32_t candidateCount, const uint64_t va,
                     uint32_t& candidateIndex, uint64_t& fileOffset) -> bool
    {
        for (uint32_t candidate = 0; candidate < candidateCount; candidate++) {
            for (uint32_t mapping = 0; mapping < candidates[candidate].mappingCount; mapping++) {
                const uint64_t address = candidates[candidate].addresses[mapping];
                if (va < address) { continue; }
                if (va - address >= candidates[candidate].sizes[mapping]) { continue; }
                candidateIndex = candidate;
                fileOffset     = candidates[candidate].fileOffsets[mapping] + (va - address);
                return true;
            }
        }
        return false;
    }

    auto readImagePath(const NRedUserPatch::ByteSource& mainCache, const uint32_t pathOffset, char* const out,
                       const size_t capacity) -> bool
    {
        uint8_t buffer[kMaxPathLength + 1U]{};
        if (!mainCache.readAt(pathOffset, buffer, kMaxPathLength)) { return false; }
        buffer[kMaxPathLength] = 0;
        size_t length = 0;
        while (length < sizeof(buffer) && buffer[length] != 0U) { length += 1U; }
        if (length >= sizeof(buffer) || length + 1U > capacity) { return false; }
        memcpy(out, buffer, length + 1U);
        return true;
    }

    auto locateImageText(const NRedUserPatch::ByteSource& mainCache, const char* const imagePath, uint64_t& loadAddress,
                         uint64_t& textSize) -> bool
    {
        uint8_t header[0x190]{};
        if (!mainCache.readAt(0, header, sizeof(header))) { return false; }
        if (memcmp(header, "dyld_v1", 7U) != 0) { return false; }

        const uint64_t imagesTextOffset = readU64(header + 0x88);
        const uint64_t imagesTextCount  = readU64(header + 0x90);
        if (imagesTextCount == 0U || imagesTextCount > kMaxImagesText) { return false; }

        for (uint64_t index = 0; index < imagesTextCount; index++) {
            uint8_t entry[32]{};
            const uint64_t at = imagesTextOffset + index * 32U;
            if (at < imagesTextOffset) { return false; }
            if (!mainCache.readAt(at, entry, sizeof(entry))) { return false; }

            const uint64_t imageLoad = readU64(entry + 16);
            const uint32_t imageSize = readU32(entry + 24);
            const uint32_t pathOffset = readU32(entry + 28);
            char path[kMaxPathLength + 1U]{};
            if (!readImagePath(mainCache, pathOffset, path, sizeof(path))) { continue; }
            if (strcmp(path, imagePath) != 0) { continue; }

            loadAddress = imageLoad;
            textSize    = imageSize;
            return true;
        }
        return false;
    }

    auto addSubcacheArray(const NRedUserPatch::ByteSource& mainCache, NRedUserPatch::OpenCacheFn open,
                          void* const openContext, Candidate* const candidates, uint32_t& candidateCount,
                          const uint8_t* const header) -> void
    {
        const uint32_t arrayOffset = readU32(header + 0x188);
        const uint32_t arrayCount  = readU32(header + 0x18C);
        if (arrayOffset != 0U && arrayCount != 0U && arrayCount <= 32U) {
            for (uint32_t index = 0; index < arrayCount; index++) {
                uint8_t entry[kSubcacheEntry]{};
                if (!mainCache.readAt(static_cast<uint64_t>(arrayOffset) + static_cast<uint64_t>(index) * kSubcacheEntry,
                                      entry, sizeof(entry))) {
                    return;
                }
                char suffix[33]{};
                memcpy(suffix, entry + 24, 32U);
                suffix[32] = '\0';
                if (suffix[0] == '\0') { continue; }

                char name[64]{};
                if (!buildName(name, sizeof(name), kMainCacheName, suffix)) { continue; }
                NRedUserPatch::ByteSource source{};
                if (!open(openContext, name, source)) { continue; }
                addCandidate(candidates, candidateCount, name, source);
            }
        }

        if (candidateCount <= 1U) {
            for (uint32_t index = 1; index <= 6; index++) {
                char name[64]{};
                if (!buildProbeName(name, sizeof(name), kMainCacheName, index)) { continue; }
                NRedUserPatch::ByteSource source{};
                if (!open(openContext, name, source)) { continue; }
                addCandidate(candidates, candidateCount, name, source);
            }
        }
    }

}    // namespace

namespace NRedUserPatch
{

    auto locateCacheImage(const ByteSource& mainCache, const OpenCacheFn open, void* const openContext,
                          const char* const imagePath, LocatedImage& out) -> bool
    {
        if (open == nullptr || imagePath == nullptr) { return false; }

        uint64_t loadAddress = 0;
        uint64_t textSize    = 0;
        if (!locateImageText(mainCache, imagePath, loadAddress, textSize)) { return false; }

        Candidate candidates[kMaxSubcaches]{};
        uint32_t  candidateCount = 0;
        if (!addCandidate(candidates, candidateCount, kMainCacheName, mainCache)) { return false; }

        uint8_t header[0x190]{};
        if (!mainCache.readAt(0, header, sizeof(header))) { return false; }
        addSubcacheArray(mainCache, open, openContext, candidates, candidateCount, header);

        uint32_t textCandidate = 0;
        uint64_t textFileOffset = 0;
        if (!findMapping(candidates, candidateCount, loadAddress, textCandidate, textFileOffset)) { return false; }

        MachOImage image{};
        if (!parseMachO(candidates[textCandidate].source, textFileOffset, loadAddress, textSize, image)) {
            return false;
        }

        uint32_t linkeditCandidate = 0;
        uint64_t linkeditFileOffset = 0;
        if (!findMapping(candidates, candidateCount, image.linkeditVmAddr, linkeditCandidate, linkeditFileOffset)) {
            return false;
        }

        copyText(out.vnodeName, sizeof(out.vnodeName), candidates[textCandidate].name);
        copyText(out.linkeditVnodeName, sizeof(out.linkeditVnodeName), candidates[linkeditCandidate].name);
        out.fileOffset         = textFileOffset;
        out.textSize           = textSize;
        out.loadAddress        = loadAddress;
        out.linkeditVmAddr     = image.linkeditVmAddr;
        out.linkeditFileOffset = linkeditFileOffset;
        return true;
    }

}    // namespace NRedUserPatch
