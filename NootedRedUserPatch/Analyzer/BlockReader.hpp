// NootedRedUserPatch block reader
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
#include <string.h>

namespace NRedUserPatch
{

    // Small block cache over a random-access reader.  The analyzer asks for 1-4 KiB at a time and
    // often revisits the same string-table region; a 16 KiB cache turns the export-trie/nlist byte
    // walks into a handful of reads.  A request that crosses the cached block is read directly;
    // never fail it just because it straddles the boundary.
    class BlockReader
    {
    public:
        using ReadFn = bool (*)(void* context, uint64_t offset, void* destination, size_t size);

        static constexpr size_t kBlockSize = 0x4000U;

        BlockReader() = default;
        BlockReader(const BlockReader&) = delete;
        auto operator=(const BlockReader&) -> BlockReader& = delete;

        void reset(uint64_t size, ReadFn read, void* context)
        {
            this->size_        = size;
            this->read_        = read;
            this->context_     = context;
            this->blockOffset_ = 0;
            this->blockSize_   = 0;
        }

        auto read(uint64_t offset, void* destination, size_t size) -> bool
        {
            if (this->read_ == nullptr || destination == nullptr) { return false; }
            if (offset > this->size_ || size > this->size_ - offset) { return false; }

            if (size > kBlockSize) { return this->read_(this->context_, offset, destination, size); }

            if (this->blockSize_ != 0U && offset >= this->blockOffset_ &&
                offset + size <= this->blockOffset_ + this->blockSize_) {
                memcpy(destination, this->block_ + (offset - this->blockOffset_), size);
                return true;
            }

            const uint64_t blockOffset = offset & ~static_cast<uint64_t>(kBlockSize - 1U);
            if (offset + size > blockOffset + kBlockSize) {
                return this->read_(this->context_, offset, destination, size);
            }

            const uint64_t remaining = this->size_ - blockOffset;
            const size_t   toRead    = remaining < kBlockSize ? static_cast<size_t>(remaining) : kBlockSize;
            if (!this->read_(this->context_, blockOffset, this->block_, toRead)) { return false; }
            this->blockOffset_ = blockOffset;
            this->blockSize_   = toRead;

            if (offset < blockOffset || offset + size > blockOffset + toRead) { return false; }
            memcpy(destination, this->block_ + (offset - blockOffset), size);
            return true;
        }

    private:
        ReadFn   read_{nullptr};
        void*    context_{nullptr};
        uint64_t size_{0};
        uint8_t  block_[kBlockSize]{};
        uint64_t blockOffset_{0};
        size_t   blockSize_{0};
    };

}    // namespace NRedUserPatch
