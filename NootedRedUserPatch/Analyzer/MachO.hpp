// NootedRedUserPatch minimal Mach-O parser
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

    // The subset of the Mach-O header the resolver needs.  `fileBase` is the file offset of the
    // Mach-O header inside the source (0 for a standalone file, the image's __TEXT file offset for a
    // dyld subcache image).  Symbol/function/export offsets are file offsets inside the subcache or
    // standalone file, not VAs.
    struct MachOImage
    {
        uint64_t fileBase{0};
        uint64_t loadAddress{0};
        uint64_t textVmAddr{0};
        uint64_t textFileOffset{0};
        uint64_t textSize{0};
        uint64_t imageVaEnd{0};
        uint64_t linkeditVmAddr{0};
        uint64_t linkeditFileOffset{0};
        uint32_t symoff{0};
        uint32_t nsyms{0};
        uint32_t stroff{0};
        uint32_t strsize{0};
        uint32_t functionStartsOffset{0};
        uint32_t functionStartsSize{0};
        uint32_t exportTrieOffset{0};
        uint32_t exportTrieSize{0};
    };

    // Parses the header and the load commands.  Returns false on any malformed input (bad magic,
    // absurd counts, command overrun, missing __TEXT).  Never allocates and never reads outside the
    // ByteSource's declared bounds.  `source` is the file containing the Mach-O header (the image's
    // __TEXT subcache for a cache image, or the standalone file).
    auto parseMachO(const ByteSource& source, uint64_t imageFileBase, uint64_t loadAddress, uint64_t textSize,
                    MachOImage& out) -> bool;

    // Symbol/function lookups read __LINKEDIT, which may live in a different subcache than __TEXT.
    // `linkedit` must therefore be the file that contains the image's __LINKEDIT segment; symoff,
    // stroff, functionStartsOffset and exportTrieOffset are file offsets inside that source.
    // findSymbol tries the export trie first, then scans nlist entries whose n_value is inside the
    // image's text range.  It fails closed on a missing or ambiguous symbol.
    auto findSymbol(const ByteSource& linkedit, const MachOImage& image, const char* name, uint64_t& outVa)
        -> bool;

    // Returns [start, end) of the function containing `va` from LC_FUNCTION_STARTS.  The starts are
    // streamed, not stored; `end` is the next start or imageVaEnd for the last function.
    auto functionRange(const ByteSource& linkedit, const MachOImage& image, uint64_t va, uint64_t& start,
                       uint64_t& end) -> bool;

}    // namespace NRedUserPatch
