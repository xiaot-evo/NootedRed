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

#pragma once
#include <Analyzer/BlockReader.hpp>
#include <Analyzer/ByteSource.hpp>
#include <Headers/kern_file.hpp>
#include <stdint.h>
#include <string.h>
#include <sys/vnode.h>

namespace NRedUserPatch
{

    // Sleepable vnode reader with a small block cache.  The analyzer asks for 1-4 KiB at a time and
    // often revisits the same string-table region; a 16 KiB cache turns the export-trie/nlist byte
    // walks into a handful of VNOP_READs instead of thousands.  Used only in the analyzer thread.
    class KernelFile
    {
    public:
        static constexpr size_t kMaxPath = 256U;

        // Trivially destructible: the analyzer calls close() explicitly, and a non-trivial destructor
        // would force a local-static guard that the kernel does not support.
        KernelFile() = default;
        KernelFile(const KernelFile&) = delete;
        auto operator=(const KernelFile&) -> KernelFile& = delete;

        auto open(const char* path) -> bool;
        void close();
        auto valid() const -> bool { return this->vnode_ != nullptr; }
        auto path() const -> const char* { return this->path_; }
        auto source() -> ByteSource { return {&KernelFile::read, this}; }

    private:
        static auto read(void* context, uint64_t offset, void* destination, size_t size) -> bool;
        static auto readBacking(void* context, uint64_t offset, void* destination, size_t size) -> bool;

        vnode_t        vnode_{nullptr};
        vfs_context_t  context_{nullptr};
        uint64_t       size_{0};
        char           path_[kMaxPath]{};
        BlockReader    reader_{};
    };

}    // namespace NRedUserPatch
