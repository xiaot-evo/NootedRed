// Host SiteSet tests
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

#include <Analyzer/AnalyzerTypes.hpp>
#include <SiteSet.hpp>

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

    auto beginWrite(void*) -> bool { return true; }
    void endWrite(void*) {}

    uint8_t find2[25]{};
    uint8_t replace2[25]{};

    void fillFind(uint8_t* const chunk)
    {
        memset(chunk, 0xCC, 0x1000);
        const uint8_t find0[] = {0xAA, 0xBB, 0xCC};
        const uint8_t find1[] = {0xDE, 0xAD, 0xBE, 0xEF};
        memcpy(chunk + 0x10, find0, sizeof(find0));
        memcpy(chunk + 0x20, find1, sizeof(find1));
        memcpy(chunk + 0x40, find2, sizeof(find2));
    }

}    // namespace

int main()
{
    static const uint8_t find0[]    = {0xAA, 0xBB, 0xCC};
    static const uint8_t replace0[] = {0x11, 0x22, 0x33};
    static const uint8_t find1[]    = {0xDE, 0xAD, 0xBE, 0xEF};
    static const uint8_t replace1[] = {0x01, 0x02, 0x03, 0x04};
    memset(find2, 0x5A, sizeof(find2));
    memset(replace2, 0xA5, sizeof(replace2));

    NRedUserPatch::ResolvedSite sites[3]{};
    snprintf(sites[0].vnodeName, sizeof(sites[0].vnodeName), "%s", "test");
    sites[0].fileOffset = 0x10;
    sites[0].find       = find0;
    sites[0].replace    = replace0;
    sites[0].size       = sizeof(find0);
    sites[0].ruleId     = 0;
    snprintf(sites[1].vnodeName, sizeof(sites[1].vnodeName), "%s", "test");
    sites[1].fileOffset = 0x20;
    sites[1].find       = find1;
    sites[1].replace    = replace1;
    sites[1].size       = sizeof(find1);
    sites[1].ruleId     = 1;
    snprintf(sites[2].vnodeName, sizeof(sites[2].vnodeName), "%s", "test");
    sites[2].fileOffset = 0x40;
    sites[2].find       = find2;
    sites[2].replace    = replace2;
    sites[2].size       = sizeof(find2);
    sites[2].ruleId     = 2;

    auto& set = NRedUserPatch::SiteSet::singleton();
    set.setWriter(&beginWrite, &endWrite, nullptr);
    set.publish(sites, 3);
    check(set.ready() && set.count() == 3U, "publish three sites");

    uint8_t chunk[0x1000]{};

    fillFind(chunk);
    check(set.apply("test", 0, chunk, sizeof(chunk)) == 3U, "apply writes all");
    check(memcmp(chunk + 0x10, replace0, sizeof(replace0)) == 0, "site 0 replaced");
    check(memcmp(chunk + 0x20, replace1, sizeof(replace1)) == 0, "site 1 replaced");
    check(memcmp(chunk + 0x40, replace2, sizeof(replace2)) == 0, "25-byte site replaced");

    check(set.apply("test", 0, chunk, sizeof(chunk)) == 0U, "apply is idempotent");
    check(set.alreadyPatched() == 3U, "already-patched counter");

    memset(chunk, 0xCC, sizeof(chunk));
    check(set.apply("test", 0, chunk, sizeof(chunk)) == 0U, "foreign bytes are not written");
    check(set.foreign() == 3U, "foreign counter");

    fillFind(chunk);
    check(set.apply("test", 0x12, chunk, 0x10) == 0U, "split chunk is not written");
    check(memcmp(chunk + 0x10, find0, sizeof(find0)) == 0, "split chunk bytes unchanged");

    fillFind(chunk);
    check(set.apply("test", 0, chunk, sizeof(chunk)) == 3U, "apply writes after split");
    check(set.applied() == 6U, "applied counter");

    printf("%s: %u failure(s)\n", failures == 0 ? "PASS" : "FAIL", failures);
    return failures == 0 ? 0 : 1;
}
