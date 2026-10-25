#!/usr/bin/env python3
"""Data-level selection matrix for the committed satellite ``PatchData/``.

The runtime selection code lives in ``NootedRedUserPatch/PatchData.cpp``; this host test cannot import
kernel code, so it exercises the *real committed data files* against the documented selection contract
in ``docs/UserPatch-Data-Format.md`` §3:

1. exact directory name == ``kern.osversion`` (plus exact Darwin major/minor/patch and a valid
   manifest/checksums, enforced by the parser);
2. ``apuMask & candidateFamilyMask != 0`` for the running PCI device ID (mainline-derived conservative
   candidate sets, documented in §3.1);
3. GL/Metal tables (kinds 1/2) are independent of VCN readiness; VDA/AppleGVA tables (kinds 3/4) are
   only eligible while ``NRedVCNBridgeReady`` is non-zero (VCN 2.2 devices only).

This replaces the retired ``tools/test_patchset_selection.py``, which re-implemented the deleted mainline
``UserPatches::selectPatchSet()`` and therefore only tested its own copy. Here a mismatch means the
deployment data is wrong, not that a removed code path changed.

Run with::

    python3 tools/test_patchdata_selection.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
ROOT = TOOLS_DIR.parent
PATCHDATA_DIR = ROOT / "PatchData"

sys.path.insert(0, str(TOOLS_DIR))
from test_userpatch_data import ValidationError, load_generated, parse_manifest  # noqa: E402

# APU family bits (mainline ApuMask, mirrored slightly below).
RAVEN = 1 << 0
RAVEN2 = 1 << 1
PICASSO = 1 << 2
RENOIR = 1 << 3
RENOIR_E = 1 << 4
GREEN_SARDINE = 1 << 5

# Conservative candidate family sets per PCI device ID, as documented in UserPatch-Data-Format §3.1.
CANDIDATE_MASKS = {
    0x15DD: RAVEN,
    0x15D8: RAVEN2 | PICASSO,
    0x1636: RENOIR | RENOIR_E,
    0x164C: RENOIR | RENOIR_E,
    0x15E7: RENOIR | GREEN_SARDINE,
    0x1638: RENOIR | GREEN_SARDINE,
}

# Mainline VCNBridge is only requested for VCN 2.2 profiles; the readiness property is the runtime gate.
VCN22_DEVICE_IDS = frozenset({0x1636, 0x164C, 0x15E7, 0x1638})

EXPECTED_BUILD_DIRS = {"24H32", "23J631", "25G241"}


def select(build: str, darwin: tuple[int, int, int], device_id: int, vcn_ready: bool) -> list[int] | None:
    """Documented selection contract applied to the committed data. ``None`` means no-op."""

    if build not in EXPECTED_BUILD_DIRS:
        return None
    build_dir = PATCHDATA_DIR / build
    if not build_dir.is_dir():
        return None
    _, _, _, parsed = load_generated(build_dir)

    if parsed.build != build or parsed.darwin != darwin:
        return None

    candidate = CANDIDATE_MASKS.get(device_id, 0)
    if candidate == 0 or (parsed.apu_mask & candidate) == 0:
        return None

    vda_enabled = vcn_ready and device_id in VCN22_DEVICE_IDS
    return [table.kind for table in parsed.tables if table.kind in (1, 2) or vda_enabled]


class PatchDataSelectionTest(unittest.TestCase):
    def test_deployment_set_matches_documented_builds(self) -> None:
        actual = {path.name for path in PATCHDATA_DIR.iterdir() if path.is_dir()}
        self.assertEqual(actual, EXPECTED_BUILD_DIRS)

    def test_selection_matrix(self) -> None:
        cases = [
            # build, darwin, device, vcn_ready, expected kinds / None for no-op
            ("24H32", (24, 6, 0), 0x1638, True, [1, 2, 3, 4]),
            ("24H32", (24, 6, 0), 0x1638, False, [1, 2]),
            ("24H32", (24, 6, 0), 0x1636, True, [1, 2, 3, 4]),
            ("24H32", (24, 6, 0), 0x164C, True, [1, 2, 3, 4]),
            ("24H32", (24, 6, 0), 0x15E7, True, [1, 2, 3, 4]),
            ("24H32", (24, 6, 0), 0x15DD, False, [1, 2]),       # Raven: GL/Metal only
            ("24H32", (24, 6, 0), 0x15D8, False, [1, 2]),       # Raven2/Picasso: GL/Metal only
            ("24H32", (24, 6, 0), 0x1234, True, None),          # unknown device: fail closed
            ("24H32", (24, 6, 1), 0x1638, True, None),          # wrong Darwin patch version
            ("23J631", (23, 6, 0), 0x1638, True, [3, 4]),       # VDA-only data set
            ("23J631", (23, 6, 0), 0x1636, True, [3, 4]),
            ("23J631", (23, 6, 0), 0x1638, False, []),          # no GL/Metal data for 14.8.9
            ("23J631", (23, 6, 0), 0x15DD, False, None),       # Raven outside the VDA-only APU mask
            ("25G241", (25, 6, 0), 0x1638, True, [1, 2, 3, 4]),
            ("25G241", (25, 6, 0), 0x15E7, True, [1, 2, 3, 4]),
            ("25G241", (25, 6, 0), 0x1638, False, [1, 2]),
            ("25G241", (25, 6, 0), 0x15DD, False, [1, 2]),
            ("24H31", (24, 6, 0), 0x1638, True, None),          # build directory does not exist
            ("23J630", (23, 6, 0), 0x1638, True, None),
        ]
        for build, darwin, device_id, vcn_ready, expected in cases:
            with self.subTest(build=build, darwin=darwin, device=f"0x{device_id:04X}",
                              vcn_ready=vcn_ready):
                self.assertEqual(select(build, darwin, device_id, vcn_ready), expected)

    def test_15_8_1_has_all_four_kinds_and_14_8_9_has_no_gl_metal(self) -> None:
        _, _, _, parsed = load_generated(PATCHDATA_DIR / "24H32")
        self.assertEqual([table.kind for table in parsed.tables], [1, 2, 3, 4])

        _, _, _, parsed = load_generated(PATCHDATA_DIR / "23J631")
        self.assertEqual([table.kind for table in parsed.tables], [3, 4])
        self.assertNotIn(1, [table.kind for table in parsed.tables])
        self.assertNotIn(2, [table.kind for table in parsed.tables])

    def test_malformed_data_is_rejected_before_selection(self) -> None:
        build_dir = PATCHDATA_DIR / "24H32"
        manifest = (build_dir / "manifest.bin").read_bytes()
        pages = (build_dir / "pages.bin").read_bytes()

        corrupted = bytearray(manifest)
        corrupted[48] ^= 0x01  # manifestSize field
        with self.assertRaises(ValidationError):
            parse_manifest(bytes(corrupted), pages)

        truncated = pages[:-1]
        with self.assertRaises(ValidationError):
            parse_manifest(manifest, truncated)


def main() -> int:
    suite = unittest.TestLoader().loadTestsFromTestCase(PatchDataSelectionTest)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
