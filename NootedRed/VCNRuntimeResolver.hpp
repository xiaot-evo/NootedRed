// VCN kernel bridge runtime resolver
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
#include <Headers/kern_patcher.hpp>
#include <VCNData.hpp>
#include <libkern/OSTypes.h>

// The only source of VCN bridge tables: parse the live X5000/X6000 kexts after
// their symbols are resolvable. There is no embedded Variant and no fallback.
namespace VCNRuntime
{
    bool prepare5000(KernelPatcher& patcher, size_t id, mach_vm_address_t slide, size_t size);
    bool prepare6000(KernelPatcher& patcher, size_t id, mach_vm_address_t slide, size_t size);

    bool have5000();
    bool have6000();
    UInt32 failure();
    UInt32 callCount();
    UInt32 seenCalls();
    UInt32 diag(UInt32 index);

    const VCNData::Variant* variant();
}    // namespace VCNRuntime
