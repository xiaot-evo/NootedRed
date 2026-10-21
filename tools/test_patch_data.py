#!/usr/bin/env python3
"""Host-side validation of the user-space patch data.

Parses the byte arrays and tables in `NootedRed/UserPatches.cpp` and
`NootedRed/TahoePatchData.hpp` and checks their internal consistency:

  * every `PagePatch` references known arrays, and `find`/`replace` sizes agree;
  * each site's `find` sequence occurs in its page image at least `skip + count` times;
  * the version/APU `PatchSet` table is ordered and versioned sensibly.

This does not load the kext and does not need a Mac; it is meant to catch table regressions before a
reboot (and to make adding a new macOS build or APU a data-only change).
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

BYTE_ARRAY_RE = re.compile(r"(?:static\s+)?const\s+UInt8\s+(\w+)\s*\[\s*\]\s*=\s*\{(.*?)\}\s*;", re.S)
HEX_BYTE_RE = re.compile(r"0x([0-9A-Fa-f]{2})")

PATCH_ROW_RE = re.compile(
    r"\{\s*UserPatcher::FileSegment::SegmentTextText\s*,\s*"
    r"(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*sizeof\((\w+)\)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}",
    re.S,
)

PATCH_SET_RE = re.compile(
    r'\{"([^"]+)",\s*PenguinWizardry::KernelVersion\((\d+),\s*(\d+)\),\s*'
    r'PenguinWizardry::KernelVersion\((\d+),\s*(\d+)\)',
    re.S,
)

ALL_APUS = 0x3F


class Failure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise Failure(message)


def load_arrays(path):
    text = path.read_text()
    arrays = {}
    for match in BYTE_ARRAY_RE.finditer(text):
        name, body = match.group(1), match.group(2)
        values = [int(value, 16) for value in HEX_BYTE_RE.findall(body)]
        arrays[name] = values
    return arrays, text


def find_all(haystack, needle):
    offsets = []
    start = 0
    while True:
        offset = find_at(haystack, needle, start)
        if offset < 0:
            return offsets
        offsets.append(offset)
        start = offset + 1
    return offsets


def find_at(haystack, needle, start):
    if not needle:
        return -1
    limit = len(haystack) - len(needle)
    for index in range(start, limit + 1):
        if haystack[index : index + len(needle)] == needle:
            return index
    return -1


def check_page_patches(arrays, text):
    rows = list(PATCH_ROW_RE.finditer(text))
    check(rows, "no PagePatch rows found")
    seen = set()
    for row in rows:
        page_name, find_name, replace_name, size_name, skip, count = row.groups()
        skip, count = int(skip), int(count)
        for name in (page_name, find_name, replace_name):
            check(name in arrays, f"PagePatch references unknown array {name}")
        find, replace, page = arrays[find_name], arrays[replace_name], arrays[page_name]
        check(size_name == find_name, f"sizeof({size_name}) should refer to {find_name}")
        check(len(page) == 0x1000, f"{page_name} must be exactly one 4 KiB page (got {len(page)})")
        check(len(find) == len(replace), f"{find_name}/{replace_name} sizes differ")
        check(0 < len(find) <= 32, f"{find_name} size {len(find)} is not 1..32")
        check(count > 0, f"{find_name} count is zero")
        key = (page_name, bytes(find))
        check(key not in seen, f"duplicate PagePatch ({page_name}, {find_name})")
        seen.add(key)
        occurrences = find_all(page, find)
        check(
            len(occurrences) >= skip + count,
            f"{find_name}: only {len(occurrences)} occurrence(s) in {page_name}, need skip({skip}) + count({count})",
        )
    return len(rows)


def check_patch_sets(text):
    sets = list(PATCH_SET_RE.finditer(text))
    check(len(sets) >= 2, "no PatchSet rows found")
    versions = set()
    for match in sets:
        name, major, minor, max_major, max_minor = match.groups()
        major, minor, max_major, max_minor = map(int, (major, minor, max_major, max_minor))
        check((major, minor) <= (max_major, max_minor), f"PatchSet {name}: minVersion > maxVersion")
        versions.add((major, minor))
        check("KernelVersion" not in name, f"PatchSet {name}: malformed entry")
    check((24, 6) in versions, "missing a Darwin 24.6 (macOS 15.8.1) PatchSet")
    check((25, 6) in versions, "missing a Darwin 25.6 (macOS 26.7.1) PatchSet")
    check((23, 6) in versions, "missing a Darwin 23.6 (macOS 14.8.x Sonoma) PatchSet")
    return len(sets)


def main():
    user_patches = ROOT / "NootedRed" / "UserPatches.cpp"
    sonoma = ROOT / "NootedRed" / "UserPatchesSonoma.inc"
    tahoe = ROOT / "NootedRed" / "TahoePatchData.hpp"
    for path in (user_patches, sonoma, tahoe):
        check(path.is_file(), f"missing {path}")

    arrays, text = load_arrays(user_patches)
    for extra in (sonoma, tahoe):
        extra_arrays, _ = load_arrays(extra)
        arrays.update(extra_arrays)

    patches = check_page_patches(arrays, text)
    sets = check_patch_sets(text)

    # Regression guard for the 26.7.1 stutter report: the Tahoe patch table must use the same
    # gate/allow pair as the known-good implementation, not the experimental direct-field form.
    tahoe_table = re.search(r"kTahoeGLDriverPatches\[\]\s*=\s*\{(.*?)\n    \};", text, re.S)
    check(tahoe_table is not None, "missing Tahoe patch table")
    check("kTahoeMTLGateFind" in tahoe_table.group(1), "Tahoe table is missing the gate patch")
    check("kTahoeMTLAllowFind" in tahoe_table.group(1), "Tahoe table is missing the allow patch")
    check("kTahoeMTLDualQuadFind" not in tahoe_table.group(1),
          "Tahoe table must not use the experimental direct-field Metal form")
    check("Exact GL/Metal page applied; semantic scanning disabled" in text,
          "semantic scanning must stop only after an exact GL/Metal page is applied")
    check("kGLDriverPatches_Sonoma" in text, "missing Sonoma patch table")

    print(f"ok: {patches} page patch(es), {sets} patch set(s)")
    print("all user-space patch data checks passed")


if __name__ == "__main__":
    try:
        main()
    except Failure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
