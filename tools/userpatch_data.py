#!/usr/bin/env python3
"""Generate the NootedRedUserPatch external patch data (``manifest.bin`` + ``pages.bin``).

Input is an explicit JSON spec plus exact 4 KiB page images. The output is one
directory per macOS build that can be dropped into a PatchData root:

    <out>/<build>/manifest.bin
    <out>/<build>/pages.bin
    <out>/<build>/manifest.json   # human-readable copy, ignored by the kext

The binary layout is defined in ``docs/UserPatch-Data-Format.md``. Adding a new
build means writing a new spec (plus page images); no tool source changes and no
kext rebuild are needed.

Usage::

    python3 tools/userpatch_data.py \
        --spec tools/fixtures/master-15.8.1/spec.json \
        --out build/PatchData

The tool never invents driver bytes: every page must be supplied by the spec and
is pinned by SHA-256. Optional ``drivers`` entries additionally pin a full driver
image hash and verify that each referenced page really is the 4 KiB slice at the
declared file offset.

The format is deliberately strict and deterministic:

* packed little-endian records, no implicit padding;
* canonical table layout (kinds ascending, ranges contiguous, covering arrays);
* identical inputs always produce byte-identical outputs;
* every site must be explicitly offset-addressed and its ``find`` bytes must
  match the page at that offset. If ``find`` occurs more than once on the page,
  the spec must pin the occurrence with ``findOccurrence``. The runtime uses the
  recorded offset; in-page uniqueness is not required (real 15.8.1 data has
  ambiguous find sequences).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path
from typing import Any

# --- Format constants (must match docs/UserPatch-Data-Format.md) -------------------------------

PAGE_SIZE = 0x1000
MAGIC = b"NRPD"
FORMAT_VERSION = 1
HEADER_SIZE = 72
HEADER_CHECKSUM_OFFSET = 64

TABLE_RECORD_SIZE = 24
PAGE_RECORD_SIZE = 16
SITE_RECORD_SIZE = 76

KIND_NAMES = {1: "gl", 2: "metal", 3: "vda-va", 4: "vda-gva"}

APU_MASK_ALL = 0x3F
APU_MASK_BITS = {
    0: "raven",
    1: "raven2",
    2: "picasso",
    3: "renoir",
    4: "renoir-e",
    5: "green-sardine",
}

MAX_TABLES = 16
MAX_PAGES = 64
MAX_SITES = 1024
MAX_MANIFEST_SIZE = 128 * 1024
MAX_PAGES_SIZE = MAX_PAGES * PAGE_SIZE
MAX_FIND_SIZE = 32
MIN_FIND_SIZE = 1
BUILD_MAX_LENGTH = 15

FNV1A32_OFFSET = 0x811C9DC5
FNV1A32_PRIME = 0x01000193
FNV1A64_OFFSET = 0xCBF29CE484222325
FNV1A64_PRIME = 0x100000001B3

BUILD_RE = re.compile(r"[0-9A-Za-z._-]+")
HEX_RE = re.compile(r"[0-9a-fA-F]+")

_HEADER_STRUCT = struct.Struct("<4sHH16sHHHHIIIIIIIIQ")
_TABLE_STRUCT = struct.Struct("<6I")
_PAGE_STRUCT = struct.Struct("<4I")
_SITE_STRUCT = struct.Struct("<II32s32sB3s")

TOP_LEVEL_KEYS = {"schema", "build", "darwin", "apuMask", "tables", "drivers", "provenance", "note"}
DRIVER_KEYS = {"path", "sha256", "size"}
TABLE_KEYS = {"kind", "pages", "note"}
PAGE_KEYS = {"source", "sha256", "sites", "fileOffset", "driver", "note"}
SITE_KEYS = {"offset", "find", "replace", "findOccurrence", "name", "note"}


class SpecError(Exception):
    """Invalid input spec or page data."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SpecError(message)


# --- Checksums ---------------------------------------------------------------------------------


def fnv1a32(data: bytes) -> int:
    value = FNV1A32_OFFSET
    for byte in data:
        value ^= byte
        value = (value * FNV1A32_PRIME) & 0xFFFFFFFF
    return value


def fnv1a64(data: bytes) -> int:
    value = FNV1A64_OFFSET
    for byte in data:
        value ^= byte
        value = (value * FNV1A64_PRIME) & 0xFFFFFFFFFFFFFFFF
    return value


# --- Spec parsing ------------------------------------------------------------------------------


def _check_keys(value: Any, allowed: set[str], where: str) -> dict[str, Any]:
    _require(isinstance(value, dict), f"{where}: expected a JSON object")
    unknown = sorted(set(value) - allowed)
    _require(not unknown, f"{where}: unknown field(s): {', '.join(unknown)}")
    return value


def _int(value: Any, where: str, minimum: int = 0, maximum: int = 0xFFFFFFFF) -> int:
    _require(isinstance(value, int) and not isinstance(value, bool), f"{where}: expected an integer")
    _require(minimum <= value <= maximum, f"{where}: value {value} outside {minimum}..{maximum}")
    return value


def _string(value: Any, where: str) -> str:
    _require(isinstance(value, str), f"{where}: expected a string")
    return value


def _hex_bytes(value: Any, where: str, minimum: int, maximum: int) -> bytes:
    _require(isinstance(value, str), f"{where}: expected a hex string")
    compact = "".join(value.split())
    _require(bool(compact), f"{where}: empty hex string")
    _require(HEX_RE.fullmatch(compact) is not None, f"{where}: invalid hex string {value!r}")
    _require(len(compact) % 2 == 0, f"{where}: hex string must have an even number of digits")
    data = bytes.fromhex(compact)
    _require(minimum <= len(data) <= maximum, f"{where}: {len(data)} byte(s) outside {minimum}..{maximum}")
    return data


def _sha256_hex(value: Any, where: str) -> str:
    text = _string(value, where).lower()
    _require(re.fullmatch(r"[0-9a-f]{64}", text) is not None, f"{where}: expected a 64-digit hex SHA-256")
    return text


def _validate_build(value: Any, where: str) -> str:
    text = _string(value, where)
    _require(1 <= len(text) <= BUILD_MAX_LENGTH,
             f"{where}: build string must be 1..{BUILD_MAX_LENGTH} characters (16-byte NUL-padded field)")
    _require(BUILD_RE.fullmatch(text) is not None,
             f"{where}: build string may only contain [0-9A-Za-z._-]")
    return text


def _validate_darwin(value: Any, where: str) -> tuple[int, int, int]:
    _require(isinstance(value, list) and len(value) == 3, f"{where}: expected [major, minor, patch]")
    major = _int(value[0], f"{where}[0]", 1, 0xFFFF)
    minor = _int(value[1], f"{where}[1]", 0, 0xFFFF)
    patch = _int(value[2], f"{where}[2]", 0, 0xFFFF)
    return major, minor, patch


def _validate_table(table: Any, index: int) -> None:
    where = f"tables[{index}]"
    _check_keys(table, TABLE_KEYS, where)
    kind = _int(table.get("kind"), f"{where}.kind", 0, 0xFFFFFFFF)
    _require(kind in KIND_NAMES, f"{where}.kind: unknown table kind {kind} (known: {sorted(KIND_NAMES)})")
    if "note" in table:
        _string(table["note"], f"{where}.note")
    pages = table.get("pages")
    _require(isinstance(pages, list) and pages, f"{where}.pages: expected a non-empty list")
    for page_index, page in enumerate(pages):
        _validate_page(page, f"{where}.pages[{page_index}]")


def _validate_page(page: Any, where: str) -> None:
    _check_keys(page, PAGE_KEYS, where)
    source = _string(page.get("source"), f"{where}.source")
    _require(source, f"{where}.source: must not be empty")
    _require(not Path(source).is_absolute(), f"{where}.source: must be relative to the spec directory")
    _require(".." not in Path(source).parts, f"{where}.source: must stay inside the spec directory")
    _sha256_hex(page.get("sha256"), f"{where}.sha256")
    if "note" in page:
        _string(page["note"], f"{where}.note")
    if "driver" in page:
        _string(page["driver"], f"{where}.driver")
        _require("fileOffset" in page, f"{where}: driver reference requires fileOffset")
    if "fileOffset" in page:
        _int(page["fileOffset"], f"{where}.fileOffset")
    sites = page.get("sites")
    _require(isinstance(sites, list) and sites, f"{where}.sites: expected a non-empty list")
    for site_index, site in enumerate(sites):
        _validate_site(site, f"{where}.sites[{site_index}]")


def _validate_site(site: Any, where: str) -> None:
    _check_keys(site, SITE_KEYS, where)
    offset = _int(site.get("offset"), f"{where}.offset", 0, PAGE_SIZE)
    find = _hex_bytes(site.get("find"), f"{where}.find", MIN_FIND_SIZE, MAX_FIND_SIZE)
    replace = _hex_bytes(site.get("replace"), f"{where}.replace", MIN_FIND_SIZE, MAX_FIND_SIZE)
    _require(len(find) == len(replace),
             f"{where}: find and replace must have the same length ({len(find)} != {len(replace)}); "
             "the site record stores a single size")
    _require(find != replace, f"{where}: replace bytes are identical to find (no-op site)")
    _require(offset + len(find) <= PAGE_SIZE, f"{where}: site extends past the end of the 4 KiB page")
    if "findOccurrence" in site:
        _int(site["findOccurrence"], f"{where}.findOccurrence", 0, PAGE_SIZE)
    if "name" in site:
        _string(site["name"], f"{where}.name")
    if "note" in site:
        _string(site["note"], f"{where}.note")


def _resolve_relative(relative: str, base_dir: Path, where: str) -> Path:
    path = (base_dir / relative).resolve()
    try:
        path.relative_to(base_dir.resolve())
    except ValueError as error:
        raise SpecError(f"{where}: path {relative!r} escapes the spec directory") from error
    return path


def load_spec(path: Path | str) -> dict[str, Any]:
    """Load and structurally validate a JSON spec. Returns the raw (validated) dict."""

    spec_path = Path(path)
    try:
        text = spec_path.read_text(encoding="utf-8")
    except OSError as error:
        raise SpecError(f"{spec_path}: cannot read spec: {error}") from error
    try:
        spec = json.loads(text)
    except json.JSONDecodeError as error:
        raise SpecError(f"{spec_path}: invalid JSON: {error}") from error

    where = str(spec_path)
    _check_keys(spec, TOP_LEVEL_KEYS, where)

    schema = spec.get("schema")
    _require(isinstance(schema, int) and not isinstance(schema, bool) and schema == FORMAT_VERSION,
             f"{where}: schema must be {FORMAT_VERSION}")
    _validate_build(spec.get("build"), f"{where}.build")
    _validate_darwin(spec.get("darwin"), f"{where}.darwin")
    _int(spec.get("apuMask"), f"{where}.apuMask", 1, APU_MASK_ALL)

    tables = spec.get("tables")
    _require(isinstance(tables, list) and tables, f"{where}.tables: expected a non-empty list")
    _require(len(tables) <= MAX_TABLES, f"{where}.tables: more than {MAX_TABLES} tables")
    kinds: list[int] = []
    for index, table in enumerate(tables):
        _validate_table(table, index)
        kinds.append(table["kind"])
    _require(len(set(kinds)) == len(kinds), f"{where}.tables: duplicate table kind(s) in {kinds}")

    drivers = spec.get("drivers", {})
    _require(isinstance(drivers, dict), f"{where}.drivers: expected an object")
    for name, driver in drivers.items():
        driver_where = f"{where}.drivers.{name}"
        _require(isinstance(name, str) and name, f"{driver_where}: driver name must be a non-empty string")
        _check_keys(driver, DRIVER_KEYS, driver_where)
        path_text = _string(driver.get("path"), f"{driver_where}.path")
        _require(path_text and not Path(path_text).is_absolute(),
                 f"{driver_where}.path: must be relative to the spec directory")
        _require(".." not in Path(path_text).parts, f"{driver_where}.path: must stay inside the spec directory")
        _sha256_hex(driver.get("sha256"), f"{driver_where}.sha256")
        if "size" in driver:
            _int(driver["size"], f"{driver_where}.size", 1)

    if "provenance" in spec:
        _require(isinstance(spec["provenance"], dict), f"{where}.provenance: expected an object")
    if "note" in spec:
        _string(spec["note"], f"{where}.note")

    page_count = sum(len(table["pages"]) for table in tables)
    site_count = sum(len(page["sites"]) for table in tables for page in table["pages"])
    _require(page_count <= MAX_PAGES, f"{where}: {page_count} pages exceeds the {MAX_PAGES}-page limit")
    _require(site_count <= MAX_SITES, f"{where}: {site_count} sites exceeds the {MAX_SITES}-site limit")
    return spec


# --- Page/site resolution ----------------------------------------------------------------------


def _find_all(page: bytes, find: bytes) -> list[int]:
    """All match offsets, including overlapping matches; occurrence index is an index in this list."""

    return [offset for offset in range(len(page) - len(find) + 1) if page.startswith(find, offset)]


def _check_overlap(sites: list[dict[str, Any]], where: str) -> None:
    ranges = sorted((site["offset"], site["offset"] + site["size"]) for site in sites)
    for (start_a, end_a), (start_b, end_b) in zip(ranges, ranges[1:]):
        _require(start_b >= end_a,
                 f"{where}: overlapping patch sites [{start_a:#x}, {end_a:#x}) and "
                 f"[{start_b:#x}, {end_b:#x}) would conflict")


def _load_drivers(spec: dict[str, Any], spec_dir: Path) -> dict[str, bytes]:
    drivers: dict[str, bytes] = {}
    for name, driver in spec.get("drivers", {}).items():
        path = _resolve_relative(driver["path"], spec_dir, f"drivers.{name}.path")
        try:
            data = path.read_bytes()
        except OSError as error:
            raise SpecError(f"drivers.{name}: cannot read {path}: {error}") from error
        digest = hashlib.sha256(data).hexdigest()
        _require(digest == driver["sha256"],
                 f"drivers.{name}: sha256 mismatch for {path}: spec {driver['sha256']}, file {digest}")
        if "size" in driver:
            _require(len(data) == driver["size"],
                     f"drivers.{name}: size mismatch for {path}: spec {driver['size']}, file {len(data)}")
        drivers[name] = data
    return drivers


def _resolve_site(site: dict[str, Any], page: bytes, where: str) -> dict[str, Any]:
    find = _hex_bytes(site["find"], f"{where}.find", MIN_FIND_SIZE, MAX_FIND_SIZE)
    replace = _hex_bytes(site["replace"], f"{where}.replace", MIN_FIND_SIZE, MAX_FIND_SIZE)
    _require(len(find) == len(replace), f"{where}: find and replace lengths differ")
    offset = site["offset"]
    _require(page[offset:offset + len(find)] == find,
             f"{where}: find bytes {find.hex()} not present at page offset {offset:#x}")
    occurrences = _find_all(page, find)
    occurrence = occurrences.index(offset)
    _require(len(occurrences) == 1 or "findOccurrence" in site,
             f"{where}: find {find.hex()} occurs {len(occurrences)} times on the page at offsets "
             f"{[hex(value) for value in occurrences]}; add \"findOccurrence\": {occurrence} to pin the site")
    if "findOccurrence" in site:
        _require(site["findOccurrence"] == occurrence,
                 f"{where}: findOccurrence is {site['findOccurrence']} but the bytes at offset "
                 f"{offset:#x} are occurrence {occurrence}")

    result: dict[str, Any] = {
        "offset": offset,
        "find": find,
        "replace": replace,
        "size": len(find),
        "findOccurrence": occurrence,
        "occurrences": len(occurrences),
    }
    for key in ("name", "note"):
        if key in site:
            result[key] = site[key]
    return result


def _resolve_page(
    page_spec: dict[str, Any],
    spec_dir: Path,
    drivers: dict[str, bytes],
    where: str,
) -> tuple[bytes, list[dict[str, Any]]]:
    source = page_spec["source"]
    path = _resolve_relative(source, spec_dir, f"{where}.source")
    try:
        page = path.read_bytes()
    except OSError as error:
        raise SpecError(f"{where}: cannot read page image {path}: {error}") from error
    _require(len(page) == PAGE_SIZE,
             f"{where}: page image {source} is {len(page)} bytes, exactly {PAGE_SIZE} required")
    digest = hashlib.sha256(page).hexdigest()
    _require(digest == page_spec["sha256"],
             f"{where}: page sha256 mismatch for {source}: spec {page_spec['sha256']}, file {digest}")

    if "driver" in page_spec:
        driver_name = page_spec["driver"]
        _require(driver_name in drivers,
                 f"{where}.driver: {driver_name!r} is not declared under drivers")
        file_offset = page_spec["fileOffset"]
        driver = drivers[driver_name]
        _require(file_offset + PAGE_SIZE <= len(driver),
                 f"{where}.fileOffset: 0x{file_offset:x} + 0x{PAGE_SIZE:x} is past the end of driver "
                 f"{driver_name} ({len(driver)} bytes)")
        _require(driver[file_offset:file_offset + PAGE_SIZE] == page,
                 f"{where}: page bytes do not match driver {driver_name} at file offset 0x{file_offset:x}")

    sites = [_resolve_site(site, page, f"{where}.sites[{index}]")
             for index, site in enumerate(page_spec["sites"])]
    _check_overlap(sites, where)
    return page, sites


# --- Serialization -----------------------------------------------------------------------------


def build_outputs(
    spec: dict[str, Any],
    spec_dir: Path,
    build_override: str | None = None,
) -> tuple[bytes, bytes, bytes]:
    """Build ``(manifest.bin, pages.bin, manifest.json)`` byte strings from a validated spec."""

    build = spec["build"] if build_override is None else _validate_build(build_override, "--build")
    darwin = _validate_darwin(spec["darwin"], "darwin")
    apu_mask = spec["apuMask"]
    drivers = _load_drivers(spec, spec_dir)

    # Canonical v1: tables are emitted in ascending kind order, pages in table order, sites in page
    # order. Table ranges are contiguous and cover the page/site arrays exactly.
    tables = sorted(spec["tables"], key=lambda table: table["kind"])

    pages_bin = bytearray()
    manifest_pages: list[dict[str, Any]] = []
    manifest_tables: list[dict[str, Any]] = []
    site_records: list[tuple[int, int, bytes, bytes]] = []

    for table in tables:
        kind = table["kind"]
        first_page = len(manifest_pages)
        first_site = len(site_records)
        for page_index, page_spec in enumerate(table["pages"]):
            where = f"tables[{kind}].pages[{page_index}]"
            page, sites = _resolve_page(page_spec, spec_dir, drivers, where)
            page_index = len(manifest_pages)
            manifest_page: dict[str, Any] = {
                "index": page_index,
                "tableKind": kind,
                "tableKindName": KIND_NAMES[kind],
                "dataOffset": len(pages_bin),
                "dataSize": PAGE_SIZE,
                "sha256": hashlib.sha256(page).hexdigest(),
                "source": page_spec["source"],
                "sites": [],
            }
            if "fileOffset" in page_spec:
                manifest_page["fileOffset"] = page_spec["fileOffset"]
            if "driver" in page_spec:
                manifest_page["driver"] = page_spec["driver"]
            if "note" in page_spec:
                manifest_page["note"] = page_spec["note"]
            for site_index, site in enumerate(sites):
                site_records.append((page_index, site["offset"], site["find"], site["replace"]))
                manifest_page["sites"].append({
                    "pageIndex": page_index,
                    "offset": site["offset"],
                    "size": site["size"],
                    "find": site["find"].hex(),
                    "replace": site["replace"].hex(),
                    "findOccurrence": site["findOccurrence"],
                    "occurrences": site["occurrences"],
                    **({"name": site["name"]} if "name" in site else {}),
                    **({"note": site["note"]} if "note" in site else {}),
                })
            pages_bin.extend(page)
            manifest_pages.append(manifest_page)

        manifest_table: dict[str, Any] = {
            "kind": kind,
            "kindName": KIND_NAMES[kind],
            "pageIndex": first_page,
            "pageCount": len(manifest_pages) - first_page,
            "siteIndex": first_site,
            "siteCount": len(site_records) - first_site,
        }
        if "note" in table:
            manifest_table["note"] = table["note"]
        manifest_tables.append(manifest_table)

    table_count = len(manifest_tables)
    page_count = len(manifest_pages)
    site_count = len(site_records)
    pages_data = bytes(pages_bin)

    manifest_size = (HEADER_SIZE + table_count * TABLE_RECORD_SIZE
                     + page_count * PAGE_RECORD_SIZE + site_count * SITE_RECORD_SIZE)
    _require(manifest_size <= MAX_MANIFEST_SIZE,
             f"manifest would be {manifest_size} bytes, limit is {MAX_MANIFEST_SIZE}")
    _require(len(pages_data) <= MAX_PAGES_SIZE,
             f"pages.bin would be {len(pages_data)} bytes, limit is {MAX_PAGES_SIZE}")

    pages_checksum = fnv1a32(pages_data)

    build_field = build.encode("ascii")
    header = _HEADER_STRUCT.pack(
        MAGIC,
        FORMAT_VERSION,
        HEADER_SIZE,
        build_field,
        darwin[0],
        darwin[1],
        darwin[2],
        0,
        apu_mask,
        table_count,
        page_count,
        site_count,
        manifest_size,
        len(pages_data),
        pages_checksum,
        0,
        0,
    )

    tables_blob = b"".join(
        _TABLE_STRUCT.pack(table["kind"], table["pageIndex"], table["pageCount"],
                           table["siteIndex"], table["siteCount"], 0)
        for table in manifest_tables
    )
    pages_blob = b"".join(
        _PAGE_STRUCT.pack(page["dataOffset"], page["dataSize"], 0, 0) for page in manifest_pages
    )
    sites_blob = b"".join(
        _SITE_STRUCT.pack(page_index, offset, find.ljust(MAX_FIND_SIZE, b"\x00"),
                          replace.ljust(MAX_FIND_SIZE, b"\x00"), len(find), b"\x00\x00\x00")
        for page_index, offset, find, replace in site_records
    )

    manifest = bytearray(header + tables_blob + pages_blob + sites_blob)
    _require(len(manifest) == manifest_size, "internal error: manifest size mismatch")
    manifest_checksum = fnv1a64(bytes(manifest))
    struct.pack_into("<Q", manifest, HEADER_CHECKSUM_OFFSET, manifest_checksum)

    document: dict[str, Any] = {
        "schemaVersion": FORMAT_VERSION,
        "format": "NootedRedUserPatch manifest.bin",
        "build": build,
        "darwin": {"major": darwin[0], "minor": darwin[1], "patch": darwin[2]},
        "apuMask": apu_mask,
        "apuMaskBits": {str(bit): name for bit, name in APU_MASK_BITS.items() if apu_mask & (1 << bit)},
        "counts": {"tables": table_count, "pages": page_count, "sites": site_count},
        "sizes": {"manifest": manifest_size, "pages": len(pages_data)},
        "checksums": {
            "manifest": f"0x{manifest_checksum:016x}",
            "pages": f"0x{pages_checksum:08x}",
        },
        "tables": manifest_tables,
        "pages": manifest_pages,
    }
    for key in ("drivers", "provenance", "note"):
        if key in spec:
            document[key] = spec[key]

    json_bytes = (json.dumps(document, indent=2, ensure_ascii=True) + "\n").encode("utf-8")
    return bytes(manifest), pages_data, json_bytes


def write_build(
    spec_path: Path | str,
    out_root: Path | str,
    build_override: str | None = None,
) -> Path:
    """Generate one ``<out_root>/<build>/`` directory. Returns the build directory path."""

    spec_path = Path(spec_path)
    spec = load_spec(spec_path)
    manifest, pages, document = build_outputs(spec, spec_path.resolve().parent, build_override)
    build = spec["build"] if build_override is None else build_override
    build_dir = Path(out_root) / build
    build_dir.mkdir(parents=True, exist_ok=True)
    (build_dir / "manifest.bin").write_bytes(manifest)
    (build_dir / "pages.bin").write_bytes(pages)
    (build_dir / "manifest.json").write_bytes(document)
    return build_dir


# --- CLI ---------------------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate NootedRedUserPatch manifest.bin/pages.bin/manifest.json from a JSON spec.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "The spec names exact 4 KiB page images relative to the spec directory and pins each\n"
            "by SHA-256. Every site is addressed by explicit page offset; ambiguous find sequences\n"
            "need an explicit findOccurrence. Adding a build is data-only: a new spec plus pages.\n"
        ),
    )
    parser.add_argument("--spec", required=True, type=Path, help="JSON input spec")
    parser.add_argument("--out", required=True, type=Path,
                        help="PatchData root; output goes to <out>/<build>/")
    parser.add_argument("--build", default=None,
                        help="override the build string/directory name (default: spec build)")
    parser.add_argument("--quiet", action="store_true", help="suppress the summary line")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        build_dir = write_build(args.spec, args.out, args.build)
        manifest = (build_dir / "manifest.bin").read_bytes()
        pages = (build_dir / "pages.bin").read_bytes()
        if not args.quiet:
            table_count, page_count, site_count = struct.unpack_from("<III", manifest, 36)
            print(f"wrote {build_dir}/")
            print(f"  manifest.bin  {len(manifest)} bytes ({table_count} table(s), "
                  f"{page_count} page(s), {site_count} site(s))")
            print(f"  pages.bin     {len(pages)} bytes")
            print(f"  manifest.json human-readable copy")
    except SpecError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
