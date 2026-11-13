// Host BlockReader tests
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

#include <Analyzer/BlockReader.hpp>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

namespace
{

    uint8_t  g_data[0x51900];    // 20 full blocks plus a 0x1900-byte tail
    uint32_t g_reads      = 0;
    uint32_t g_failures   = 0;
    bool     g_failing    = false;

    void check(const bool condition, const char* const what)
    {
        if (!condition) {
            printf("FAIL: %s\n", what);
            g_failures += 1U;
        }
        else {
            printf("ok: %s\n", what);
        }
    }

    auto backing(void*, const uint64_t offset, void* const destination, const size_t size) -> bool
    {
        if (g_failing) { return false; }
        if (offset > sizeof(g_data) || size > sizeof(g_data) - offset) { return false; }
        memcpy(destination, g_data + offset, size);
        g_reads += 1U;
        return true;
    }

}    // namespace

int main()
{
    for (size_t index = 0; index < sizeof(g_data); index++) {
        g_data[index] = static_cast<uint8_t>((index * 31U) & 0xFFU);
    }

    NRedUserPatch::BlockReader reader;
    reader.reset(sizeof(g_data), &backing, nullptr);

    uint8_t buffer[0x5000]{};
    check(reader.read(0x100, buffer, 0x20) && memcmp(buffer, g_data + 0x100, 0x20) == 0, "read inside block");
    const uint32_t readsAfterMiss = g_reads;
    check(reader.read(0x110, buffer, 0x10) && memcmp(buffer, g_data + 0x110, 0x10) == 0, "cached read");
    check(g_reads == readsAfterMiss, "cache hit does not read backing");

    check(reader.read(0x3FF8, buffer, 0x10) && memcmp(buffer, g_data + 0x3FF8, 0x10) == 0, "cross-block read");
    check(reader.read(0x4000, buffer, 0x20) && memcmp(buffer, g_data + 0x4000, 0x20) == 0, "next block read");
    check(reader.read(0x8000, buffer, 0x20) && memcmp(buffer, g_data + 0x8000, 0x20) == 0, "later block read");
    check(reader.read(0x100, buffer, 0x4001) && memcmp(buffer, g_data + 0x100, 0x4001) == 0,
          "read larger than block");

    check(!reader.read(sizeof(g_data) - 4U, buffer, 8), "read past end rejected");
    check(!reader.read(sizeof(g_data) + 1U, buffer, 1), "offset past end rejected");
    check(reader.read(sizeof(g_data) - 8U, buffer, 8) && memcmp(buffer, g_data + sizeof(g_data) - 8U, 8) == 0,
          "read at end");
    check(reader.read(0x51000, buffer, 0x100) && memcmp(buffer, g_data + 0x51000, 0x100) == 0,
          "read inside short final block");
    check(reader.read(0x4FFF8, buffer, 0x10) && memcmp(buffer, g_data + 0x4FFF8, 0x10) == 0,
          "cross-block read into short final block");

    g_failing = true;
    check(!reader.read(0x10000, buffer, 0x10), "backing failure rejected");
    g_failing = false;
    check(reader.read(0x10000, buffer, 0x10) && memcmp(buffer, g_data + 0x10000, 0x10) == 0,
          "read after backing failure");

    reader.reset(0, nullptr, nullptr);
    check(!reader.read(0, buffer, 1), "reset reader rejects reads");

    printf("%s: %u failure(s)\n", g_failures == 0 ? "PASS" : "FAIL", g_failures);
    return g_failures == 0 ? 0 : 1;
}
