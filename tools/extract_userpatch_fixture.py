#!/usr/bin/env python3
"""Derive the checked-in ``tools/fixtures/master-15.8.1`` fixture from master's page tables.

The fixture is *real* 15.8.1 patch data: the three exact 4 KiB page images and the four find/replace
sites are decoded from the C++ byte arrays in ``NootedRed/UserPatches.cpp`` (the same arrays the
mainline kext uses for its exact-page backend). No driver bytes are invented and no driver binaries
are copied into the repository; the provenance block in ``spec.json`` pins the source file hashes,
the source array/patch-table names and the driver build the pages came from.

The offsets and occurrence numbers are not hand-written: they are derived from the patch table's
``skip``/``count`` fields, exactly like Lilu does, and must land on matching bytes in the page.

Usage::

    python3 tools/extract_userpatch_fixture.py            # rewrite the fixture
    python3 tools/extract_userpatch_fixture.py --check     # verify the fixture is up to date

The test suite imports :func:`extract` to cross-check the checked-in fixture against the current
source tree, so a stale or hand-edited fixture fails validation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

import master_source

ROOT = Path(__file__).resolve().parents[1]
LIVE_SOURCE = ROOT / "NootedRed" / "UserPatches.cpp"
PINNED_SOURCE = master_source.PINNED_ROOT / "NootedRed" / "UserPatches.cpp"
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "master-15.8.1"


def default_source() -> Path:
    """Prefer the live tree if master's file exists, otherwise the pinned master snapshot."""

    return LIVE_SOURCE if LIVE_SOURCE.is_file() else PINNED_SOURCE

PAGE_SIZE = 0x1000

BYTE_ARRAY_RE = re.compile(r"(?:static\s+)?const\s+UInt8\s+(\w+)\s*\[\s*\]\s*=\s*\{(.*?)\}\s*;", re.S)
HEX_BYTE_RE = re.compile(r"0x([0-9A-Fa-f]{2})")

PATCH_TABLE_RE = re.compile(
    r"const\s+UserPatches::PagePatch\s+kGLDriverPatches\s*\[\s*\]\s*=\s*\{(.*?)\n\s*\};", re.S
)
PATCH_ROW_RE = re.compile(
    r"\{\s*UserPatcher::FileSegment::(\w+)\s*,\s*"
    r"(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*sizeof\(\s*(\w+)\s*\)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}",
    re.S,
)

# Fixture-local names for the arrays referenced by the 15.8.1 table.
PAGE_FILES = {
    "kGLDriverHwInfoPage": ("gl-driver-hwinfo-0xE000.bin", 0xE000,
                            "exact 4 KiB AMDRadeonX5000GLDriver page at file offset 0xE000 "
                            "(master array kGLDriverHwInfoPage)"),
    "kGLDriverDualQuadPage": ("gl-driver-dualquad-0x8000.bin", 0x8000,
                              "exact 4 KiB AMDRadeonX5000GLDriver page at file offset 0x8000 "
                              "(master array kGLDriverDualQuadPage)"),
    "kMTLControlPage": ("mtl-driver-control-page.bin", None,
                        "exact 4 KiB AMDRadeonX5000MTLDriver shared-cache page containing the "
                        "CB_COLOR_CONTROL pipeline setup (master array kMTLControlPage); the "
                        "master source does not record a file offset for this page"),
}
SITE_NAMES = {
    "kGLDriverHwInfoFind": "gfx9 HwInfo shader-engine count (Vega10 branch)",
    "kGLDriverDualQuadFind": "dual-quad CB_COLOR_CONTROL.DISABLE_DUAL_QUAD",
    "kMTLGateFind": "Metal RB+ gate",
    "kMTLAllowFind": "Metal allowRBPlus",
}
SITE_NOTES = {
    "kGLDriverHwInfoFind": "page offset 0x81; the same 7-byte find also occurs at 0xCC and 0x109, "
                           "only the first occurrence is patched (master skip=0, count=1)",
    "kGLDriverDualQuadFind": "page offset 0x160; the same 3-byte find also occurs at 0x68 "
                             "(master skip=1, count=1)",
    "kMTLGateFind": "page offset 0x164 (jnz over the condition)",
    "kMTLAllowFind": "page offset 0x198; the same 3-byte find also occurs at 0x722 "
                     "(master skip=0, count=1)",
}


class FixtureError(Exception):
    pass


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise FixtureError(message)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_arrays(text: str) -> dict[str, bytes]:
    arrays: dict[str, bytes] = {}
    for match in BYTE_ARRAY_RE.finditer(text):
        name = match.group(1)
        values = bytes(int(value, 16) for value in HEX_BYTE_RE.findall(match.group(2)))
        _require(name not in arrays, f"duplicate array {name}")
        arrays[name] = values
    return arrays


def find_occurrences(page: bytes, find: bytes) -> list[int]:
    return [offset for offset in range(len(page) - len(find) + 1) if page.startswith(find, offset)]


def parse_patch_table(text: str) -> list[dict[str, Any]]:
    table = PATCH_TABLE_RE.search(text)
    _require(table is not None, "missing 15.8.1 patch table kGLDriverPatches[]")
    rows = []
    for match in PATCH_ROW_RE.finditer(table.group(1)):
        segment, page_name, find_name, replace_name, size_name, skip, count = match.groups()
        rows.append({
            "segment": segment,
            "page": page_name,
            "find": find_name,
            "replace": replace_name,
            "sizeName": size_name,
            "skip": int(skip),
            "count": int(count),
        })
    _require(rows, "15.8.1 patch table kGLDriverPatches[] has no rows")
    return rows


def extract(source: Path | None = None) -> dict[str, Any]:
    """Return ``{"pages": {filename: bytes}, "spec": dict}`` for the fixture."""

    source = Path(source) if source is not None else default_source()
    _require(source.is_file(), f"missing source file {source}")
    text = source.read_text(encoding="utf-8")
    arrays = parse_arrays(text)
    rows = parse_patch_table(text)

    _require(len(arrays) > 0, "no byte arrays parsed from the source")
    pages: dict[str, bytes] = {}
    tables: dict[int, dict[str, Any]] = {}
    page_site_map: dict[str, list[dict[str, Any]]] = {}

    for row in rows:
        page_name = row["page"]
        _require(page_name in arrays, f"{page_name}: page array not found")
        _require(row["find"] in arrays, f"{row['find']}: find array not found")
        _require(row["replace"] in arrays, f"{row['replace']}: replace array not found")
        _require(row["sizeName"] == row["find"], f"{row['sizeName']}: sizeof() must name the find array")

        find = arrays[row["find"]]
        replace = arrays[row["replace"]]
        _require(len(find) == len(replace),
                 f"{row['find']}: find/replace length mismatch")
        _require(1 <= len(find) <= 32, f"{row['find']}: size {len(find)} outside 1..32")
        _require(page_name in PAGE_FILES, f"{page_name}: no fixture file mapping")

        page = arrays[page_name]
        _require(len(page) == PAGE_SIZE, f"{page_name}: {len(page)} bytes, expected {PAGE_SIZE}")
        occurrences = find_occurrences(page, find)
        selected = occurrences[row["skip"]:row["skip"] + row["count"]]
        _require(len(selected) == row["count"],
                 f"{row['find']}: expected {row['count']} occurrence(s) after skip={row['skip']}, "
                 f"found {len(occurrences)} total")
        for selected_index, offset in enumerate(selected):
            site = {
                "offset": offset,
                "find": find.hex(),
                "replace": replace.hex(),
                "findOccurrence": row["skip"] + selected_index,
                "name": SITE_NAMES.get(row["find"], row["find"]),
                "note": SITE_NOTES.get(row["find"], ""),
            }
            if not site["note"]:
                del site["note"]
            page_site_map.setdefault(page_name, []).append(site)

        kind = 2 if "MTL" in page_name else 1
        table = tables.setdefault(kind, {"kind": kind, "pages": []})
        known_pages = [entry["page"] for entry in table["pages"]]
        if page_name not in known_pages:
            table["pages"].append({"array": page_name, "page": page_name})

    # Order tables by kind (matching the canonical manifest layout) and pages by first table use.
    spec_tables: list[dict[str, Any]] = []
    for kind in sorted(tables):
        table = tables[kind]
        spec_pages: list[dict[str, Any]] = []
        offset_seen: set[int] = set()
        for entry in table["pages"]:
            page_name = entry["page"]
            file_name, file_offset, page_note = PAGE_FILES[page_name]
            _require(file_name not in pages, f"{file_name}: duplicate fixture page")
            page = arrays[page_name]
            pages[file_name] = page
            page_spec: dict[str, Any] = {
                "source": f"pages/{file_name}",
                "sha256": sha256_hex(page),
                "sites": page_site_map[page_name],
            }
            if file_offset is not None:
                page_spec["fileOffset"] = file_offset
                _require(file_offset not in offset_seen, "duplicate page file offset")
                offset_seen.add(file_offset)
            page_spec["note"] = page_note
            spec_pages.append(page_spec)
        spec_table: dict[str, Any] = {
            "kind": kind,
            "note": ("AMDRadeonX5000GLDriver exact pages" if kind == 1
                     else "AMDRadeonX5000MTLDriver exact page (same validation hook path)"),
            "pages": spec_pages,
        }
        spec_tables.append(spec_table)

    _require([table["kind"] for table in spec_tables] == [1, 2],
             "unexpected table kinds; fixture expects GL (1) and Metal (2)")

    spec = {
        "schema": 1,
        "build": "24H32",
        "darwin": [24, 6, 0],
        "apuMask": 0x3F,
        "note": ("Real 15.8.1 page/site data derived from master's exact-page tables. "
                 "See README.md for provenance; this is a test fixture, not an installed build."),
        "provenance": {
            "origin": "decoded from the exact 4 KiB page arrays and PagePatch table in master's "
                      "NootedRed/UserPatches.cpp",
            "sourceFiles": [
                {"path": "NootedRed/UserPatches.cpp", "sha256": sha256_hex(source.read_bytes())},
            ],
            "patchTable": "kGLDriverPatches",
            "pageArrays": sorted(PAGE_FILES),
            "driverBuild": ("AMDRadeonX5000GLDriver 7.0.25 / macOS 15.8.1 (Darwin 24.6.0) / "
                            "kern.osversion 24H32 (per master source comments)"),
            "metalDriverBuild": ("AMDRadeonX5000MTLDriver / macOS 15.8.1 shared-cache page "
                                 "(kMTLControlPage)"),
            "apuMaskNote": ("master's 15.8.1 Renoir-family, Raven-family and gfx9 fallback sets "
                            "share byte-identical page tables; the fixture declares their union "
                            "mask 0x3F"),
            "extractor": "tools/extract_userpatch_fixture.py",
            "note": ("No driver binaries are included or needed. The page images are the byte "
                     "arrays master uses for patching; master extracted them from the real driver "
                     "build. The extractor derives every site offset and occurrence index from the "
                     "PagePatch skip/count fields instead of trusting hand-written offsets."),
        },
        "tables": spec_tables,
    }
    return {"pages": pages, "spec": spec}


def write_fixture(fixture_dir: Path = FIXTURE, source: Path | None = None) -> list[Path]:
    result = extract(source)
    fixture_dir.mkdir(parents=True, exist_ok=True)
    pages_dir = fixture_dir / "pages"
    pages_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for file_name, data in sorted(result["pages"].items()):
        path = pages_dir / file_name
        path.write_bytes(data)
        written.append(path)
    spec_path = fixture_dir / "spec.json"
    spec_path.write_text(json.dumps(result["spec"], indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    written.append(spec_path)
    return written


def check_fixture(fixture_dir: Path = FIXTURE, source: Path | None = None) -> list[str]:
    """Return a list of differences between the source-derived fixture and the checked-in files."""

    result = extract(source)
    problems: list[str] = []
    for file_name, data in sorted(result["pages"].items()):
        path = fixture_dir / "pages" / file_name
        if not path.is_file():
            problems.append(f"missing {path}")
        elif path.read_bytes() != data:
            problems.append(f"{path}: page bytes differ from source")
    spec_path = fixture_dir / "spec.json"
    expected = json.dumps(result["spec"], indent=2, ensure_ascii=True) + "\n"
    if not spec_path.is_file():
        problems.append(f"missing {spec_path}")
    elif spec_path.read_text(encoding="utf-8") != expected:
        problems.append(f"{spec_path}: spec differs from source-derived spec")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Regenerate/verify tools/fixtures/master-15.8.1.")
    parser.add_argument("--check", action="store_true", help="verify the fixture without writing")
    parser.add_argument("--source", type=Path, default=None,
                        help="UserPatches.cpp to read (default: live tree, else the pinned master snapshot)")
    parser.add_argument("--fixture", type=Path, default=FIXTURE, help="fixture directory")
    args = parser.parse_args(argv)
    try:
        if args.check:
            problems = check_fixture(args.fixture, args.source)
            if problems:
                for problem in problems:
                    print(f"error: {problem}", file=sys.stderr)
                return 1
            print(f"ok: {args.fixture} matches the source-derived 15.8.1 fixture")
            return 0
        written = write_fixture(args.fixture, args.source)
        for path in written:
            print(f"wrote {path}")
        return 0
    except FixtureError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
