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

#include <VCNRuntimeResolver.hpp>

#include <Headers/kern_util.hpp>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <string.h>

namespace
{

    constexpr char kTable5000[] = "__ZTV32AMDRadeonX5000_AMDVega10Hardware";
    constexpr char kTable6000[] = "__ZTV32AMDRadeonX6000_AMDNavi10Hardware";
    constexpr char kSignal[] = "__ZN26AMDRadeonX6000_AMDHardware22signalGPUWorkSubmittedEv";
    constexpr char kChannelPrefix[] = "__ZN27AMDRadeonX6000_AMDHWChannel";
    constexpr char kChannelWait[] = "__ZN27AMDRadeonX6000_AMDHWChannel11waitForIdleEj";
    constexpr char kEngineWait[] = "__ZN26AMDRadeonX6000_AMDHWEngine11waitForIdleEj";
    constexpr char kVideoSuspend[] = "__ZN36AMDRadeonX6000_AMDNavi10VideoContext21setSuspendResumeStateEb";
    constexpr char kEngineIdle[] = "__ZN30AMDRadeonX6000_AMDVCN2HWEngine6isIdleEv";

    struct GuardSpec
    {
        UInt32      slot;
        const char* method;
        UInt32      getterSize;
    };

    constexpr GuardSpec kGuards5000[] = {
        {0x298, "__ZN26AMDRadeonX5000_AMDHardware13isDeviceValidEv", 0},
        {0x2A8, nullptr, 12},
        {0x3B8, nullptr, 13},
        {0x3C8, nullptr, 12},
        {0x3E8, "__ZN28AMDRadeonX5000_AMDRTHardware13disableGfxOffEv", 0},
        {0x3F0, "__ZN28AMDRadeonX5000_AMDRTHardware12enableGfxOffEv", 0},
    };

    constexpr GuardSpec kGuards6000[] = {
        {0x2A0, "__ZN26AMDRadeonX6000_AMDHardware13isDeviceValidEv", 0},
        {0x2B0, nullptr, 12},
        {0x3B0, nullptr, 13},
        {0x3C0, nullptr, 12},
        {0x3E0, "__ZN28AMDRadeonX6000_AMDRTHardware13disableGfxOffEv", 0},
        {0x3E8, "__ZN28AMDRadeonX6000_AMDRTHardware12enableGfxOffEv", 0},
    };

    constexpr const char* kCallSymbols[] = {
        "__ZN26AMDRadeonX6000_AMDHWEngine11waitForIdleEj",
        "__ZN27AMDRadeonX6000_AMDHWChannel11waitForIdleEj",
        "__ZN27AMDRadeonX6000_AMDHWChannel14waitForHwStampEj",
        "__ZN27AMDRadeonX6000_AMDHWChannel16timestampUpdatedEv",
        "__ZN27AMDRadeonX6000_AMDHWChannel19submitCommandBufferEP30AMD_SUBMIT_COMMAND_BUFFER_INFO",
        "__ZN27AMDRadeonX6000_AMDHWChannel20writeDiagnosisReportERPcRj",
        "__ZN27AMDRadeonX6000_AMDHWChannel24enableTimestampInterruptEv",
        "__ZN27AMDRadeonX6000_AMDHWChannel4initEiP30AMDRadeonX6000_IAMDHWInterfaceP27AMDRadeonX6000_IAMDHWEngineP25AMDRadeonX6000_IAMDHWRingPKc",
        "__ZN27AMDRadeonX6000_AMDHWChannel5resetEv",
        "__ZN30AMDRadeonX6000_AMDVCN2HWEngine6isIdleEv",
        "__ZN36AMDRadeonX6000_AMDNavi10VideoContext21setSuspendResumeStateEb",
    };

    constexpr UInt32 kExpectedCalls = 20;

    UInt32 newSlotFor(const UInt32 slot)
    {
        switch (slot) {
            case 0x2A0: return 0x298;
            case 0x2B0: return 0x2A8;
            case 0x3B0: return 0x3B8;
            case 0x3C0: return 0x3C8;
            case 0x3E0: return 0x3E8;
            case 0x3E8: return 0x3F0;
            case 0x230: return 0;
            default: return 0xFFFFFFFFU;
        }
    }

    // Derive the real function end from the loaded kext Mach-O symbol table.
    // This avoids both truncating at the first ret and scanning into the next
    // function; there is no static size table.
    UInt32 functionExtent(const mach_vm_address_t slide, const size_t size, const mach_vm_address_t function)
    {
        const auto* const header = reinterpret_cast<const mach_header_64*>(slide);
        if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_X86_64) {
            DBGLOG("VCNRuntime", "mach header mismatch slide=%llx magic=%x cputype=%x",
                   static_cast<unsigned long long>(slide), header->magic, header->cputype);
            return 0;
        }

        const auto* command = reinterpret_cast<const load_command*>(header + 1);
        const auto* const commandEnd = reinterpret_cast<const UInt8*>(header) + sizeof(*header) + header->sizeofcmds;
        UInt64 textVmaddr = 0;
        UInt64 linkeditVmaddr = 0;
        UInt64 linkeditFileoff = 0;
        UInt32 symoff = 0;
        UInt32 nsyms = 0;
        bool   haveText = false;
        bool   haveLinkedit = false;
        bool   haveSymtab = false;

        for (UInt32 i = 0; i < header->ncmds; ++i) {
            if (reinterpret_cast<const UInt8*>(command) + sizeof(*command) > commandEnd) { return 0; }
            if (command->cmdsize < sizeof(*command)) { return 0; }

            if (command->cmd == LC_SEGMENT_64) {
                const auto* const segment = reinterpret_cast<const segment_command_64*>(command);
                if (strcmp(segment->segname, "__TEXT") == 0) {
                    textVmaddr = segment->vmaddr;
                    haveText = true;
                }
                else if (strcmp(segment->segname, "__LINKEDIT") == 0) {
                    linkeditVmaddr = segment->vmaddr;
                    linkeditFileoff = segment->fileoff;
                    haveLinkedit = true;
                }
            }
            else if (command->cmd == LC_SYMTAB) {
                const auto* const symtab = reinterpret_cast<const symtab_command*>(command);
                symoff = symtab->symoff;
                nsyms = symtab->nsyms;
                haveSymtab = true;
            }

            command = reinterpret_cast<const load_command*>(reinterpret_cast<const UInt8*>(command)
                                                             + command->cmdsize);
        }

        DBGLOG("VCNRuntime", "mh slide=%llx size=%llu text=%llx link=%llx fileoff=%llx symoff=%x nsyms=%u",
               static_cast<unsigned long long>(slide), static_cast<unsigned long long>(size),
               static_cast<unsigned long long>(textVmaddr), static_cast<unsigned long long>(linkeditVmaddr),
               static_cast<unsigned long long>(linkeditFileoff), symoff, nsyms);

        if (!haveText || !haveLinkedit || !haveSymtab || nsyms > 0x10000) { return 0; }

        const auto loadSlide = slide - textVmaddr;
        if (symoff < linkeditFileoff) { return 0; }
        const auto symbolsAddress = loadSlide + linkeditVmaddr + (symoff - linkeditFileoff);
        DBGLOG("VCNRuntime", "symbols address=%llx loadSlide=%llx",
               static_cast<unsigned long long>(symbolsAddress), static_cast<unsigned long long>(loadSlide));
        if (symbolsAddress == 0) { return 0; }

        const auto* const symbols = reinterpret_cast<const nlist_64*>(symbolsAddress);
        UInt64 next = 0;
        for (UInt32 i = 0; i < nsyms; ++i) {
            const auto& symbol = symbols[i];
            if ((symbol.n_type & N_STAB) != 0 || (symbol.n_type & N_TYPE) != N_SECT || symbol.n_sect == 0) {
                continue;
            }
            const auto address = loadSlide + symbol.n_value;
            if (address <= function || address < slide || address - slide > size) { continue; }
            if (next == 0 || address < next) { next = address; }
        }

        if (next == 0 || next <= function) { return 0; }
        const auto extent = next - function;
        if (extent > 0x10000 || extent > size) { return 0; }
        return static_cast<UInt32>(extent);
    }

    bool isChannel(const char* const symbol)
    {
        return strncmp(symbol, kChannelPrefix, sizeof(kChannelPrefix) - 1) == 0;
    }

    bool named(const char* const symbol, const char* const expected)
    {
        return strcmp(symbol, expected) == 0;
    }

    mach_vm_address_t solve(KernelPatcher& patcher, const size_t id, const char* const name,
                            const mach_vm_address_t slide, const size_t size)
    {
        const auto address = patcher.solveSymbol(id, name, slide, size);
        if (patcher.getError() != KernelPatcher::Error::NoError) {
            patcher.clearError();
            return 0;
        }
        return address;
    }

    struct Resolver
    {
        VCNData::CallPatch calls[VCNData::kMaxCallPatches]{};
        VCNData::SlotGuard  guards5000[6]{};
        VCNData::SlotGuard  guards6000[6]{};
        UInt8               getters5000[3][32]{};
        UInt8               getters6000[3][32]{};
        VCNData::Variant    data{};

        bool   ready5000{false};
        bool   ready6000{false};
        UInt32 failureStage{0};
        UInt32 callCount{0};
        UInt32 seenCalls{0};
        UInt32 diagCounters[4]{};

        void initVariant()
        {
            data.id                  = 0;
            data.build               = "runtime";
            data.darwinMajor         = 0;
            data.darwinMinor         = 0;
            data.sourceDescription   = "runtime VCN resolver";
            data.callPatches         = this->calls;
            data.callPatchCount      = 0;
            data.guards5000          = this->guards5000;
            data.guard5000Count      = 0;
            data.guards6000          = this->guards6000;
            data.guard6000Count      = 0;
            data.table5000           = kTable5000;
            data.table6000           = kTable6000;
            data.signalSymbol        = kSignal;
            data.hasKernelIdentity   = false;
            data.kernelCollectionUUID = "";
            data.driverUUID5000      = "";
            data.driverUUID6000      = "";
            data.driverVersion5000   = "";
            data.driverVersion6000   = "";
            data.driverSHA256_5000   = "";
            data.driverSHA256_6000   = "";
        }

        bool guard(KernelPatcher& patcher, const size_t id, const mach_vm_address_t slide, const size_t size,
                   const char* const tableSymbol, const GuardSpec* const specs, const UInt32 count,
                   VCNData::SlotGuard* const guards, UInt8 getters[3][32])
        {
            const auto table = solve(patcher, id, tableSymbol, slide, size);
            if (table == 0) { return false; }

            UInt32 getterIndex = 0;
            for (UInt32 i = 0; i < count; ++i) {
                const auto offset = 2 * sizeof(void*) + specs[i].slot;
                if (offset > size - sizeof(void*)) { return false; }
                mach_vm_address_t target = 0;
                memcpy(&target, reinterpret_cast<void*>(table + offset), sizeof(target));
                if (target < slide || target - slide >= size) { return false; }

                guards[i].slot         = specs[i].slot;
                guards[i].methodSymbol = specs[i].method;
                guards[i].getter       = nullptr;
                guards[i].getterSize   = 0;

                if (specs[i].method != nullptr) {
                    const auto method = solve(patcher, id, specs[i].method, slide, size);
                    if (method == 0 || method != target) { return false; }
                }
                else {
                    if (getterIndex >= 3 || specs[i].getterSize > sizeof(getters[0])) { return false; }
                    memcpy(getters[getterIndex], reinterpret_cast<void*>(target), specs[i].getterSize);
                    guards[i].getter     = getters[getterIndex];
                    guards[i].getterSize = specs[i].getterSize;
                    ++getterIndex;
                }
            }
            return getterIndex == 3;
        }

        bool callsFromX6000(KernelPatcher& patcher, const size_t id, const mach_vm_address_t slide,
                            const size_t size)
        {
            UInt32 count = 0;
            for (UInt32 symbolIndex = 0; symbolIndex < arrsize(kCallSymbols); ++symbolIndex) {
                const auto* const symbol = kCallSymbols[symbolIndex];
                const auto function = solve(patcher, id, symbol, slide, size);
                if (function == 0) {
                    SYSLOG("VCN", "symbol[%u] %s resolve failed", symbolIndex, symbol);
                    this->failureStage = 10 + symbolIndex;
                    return false;
                }
                const auto limit = functionExtent(slide, size, function);
                if (limit == 0) {
                    this->failureStage = 20 + symbolIndex;
                    return false;
                }
                const auto* const bytes = reinterpret_cast<const UInt8*>(function);
                const auto beforeSeen  = this->seenCalls;
                (void)beforeSeen;
                DBGLOG("VCNRuntime", "symbol[%u] solve=%llx extent=%u", symbolIndex,
                       static_cast<unsigned long long>(function), limit);

                for (UInt32 offset = 3; offset + 6 <= limit; ++offset) {
                    if (bytes[offset] != 0xFF || bytes[offset + 1] != 0x90) { continue; }
                    ++this->seenCalls;
                    UInt32 slot = 0;
                    memcpy(&slot, bytes + offset + 2, sizeof(slot));
                    const auto newSlot = newSlotFor(slot);
                    if (newSlot == 0xFFFFFFFFU) {
                        ++this->diagCounters[0];
                        continue;
                    }
                    if (memcmp(bytes + offset - 3, "\x48\x8B\x07", 3) != 0) {
                        ++this->diagCounters[1];
                        continue;
                    }

                    bool isWait = false;
                    if (isChannel(symbol) && (slot == 0x2A0 || slot == 0x3B0 || slot == 0x3C0 || slot == 0x230)) {
                        // channel call site
                    }
                    else if (named(symbol, kChannelWait) || named(symbol, kEngineWait)) {
                        if (slot != 0x3E0 && slot != 0x3E8) { continue; }
                        isWait = true;
                    }
                    else if (named(symbol, kEngineIdle) && slot == 0x2A0) {
                    }
                    else if (named(symbol, kVideoSuspend) && slot == 0x2B0) {
                    }
                    else {
                        ++this->diagCounters[2];
                        continue;
                    }

                    if (isWait) {
                        const bool engine = named(symbol, kEngineWait);
                        const auto receiver = bytes[offset - 7] == 0x48 && bytes[offset - 6] == 0x8B
                                              && (bytes[offset - 5] == 0x7F || bytes[offset - 5] == 0x7B)
                                              && bytes[offset - 4] == (engine ? 0x18 : 0x20);
                        if (!receiver) {
                            ++this->diagCounters[3];
                            continue;
                        }
                    }

                    if (count >= VCNData::kMaxCallPatches) { return false; }
                    auto& patch   = this->calls[count++];
                    patch.symbol  = symbol;
                    patch.offset  = offset;
                    memcpy(patch.original, bytes + offset, sizeof(patch.original));
                    patch.newSlot = newSlot;
                }
                DBGLOG("VCNRuntime", "symbol[%u] solve=%llx seen=%u", symbolIndex,
                       static_cast<unsigned long long>(function), this->seenCalls - beforeSeen);
            }
            this->callCount = count;
            if (count != kExpectedCalls) {
                DBGLOG("VCNRuntime", "rejects slot=%u vtable=%u class=%u receiver=%u", this->diagCounters[0],
                       this->diagCounters[1], this->diagCounters[2], this->diagCounters[3]);
                SYSLOG("VCN", "runtime resolver found %u call sites, expected %u", count, kExpectedCalls);
                return false;
            }
            this->data.callPatchCount = count;
            return true;
        }
    };

    Resolver& resolver()
    {
        static Resolver instance;
        return instance;
    }

}    // namespace

bool VCNRuntime::prepare5000(KernelPatcher& patcher, const size_t id, const mach_vm_address_t slide,
                             const size_t size)
{
    auto& r = resolver();
    if (r.ready5000) { return true; }
    r.initVariant();
    if (!r.guard(patcher, id, slide, size, kTable5000, kGuards5000, arrsize(kGuards5000), r.guards5000,
                 r.getters5000))
    {
        r.failureStage = 1;
        SYSLOG("VCN", "runtime resolver failed X5000 guard table");
        return false;
    }
    r.data.guard5000Count = arrsize(kGuards5000);
    r.ready5000           = true;
    DBGLOG("VCNRuntime", "X5000 guards resolved");
    return true;
}

bool VCNRuntime::prepare6000(KernelPatcher& patcher, const size_t id, const mach_vm_address_t slide,
                             const size_t size)
{
    auto& r = resolver();
    if (r.ready6000) { return true; }
    if (!r.ready5000) { return false; }
    if (!r.guard(patcher, id, slide, size, kTable6000, kGuards6000, arrsize(kGuards6000), r.guards6000,
                 r.getters6000))
    {
        r.failureStage = 2;
        SYSLOG("VCN", "runtime resolver failed X6000 guard table");
        return false;
    }
    r.data.guard6000Count = arrsize(kGuards6000);
    if (!r.callsFromX6000(patcher, id, slide, size)) {
        if (r.failureStage == 0) { r.failureStage = 3; }
        return false;
    }
    r.ready6000 = true;
    DBGLOG("VCNRuntime", "X6000 tables resolved: %u calls", r.callCount);
    return true;
}

bool VCNRuntime::have5000() { return resolver().ready5000; }

bool VCNRuntime::have6000() { return resolver().ready6000; }

UInt32 VCNRuntime::failure() { return resolver().failureStage; }

UInt32 VCNRuntime::callCount() { return resolver().callCount; }

UInt32 VCNRuntime::seenCalls() { return resolver().seenCalls; }

UInt32 VCNRuntime::diag(const UInt32 index) { return index < 4 ? resolver().diagCounters[index] : 0; }

const VCNData::Variant* VCNRuntime::variant() { return &resolver().data; }
