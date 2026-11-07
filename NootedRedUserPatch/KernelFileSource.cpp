// NootedRedUserPatch kernel vnode ByteSource
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

#include <KernelFileSource.hpp>

namespace NRedUserPatch
{

    auto KernelFile::open(const char* const path) -> bool
    {
        this->close();
        if (path == nullptr) { return false; }
        strlcpy(this->path_, path, sizeof(this->path_));

        this->context_ = vfs_context_create(nullptr);
        if (this->context_ == nullptr) { return false; }

        vnode_t resolved = nullptr;
        if (vnode_lookup(path, 0, &resolved, this->context_) != 0 || resolved == nullptr) {
            this->close();
            return false;
        }
        this->vnode_ = resolved;
        this->size_   = FileIO::readFileSize(resolved, this->context_);
        if (this->size_ == 0) {
            this->close();
            return false;
        }
        return true;
    }

    void KernelFile::close()
    {
        if (this->vnode_ != nullptr) {
            vnode_put(this->vnode_);
            this->vnode_ = nullptr;
        }
        if (this->context_ != nullptr) {
            vfs_context_rele(this->context_);
            this->context_ = nullptr;
        }
        this->size_        = 0;
        this->blockOffset_ = 0;
        this->blockSize_   = 0;
        this->path_[0]     = '\0';
    }

    auto KernelFile::read(void* const context, const uint64_t offset, void* const destination, const size_t size)
        -> bool
    {
        auto* const self = static_cast<KernelFile*>(context);
        if (self == nullptr || self->vnode_ == nullptr || destination == nullptr) { return false; }
        if (offset > self->size_ || size > self->size_ - offset) { return false; }

        if (size > kBlockSize) {
            return FileIO::readFileData(destination, static_cast<off_t>(offset), size, self->vnode_, self->context_) == 0;
        }

        if (self->blockSize_ != 0U && offset >= self->blockOffset_ &&
            offset + size <= self->blockOffset_ + self->blockSize_) {
            memcpy(destination, self->block_ + (offset - self->blockOffset_), size);
            return true;
        }

        const uint64_t blockOffset = offset & ~static_cast<uint64_t>(kBlockSize - 1U);
        const uint64_t remaining   = self->size_ - blockOffset;
        const size_t   toRead      = remaining < kBlockSize ? static_cast<size_t>(remaining) : kBlockSize;
        if (FileIO::readFileData(self->block_, static_cast<off_t>(blockOffset), toRead, self->vnode_, self->context_) != 0) {
            return false;
        }
        self->blockOffset_ = blockOffset;
        self->blockSize_   = toRead;

        if (offset < blockOffset || offset + size > blockOffset + toRead) { return false; }
        memcpy(destination, self->block_ + (offset - blockOffset), size);
        return true;
    }

}    // namespace NRedUserPatch
