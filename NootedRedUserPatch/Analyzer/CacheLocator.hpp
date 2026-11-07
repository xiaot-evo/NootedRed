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

#pragma once
#include <Analyzer/ByteSource.hpp>
#include <stdint.h>

namespace NRedUserPatch
{

    // Opens a dyld subcache file by basename (e.g. "dyld_shared_cache_x86_64h.03").  The returned
    // ByteSource must stay valid until the caller finishes with the located image; the opener owns
    // the underlying file/vnode.
    using OpenCacheFn = bool (*)(void* context, const char* subcacheName, ByteSource& out);

    struct LocatedImage
    {
        char     vnodeName[64]{};          // __TEXT subcache basename
        char     linkeditVnodeName[64]{};  // subcache that contains __LINKEDIT
        uint64_t fileOffset{0};            // __TEXT file offset inside vnodeName
        uint64_t textSize{0};
        uint64_t loadAddress{0};           // unslid VA of the image
        uint64_t linkeditVmAddr{0};
        uint64_t linkeditFileOffset{0};
    };

    // Locates an image by its dyld path in the main cache's imagesText table, then maps its load
    // address to the owning subcache via that subcache's mapping table.  The subcache list comes
    // from the main header's subCacheArray; if it is absent, .01-.06 are probed.  __LINKEDIT is
    // resolved separately because it may live in a different subcache than __TEXT.
    auto locateCacheImage(const ByteSource& mainCache, OpenCacheFn open, void* openContext, const char* imagePath,
                          LocatedImage& out) -> bool;

}    // namespace NRedUserPatch
