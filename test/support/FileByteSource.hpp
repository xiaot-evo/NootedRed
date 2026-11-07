// Host file-backed ByteSource for the analyzer tests
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
#include <stdio.h>
#include <sys/stat.h>

namespace TestSupport
{

    struct FileSource
    {
        FILE*    file{nullptr};
        uint64_t size{0};

        FileSource() = default;
        FileSource(const FileSource&) = delete;
        auto operator=(const FileSource&) -> FileSource& = delete;

        ~FileSource()
        {
            if (this->file != nullptr) { fclose(this->file); }
        }

        static auto read(void* const context, const uint64_t offset, void* const destination,
                         const size_t size) -> bool
        {
            auto* const self = static_cast<FileSource*>(context);
            if (self == nullptr || self->file == nullptr || offset > self->size) { return false; }
            if (size > self->size - offset) { return false; }
            if (fseeko(self->file, static_cast<off_t>(offset), SEEK_SET) != 0) { return false; }
            return fread(destination, 1, size, self->file) == size;
        }

        auto source() -> NRedUserPatch::ByteSource { return {&FileSource::read, this}; }
    };

    inline auto openFixtureFile(const char* const path, FileSource& out) -> bool
    {
        struct stat attributes {};
        if (path == nullptr || stat(path, &attributes) != 0 || attributes.st_size <= 0) { return false; }
        FILE* const file = fopen(path, "rb");
        if (file == nullptr) { return false; }
        out.file = file;
        out.size = static_cast<uint64_t>(attributes.st_size);
        return true;
    }

}    // namespace TestSupport
