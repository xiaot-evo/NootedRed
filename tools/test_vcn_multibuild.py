#!/usr/bin/env python3
"""Static validation for the multi-version VCN kernel tables.

Checks the generated kernel call-site tables, the per-build source identity strings, and the
build-selection code paths in the main kext. It does not execute Apple code; it is a consistency check
for the data imported from the 14.8.9, 15.8.1 and 26.7.1 builds.

The user-space VDA/AppleGVA tables moved to the NootedRedUserPatch satellite (``PatchData/``); they are
validated by ``tools/test_userpatch_data.py`` and ``tools/test_patchdata_selection.py`` instead of here.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

KERNEL_DATA_24H32 = ROOT / "NootedRed" / "VCNData" / "24H32.hpp"
KERNEL_DATA_23J631 = ROOT / "NootedRed" / "VCNData" / "23J631.hpp"
KERNEL_DATA_25G241 = ROOT / "NootedRed" / "VCNData" / "25G241.hpp"
VCN_DATA = ROOT / "NootedRed" / "VCNData.hpp"
VCN_SELECTOR = ROOT / "NootedRed" / "VCNData.cpp"
VCN_BRIDGE = ROOT / "NootedRed" / "VCNBridge.cpp"


class Failure(RuntimeError):
    pass


def parse_call_patches(text: str, label: str, name: str = "CallPatches") -> list[dict]:
    match = re.search(rf"inline constexpr CallPatch\s+{name}\[\]\s*=\s*\{{(.*?)\n    \}};", text, re.S)
    if not match:
        raise Failure(f"{label}: {name} not found")
    entries = []
    for entry in re.finditer(
        r'\{\s*"([^"]+)"\s*,\s*(0x[0-9A-Fa-f]+)\s*,\s*\{\s*([^}]+)\}\s*,\s*(0x[0-9A-Fa-f]+)\s*,?\s*\}',
        match.group(1),
    ):
        symbol, offset, original, new_slot = entry.groups()
        original_bytes = bytes(int(value, 16) for value in re.findall(r"0x([0-9A-Fa-f]{2})", original))
        if len(original_bytes) != 6:
            raise Failure(f"{label}: {symbol} original is {len(original_bytes)} bytes, expected 6")
        entries.append({
            "symbol": symbol,
            "offset": int(offset, 16),
            "original": original_bytes,
            "newSlot": int(new_slot, 16),
        })
    if len(entries) != 20:
        raise Failure(f"{label}: parsed {len(entries)} entries, expected 20")
    return entries


def main() -> int:
    sequoia_text = KERNEL_DATA_24H32.read_text()
    sonoma_text = KERNEL_DATA_23J631.read_text()
    tahoe_text = KERNEL_DATA_25G241.read_text()
    sequoia = parse_call_patches(sequoia_text, "24H32 CallPatches")
    sonoma = parse_call_patches(sonoma_text, "23J631 CallPatches")
    tahoe = parse_call_patches(tahoe_text, "25G241 CallPatches")
    if len(sequoia) != 20 or len(sonoma) != 20 or len(tahoe) != 20:
        raise Failure("all VCN call-site tables must contain 20 sites")
    if sonoma == sequoia or tahoe == sequoia:
        raise Failure("VCN build tables are identical; expected build-specific data")
    if ('Build[] = "24H32"' not in sequoia_text or 'Build[] = "23J631"' not in sonoma_text
            or 'Build[] = "25G241"' not in tahoe_text):
        raise Failure("per-build headers do not declare their exact build strings")
    if 'static_assert(kCallPatchCount <= kMaxCallPatches' not in sequoia_text:
        raise Failure("24H32 call-site table has no compile-time bound check")
    if 'static_assert(kCallPatchCount <= kMaxCallPatches' not in sonoma_text:
        raise Failure("23J631 call-site table has no compile-time bound check")
    if 'DriverSHA256_6000' not in sequoia_text or 'No locally generated identity' not in sonoma_text:
        raise Failure("per-build headers do not declare identity availability")
    print(f"kernel tables: 24H32 {len(sequoia)} sites, 23J631 {len(sonoma)} sites, 25G241 {len(tahoe)} sites")

    data_text = VCN_DATA.read_text()
    selector_text = VCN_SELECTOR.read_text()
    for token in ("findVariant", "variantForDarwin", "hasVariantForDarwin", "kMaxCallPatches"):
        if token not in data_text:
            raise Failure(f"VCNData.hpp is missing {token!r}")
    for token in ("Build23J631::kData", "Build23H::kData", "Build23G::kData", "Build24H32::kData",
                  "Build25G241::kData", "Build23J::kData", "Build24H::kData", "Build25G::kData",
                  "buildMatches", "buildPrefix", "osversion[i] == '\\0'"):
        if token not in selector_text:
            raise Failure(f"VCNData.cpp is missing {token!r}")
    if 'major() == 23' in selector_text or '"23J"' in selector_text or '"24H"' in selector_text:
        raise Failure("VCNData.cpp still contains a Darwin-major/family-prefix selector")

    bridge_text = VCN_BRIDGE.read_text()
    for token in ("VCNData::variantForDarwin", "VCNData::findVariant", "currentVariant", "hasVariantForDarwin"):
        if token not in bridge_text:
            raise Failure(f"VCNBridge.cpp is missing the exact-build marker {token!r}")
    if "VCNKernelData" in bridge_text or "getCallPatches" in bridge_text:
        raise Failure("VCNBridge.cpp still uses the old VCNKernelData selector")
    print("bridge: exact-build VCNData lookup present")

    print("all multi-version VCN kernel-table checks passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
