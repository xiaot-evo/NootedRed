// NootedRedUserPatch byte source abstraction
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
#include <stddef.h>
#include <stdint.h>

namespace NRedUserPatch
{

    // A bounded random-access reader.  The host test backs it with a FILE; the satellite backs it
    // with a vnode + vfs_context_t and FileIO::readFileData.  `read` must return false on any short
    // read or out-of-range request; the parser treats that as malformed input and fails closed.
    struct ByteSource
    {
        using ReadFn = bool (*)(void* context, uint64_t offset, void* destination, size_t size);

        ReadFn read{nullptr};
        void*  context{nullptr};

        auto readAt(const uint64_t offset, void* const destination, const size_t size) const -> bool
        {
            return this->read != nullptr && this->read(this->context, offset, destination, size);
        }
    };

}    // namespace NRedUserPatch
