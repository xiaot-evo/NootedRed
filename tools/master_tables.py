#!/usr/bin/env python3
"""Parsers for the pinned master C++ table sources.

The mainline tables are plain C++ arrays (``static const UInt8 Name[]`` / ``inline constexpr UInt8
Page0[4096]``) and ``UserPatches::PagePatch`` rows. This module decodes them without compiling
anything, so the fixture/spec/PatchData derivation can be verified from the pinned snapshot at HEAD.

Only read-only parsing lives here; the data policy (which build/table/kind a row belongs to) is in
``tools/convert_master_patchdata.py``.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PAGE_SIZE = 0x1000

BYTE_ARRAY_RE = re.compile(
    r"(?:static\s+|inline\s+)?(?:constexpr\s+)?(?:const\s+)?UInt8\s+(\w+)\s*\[\s*\d*\s*\]\s*=\s*\{(.*?)\}\s*;",
    re.S,
)
HEX_BYTE_RE = re.compile(r"0x([0-9A-Fa-f]{2})")

PATCH_ROW_RE = re.compile(
    r"\{\s*UserPatcher::FileSegment::(\w+)\s*,\s*"
    r"(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*sizeof\(\s*(\w+)\s*\)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}",
    re.S,
)
SOURCE_DESCRIPTION_RE = re.compile(r"SourceDescription\s*\[\s*\]\s*=\s*((?:\"[^\"]*\"\s*)+)\s*;", re.S)
SOURCE_DESCRIPTION_PART_RE = re.compile(r"\"([^\"]*)\"")

OFFSET_RES = (
    re.compile(r"(?:file page at|File offset|image offset)\s*(0x[0-9A-Fa-f]+)"),
)


class TableParseError(Exception):
    """A pinned table source could not be parsed unambiguously."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise TableParseError(message)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_byte_arrays(text: str, where: str = "<source>") -> dict[str, bytes]:
    arrays: dict[str, bytes] = {}
    for match in BYTE_ARRAY_RE.finditer(text):
        name = match.group(1)
        values = bytes(int(value, 16) for value in HEX_BYTE_RE.findall(match.group(2)))
        _require(name not in arrays, f"{where}: duplicate byte array {name}")
        _require(bool(values), f"{where}: empty byte array {name}")
        arrays[name] = values
    _require(bool(arrays), f"{where}: no byte arrays found")
    return arrays


@dataclass(frozen=True)
class PatchRow:
    page: str
    find: str
    replace: str
    skip: int
    count: int
    where: str


def parse_patch_rows(text: str, table_name: str, where: str = "<source>") -> list[PatchRow]:
    table = re.search(rf"\b{re.escape(table_name)}\s*\[\s*\]\s*=\s*\{{(.*?)\n\s*\}};", text, re.S)
    _require(table is not None, f"{where}: missing patch table {table_name}[]")
    rows = []
    for match in PATCH_ROW_RE.finditer(table.group(1)):
        segment, page, find, replace, size_name, skip, count = match.groups()
        _require(segment == "SegmentTextText", f"{where}: {table_name}[] uses non-text segment {segment}")
        _require(size_name == find, f"{where}: {table_name}[] sizeof({size_name}) does not name the find array")
        rows.append(PatchRow(page, find, replace, int(skip), int(count), where))
    _require(bool(rows), f"{where}: patch table {table_name}[] has no rows")
    return rows


def parse_source_description(text: str) -> str | None:
    match = SOURCE_DESCRIPTION_RE.search(text)
    if match is None:
        return None
    return "".join(SOURCE_DESCRIPTION_PART_RE.findall(match.group(1)))


def _preceding_comment_block(text: str, index: int) -> str:
    lines = text[:index].splitlines()
    collected: list[str] = []
    for line in reversed(lines):
        stripped = line.strip()
        if stripped.startswith("//"):
            collected.append(stripped[2:].strip())
        elif not stripped:
            if collected:
                break
            continue
        else:
            break
    return "\n".join(reversed(collected))


def page_comment_block(text: str, array_name: str) -> str:
    """Return the contiguous comment block immediately above a byte-array definition."""

    match = re.search(rf"\b{re.escape(array_name)}\s*\[\s*\d*\s*\]\s*=\s*\{{", text)
    _require(match is not None, f"array {array_name} not found")
    line_start = text.rfind("\n", 0, match.start()) + 1
    return _preceding_comment_block(text, line_start)


def page_provenance(text: str, array_name: str) -> dict[str, Any]:
    """Human note plus any recorded page offset from the comment above an array."""

    block = page_comment_block(text, array_name)
    lines = [line for line in block.splitlines() if line]
    note = ""
    for line in lines:
        if re.search(r"Page \d+:", line) or re.search(r"source page", line, re.I):
            note = line
            break
    if not note and lines:
        note = lines[0]
    offset = None
    for pattern in OFFSET_RES:
        match = pattern.search(block)
        if match is not None:
            offset = int(match.group(1), 16)
            break
    return {"note": note, "recordedOffset": offset}


def find_all(page: bytes, find: bytes) -> list[int]:
    """All match offsets including overlapping matches; occurrence index indexes this list."""

    return [offset for offset in range(len(page) - len(find) + 1) if page.startswith(find, offset)]


def slugify(name: str) -> str:
    """Deterministic file-name fragment from a C++ array name."""

    stripped = name[1:] if name.startswith("k") else name
    stripped = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "-", stripped)
    stripped = re.sub(r"[^0-9A-Za-z]+", "-", stripped).strip("-").lower()
    return stripped or "page"


def derive_sites(
    rows: list[PatchRow],
    arrays: dict[str, bytes],
    selected_page: str,
) -> list[dict[str, Any]]:
    """Resolve rows belonging to one page into explicit site specs (offset + occurrence)."""

    sites: list[dict[str, Any]] = []
    page = arrays[selected_page]
    _require(len(page) == PAGE_SIZE, f"{selected_page}: {len(page)} bytes, expected {PAGE_SIZE}")
    for row in rows:
        _require(row.page == selected_page, f"{row.where}: row page {row.page} != {selected_page}")
        _require(row.find in arrays, f"{row.where}: find array {row.find} not found")
        _require(row.replace in arrays, f"{row.where}: replace array {row.replace} not found")
        find = arrays[row.find]
        replace = arrays[row.replace]
        _require(1 <= len(find) <= 32, f"{row.where}: find {row.find} has {len(find)} bytes")
        _require(len(find) == len(replace),
                 f"{row.where}: {row.find}/{row.replace} length mismatch "
                 f"({len(find)} != {len(replace)})")
        occurrences = find_all(page, find)
        selected = occurrences[row.skip:row.skip + row.count]
        _require(len(selected) == row.count,
                 f"{row.where}: {row.find} has {len(occurrences)} occurrence(s) on {selected_page}, "
                 f"skip={row.skip} count={row.count} does not fit")
        for index, offset in enumerate(selected):
            sites.append({
                "offset": offset,
                "find": find.hex(),
                "replace": replace.hex(),
                "findOccurrence": row.skip + index,
                "name": f"{row.find} -> {row.replace}",
                "note": f"{row.where}: {row.find} occurrence {row.skip + index} of {len(occurrences)}",
            })
    overlap = sorted((site["offset"], site["offset"] + len(bytes.fromhex(site["find"]))) for site in sites)
    for (start_a, end_a), (start_b, end_b) in zip(overlap, overlap[1:]):
        _require(start_b >= end_a,
                 f"{selected_page}: overlapping sites [0x{start_a:x},0x{end_a:x}) and "
                 f"[0x{start_b:x},0x{end_b:x})")
    return sites


def group_rows_by_page(rows: list[PatchRow]) -> dict[str, list[PatchRow]]:
    grouped: dict[str, list[PatchRow]] = {}
    for row in rows:
        grouped.setdefault(row.page, []).append(row)
    return grouped


def check_page_file(path: Path) -> bytes:
    data = path.read_bytes()
    _require(len(data) == PAGE_SIZE, f"{path}: {len(data)} bytes, expected {PAGE_SIZE}")
    return data
