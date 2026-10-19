#!/usr/bin/env python3
# VCN kernel bridge data generator
#
# Copyright (C) 2022-2026  ChefKiss.
#
# Licensed under the ChefKiss Open Knowledge License version 1.
#
# This work is licensed to you under the terms of the ChefKiss Open Knowledge
# License, either version 1 of the License, or (at your option) any later
# version published by ChefKiss.
#
# This work may not be used to train or develop artificial intelligence,
# and may not be used with artificial intelligence in any other way. See
# the ChefKiss Open Knowledge License for details.
#
# This work is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# ChefKiss Open Knowledge License for more details.
#
# You should have received a copy of the ChefKiss Open Knowledge License
# along with this work.  If not, see https://git.chefkiss.dev/ChefKiss/OpenKnowledge/raw/branch/master/LICENSE-v1.md.

"""Generate NootedRed/VCNKernelData.hpp from the live macOS 15.8.1 kernel collection.

The header carries the version-specific data required by the native
AMDRadeonX6000 VCN2 engine bridge inside the AMDRadeonX5000 accelerator
(option A of the VDA plan):

  * the two hardware vtable symbols and the six ABI guard slots per driver,
  * the real getter bytes behind the anonymous vtable slots,
  * the 20 X6000 call sites that must be redirected to the X5000 vtable slots
    (GFXOFF pairing / getter slots) or to AMDHardware::signalGPUWorkSubmitted,
  * source identification (kernel collection and kext UUIDs, driver versions
    and segment hashes).

Every value is derived from /System/Library/KernelCollections/SystemKernelExtensions.kc
on the current machine.  Nothing is loaded, executed, or written outside the
output header.  Run without arguments to (re)write the header and with --check to
re-read the kernel collection and the emitted header and fail loudly on any
mismatch.

Usage:
    python3 tools/gen_vcn_kernel_data.py
    python3 tools/gen_vcn_kernel_data.py --check
"""

import argparse
import hashlib
import os
import plistlib
import re
import struct
import sys
from bisect import bisect_right
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_KC = Path("/System/Library/KernelCollections/SystemKernelExtensions.kc")
DEFAULT_HEADER = REPO_ROOT / "NootedRed" / "VCNKernelData.hpp"

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_X86_64 = 0x01000007
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02
LC_UUID = 0x1B
LC_FILESET_ENTRY = 0x80000035

SEGMENT_LIST = ("__TEXT", "__DATA", "__DATA_CONST")

X5000_ID = "com.apple.kext.AMDRadeonX5000"
X6000_ID = "com.apple.kext.AMDRadeonX6000"

TABLE_5000 = "__ZTV32AMDRadeonX5000_AMDVega10Hardware"
TABLE_6000 = "__ZTV32AMDRadeonX6000_AMDNavi10Hardware"

SIGNAL_SYMBOL = "__ZN26AMDRadeonX6000_AMDHardware22signalGPUWorkSubmittedEv"

# Itanium C++ ABI: vtable symbol points at two header words (offset-to-top,
# typeinfo); the address point used for virtual dispatch is symbol + 16.
VTABLE_ADDRESS_POINT = 2 * 8

# Semantic guard set (from the prior-art report; identities/bytes are re-derived
# below from this machine's kernel collection).
GUARD_SPEC = {
    X5000_ID: (
        (0x298, "__ZN26AMDRadeonX5000_AMDHardware13isDeviceValidEv"),
        (0x2A8, None),
        (0x3B8, None),
        (0x3C8, None),
        (0x3E8, "__ZN28AMDRadeonX5000_AMDRTHardware13disableGfxOffEv"),
        (0x3F0, "__ZN28AMDRadeonX5000_AMDRTHardware12enableGfxOffEv"),
    ),
    X6000_ID: (
        (0x2A0, "__ZN26AMDRadeonX6000_AMDHardware13isDeviceValidEv"),
        (0x2B0, None),
        (0x3B0, None),
        (0x3C0, None),
        (0x3E0, "__ZN28AMDRadeonX6000_AMDRTHardware13disableGfxOffEv"),
        (0x3E8, "__ZN28AMDRadeonX6000_AMDRTHardware12enableGfxOffEv"),
    ),
}

# X6000 virtual slot -> X5000 virtual slot.  Slot 0x230 is special: the call is
# replaced by a direct call to SIGNAL_SYMBOL plus a NOP (newSlot == 0).
SLOT_MAP = {
    0x2A0: 0x298,
    0x2B0: 0x2A8,
    0x3B0: 0x3B8,
    0x3C0: 0x3C8,
    0x3E0: 0x3E8,
    0x3E8: 0x3F0,
    0x230: 0x00,
}

CHANNEL_PREFIX = "__ZN27AMDRadeonX6000_AMDHWChannel"
VCN_ISIDLE_SYMBOL = "__ZN30AMDRadeonX6000_AMDVCN2HWEngine6isIdleEv"
VIDEO_SUSPEND_SYMBOL = "__ZN36AMDRadeonX6000_AMDNavi10VideoContext21setSuspendResumeStateEb"
CHANNEL_WAIT_SYMBOL = "__ZN27AMDRadeonX6000_AMDHWChannel11waitForIdleEj"
ENGINE_WAIT_SYMBOL = "__ZN26AMDRadeonX6000_AMDHWEngine11waitForIdleEj"

# movq (%rdi), %rax -- the X6000 hardware vtable load that must precede every
# redirected call site.
VTABLE_LOAD = b"\x48\x8b\x07"

# movq <field>(%rdi|%rbx), %rdi -- receiver loaded from the channel/engine
# hardware field on the GFXOFF wait paths (channel field 0x20, engine 0x18).
IDLE_RECEIVER_PREFIXES = {
    CHANNEL_WAIT_SYMBOL: (b"\x48\x8b\x7f\x20", b"\x48\x8b\x7b\x20"),
    ENGINE_WAIT_SYMBOL: (b"\x48\x8b\x7f\x18", b"\x48\x8b\x7b\x18"),
}

EXPECTED_CALL_PATCHES = 20
EXPECTED_IDLE_PATCHES = 4

# Little-endian 32-bit immediate of "callq *imm32(%rax)".
CALL_RAX_PREFIX = b"\xff\x90"

MAX_GETTER_SIZE = 32

LICENSE_HEADER = """\
// VCN kernel bridge data for macOS 15.8.1
//
// Copyright (C) 2022-2026  ChefKiss.
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
//
// Generated by tools/gen_vcn_kernel_data.py from
// /System/Library/KernelCollections/SystemKernelExtensions.kc.
// Do not edit by hand: regenerate and let --check validate the result.
// Evidence and derivations: analysis/vcn-1581-kernel-data.md.
"""


class GeneratorError(RuntimeError):
    """Raised for any derivation or verification failure."""


def fail(message):
    raise GeneratorError(message)


def format_uuid(raw):
    text = raw.hex().upper()
    return "{}-{}-{}-{}-{}".format(text[0:8], text[8:12], text[12:16], text[16:20], text[20:32])


def read_plist(path):
    try:
        with open(path, "rb") as handle:
            return plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return {}


class KextSlice:
    """One fileset entry of a kernel collection: segments, symbols, version."""

    def __init__(self, kc, kext_id, vmaddr, fileoff):
        self.kc = kc
        self.kext_id = kext_id
        self.fileset_vmaddr = vmaddr
        self.fileoff = fileoff
        header = kc.data[fileoff:fileoff + 32]
        magic, cputype, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", header, 0)
        if magic != MH_MAGIC_64:
            fail("{}: bad Mach-O magic {:#x} at {:#x}".format(kext_id, magic, fileoff))
        if cputype != CPU_TYPE_X86_64:
            fail("{}: not x86_64 (cputype {:#x})".format(kext_id, cputype))
        self.ncmds = ncmds
        self.uuid = None
        self.segments = {}
        self.symtab = None
        self._parse_load_commands()
        if "__TEXT" not in self.segments:
            fail("{}: no __TEXT segment".format(kext_id))
        if self.segments["__TEXT"][0] != vmaddr:
            fail("{}: fileset vmaddr {:#x} != __TEXT vmaddr {:#x}".format(
                kext_id, vmaddr, self.segments["__TEXT"][0]))
        self.symbols = {}
        self.names_by_value = {}
        self._parse_symbols()
        self.mangled_text = sorted(
            (value, name)
            for name, value in self.symbols.items()
            if name.startswith("__Z")
            and self.text_vmaddr <= value < self.text_vmaddr + self.text_vmsize
        )
        if not self.mangled_text:
            fail("{}: no mangled text symbols".format(kext_id))

    @property
    def text_vmaddr(self):
        return self.segments["__TEXT"][0]

    @property
    def text_vmsize(self):
        return self.segments["__TEXT"][1]

    def _parse_load_commands(self):
        cursor = self.fileoff + 32
        for _ in range(self.ncmds):
            cmd, cmdsize = struct.unpack_from("<II", self.kc.data, cursor)
            if cmdsize < 8:
                fail("{}: invalid load command size {}".format(self.kext_id, cmdsize))
            if cmd == LC_SEGMENT_64:
                name = self.kc.data[cursor + 8:cursor + 24].split(b"\0")[0].decode(errors="replace")
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from(
                    "<QQQQ", self.kc.data, cursor + 24)
                self.segments[name] = (vmaddr, vmsize, fileoff, filesize)
            elif cmd == LC_SYMTAB:
                self.symtab = struct.unpack_from("<IIII", self.kc.data, cursor + 8)
            elif cmd == LC_UUID:
                self.uuid = self.kc.data[cursor + 8:cursor + 24]
            cursor += cmdsize

    def _parse_symbols(self):
        if self.symtab is None:
            fail("{}: no LC_SYMTAB".format(self.kext_id))
        symoff, nsyms, stroff, strsize = self.symtab
        if symoff + nsyms * 16 > len(self.kc.data):
            fail("{}: symbol table out of range".format(self.kext_id))
        strtab = self.kc.data[stroff:stroff + strsize]
        for index in range(nsyms):
            strx, ntype, _, _, value = struct.unpack_from("<IBBHQ", self.kc.data, symoff + index * 16)
            if ntype & 0x0E != 0x0E:  # N_SECT only
                continue
            end = strtab.find(b"\0", strx)
            if end < 0:
                fail("{}: unterminated symbol name".format(self.kext_id))
            name = strtab[strx:end].decode(errors="replace")
            self.symbols.setdefault(name, value)
            self.names_by_value.setdefault(value, []).append(name)
        for names in self.names_by_value.values():
            names.sort()

    def read(self, vmaddr, size):
        for _, (seg_vmaddr, _, fileoff, filesize) in self.segments.items():
            if seg_vmaddr <= vmaddr and vmaddr + size <= seg_vmaddr + filesize:
                start = fileoff + vmaddr - seg_vmaddr
                return self.kc.data[start:start + size]
        fail("{}: cannot read {} bytes at {:#x}".format(self.kext_id, size, vmaddr))

    def read_u64(self, vmaddr):
        return struct.unpack("<Q", self.read(vmaddr, 8))[0]

    def symbol_at(self, vmaddr):
        names = self.names_by_value.get(vmaddr)
        if not names:
            return None
        return names[0]

    def enclosing_function(self, vmaddr):
        """Return (start, name) of the mangled text symbol enclosing vmaddr."""
        index = bisect_right(self.mangled_text, (vmaddr, "\uffff")) - 1
        if index < 0:
            return None
        start, name = self.mangled_text[index]
        return start, name

    def segment_sha256(self):
        digest = hashlib.sha256()
        for name in SEGMENT_LIST:
            if name not in self.segments:
                fail("{}: missing {} segment".format(self.kext_id, name))
            _, _, fileoff, filesize = self.segments[name]
            digest.update(self.kc.data[fileoff:fileoff + filesize])
        return digest.hexdigest()

    def version_string(self):
        bundle = self.kext_id[len("com.apple.kext."):] if self.kext_id.startswith("com.apple.kext.") \
            else self.kext_id
        plist = read_plist(Path("/System/Library/Extensions") / "{}.kext".format(bundle) /
                           "Contents" / "Info.plist")
        info = plist.get("CFBundleGetInfoString")
        if isinstance(info, str) and info:
            return info
        version = plist.get("CFBundleShortVersionString")
        if isinstance(version, str) and version:
            return "{} {}".format(self.kext_id, version)
        return "{} version unknown".format(self.kext_id)

    def text_bytes(self):
        _, _, fileoff, filesize = self.segments["__TEXT"]
        return self.kc.data[fileoff:fileoff + filesize]


class KernelCollection:
    """x86_64 SystemKernelExtensions.kc reader for the two AMD drivers."""

    def __init__(self, path):
        self.path = Path(path)
        try:
            self.data = self.path.read_bytes()
        except OSError as error:
            fail("cannot read {}: {}".format(self.path, error))
        if len(self.data) < 32:
            fail("{}: truncated kernel collection".format(self.path))
        magic, cputype, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", self.data, 0)
        if magic != MH_MAGIC_64:
            fail("{}: bad kernel collection magic {:#x}".format(self.path, magic))
        if cputype != CPU_TYPE_X86_64:
            fail("{}: not an x86_64 kernel collection (cputype {:#x})".format(self.path, cputype))
        self.uuid = None
        self.ncmds = ncmds
        self.fileset_entries = {}
        self._parse_header()
        self.kexts = {}
        for kext_id in (X5000_ID, X6000_ID):
            if kext_id not in self.fileset_entries:
                fail("{}: fileset entry for {} not found".format(self.path, kext_id))
            vmaddr, fileoff = self.fileset_entries[kext_id]
            self.kexts[kext_id] = KextSlice(self, kext_id, vmaddr, fileoff)

    def _parse_header(self):
        cursor = 32
        for _ in range(self.ncmds):
            cmd, cmdsize = struct.unpack_from("<II", self.data, cursor)
            if cmdsize < 8:
                fail("{}: invalid load command size {}".format(self.path, cmdsize))
            if cmd == LC_FILESET_ENTRY:
                vmaddr, fileoff = struct.unpack_from("<QQ", self.data, cursor + 8)
                stroff = struct.unpack_from("<I", self.data, cursor + 24)[0]
                name = self.data[cursor + stroff:cursor + cmdsize].split(b"\0")[0].decode(errors="replace")
                self.fileset_entries[name] = (vmaddr, fileoff)
            elif cmd == LC_UUID:
                self.uuid = self.data[cursor + 8:cursor + 24]
            cursor += cmdsize
        if self.uuid is None:
            fail("{}: no LC_UUID".format(self.path))


def derive_prelink_bias(kc):
    """Derive the prelink->vtable pointer bias from an independently verified anchor.

    The Itanium vtable slot for AMDHardware::isDeviceValid is an alias of the
    function symbol of the same name.  The difference between the stored pointer
    and the symbol value is the constant prelink bias used by the kernel
    collection relocation format; it is then cross-checked on the other driver.
    """
    kext5 = kc.kexts[X5000_ID]
    kext6 = kc.kexts[X6000_ID]
    anchor5000 = "__ZN26AMDRadeonX5000_AMDHardware13isDeviceValidEv"
    anchor6000 = "__ZN26AMDRadeonX6000_AMDHardware13isDeviceValidEv"
    for kext, names in ((kext5, (TABLE_5000, anchor5000)), (kext6, (TABLE_6000, anchor6000))):
        for name in names:
            if name not in kext.symbols:
                fail("{}: missing prelink-bias anchor symbol {}".format(kext.kext_id, name))
    bias5 = (kext5.read_u64(kext5.symbols[TABLE_5000] + VTABLE_ADDRESS_POINT + 0x298)
             - kext5.symbols[anchor5000])
    bias6 = (kext6.read_u64(kext6.symbols[TABLE_6000] + VTABLE_ADDRESS_POINT + 0x2A0)
             - kext6.symbols[anchor6000])
    if bias5 != bias6:
        fail("prelink bias mismatch between drivers: {:#x} vs {:#x}".format(bias5, bias6))
    if bias5 <= 0 or bias5 % 0x1000:
        fail("implausible prelink bias {:#x}".format(bias5))
    return bias5


def extract_getter(kext, vmaddr):
    """Extract a complete anonymous getter, validating its instruction shape.

    The guarded getters are tiny accessors of the form
        push rbp; mov rbp, rsp; <one load>; [and al, 1]; pop rbp; ret
    with no calls, branches or RIP-relative references.  The byte length is
    derived from the terminating 'pop rbp; ret' pair, never assumed.
    """
    raw = kext.read(vmaddr, MAX_GETTER_SIZE)
    if raw[0:4] != b"\x55\x48\x89\xe5":
        fail("getter at {:#x} ({}) has unexpected prologue {}".format(
            vmaddr, kext.kext_id, raw[0:4].hex()))
    position = 4
    while position < len(raw):
        if raw[position:position + 2] == b"\x5d\xc3":
            code = raw[:position + 2]
            if len(code) > MAX_GETTER_SIZE:
                fail("getter at {:#x} too long".format(vmaddr))
            return code
        if raw[position:position + 2] == b"\x24\x01":  # and al, 1
            position += 2
            continue
        if raw[position:position + 2] in (b"\x8a\x87", b"\x8b\x87"):  # mov (al/eax), disp32
            position += 6
            continue
        if raw[position:position + 3] == b"\x48\x8b\x87":  # mov rax, disp32
            position += 7
            continue
        fail("getter at {:#x} ({}) has unsupported byte {} at +{:#x}".format(
            vmaddr, kext.kext_id, raw[position:position + 1].hex(), position))
    fail("getter at {:#x} ({}) has no terminator within {} bytes".format(
        vmaddr, kext.kext_id, MAX_GETTER_SIZE))


def getter_displacement(code):
    """Return the displacement of the single memory access in a guarded getter."""
    if len(code) >= 6 and code[4:6] in (b"\x8a\x87", b"\x8b\x87"):
        return struct.unpack_from("<I", code, 6)[0]
    if len(code) >= 7 and code[4:7] == b"\x48\x8b\x87":
        return struct.unpack_from("<I", code, 7)[0]
    fail("getter has no recognised memory access: {}".format(code.hex()))


def resolve_vtable_slot(kext, table_symbol, slot, bias):
    target = kext.read_u64(kext.symbols[table_symbol] + VTABLE_ADDRESS_POINT + slot) - bias
    if not (kext.text_vmaddr <= target < kext.text_vmaddr + kext.text_vmsize):
        fail("{}: vtable slot {:#x} target {:#x} is outside __TEXT".format(
            kext.kext_id, slot, target))
    return target


def build_guards(kc, bias):
    guards = {}
    for kext_id, table_symbol in ((X5000_ID, TABLE_5000), (X6000_ID, TABLE_6000)):
        kext = kc.kexts[kext_id]
        if table_symbol not in kext.symbols:
            fail("{}: missing vtable symbol {}".format(kext_id, table_symbol))
        suffix = "5000" if kext_id == X5000_ID else "6000"
        entries = []
        getter_index = 0
        seen_targets = set()
        for slot, method_symbol in GUARD_SPEC[kext_id]:
            target = resolve_vtable_slot(kext, table_symbol, slot, bias)
            if target in seen_targets:
                fail("{}: duplicate guard target {:#x}".format(kext_id, target))
            seen_targets.add(target)
            if method_symbol is not None:
                resolved = kext.symbol_at(target)
                if resolved != method_symbol:
                    fail("{}: slot {:#x} resolves to {}, expected {}".format(
                        kext_id, slot, resolved, method_symbol))
                entries.append({
                    "slot": slot,
                    "method": method_symbol,
                    "getter_name": None,
                    "getter_bytes": None,
                    "target": target,
                })
            else:
                getter_index += 1
                code = extract_getter(kext, target)
                entries.append({
                    "slot": slot,
                    "method": None,
                    "getter_name": "Getter{}_{}".format(suffix, getter_index),
                    "getter_bytes": code,
                    "displacement": getter_displacement(code),
                    "target": target,
                })
        if getter_index != 3:
            fail("{}: expected 3 anonymous getter guards, found {}".format(kext_id, getter_index))
        guards[kext_id] = entries
    return guards


def classify_call_site(function_name, slot):
    """Apply the bridge's semantic map to an X6000 call site candidate."""
    if function_name.startswith(CHANNEL_PREFIX) and slot in (0x2A0, 0x3B0, 0x3C0, 0x230):
        return "channel"
    if function_name == VCN_ISIDLE_SYMBOL and slot == 0x2A0:
        return "engine-idle"
    if function_name == VIDEO_SUSPEND_SYMBOL and slot == 0x2B0:
        return "video-context"
    if function_name in (CHANNEL_WAIT_SYMBOL, ENGINE_WAIT_SYMBOL) and slot in (0x3E0, 0x3E8):
        return "gfxoff-wait"
    return None


def find_call_patches(kc):
    """Derive the 20 X6000 call sites that must be redirected for the bridge."""
    kext = kc.kexts[X6000_ID]
    text = kext.text_bytes()
    stats = {}
    patches = []
    scan = 0
    while True:
        location = text.find(CALL_RAX_PREFIX, scan)
        if location < 0 or location + 6 > len(text):
            break
        scan = location + 1
        slot = struct.unpack_from("<I", text, location + 2)[0]
        candidate_address = kext.text_vmaddr + location
        if slot not in SLOT_MAP:
            continue
        stats[slot] = stats.get(slot, 0) + 1
        if location < 7:  # Mach-O header/load commands live at the start of __TEXT
            continue
        enclosing = kext.enclosing_function(candidate_address)
        if enclosing is None:
            continue
        function_start, function_name = enclosing
        category = classify_call_site(function_name, slot)
        if category is None:
            continue
        if text[location - 3:location] != VTABLE_LOAD:
            fail("{}: {}+{:#x} lacks the hardware vtable load".format(
                kext.kext_id, function_name, candidate_address - function_start))
        if category == "gfxoff-wait":
            prefixes = IDLE_RECEIVER_PREFIXES[function_name]
            if text[location - 7:location - 3] not in prefixes:
                fail("{}: {}+{:#x} lacks the hardware-field receiver load".format(
                    kext.kext_id, function_name, candidate_address - function_start))
        original = bytes(text[location:location + 6])
        expected = CALL_RAX_PREFIX + struct.pack("<I", slot)
        if original != expected:
            fail("{}: bad original bytes at {:#x}: {}".format(X6000_ID, candidate_address, original.hex()))
        patches.append({
            "symbol": function_name,
            "offset": candidate_address - function_start,
            "original": original,
            "slot": slot,
            "new_slot": SLOT_MAP[slot],
            "category": category,
            "address": candidate_address,
        })
    patches.sort(key=lambda entry: (entry["symbol"], entry["offset"]))
    if len(patches) != EXPECTED_CALL_PATCHES:
        fail("expected {} call patches, derived {} (per-slot candidates: {})".format(
            EXPECTED_CALL_PATCHES, len(patches),
            ", ".join("{:#x}:{}".format(k, v) for k, v in sorted(stats.items()))))
    idle = [entry for entry in patches if entry["category"] == "gfxoff-wait"]
    if len(idle) != EXPECTED_IDLE_PATCHES:
        fail("expected {} GFXOFF wait pairs, derived {}".format(EXPECTED_IDLE_PATCHES, len(idle)))
    if [entry["slot"] for entry in idle].count(0x3E0) != 2:
        fail("GFXOFF wait pairing is incomplete (slot 0x3E0)")
    if [entry["slot"] for entry in idle].count(0x3E8) != 2:
        fail("GFXOFF wait pairing is incomplete (slot 0x3E8)")
    submit = [entry for entry in patches if entry["slot"] == 0x230]
    if len(submit) != 1 or submit[0]["new_slot"] != 0:
        fail("expected exactly one submitCommandBuffer -> signalGPUWorkSubmitted patch")
    signal = kext.symbols.get(SIGNAL_SYMBOL)
    if signal is None:
        fail("{}: missing signal symbol {}".format(kext.kext_id, SIGNAL_SYMBOL))
    call_site = submit[0]["address"] + 6
    if call_site < signal:
        displacement = signal - call_site
    else:
        displacement = call_site - signal
    if displacement >= 2 ** 31:
        fail("signal symbol is not reachable by a rel32 call from the submit site")
    stats = {slot: stats.get(slot, 0) for slot in SLOT_MAP}
    return patches, stats, signal


def collect_source_info(kc):
    system_version = read_plist(Path("/System/Library/CoreServices/SystemVersion.plist"))
    product = system_version.get("ProductVersion", "unknown")
    build = system_version.get("ProductBuildVersion", "unknown")
    kernel = os.uname().release
    kexts = {}
    for kext_id in (X5000_ID, X6000_ID):
        kext = kc.kexts[kext_id]
        kexts[kext_id] = {
            "uuid": format_uuid(kext.uuid),
            "sha256": kext.segment_sha256(),
            "version": kext.version_string(),
            "fileoff": kext.fileoff,
            "vmaddr": kext.fileset_vmaddr,
            "segments": dict(kext.segments),
        }
    return {
        "kc_path": str(kc.path),
        "product": product,
        "build": build,
        "kernel": kernel,
        "kc_uuid": format_uuid(kc.uuid),
        "kc_size": len(kc.data),
        "kexts": kexts,
        "tables": {
            X5000_ID: kc.kexts[X5000_ID].symbols[TABLE_5000],
            X6000_ID: kc.kexts[X6000_ID].symbols[TABLE_6000],
        },
    }


def build_data(kc):
    bias = derive_prelink_bias(kc)
    guards = build_guards(kc, bias)
    patches, stats, signal = find_call_patches(kc)
    return {
        "bias": bias,
        "guards": guards,
        "patches": patches,
        "slot_stats": stats,
        "signal": signal,
        "source": collect_source_info(kc),
    }


def format_hex_array(name, values, indent="    "):
    lines = ["{}inline constexpr UInt8 {}[] = {{".format(indent, name)]
    for start in range(0, len(values), 8):
        chunk = values[start:start + 8]
        lines.append(indent + "    " + ", ".join("0x{:02X}".format(value) for value in chunk) + ",")
    lines.append(indent + "};")
    return lines


def emit_header(data):
    source = data["source"]
    lines = [LICENSE_HEADER.rstrip("\n"), "", "#pragma once", "", "#include <IOKit/IOTypes.h>", ""]
    lines += ["namespace VCNKernelData {", "    struct CallPatch {",
              "        const char* symbol;", "        UInt32 offset;", "        UInt8 original[6];",
              "        UInt32 newSlot;", "    };", ""]
    lines += ["    struct SlotGuard {", "        UInt32 slot;", "        const char* methodSymbol;",
              "        const UInt8* getter;", "        UInt32 getterSize;", "    };", ""]
    for kext_id in (X5000_ID, X6000_ID):
        for entry in data["guards"][kext_id]:
            if entry["getter_name"] is not None:
                lines += format_hex_array(entry["getter_name"], entry["getter_bytes"])
                lines.append("")
    lines += ['    inline constexpr char Table5000[] = "{}";'.format(TABLE_5000),
              '    inline constexpr char Table6000[] = "{}";'.format(TABLE_6000), ""]
    for kext_id, suffix in ((X5000_ID, "5000"), (X6000_ID, "6000")):
        lines.append("    inline constexpr SlotGuard Guards{}[] = {{".format(suffix))
        for entry in data["guards"][kext_id]:
            if entry["method"] is not None:
                lines.append('        {{ 0x{:03X}, "{}", nullptr, 0 }},'.format(
                    entry["slot"], entry["method"]))
            else:
                lines.append("        {{ 0x{:03X}, nullptr, {}, {} }},".format(
                    entry["slot"], entry["getter_name"], len(entry["getter_bytes"])))
        lines += ["    };", ""]
    lines.append("    // Original bytes are `callq *slot(%rax)`; newSlot == 0 means the call is")
    lines.append("    // replaced by `call SignalSymbol` (E8 rel32) plus a NOP at runtime.")
    lines.append("    inline constexpr CallPatch CallPatches[] = {")
    for entry in data["patches"]:
        lines.append("        {")
        lines.append('            "{}",'.format(entry["symbol"]))
        lines.append("            0x{:X},".format(entry["offset"]))
        lines.append("            { " + ", ".join("0x{:02X}".format(byte) for byte in entry["original"]) + " },")
        lines.append("            0x{:X},".format(entry["new_slot"]))
        lines.append("        },")
    lines += ["    };", ""]
    lines += ['    inline constexpr char SignalSymbol[] = "{}";'.format(SIGNAL_SYMBOL), ""]
    source_parts = (
        "macOS {} ({}) x86_64, Darwin {}; ".format(
            source["product"], source["build"], source["kernel"]),
        "SystemKernelExtensions.kc UUID {}; ".format(source["kc_uuid"]),
        "{}; {}".format(source["kexts"][X5000_ID]["version"],
                        source["kexts"][X6000_ID]["version"]),
    )
    lines.append("    inline constexpr char SourceDescription[] =")
    for index, part in enumerate(source_parts):
        suffix = ";" if index == len(source_parts) - 1 else ""
        lines.append("        \"{}\"{}".format(part, suffix))
    lines.append("")
    lines.append("    // Source identity for runtime diagnostics; the bridge must compare these against")
    lines.append("    // the loaded kernel collection/kexts before installing any guard or patch.")
    lines.append('    inline constexpr char KernelCollectionUUID[] = "{}";'.format(source["kc_uuid"]))
    lines.append('    inline constexpr char DriverUUID5000[] = "{}";'.format(
        source["kexts"][X5000_ID]["uuid"]))
    lines.append('    inline constexpr char DriverUUID6000[] = "{}";'.format(
        source["kexts"][X6000_ID]["uuid"]))
    lines.append('    inline constexpr char DriverVersion5000[] = "{}";'.format(
        source["kexts"][X5000_ID]["version"]))
    lines.append('    inline constexpr char DriverVersion6000[] = "{}";'.format(
        source["kexts"][X6000_ID]["version"]))
    lines.append('    inline constexpr char DriverSHA256_5000[] = "{}";'.format(
        source["kexts"][X5000_ID]["sha256"]))
    lines.append('    inline constexpr char DriverSHA256_6000[] = "{}";'.format(
        source["kexts"][X6000_ID]["sha256"]))
    lines.append("}    // namespace VCNKernelData")
    lines.append("")
    return "\n".join(lines)


def print_summary(data, output, check=False):
    source = data["source"]
    print("Kernel collection: {} (UUID {})".format(source["kc_path"], source["kc_uuid"]))
    print("macOS {} ({}) Darwin {}; kernel collection size {} bytes".format(
        source["product"], source["build"], source["kernel"], source["kc_size"]))
    print("Prelink bias: {:#x}".format(data["bias"]))
    for kext_id in (X5000_ID, X6000_ID):
        kext = source["kexts"][kext_id]
        segments = ", ".join(
            "{} vm={:#x} fileoff={:#x} size={:#x}".format(
                name, value[0], value[2], value[3])
            for name, value in kext["segments"].items())
        print("{}: version '{}', UUID {}, slice fileoff {:#x}".format(
            kext_id, kext["version"], kext["uuid"], kext["fileoff"]))
        print("    sha256 {}: {}".format(kext_id, kext["sha256"]))
        print("    segments: {}".format(segments))
    print("Guards:")
    for kext_id in (X5000_ID, X6000_ID):
        table = TABLE_5000 if kext_id == X5000_ID else TABLE_6000
        address = data["source"]["tables"][kext_id]
        print("    {} table {} @ {:#x}".format(kext_id, table, address))
        for entry in data["guards"][kext_id]:
            if entry["method"] is not None:
                print("        slot {:#03x}: {} @ {:#x}".format(
                    entry["slot"], entry["method"], entry["target"]))
            else:
                print("        slot {:#03x}: {} {} bytes @ {:#x} (disp {:#x})".format(
                    entry["slot"], entry["getter_name"], len(entry["getter_bytes"]),
                    entry["target"], entry["displacement"]))
    print("Call-site candidates (`callq *imm32(%rax)`) by X6000 slot: " + ", ".join(
        "{:#05x}: {}".format(slot, data["slot_stats"][slot]) for slot in sorted(data["slot_stats"])))
    submit = [entry for entry in data["patches"] if entry["new_slot"] == 0]
    if submit:
        print("Submit -> signal rel32 displacement from {:#x} to {:#x}: {:#x}".format(
            submit[0]["address"] + 6, data["signal"], data["signal"] - (submit[0]["address"] + 6)))
    print("Call patches ({}):".format(len(data["patches"])))
    for entry in data["patches"]:
        print("    {} +{:#x}: {} -> slot {:#x} ({})".format(
            entry["symbol"], entry["offset"], entry["original"].hex(),
            entry["new_slot"], entry["category"]))
    print("Signal symbol: {} @ {:#x}".format(SIGNAL_SYMBOL, data["signal"]))
    if check:
        print("CHECK OK: {} matches a fresh derivation and every entry revalidates against the KC".format(
            output))
    else:
        print("Wrote {}".format(output))


def check_header(kc, data, expected_text, output):
    if not output.is_file():
        fail("{} does not exist; run the generator first".format(output))
    actual_text = output.read_text(encoding="utf-8")
    source = data["source"]
    kext5 = kc.kexts[X5000_ID]
    kext6 = kc.kexts[X6000_ID]

    getter_pattern = re.compile(
        r"inline constexpr UInt8 (Getter\d{4}_\d)\[\] = \{(.*?)\};", re.S)
    getters = {}
    for match in getter_pattern.finditer(actual_text):
        values = [int(token, 16) for token in re.findall(r"0x([0-9A-F]{2})", match.group(2))]
        getters[match.group(1)] = bytes(values)

    table_pattern = re.compile(r'inline constexpr char (Table\d{4})\[\] = "([^"]+)";')
    tables = {match.group(1): match.group(2) for match in table_pattern.finditer(actual_text)}

    guard_pattern = re.compile(
        r"inline constexpr SlotGuard Guards(5000|6000)\[\] = \{(.*?)\n    \};", re.S)
    guard_blocks = {}
    for match in guard_pattern.finditer(actual_text):
        entries = []
        for entry in re.finditer(
                r'\{ 0x([0-9A-F]+), (nullptr|"[^"]+"), (nullptr|Getter\d+_\d+), (\d+) \}',
                match.group(2)):
            entries.append((int(entry.group(1), 16), entry.group(2), entry.group(3),
                            int(entry.group(4))))
        guard_blocks[match.group(1)] = entries

    patch_pattern = re.compile(
        r'\{\s*"([^"]+)",\s*0x([0-9A-F]+),\s*\{\s*([0-9A-Fx,\s]+?)\s*\},\s*0x([0-9A-F]+),\s*\}',
        re.S)
    patches = []
    for match in patch_pattern.finditer(actual_text):
        original = bytes(int(token, 16) for token in re.findall(r"0x([0-9A-F]{2})", match.group(3)))
        patches.append((match.group(1), int(match.group(2), 16), original, int(match.group(4), 16)))

    signal_match = re.search(r'inline constexpr char SignalSymbol\[\] = "([^"]+)";',
                                           actual_text)
    kc_uuid_match = re.search(r'inline constexpr char KernelCollectionUUID\[\] = "([^"]+)";',
                                            actual_text)
    if not signal_match or signal_match.group(1) != SIGNAL_SYMBOL:
        fail("header SignalSymbol is missing or wrong")
    if not kc_uuid_match or kc_uuid_match.group(1) != source["kc_uuid"]:
        fail("header KernelCollectionUUID does not match the kernel collection")
    for suffix, kext_id in (("5000", X5000_ID), ("6000", X6000_ID)):
        kext_source = source["kexts"][kext_id]
        for label, expected in (
                ("DriverUUID{}".format(suffix), kext_source["uuid"]),
                ("DriverVersion{}".format(suffix), kext_source["version"]),
                ("DriverSHA256_{}".format(suffix), kext_source["sha256"])):
            match = re.search(
                r'inline constexpr char {}\[\] = "([^"]+)";'.format(label), actual_text)
            if match is None or match.group(1) != expected:
                fail("header {} does not match the kernel collection".format(label))
    for suffix, expected_count in (("5000", 6), ("6000", 6)):
        if len(guard_blocks.get(suffix, [])) != expected_count:
            fail("header Guards{} does not contain {} entries".format(suffix, expected_count))
    if len(getters) != 6:
        fail("header contains {} getter arrays, expected 6".format(len(getters)))
    if len(patches) != EXPECTED_CALL_PATCHES:
        fail("header contains {} call patches, expected {}".format(len(patches), EXPECTED_CALL_PATCHES))

    bias = data["bias"]
    for kext_id, suffix, table_symbol, kext in (
            (X5000_ID, "5000", TABLE_5000, kext5), (X6000_ID, "6000", TABLE_6000, kext6)):
        table = tables.get("Table{}".format(suffix))
        if table != table_symbol:
            fail("header Table{} is {!r}, expected {!r}".format(suffix, table, table_symbol))
        expected_guards = data["guards"][kext_id]
        for (slot, method_token, getter_token, getter_size), expected in zip(
                guard_blocks[suffix], expected_guards):
            target = resolve_vtable_slot(kext, table_symbol, slot, bias)
            if slot != expected["slot"]:
                fail("{}.slot order mismatch at {:#x}".format(kext_id, slot))
            if expected["method"] is not None:
                if method_token != '"{}"'.format(expected["method"]) or getter_token != "nullptr" or getter_size != 0:
                    fail("{}.slot {:#x} method guard is malformed in the header".format(kext_id, slot))
                if kext.symbol_at(target) != expected["method"]:
                    fail("{}.slot {:#x} no longer resolves to {}".format(
                        kext_id, slot, expected["method"]))
            else:
                if method_token != "nullptr" or getter_token != expected["getter_name"]:
                    fail("{}.slot {:#x} getter guard is malformed in the header".format(kext_id, slot))
                if getter_token not in getters:
                    fail("header is missing array {}".format(getter_token))
                code = getters[getter_token]
                if len(code) != getter_size or len(code) != len(expected["getter_bytes"]):
                    fail("{}.{} size mismatch".format(kext_id, getter_token))
                if kext.read(target, len(code)) != code:
                    fail("{}.slot {:#x} getter bytes no longer match the KC".format(kext_id, slot))

    for symbol, offset, original, new_slot in patches:
        if symbol not in kext6.symbols:
            fail("patch symbol {} is not in {}".format(symbol, X6000_ID))
        address = kext6.symbols[symbol] + offset
        if kext6.read(address, 6) != original:
            fail("patch bytes at {}+{:#x} no longer match the KC".format(symbol, offset))
        actual_slot = struct.unpack_from("<I", original, 2)[0]
        if SLOT_MAP.get(actual_slot, -1) != new_slot:
            fail("patch {}+{:#x} has inconsistent newSlot {:#x}".format(symbol, offset, new_slot))

    if actual_text != expected_text:
        actual_lines = actual_text.splitlines()
        expected_lines = expected_text.splitlines()
        for index, (actual_line, expected_line) in enumerate(
                zip(actual_lines, expected_lines), start=1):
            if actual_line != expected_line:
                fail("{} is stale at line {}: header has {!r}, generator has {!r}".format(
                    output, index, actual_line, expected_line))
        fail("{} is stale: {} lines vs {} expected".format(
            output, len(actual_lines), len(expected_lines)))


def main(argv):
    parser = argparse.ArgumentParser(
        description="Generate/verify NootedRed/VCNKernelData.hpp from the 15.8.1 kernel collection.")
    parser.add_argument("--check", action="store_true",
                        help="re-read the kernel collection and header and fail on any mismatch")
    parser.add_argument("--kc", type=Path, default=DEFAULT_KC,
                        help="kernel collection to read (default: %(default)s)")
    parser.add_argument("--output", type=Path, default=DEFAULT_HEADER,
                        help="header to write/check (default: %(default)s)")
    args = parser.parse_args(argv)
    try:
        kc = KernelCollection(args.kc)
        data = build_data(kc)
        expected_text = emit_header(data)
        if args.check:
            check_header(kc, data, expected_text, args.output)
            print_summary(data, args.output, check=True)
        else:
            try:
                args.output.write_bytes(expected_text.encode("utf-8"))
            except OSError as error:
                fail("cannot write {}: {}".format(args.output, error))
            print_summary(data, args.output, check=False)
    except GeneratorError as error:
        print("gen_vcn_kernel_data: ERROR: {}".format(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
