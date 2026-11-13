// NootedRedUserPatch fixture probe
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
#include <sys/stat.h>

using namespace NRedUserPatch;

namespace
{

    constexpr uint32_t kMaxCacheFiles = 8U;
    constexpr uint32_t kMaxImageFiles = 4U;

    struct ProbeFixture
    {
        char                     root[1024]{};
        char                     dyldDir[1024]{};
        TestSupport::FileSource  caches[kMaxCacheFiles]{};
        char                     cacheNames[kMaxCacheFiles][64]{};
        uint32_t                 cacheCount{0};
        TestSupport::FileSource  images[kMaxImageFiles]{};
        char                     imagePaths[kMaxImageFiles][256]{};
        uint32_t                 imageCount{0};
    };

    auto fileExists(const char* const path) -> bool
    {
        struct stat attributes {};
        return stat(path, &attributes) == 0 && attributes.st_size > 0;
    }

    auto openCache(void* const context, const char* const name, ByteSource& out) -> bool
    {
        auto* const self = static_cast<ProbeFixture*>(context);
        for (uint32_t index = 0; index < self->cacheCount; index++) {
            if (strcmp(self->cacheNames[index], name) == 0) {
                out = self->caches[index].source();
                return true;
            }
        }
        if (self->cacheCount >= kMaxCacheFiles) { return false; }

        char path[1200]{};
        snprintf(path, sizeof(path), "%s/%s", self->dyldDir, name);
        if (!TestSupport::openFixtureFile(path, self->caches[self->cacheCount])) { return false; }
        snprintf(self->cacheNames[self->cacheCount], sizeof(self->cacheNames[self->cacheCount]), "%s", name);
        out = self->caches[self->cacheCount].source();
        self->cacheCount += 1U;
        return true;
    }

    auto openImage(void* const context, const char* const imagePath, ByteSource& out) -> bool
    {
        auto* const self = static_cast<ProbeFixture*>(context);
        for (uint32_t index = 0; index < self->imageCount; index++) {
            if (strcmp(self->imagePaths[index], imagePath) == 0) {
                out = self->images[index].source();
                return true;
            }
        }
        if (self->imageCount >= kMaxImageFiles) { return false; }

        char path[1200]{};
        snprintf(path, sizeof(path), "%s%s", self->root, imagePath);
        if (!TestSupport::openFixtureFile(path, self->images[self->imageCount])) { return false; }
        snprintf(self->imagePaths[self->imageCount], sizeof(self->imagePaths[self->imageCount]), "%s", imagePath);
        out = self->images[self->imageCount].source();
        self->imageCount += 1U;
        return true;
    }

}    // namespace

int main(int argc, char** argv)
{
    if (argc < 2) {
        printf("usage: %s <fixture-root>\n", argv[0]);
        return 2;
    }

    char cryptexDir[1024]{};
    char systemDir[1024]{};
    char mainCryptex[1200]{};
    char mainSystem[1200]{};
    snprintf(cryptexDir, sizeof(cryptexDir), "%s/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld", argv[1]);
    snprintf(systemDir, sizeof(systemDir), "%s/System/Library/dyld", argv[1]);
    snprintf(mainCryptex, sizeof(mainCryptex), "%s/dyld_shared_cache_x86_64h", cryptexDir);
    snprintf(mainSystem, sizeof(mainSystem), "%s/dyld_shared_cache_x86_64h", systemDir);

    const char* mainPath = nullptr;
    if (fileExists(mainCryptex)) {
        mainPath = mainCryptex;
    }
    else if (fileExists(mainSystem)) {
        mainPath = mainSystem;
    }
    else {
        printf("FAIL: no main dyld cache under %s\n", argv[1]);
        return 1;
    }

    TestSupport::FileSource mainFile;
    if (!TestSupport::openFixtureFile(mainPath, mainFile)) {
        printf("FAIL: cannot open %s\n", mainPath);
        return 1;
    }

    ProbeFixture fixture{};
    snprintf(fixture.root, sizeof(fixture.root), "%s", argv[1]);
    const char* const dyldDir = mainPath == mainCryptex ? cryptexDir : systemDir;
    snprintf(fixture.dyldDir, sizeof(fixture.dyldDir), "%s", dyldDir);

    auto mainSource = mainFile.source();
    ResolveCache cache{};
    ResolveContext context{};
    context.mainCache     = &mainSource;
    context.openCache     = &openCache;
    context.openImage     = &openImage;
    context.openContext   = &fixture;
    context.cache         = &cache;
    context.runningFamily = kFamilyVCN2;
    context.vdaEnabled    = true;

    unsigned resolved = 0;
    for (uint32_t index = 0; index < kRuleCount; index++) {
        const Rule& rule = kRules[index];
        ResolvedSite site{};
        const char* reason = nullptr;
        if (!ruleEnabled(rule, context.runningFamily, context.vdaEnabled)) {
            printf("rule %2u SKIP (gate)\n", rule.id);
            continue;
        }
        if (!resolveRule(context, rule, site, &reason)) {
            printf("rule %2u UNRESOLVED: %s\n", rule.id, reason != nullptr ? reason : "?");
            continue;
        }
        resolved += 1U;
        printf("rule %2u RESOLVED off=0x%llx vnode=%s\n", rule.id,
               static_cast<unsigned long long>(site.fileOffset), site.vnodeName);
    }

    printf("summary: %u/%u resolved (family 0x%X, VDA 1)\n", resolved, kRuleCount,
           static_cast<unsigned>(context.runningFamily));
    return resolved == kRuleCount ? 0 : 1;
}
