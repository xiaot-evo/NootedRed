// Host analyzer tests
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

#include <Analyzer/ByteSource.hpp>
#include <Analyzer/CacheLocator.hpp>
#include <Analyzer/MachO.hpp>
#include <Analyzer/RuleResolver.hpp>
#include <Analyzer/RuleTable.hpp>
#include <FileByteSource.hpp>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

namespace
{

    uint32_t failures = 0;

    void check(const bool condition, const char* const what)
    {
        if (!condition) {
            printf("FAIL: %s\n", what);
            failures += 1U;
        }
        else {
            printf("ok: %s\n", what);
        }
    }

    void makePath(char* const out, const size_t size, const char* const root, const char* const tail)
    {
        snprintf(out, size, "%s/%s", root, tail);
    }

    void testMachO(const char* const root)
    {
        char path[1024];

        makePath(path, sizeof(path), root,
                 "System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver");
        TestSupport::FileSource glFile;
        check(TestSupport::openFixtureFile(path, glFile), "open standalone GL driver");
        if (glFile.file != nullptr) {
            auto glSource = glFile.source();
            uint8_t magic[4]{};
            check(glSource.readAt(0, magic, sizeof(magic)), "read Mach-O magic");
            check(magic[0] == 0xCF && magic[1] == 0xFA && magic[2] == 0xED && magic[3] == 0xFE,
                  "GL driver has MH_MAGIC_64");

            NRedUserPatch::MachOImage image{};
            check(NRedUserPatch::parseMachO(glSource, 0, 0, 0x14D000U, image), "parse GL Mach-O");
            check(image.nsyms == 8384U, "GL nsyms");
            check(image.functionStartsOffset == 0x157BC0U, "GL function starts offset");

            uint64_t symbol = 0;
            check(NRedUserPatch::findSymbol(glSource, image, "_glrAMD_GFX9_UpdateHwCbDualQuadMode", symbol),
                  "find GL UpdateHwCb symbol");
            check(symbol == 0x8134U, "GL UpdateHwCb symbol address");
            check(NRedUserPatch::findSymbol(glSource, image, "_gfx9_HwInfoInitData", symbol),
                  "find GL HwInfoInitData symbol");
            check(symbol == 0xDF40U, "GL HwInfoInitData symbol address");

            uint64_t funcStart = 0;
            uint64_t funcEnd = 0;
            check(NRedUserPatch::functionRange(glSource, image, 0x8160U, funcStart, funcEnd),
                  "GL function range");
            check(funcStart == 0x8134U && funcEnd == 0x81C2U, "GL function range bounds");
        }

        makePath(path, sizeof(path), root,
                 "System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64h.03");
        TestSupport::FileSource mtlFile;
        check(TestSupport::openFixtureFile(path, mtlFile), "open shared-cache subcache .03");
        if (mtlFile.file != nullptr) {
            auto mtlSource = mtlFile.source();
            NRedUserPatch::MachOImage image{};
            check(NRedUserPatch::parseMachO(mtlSource, 0x8757000U, 0x7FFB08757000ULL, 0x44FC11U, image),
                  "parse MTL Mach-O from subcache");
            check(image.nsyms == 19870U, "MTL nsyms");
            check(image.functionStartsOffset == 0x23BA3918U, "MTL function starts offset");
            check(image.textFileOffset == 0x8757000U, "MTL __TEXT file offset");

            // Local symbol: not in the export trie, so this exercises the nlist scan.
            uint64_t symbol = 0;
            check(NRedUserPatch::findSymbol(mtlSource, image,
                                            "__Z19gfx9_HwInfoInitDataP14GFX9_HwInfoRecP24_sAMD_GET_HW_INFO_VALUESj",
                                            symbol),
                  "find MTL local gfx9_HwInfoInitData symbol");
            check(symbol == 0x7FFB087EF3DCULL, "MTL local symbol address");

            uint64_t funcStart = 0;
            uint64_t funcEnd = 0;
            check(NRedUserPatch::functionRange(mtlSource, image, 0x7FFB087EF51DULL, funcStart, funcEnd),
                  "MTL function range");
            check(funcStart == 0x7FFB087EF3DCULL && funcEnd > 0x7FFB087EF51DULL, "MTL function range bounds");

            NRedUserPatch::MachOImage vaImage{};
            check(NRedUserPatch::parseMachO(mtlSource, 0x8606000U, 0x7FFB08606000ULL, 0xB8268U, vaImage),
                  "parse VADriver2 Mach-O from subcache");
            uint64_t vaSymbol = 0;
            check(NRedUserPatch::findSymbol(mtlSource, vaImage, "__ZN17VAAcceleratorInfo8identifyEjj", vaSymbol),
                  "find VADriver2 identify symbol via export trie");
            check(vaSymbol == 0x7FFB086069E0ULL, "VADriver2 identify symbol address");
            check(NRedUserPatch::functionRange(mtlSource, vaImage, 0x7FFB08606B96ULL, funcStart, funcEnd),
                  "VADriver2 function range");
            check(funcStart == 0x7FFB086069E0ULL && funcEnd > 0x7FFB08606B96ULL,
                  "VADriver2 function range bounds");
        }
    }

    struct FixtureOpener
    {
        struct Entry
        {
            char                     name[64]{};
            TestSupport::FileSource  file{};
        };

        char     dyldDir[1024]{};
        Entry    entries[8]{};
        uint32_t count{0};

        static auto open(void* const context, const char* const name, NRedUserPatch::ByteSource& out) -> bool
        {
            auto* const self = static_cast<FixtureOpener*>(context);
            for (uint32_t index = 0; index < self->count; index++) {
                if (strcmp(self->entries[index].name, name) == 0) {
                    out = self->entries[index].file.source();
                    return true;
                }
            }
            if (self->count >= 8U) { return false; }
            char path[1200]{};
            snprintf(path, sizeof(path), "%s/%s", self->dyldDir, name);
            if (!TestSupport::openFixtureFile(path, self->entries[self->count].file)) { return false; }
            snprintf(self->entries[self->count].name, sizeof(self->entries[self->count].name), "%s", name);
            out = self->entries[self->count].file.source();
            self->count += 1U;
            return true;
        }
    };

    void locateOne(const char* const root, const char* const imagePath, const char* const expectedVnode,
                   const uint64_t expectedOffset, const uint64_t expectedSize, const uint64_t expectedLoad,
                   const char* const expectedLinkeditVnode)
    {
        char dyldDir[1024]{};
        snprintf(dyldDir, sizeof(dyldDir), "%s/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld", root);
        char mainPath[1200]{};
        snprintf(mainPath, sizeof(mainPath), "%s/dyld_shared_cache_x86_64h", dyldDir);

        TestSupport::FileSource mainFile;
        if (!TestSupport::openFixtureFile(mainPath, mainFile)) {
            check(false, "open main dyld cache");
            return;
        }

        FixtureOpener opener{};
        snprintf(opener.dyldDir, sizeof(opener.dyldDir), "%s", dyldDir);

        NRedUserPatch::LocatedImage located{};
        const bool ok = NRedUserPatch::locateCacheImage(mainFile.source(), &FixtureOpener::open, &opener, imagePath,
                                                        located);
        check(ok, "locate cache image");
        if (!ok) { return; }
        check(strcmp(located.vnodeName, expectedVnode) == 0, "located text vnode");
        check(located.fileOffset == expectedOffset, "located text file offset");
        check(located.textSize == expectedSize, "located text size");
        check(located.loadAddress == expectedLoad, "located load address");
        check(strcmp(located.linkeditVnodeName, expectedLinkeditVnode) == 0, "located __LINKEDIT vnode");
    }

    void testCacheLocator(const char* const root15, const char* const root26)
    {
        locateOne(root15, "/System/Library/Extensions/AMDRadeonX5000MTLDriver.bundle/Contents/MacOS/"
                          "AMDRadeonX5000MTLDriver",
                  "dyld_shared_cache_x86_64h.03", 0x8757000U, 0x44FC11U, 0x7FFB08757000ULL,
                  "dyld_shared_cache_x86_64h.03");
        locateOne(root15, "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2",
                  "dyld_shared_cache_x86_64h.03", 0x8606000U, 0xB8268U, 0x7FFB08606000ULL,
                  "dyld_shared_cache_x86_64h.03");
        locateOne(root15, "/System/Library/PrivateFrameworks/AppleGVA.framework/Versions/A/AppleGVA",
                  "dyld_shared_cache_x86_64h.02", 0x6672000U, 0xEE2CFU, 0x7FFA06672000ULL,
                  "dyld_shared_cache_x86_64h.02");

        locateOne(root26, "/System/Library/Extensions/AMDRadeonX5000MTLDriver.bundle/Contents/MacOS/"
                          "AMDRadeonX5000MTLDriver",
                  "dyld_shared_cache_x86_64h.03", 0x10C50000U, 0x437EB3U, 0x7FFB10C50000ULL,
                  "dyld_shared_cache_x86_64h.03");
        locateOne(root26, "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2",
                  "dyld_shared_cache_x86_64h.03", 0x10B00000U, 0xB7850U, 0x7FFB10B00000ULL,
                  "dyld_shared_cache_x86_64h.03");
        locateOne(root26, "/System/Library/PrivateFrameworks/AppleGVA.framework/Versions/A/AppleGVA",
                  "dyld_shared_cache_x86_64h.02", 0xC57C000U, 0xEAD27U, 0x7FFA0C57C000ULL,
                  "dyld_shared_cache_x86_64h.02");
    }

    struct ResolverFixture
    {
        struct CacheEntry
        {
            char                    name[64]{};
            TestSupport::FileSource file{};
        };
        struct ImageEntry
        {
            char                    path[1024]{};
            TestSupport::FileSource file{};
        };

        char        root[1024]{};
        char        dyldDir[1024]{};
        CacheEntry  cache[8]{};
        uint32_t    cacheCount{0};
        ImageEntry  images[4]{};
        uint32_t    imageCount{0};

        static auto openCache(void* const context, const char* const name, NRedUserPatch::ByteSource& out) -> bool
        {
            auto* const self = static_cast<ResolverFixture*>(context);
            for (uint32_t index = 0; index < self->cacheCount; index++) {
                if (strcmp(self->cache[index].name, name) == 0) {
                    out = self->cache[index].file.source();
                    return true;
                }
            }
            if (self->cacheCount >= 8U) { return false; }
            char path[1200]{};
            snprintf(path, sizeof(path), "%s/%s", self->dyldDir, name);
            if (!TestSupport::openFixtureFile(path, self->cache[self->cacheCount].file)) { return false; }
            snprintf(self->cache[self->cacheCount].name, sizeof(self->cache[self->cacheCount].name), "%s", name);
            out = self->cache[self->cacheCount].file.source();
            self->cacheCount += 1U;
            return true;
        }

        static auto openImage(void* const context, const char* const imagePath, NRedUserPatch::ByteSource& out) -> bool
        {
            auto* const self = static_cast<ResolverFixture*>(context);
            for (uint32_t index = 0; index < self->imageCount; index++) {
                if (strcmp(self->images[index].path, imagePath) == 0) {
                    out = self->images[index].file.source();
                    return true;
                }
            }
            if (self->imageCount >= 4U) { return false; }
            char path[1200]{};
            snprintf(path, sizeof(path), "%s%s", self->root, imagePath);
            if (!TestSupport::openFixtureFile(path, self->images[self->imageCount].file)) { return false; }
            snprintf(self->images[self->imageCount].path, sizeof(self->images[self->imageCount].path), "%s", imagePath);
            out = self->images[self->imageCount].file.source();
            self->imageCount += 1U;
            return true;
        }
    };

    static const uint64_t kExpected15[] = {
        0x8160U,    0xE081U,    0x87B3164U, 0x87B3198U, 0x87EF51DU, 0x8606B96U, 0x8608449U,
        0x860F987U, 0x860FA49U, 0x860FACBU, 0x860FBD0U, 0x860FC69U, 0x864CAF5U, 0x864CB01U,
        0x864DF88U, 0x864F626U, 0x865082CU, 0x8667C65U, 0x867D770U,
    };

    static const uint64_t kExpected26[] = {
        0x81CAU,     0xE0C1U,     0x10C79708U, 0x10C7972AU, 0x10C56121U, 0x10B00F4EU, 0x10B024A9U,
        0x10B0DF5FU, 0x10B0E021U, 0x10B0E0A3U, 0x10B0E1A8U, 0x10B0E241U, 0x10B49C4FU, 0x10B49C5BU,
        0x10B4B0D4U, 0x10B4C71EU, 0x10B4D8E4U, 0x10B026F5U, 0x10B02B00U,
    };

    uint32_t resolveAll(const char* const root, const bool vdaEnabled, const bool expect26)
    {
        char dyldDir[1024]{};
        snprintf(dyldDir, sizeof(dyldDir), "%s/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld", root);
        char mainPath[1200]{};
        snprintf(mainPath, sizeof(mainPath), "%s/dyld_shared_cache_x86_64h", dyldDir);

        TestSupport::FileSource mainFile;
        if (!TestSupport::openFixtureFile(mainPath, mainFile)) {
            check(false, "resolver: open main cache");
            return 0;
        }

        ResolverFixture fixture{};
        snprintf(fixture.root, sizeof(fixture.root), "%s", root);
        snprintf(fixture.dyldDir, sizeof(fixture.dyldDir), "%s", dyldDir);

        auto mainSource = mainFile.source();
        NRedUserPatch::ResolveContext context{};
        context.mainCache    = &mainSource;
        context.openCache    = &ResolverFixture::openCache;
        context.openImage    = &ResolverFixture::openImage;
        context.openContext  = &fixture;
        NRedUserPatch::ResolveCache cache{};
        context.cache = &cache;
        context.runningFamily = NRedUserPatch::kFamilyVCN2;
        context.vdaEnabled   = vdaEnabled;

        uint32_t resolved = 0;
        for (uint32_t index = 0; index < NRedUserPatch::kRuleCount; index++) {
            const auto& rule = NRedUserPatch::kRules[index];
            if (!NRedUserPatch::ruleEnabled(rule, context.runningFamily, vdaEnabled)) { continue; }

            NRedUserPatch::ResolvedSite site{};
            const char* reason = nullptr;
            if (!NRedUserPatch::resolveRule(context, rule, site, &reason)) {
                printf("FAIL: rule %u unresolved: %s\n", rule.id, reason != nullptr ? reason : "?");
                failures += 1U;
                continue;
            }

            check(site.ruleId == rule.id, "resolved rule id");
            const uint64_t expected = expect26 ? kExpected26[rule.id] : kExpected15[rule.id];
            if (site.fileOffset != expected) {
                printf("FAIL: rule %u offset 0x%llx != 0x%llx\n", rule.id,
                       static_cast<unsigned long long>(site.fileOffset),
                       static_cast<unsigned long long>(expected));
                failures += 1U;
            }
            else {
                printf("ok: rule %u offset 0x%llx\n", rule.id, static_cast<unsigned long long>(site.fileOffset));
            }

            if (rule.id == 2) {
                check(expect26 ? (site.find[0] == 0x74 && site.find[1] == 0x28)
                               : (site.find[0] == 0x75 && site.find[1] == 0x0B),
                      "MTL gate variant");
            }
            if (rule.id == 3) {
                check(expect26 ? (site.find[0] == 0x0F && site.find[1] == 0x94 && site.find[2] == 0xC1)
                               : (site.find[0] == 0x0F && site.find[1] == 0x94 && site.find[2] == 0xC0),
                      "MTL allow variant");
            }
            resolved += 1U;
        }
        return resolved;
    }

    void testRuleGuards()
    {
        NRedUserPatch::RuleVariant variant{};
        NRedUserPatch::Rule        rule{};
        rule.familyMask   = NRedUserPatch::kFamilyVCN2;
        rule.imageKind    = NRedUserPatch::ImageKind::kSharedCache;
        rule.symbol       = "_unused";
        rule.variants     = &variant;
        rule.variantCount = 1U;

        NRedUserPatch::ResolveContext context{};
        context.runningFamily = NRedUserPatch::kFamilyVCN2;

        NRedUserPatch::ResolvedSite site{};
        const char*                 reason = nullptr;
        check(!NRedUserPatch::resolveRule(context, rule, site, &reason), "rule without image path rejected");
        check(reason != nullptr && strcmp(reason, "rule incomplete") == 0, "rule without image path reason");
    }

    void testRuleResolver(const char* const root15, const char* const root26)
    {
        check(NRedUserPatch::kRuleCount == 19U, "rule count");
        check(resolveAll(root15, false, false) == 5U, "default resolves 5 on 15.8.2");
        check(resolveAll(root15, true, false) == 19U, "VDA resolves 19 on 15.8.2");
        check(resolveAll(root26, false, true) == 5U, "default resolves 5 on 26.7.2");
        check(resolveAll(root26, true, true) == 19U, "VDA resolves 19 on 26.7.2");

        check(!NRedUserPatch::ruleEnabled(NRedUserPatch::kRules[0], 0x10U, false), "family gate rejects");
        check(NRedUserPatch::ruleEnabled(NRedUserPatch::kRules[0], NRedUserPatch::kFamilyVCN2, false),
              "family gate accepts");
        check(!NRedUserPatch::ruleEnabled(NRedUserPatch::kRules[5], NRedUserPatch::kFamilyVCN2, false),
              "VDA gate off");
        check(NRedUserPatch::ruleEnabled(NRedUserPatch::kRules[5], NRedUserPatch::kFamilyVCN2, true),
              "VDA gate on");
    }

}    // namespace

int main(int argc, char** argv)
{
    if (argc < 2) {
        printf("usage: %s <fixtures-root>\n", argv[0]);
        return 2;
    }

    char root15[1024];
    char root26[1024];
    snprintf(root15, sizeof(root15), "%s/15.8.2", argv[1]);
    snprintf(root26, sizeof(root26), "%s/26.7.2", argv[1]);

    testMachO(root15);
    testCacheLocator(root15, root26);
    testRuleGuards();
    testRuleResolver(root15, root26);

    printf("%s: %u failure(s)\n", failures == 0 ? "PASS" : "FAIL", failures);
    return failures == 0 ? 0 : 1;
}
