// NootedRedUserPatch site/chunk policy
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

#pragma once
#include <stdint.h>

namespace PatchPolicy
{

    // True when the site's bytes lie entirely inside the delivered chunk.  A site is only written
    // when it fits, so a chunk that starts or ends mid-page still patches the sites it fully
    // contains, while a site split across chunks waits for a later delivery.  Subtraction form
    // avoids overflow on chunk-relative arithmetic.
    inline auto siteFitsChunk(const uint64_t fileOffset, const uint64_t siteSize, const uint64_t chunkOffset,
                              const uint64_t chunkSize) -> bool
    {
        if (fileOffset < chunkOffset) { return false; }
        const uint64_t relative = fileOffset - chunkOffset;
        return relative <= chunkSize && siteSize <= chunkSize - relative;
    }

}    // namespace PatchPolicy
