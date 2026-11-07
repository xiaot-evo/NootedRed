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

}    // namespace

int main(int argc, char** argv)
{
    if (argc < 2) {
        printf("usage: %s <fixture-root>\n", argv[0]);
        return 2;
    }

    const char* const root = argv[1];
    char              path[1024];

    makePath(path, sizeof(path), root,
             "System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver");

    TestSupport::FileSource file;
    check(TestSupport::openFixtureFile(path, file), "open standalone GL driver");
    if (file.file != nullptr) {
        auto source = file.source();
        uint8_t magic[4]{};
        check(source.readAt(0, magic, sizeof(magic)), "read Mach-O magic");
        check(magic[0] == 0xCF && magic[1] == 0xFA && magic[2] == 0xED && magic[3] == 0xFE,
              "GL driver has MH_MAGIC_64");
    }

    printf("%s: %u failure(s)\n", failures == 0 ? "PASS" : "FAIL", failures);
    return failures == 0 ? 0 : 1;
}
