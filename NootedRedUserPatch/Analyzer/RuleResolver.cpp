// NootedRedUserPatch rule resolver
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

#include <Analyzer/RuleResolver.hpp>
#include <Analyzer/MachO.hpp>

#include <string.h>

namespace
{

    static constexpr uint32_t kMaxMatches   = 16U;
    static constexpr size_t   kScanChunk    = 512U;
    static constexpr size_t   kScanOverlap  = 64U;
    static constexpr size_t   kMaxPattern   = 64U;

    auto basenameOf(const char* const path) -> const char*
    {
        if (path == nullptr) { return ""; }
        const char* base = path;
        for (const char* cursor = path; *cursor != '\0'; cursor++) {
            if (*cursor == '/') { base = cursor + 1; }
        }
        return base;
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

    auto readExact(const NRedUserPatch::ByteSource& source, const uint64_t offset, const uint8_t* const expected,
                   const size_t size) -> bool
    {
        uint8_t buffer[64]{};
        if (size > sizeof(buffer)) { return false; }
        if (!source.readAt(offset, buffer, size)) { return false; }
        return memcmp(buffer, expected, size) == 0;
    }

    struct PatternMatches
    {
        uint64_t offsets[kMaxMatches]{};
        uint32_t count{0};
        bool     overflow{false};
    };

    auto scanPattern(const NRedUserPatch::ByteSource& source, const uint64_t startFile, const uint64_t endFile,
                     const NRedUserPatch::RuleVariant& variant, PatternMatches& matches) -> bool
    {
        const size_t patternSize = variant.localPatternSize;
        if (patternSize == 0U || patternSize > kMaxPattern) { return false; }
        if (endFile < startFile + patternSize) { return false; }

        uint8_t chunk[kScanChunk + kScanOverlap]{};
        uint64_t cursor = startFile;
        uint64_t lastRecorded = 0;
        bool     haveRecorded = false;

        while (cursor + patternSize <= endFile) {
            const size_t remaining = static_cast<size_t>(endFile - cursor);
            const size_t amount = remaining < kScanChunk ? remaining : kScanChunk;
            if (!source.readAt(cursor, chunk, amount)) { return false; }

            for (size_t offset = 0; offset + patternSize <= amount; offset++) {
                bool equal = true;
                for (size_t index = 0; index < patternSize; index++) {
                    if (variant.localMask[index] != 0U && chunk[offset + index] != variant.localPattern[index]) {
                        equal = false;
                        break;
                    }
                }
                if (!equal) { continue; }

                const uint64_t match = cursor + offset;
                if (haveRecorded && match == lastRecorded) { continue; }
                if (matches.count >= kMaxMatches) {
                    matches.overflow = true;
                    return true;
                }
                matches.offsets[matches.count++] = match;
                lastRecorded = match;
                haveRecorded = true;
            }

            if (amount < kScanChunk) { break; }
            cursor += amount - (patternSize - 1U);
        }
        return true;
    }

}    // namespace

namespace NRedUserPatch
{

    auto ruleEnabled(const Rule& rule, const uint32_t runningFamily, const bool vdaEnabled) -> bool
    {
        if ((rule.familyMask & runningFamily) == 0U) { return false; }
        if ((rule.flags & kRuleFlagVDA) != 0U && !vdaEnabled) { return false; }
        return true;
    }

    auto resolveRule(const ResolveContext& context, const Rule& rule, ResolvedSite& out, const char** const reason)
        -> bool
    {
        const auto fail = [reason](const char* const why) -> bool {
            if (reason != nullptr) { *reason = why; }
            return false;
        };

        if (!ruleEnabled(rule, context.runningFamily, context.vdaEnabled)) { return fail("rule gated"); }
        if (rule.symbol == nullptr || rule.variants == nullptr || rule.variantCount == 0U) {
            return fail("rule incomplete");
        }

        ByteSource textSource{};
        ByteSource linkeditSource{};
        MachOImage image{};
        uint64_t   textBase = 0;
        uint64_t   loadAddress = 0;
        char       vnodeName[64]{};

        if (rule.imageKind == ImageKind::kSharedCache) {
            if (context.mainCache == nullptr || context.openCache == nullptr) { return fail("no cache opener"); }
            LocatedImage located{};
            if (!locateCacheImage(*context.mainCache, context.openCache, context.openContext, rule.imagePath, located)) {
                return fail("image not located");
            }
            if (!context.openCache(context.openContext, located.vnodeName, textSource)) {
                return fail("text subcache not opened");
            }
            if (!context.openCache(context.openContext, located.linkeditVnodeName, linkeditSource)) {
                return fail("linkedit subcache not opened");
            }
            if (!parseMachO(textSource, located.fileOffset, located.loadAddress, located.textSize, image)) {
                return fail("text Mach-O parse failed");
            }
            textBase    = located.fileOffset;
            loadAddress = located.loadAddress;
            copyText(vnodeName, sizeof(vnodeName), located.vnodeName);
        }
        else {
            if (context.openImage == nullptr) { return fail("no image opener"); }
            if (!context.openImage(context.openContext, rule.imagePath, textSource)) {
                return fail("standalone image not opened");
            }
            linkeditSource = textSource;
            if (!parseMachO(textSource, 0, 0, 0, image)) { return fail("standalone Mach-O parse failed"); }
            textBase    = image.textFileOffset;
            loadAddress = 0;
            copyText(vnodeName, sizeof(vnodeName), basenameOf(rule.imagePath));
        }

        uint64_t symbolVa = 0;
        if (!findSymbol(linkeditSource, image, rule.symbol, symbolVa)) { return fail("symbol not found"); }

        uint64_t funcStart = 0;
        uint64_t funcEnd = 0;
        if (!functionRange(linkeditSource, image, symbolVa, funcStart, funcEnd)) {
            return fail("function range not found");
        }
        if (funcStart < loadAddress || funcEnd > image.imageVaEnd) { return fail("function range invalid"); }

        const uint64_t funcFileStart = textBase + (funcStart - loadAddress);
        const uint64_t funcFileEnd   = textBase + (funcEnd - loadAddress);
        if (funcFileEnd <= funcFileStart) { return fail("function range empty"); }

        for (uint32_t variantIndex = 0; variantIndex < rule.variantCount; variantIndex++) {
            const RuleVariant& variant = rule.variants[variantIndex];
            if (variant.patchSize == 0U || variant.patchSize > 64U) { continue; }
            if (variant.find == nullptr || variant.replace == nullptr) { continue; }

            uint64_t siteFile = 0;

            if (variant.localKind == LocalKind::kOffset) {
                const uint64_t siteVa = funcStart + variant.localOffset;
                if (siteVa < funcStart || siteVa >= funcEnd) { continue; }
                siteFile = textBase + (siteVa - loadAddress);
            }
            else {
                if (variant.localPattern == nullptr || variant.localMask == nullptr) { continue; }
                PatternMatches matches{};
                if (!scanPattern(textSource, funcFileStart, funcFileEnd, variant, matches)) {
                    return fail("pattern scan failed");
                }
                if (matches.overflow) { return fail("too many pattern matches"); }
                if (matches.count == 0U) { continue; }

                if (rule.policy == MatchPolicy::kUnique) {
                    if (matches.count != 1U) { return fail("pattern not unique"); }
                    siteFile = matches.offsets[0] + variant.patchOffset;
                }
                else if (rule.policy == MatchPolicy::kNth) {
                    const uint32_t nth = rule.localNth != 0U ? rule.localNth : 1U;
                    if (matches.count < nth) { continue; }
                    siteFile = matches.offsets[nth - 1U] + variant.patchOffset;
                }
                else {
                    return fail("match-all policy not supported");
                }
            }

            if (siteFile < funcFileStart || siteFile + variant.patchSize > funcFileEnd) { continue; }
            if (!readExact(textSource, siteFile, variant.find, variant.patchSize)) { continue; }

            copyText(out.vnodeName, sizeof(out.vnodeName), vnodeName);
            out.fileOffset = siteFile;
            out.find       = variant.find;
            out.replace    = variant.replace;
            out.size       = variant.patchSize;
            out.ruleId     = rule.id;
            return true;
        }

        return fail("no variant matched");
    }

}    // namespace NRedUserPatch
