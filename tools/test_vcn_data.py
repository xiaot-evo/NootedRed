#!/usr/bin/env python3
"""Static validation for the single supported VCN kernel table (24H32).

Checks the generated kernel call-site table, source identity strings, and exact-build selector in the
main kext. It does not execute Apple code. Unsupported builds are intentionally absent from VCNData.

Run with::

    python3 tools/test_vcn_data.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
KERNEL_DATA_24H32 = ROOT / "NootedRed" / "VCNData" / "24H32.hpp"
VCN_DATA = ROOT / "NootedRed" / "VCNData.hpp"
VCN_SELECTOR = ROOT / "NootedRed" / "VCNData.cpp"
VCN_BRIDGE = ROOT / "NootedRed" / "VCNBridge.cpp"


class Failure(RuntimeError):
    pass


def parse_call_patches(text: str, label: str) -> list[dict]:
    match = re.search(r"inline constexpr CallPatch\s+CallPatches\[\]\s*=\s*\{(.*?)\n    \};", text, re.S)
    if not match:
        raise Failure(f"{label}: CallPatches not found")
    entries = []
    for entry in re.finditer(
        r'\{\s*"([^"]+)"\s*,\s*(0x[0-9A-Fa-f]+)\s*,\s*\{\s*([^}]+)\}\s*,\s*(0x[0-9A-Fa-f]+)\s*,?\s*\}',
        match.group(1),
    ):
        symbol, offset, original, new_slot = entry.groups()
        original_bytes = bytes(int(value, 16) for value in re.findall(r"0x([0-9A-Fa-f]{2})", original))
        if len(original_bytes) != 6:
            raise Failure(f"{label}: {symbol} original is {len(original_bytes)} bytes, expected 6")
        entries.append({"symbol": symbol, "offset": int(offset, 16),
                        "original": original_bytes, "newSlot": int(new_slot, 16)})
    if len(entries) != 20:
        raise Failure(f"{label}: parsed {len(entries)} entries, expected 20")
    return entries


def main() -> int:
    text = KERNEL_DATA_24H32.read_text()
    call_patches = parse_call_patches(text, "24H32 CallPatches")
    if 'Build[] = "24H32"' not in text:
        raise Failure("24H32 header does not declare its exact build string")
    if 'static_assert(kCallPatchCount <= kMaxCallPatches' not in text:
        raise Failure("24H32 call-site table has no compile-time bound check")
    if "DriverSHA256_6000" not in text:
        raise Failure("24H32 header is missing its driver identity")
    print(f"kernel table: 24H32 {len(call_patches)} sites")

    data_text = VCN_DATA.read_text()
    selector_text = VCN_SELECTOR.read_text()
    for token in ("findVariant", "variantForDarwin", "hasVariantForDarwin", "kMaxCallPatches"):
        if token not in data_text:
            raise Failure(f"VCNData.hpp is missing {token!r}")
    if "Build24H32::kData" not in selector_text:
        raise Failure("VCNData.cpp does not register Build24H32::kData")
    for token in ("Build23J631::kData", "Build25G241::kData", "Build23H::kData", "Build23G::kData",
                  "Build24H::kData", "Build25G::kData", "buildPrefix"):
        if token in selector_text:
            raise Failure(f"VCNData.cpp still contains removed fallback token {token!r}")
    if not re.search(r'buildMatches\(osversion, variant->build\)', selector_text):
        raise Failure("VCNData.cpp does not use the exact-build matcher")

    bridge_text = VCN_BRIDGE.read_text()
    for token in ("VCNData::variantForDarwin", "VCNData::findVariant", "currentVariant", "hasVariantForDarwin"):
        if token not in bridge_text:
            raise Failure(f"VCNBridge.cpp is missing the exact-build marker {token!r}")
    if "VCNKernelData" in bridge_text or "getCallPatches" in bridge_text:
        raise Failure("VCNBridge.cpp still uses the old VCNKernelData selector")
    print("bridge: exact-build VCNData lookup present")
    print("all VCN kernel-table checks passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
