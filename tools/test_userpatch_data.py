#!/usr/bin/env python3
"""Independent validator and regression tests for the UserPatch data tooling.

This file deliberately re-implements the binary parser instead of importing one from
``tools/userpatch_data.py``: the generator and the validator must agree only through
``docs/UserPatch-Data-Format.md``. It checks, on generated data:

* magic / version / header size / reserved fields / build and Darwin identity;
* ``manifestSize`` formula and exact file length, ``pagesSize`` and both checksums;
* canonical table layout and table/page/site range bounds;
* 4 KiB page alignment/size, page blobs and per-page SHA-256;
* every site: size, offset, page bounds, find bytes at the declared offset, zero padding;
* human-readable ``manifest.json`` consistency, find occurrence acknowledgements and
  non-overlapping site writes;
* malformed manifests and pages are rejected with a specific reason.

Run it with::

    python3 tools/test_userpatch_data.py

No kext, driver binary, network or macOS-only API is needed: the checked-in fixture
(``tools/fixtures/master-15.8.1``) is real 15.8.1 page/site data decoded from master's
``NootedRed/UserPatches.cpp`` (see its README for provenance).
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import Any

TOOLS_DIR = Path(__file__).resolve().parent
ROOT = TOOLS_DIR.parent

sys.path.insert(0, str(TOOLS_DIR))
import convert_master_patchdata as converter  # noqa: E402
import extract_userpatch_fixture as fixture_extractor  # noqa: E402
import master_source  # noqa: E402
import master_tables  # noqa: E402
import userpatch_data as generator  # noqa: E402

FIXTURE_DIR = TOOLS_DIR / "fixtures" / "master-15.8.1"
FIXTURE_SPEC = FIXTURE_DIR / "spec.json"
MINIMAL_FIXTURE_DIR = TOOLS_DIR / "fixtures" / "minimal-24H32"
MINIMAL_SPEC = MINIMAL_FIXTURE_DIR / "spec.json"
GENERATOR = TOOLS_DIR / "userpatch_data.py"
SOURCE_CPP = ROOT / "NootedRed" / "UserPatches.cpp"
PINNED_SOURCE = master_source.PINNED_ROOT / "NootedRed" / "UserPatches.cpp"
PATCHDATA_DIR = ROOT / "PatchData"
SPECS_DIR = TOOLS_DIR / "specs"

# --- Independent copy of the format contract ---------------------------------------------------

PAGE_SIZE = 0x1000
MAGIC = b"NRPD"
VERSION = 1
HEADER_SIZE = 72
HEADER_CHECKSUM_OFFSET = 64
TABLE_RECORD_SIZE = 24
PAGE_RECORD_SIZE = 16
SITE_RECORD_SIZE = 76
KNOWN_KINDS = {1, 2, 3, 4}
MAX_TABLES = 16
MAX_PAGES = 64
MAX_SITES = 1024
MAX_MANIFEST_SIZE = 128 * 1024
MAX_PAGES_SIZE = MAX_PAGES * PAGE_SIZE
MAX_FIND_SIZE = 32
BUILD_MAX_LENGTH = 15

FNV1A32_OFFSET = 0x811C9DC5
FNV1A32_PRIME = 0x01000193
FNV1A64_OFFSET = 0xCBF29CE484222325
FNV1A64_PRIME = 0x100000001B3

HEADER_STRUCT = struct.Struct("<4sHH16sHHHHIIIIIIIIQ")
TABLE_STRUCT = struct.Struct("<6I")
PAGE_STRUCT = struct.Struct("<4I")
SITE_STRUCT = struct.Struct("<II32s32sB3s")

# Fixture layout (independent expectations; a generator change must update these tests)
FIXTURE_TABLES = 2
FIXTURE_PAGES = 3
FIXTURE_SITES = 4
FIXTURE_MANIFEST_SIZE = (HEADER_SIZE + FIXTURE_TABLES * TABLE_RECORD_SIZE
                         + FIXTURE_PAGES * PAGE_RECORD_SIZE + FIXTURE_SITES * SITE_RECORD_SIZE)
FIXTURE_PAGES_SIZE = FIXTURE_PAGES * PAGE_SIZE
FIXTURE_PAGE_OFFSETS = (0x81, 0x160, 0x164, 0x198)
FIXTURE_SITE_SIZES = (7, 3, 2, 3)
FIXTURE_SITE_PAGE_INDICES = (0, 1, 2, 2)
FIXTURE_OCCURRENCES = (3, 2, 1, 2)
FIXTURE_OCCURRENCE_INDICES = (0, 1, 0, 0)
SITE_TABLE_OFFSET = HEADER_SIZE + FIXTURE_TABLES * TABLE_RECORD_SIZE
SITE_ARRAY_OFFSET = SITE_TABLE_OFFSET + FIXTURE_PAGES * PAGE_RECORD_SIZE
PAGE_ARRAY_OFFSET = HEADER_SIZE + FIXTURE_TABLES * TABLE_RECORD_SIZE


class ValidationError(Exception):
    """Manifest/pages failed validation."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


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


def find_all(page: bytes, find: bytes) -> list[int]:
    return [offset for offset in range(len(page) - len(find) + 1) if page.startswith(find, offset)]


@dataclass(frozen=True)
class TableRecord:
    kind: int
    page_index: int
    page_count: int
    site_index: int
    site_count: int


@dataclass(frozen=True)
class PageRecord:
    data_offset: int
    data_size: int


@dataclass(frozen=True)
class SiteRecord:
    page_index: int
    offset: int
    find: bytes
    replace: bytes
    size: int


@dataclass(frozen=True)
class ParsedManifest:
    build: str
    darwin: tuple[int, int, int]
    apu_mask: int
    manifest_size: int
    pages_size: int
    pages_checksum: int
    manifest_checksum: int
    tables: list[TableRecord]
    pages: list[PageRecord]
    sites: list[SiteRecord]
    pages_data: bytes


def parse_manifest(manifest: bytes, pages: bytes) -> ParsedManifest:
    """Parse and fully validate a manifest.bin/pages.bin pair (independent implementation)."""

    _require(len(manifest) <= MAX_MANIFEST_SIZE,
             f"manifest too large: {len(manifest)} > {MAX_MANIFEST_SIZE} bytes")
    _require(len(manifest) >= HEADER_SIZE,
             f"manifest too short: {len(manifest)} < {HEADER_SIZE} bytes")
    _require(len(pages) <= MAX_PAGES_SIZE,
             f"pages.bin too large: {len(pages)} > {MAX_PAGES_SIZE} bytes")

    magic, version, header_size = struct.unpack_from("<4sHH", manifest, 0)
    _require(magic == MAGIC, f"bad manifest magic {magic!r}, expected {MAGIC!r}")
    _require(version == VERSION, f"unsupported manifest version {version}, expected {VERSION}")
    _require(header_size == HEADER_SIZE,
             f"bad headerSize {header_size}, expected {HEADER_SIZE} (packed v1 header)")

    (magic, version, header_size, build_raw, darwin_major, darwin_minor, darwin_patch,
     reserved, apu_mask, table_count, page_count, site_count, manifest_size,
     pages_size, pages_checksum, reserved2, manifest_checksum) = HEADER_STRUCT.unpack(manifest[:HEADER_SIZE])

    _require(reserved == 0 and reserved2 == 0, "reserved header fields must be zero")

    nul = build_raw.find(b"\x00")
    _require(nul > 0, "build string must be non-empty and NUL padded")
    _require(all(byte == 0 for byte in build_raw[nul:]), "build string must be zero padded after NUL")
    _require(BUILD_MAX_LENGTH >= nul >= 1,
             f"build string length {nul} outside 1..{BUILD_MAX_LENGTH}")
    _require(re.fullmatch(rb"[0-9A-Za-z._-]+", build_raw[:nul]) is not None,
             f"build string {build_raw[:nul]!r} has invalid characters")
    build = build_raw[:nul].decode("ascii")

    _require(darwin_major >= 1, f"invalid Darwin major {darwin_major}")
    _require(apu_mask != 0, "apuMask must not be zero")
    _require(apu_mask & ~0x3F == 0, f"apuMask 0x{apu_mask:x} has bits outside the supported 0..5 range")

    _require(table_count <= MAX_TABLES, f"tableCount {table_count} exceeds {MAX_TABLES}")
    _require(page_count <= MAX_PAGES, f"pageCount {page_count} exceeds {MAX_PAGES}")
    _require(site_count <= MAX_SITES, f"siteCount {site_count} exceeds {MAX_SITES}")

    expected_size = (HEADER_SIZE + table_count * TABLE_RECORD_SIZE
                     + page_count * PAGE_RECORD_SIZE + site_count * SITE_RECORD_SIZE)
    _require(manifest_size == expected_size,
             f"manifestSize {manifest_size} does not match record layout {expected_size}")
    _require(manifest_size == len(manifest),
             f"manifestSize {manifest_size} does not match readable file length {len(manifest)}")
    _require(pages_size == len(pages),
             f"pagesSize {pages_size} does not match pages.bin length {len(pages)}")
    _require(pages_size <= page_count * PAGE_SIZE,
             f"pagesSize {pages_size} exceeds pageCount * {PAGE_SIZE} "
             f"({page_count} * {PAGE_SIZE})")

    computed_pages_checksum = fnv1a32(pages)
    _require(pages_checksum == computed_pages_checksum,
             f"pagesChecksum 0x{pages_checksum:08x} does not match pages.bin FNV-1a-32 "
             f"0x{computed_pages_checksum:08x}")

    checksum_view = bytearray(manifest)
    checksum_view[HEADER_CHECKSUM_OFFSET:HEADER_CHECKSUM_OFFSET + 8] = b"\x00" * 8
    computed_manifest_checksum = fnv1a64(bytes(checksum_view))
    _require(manifest_checksum == computed_manifest_checksum,
             f"manifestChecksum 0x{manifest_checksum:016x} does not match FNV-1a-64 over the manifest "
             f"with the checksum field zeroed (0x{computed_manifest_checksum:016x})")

    tables: list[TableRecord] = []
    offset = HEADER_SIZE
    for index in range(table_count):
        kind, page_index, page_count_value, site_index, site_count_value, table_reserved = \
            TABLE_STRUCT.unpack_from(manifest, offset)
        offset += TABLE_RECORD_SIZE
        _require(table_reserved == 0, f"table[{index}] reserved field must be zero")
        _require(kind in KNOWN_KINDS, f"table[{index}] has unknown kind {kind}")
        _require(index == 0 or kind > tables[-1].kind,
                 f"table[{index}] kind {kind} breaks strictly ascending canonical order")
        _require(page_count_value >= 1, f"table[{index}] pageCount must be >= 1")
        _require(site_count_value >= 1, f"table[{index}] siteCount must be >= 1")
        tables.append(TableRecord(kind, page_index, page_count_value, site_index, site_count_value))

    _require([table.kind for table in tables] == sorted(table.kind for table in tables)
             and len({table.kind for table in tables}) == len(tables),
             "table kinds must be unique and strictly ascending")

    page_cursor = 0
    site_cursor = 0
    for index, table in enumerate(tables):
        _require(table.page_index == page_cursor,
                 f"table[{index}] page range is not contiguous: pageIndex {table.page_index}, "
                 f"expected {page_cursor}")
        _require(table.site_index == site_cursor,
                 f"table[{index}] site range is not contiguous: siteIndex {table.site_index}, "
                 f"expected {site_cursor}")
        page_cursor += table.page_count
        site_cursor += table.site_count
    _require(page_cursor == page_count,
             f"table page ranges cover {page_cursor} page(s), manifest has {page_count}")
    _require(site_cursor == site_count,
             f"table site ranges cover {site_cursor} site(s), manifest has {site_count}")

    page_records: list[PageRecord] = []
    for index in range(page_count):
        data_offset, data_size, page_reserved_a, page_reserved_b = PAGE_STRUCT.unpack_from(manifest, offset)
        offset += PAGE_RECORD_SIZE
        _require(page_reserved_a == 0 and page_reserved_b == 0,
                 f"page[{index}] reserved fields must be zero")
        _require(data_size == PAGE_SIZE, f"page[{index}] dataSize {data_size}, expected {PAGE_SIZE}")
        _require(data_offset % PAGE_SIZE == 0,
                 f"page[{index}] dataOffset 0x{data_offset:x} is not 4 KiB aligned")
        _require(data_offset + data_size <= pages_size,
                 f"page[{index}] data range 0x{data_offset:x}+0x{data_size:x} exceeds pages.bin "
                 f"({pages_size} bytes)")
        page_records.append(PageRecord(data_offset, data_size))

    site_records: list[SiteRecord] = []
    for index in range(site_count):
        page_index, site_offset, find_raw, replace_raw, size, site_reserved = \
            SITE_STRUCT.unpack_from(manifest, offset)
        offset += SITE_RECORD_SIZE
        _require(site_reserved == b"\x00\x00\x00", f"site[{index}] reserved bytes must be zero")
        _require(1 <= size <= MAX_FIND_SIZE, f"site[{index}] size {size} outside 1..{MAX_FIND_SIZE}")
        _require(page_index < page_count,
                 f"site[{index}] pageIndex {page_index} outside 0..{page_count - 1}")
        _require(site_offset + size <= PAGE_SIZE,
                 f"site[{index}] offset 0x{site_offset:x}+{size} exceeds the 4 KiB page")
        _require(all(byte == 0 for byte in find_raw[size:]), f"site[{index}] find padding must be zero")
        _require(all(byte == 0 for byte in replace_raw[size:]), f"site[{index}] replace padding must be zero")
        find = find_raw[:size]
        replace = replace_raw[:size]
        _require(replace != find, f"site[{index}] replace bytes equal find bytes (no-op site)")
        site_records.append(SiteRecord(page_index, site_offset, find, replace, size))

    ranges_by_page: dict[int, list[tuple[int, int, int]]] = {}
    for index, site in enumerate(site_records):
        ranges_by_page.setdefault(site.page_index, []).append((site.offset, site.offset + site.size, index))
    for page_index, ranges in ranges_by_page.items():
        ranges.sort()
        for (start_a, end_a, index_a), (start_b, end_b, index_b) in zip(ranges, ranges[1:]):
            _require(start_b >= end_a,
                     f"site[{index_b}] at page {page_index} offset 0x{start_b:x} overlaps "
                     f"site[{index_a}] range [0x{start_a:x},0x{end_a:x})")

    for index, site in enumerate(site_records):
        page = pages[page_records[site.page_index].data_offset:
                     page_records[site.page_index].data_offset + PAGE_SIZE]
        _require(page[site.offset:site.offset + site.size] == site.find,
                 f"site[{index}] find bytes {site.find.hex()} not present at page {site.page_index} "
                 f"offset 0x{site.offset:x}")

    _require(offset == len(manifest), f"internal error: parsed {offset} of {len(manifest)} bytes")

    return ParsedManifest(
        build=build,
        darwin=(darwin_major, darwin_minor, darwin_patch),
        apu_mask=apu_mask,
        manifest_size=manifest_size,
        pages_size=pages_size,
        pages_checksum=pages_checksum,
        manifest_checksum=manifest_checksum,
        tables=tables,
        pages=page_records,
        sites=site_records,
        pages_data=pages,
    )


def validate_manifest_document(
    parsed: ParsedManifest,
    document: dict[str, Any],
    pages: bytes,
) -> None:
    """Cross-check the human-readable manifest.json against the parsed binary.

    This is where find uniqueness is enforced for generated data: the binary only stores an
    offset, so the document must acknowledge the occurrence index when ``find`` is not unique.
    """

    _require(document.get("schemaVersion") == VERSION, "manifest.json: wrong schemaVersion")
    _require(document.get("build") == parsed.build, "manifest.json: build mismatch")
    _require(document.get("apuMask") == parsed.apu_mask, "manifest.json: apuMask mismatch")
    darwin = document.get("darwin", {})
    _require((darwin.get("major"), darwin.get("minor"), darwin.get("patch")) == parsed.darwin,
             "manifest.json: Darwin version mismatch")
    counts = document.get("counts", {})
    _require(counts == {"tables": len(parsed.tables), "pages": len(parsed.pages),
                        "sites": len(parsed.sites)}, "manifest.json: counts mismatch")
    sizes = document.get("sizes", {})
    _require(sizes == {"manifest": parsed.manifest_size, "pages": parsed.pages_size},
             "manifest.json: sizes mismatch")
    checksums = document.get("checksums", {})
    _require(checksums.get("manifest") == f"0x{parsed.manifest_checksum:016x}",
             "manifest.json: manifest checksum mismatch")
    _require(checksums.get("pages") == f"0x{parsed.pages_checksum:08x}",
             "manifest.json: pages checksum mismatch")

    document_tables = document.get("tables", [])
    _require(len(document_tables) == len(parsed.tables), "manifest.json: table count mismatch")
    for index, (table, table_doc) in enumerate(zip(parsed.tables, document_tables)):
        _require(table_doc.get("kind") == table.kind, f"manifest.json: table[{index}] kind mismatch")
        _require(table_doc.get("pageIndex") == table.page_index
                 and table_doc.get("pageCount") == table.page_count,
                 f"manifest.json: table[{index}] page range mismatch")
        _require(table_doc.get("siteIndex") == table.site_index
                 and table_doc.get("siteCount") == table.site_count,
                 f"manifest.json: table[{index}] site range mismatch")

    document_pages = document.get("pages", [])
    _require(len(document_pages) == len(parsed.pages), "manifest.json: page count mismatch")
    expected_table_kind: list[int] = []
    for table in parsed.tables:
        expected_table_kind.extend([table.kind] * table.page_count)
    document_sites: list[dict[str, Any]] = []
    for index, (page_record, page_doc) in enumerate(zip(parsed.pages, document_pages)):
        _require(page_doc.get("index") == index, f"manifest.json: page[{index}] index mismatch")
        _require(page_doc.get("dataOffset") == page_record.data_offset,
                 f"manifest.json: page[{index}] dataOffset mismatch")
        _require(page_doc.get("dataSize") == page_record.data_size,
                 f"manifest.json: page[{index}] dataSize mismatch")
        _require(page_doc.get("tableKind") == expected_table_kind[index],
                 f"manifest.json: page[{index}] tableKind mismatch")
        page_bytes = pages[page_record.data_offset:page_record.data_offset + PAGE_SIZE]
        _require(page_doc.get("sha256") == hashlib.sha256(page_bytes).hexdigest(),
                 f"manifest.json: page[{index}] sha256 does not match pages.bin")
        for site_doc in page_doc.get("sites", []):
            document_sites.append(site_doc)

    _require(len(document_sites) == len(parsed.sites), "manifest.json: site count mismatch")
    seen: dict[tuple[int, int], int] = {}
    write_ranges: dict[int, list[tuple[int, int]]] = {}
    for index, (site, site_doc) in enumerate(zip(parsed.sites, document_sites)):
        _require(site_doc.get("pageIndex") == site.page_index,
                 f"manifest.json: site[{index}] pageIndex mismatch")
        _require(site_doc.get("offset") == site.offset, f"manifest.json: site[{index}] offset mismatch")
        _require(site_doc.get("size") == site.size, f"manifest.json: site[{index}] size mismatch")
        _require(site_doc.get("find") == site.find.hex(),
                 f"manifest.json: site[{index}] find mismatch")
        _require(site_doc.get("replace") == site.replace.hex(),
                 f"manifest.json: site[{index}] replace mismatch")

        key = (site.page_index, site.offset)
        _require(key not in seen, f"manifest.json: duplicate site at page {site.page_index} "
                                  f"offset 0x{site.offset:x}")
        seen[key] = index

        page = pages[parsed.pages[site.page_index].data_offset:parsed.pages[site.page_index].data_offset + PAGE_SIZE]
        occurrences = find_all(page, site.find)
        _require(occurrences, "manifest.json: site find does not occur on its page")
        occurrence_index = occurrences.index(site.offset)
        _require(len(occurrences) == 1 or "findOccurrence" in site_doc,
                 f"manifest.json: site[{index}] find {site.find.hex()} occurs {len(occurrences)} "
                 f"times; add findOccurrence")
        _require(site_doc.get("findOccurrence", 0) == occurrence_index,
                 f"manifest.json: site[{index}] findOccurrence {site_doc.get('findOccurrence')} "
                 f"but offset 0x{site.offset:x} is occurrence {occurrence_index}")
        _require(site_doc.get("occurrences") == len(occurrences),
                 f"manifest.json: site[{index}] occurrences mismatch")

        write_ranges.setdefault(site.page_index, []).append((site.offset, site.offset + site.size))

    for page_index, ranges in write_ranges.items():
        ranges.sort()
        for (start_a, end_a), (start_b, end_b) in zip(ranges, ranges[1:]):
            _require(start_b >= end_a,
                     f"manifest.json: overlapping site writes on page {page_index}: "
                     f"[{start_a:#x},{end_a:#x}) and [{start_b:#x},{end_b:#x})")


def load_generated(build_dir: Path) -> tuple[bytes, bytes, dict[str, Any], ParsedManifest]:
    """Parse a generated build directory and cross-check manifest.json (raises on any problem)."""

    manifest = (build_dir / "manifest.bin").read_bytes()
    pages = (build_dir / "pages.bin").read_bytes()
    document = json.loads((build_dir / "manifest.json").read_text(encoding="utf-8"))
    parsed = parse_manifest(manifest, pages)
    validate_manifest_document(parsed, document, pages)
    return manifest, pages, document, parsed


def apply_sites(parsed: ParsedManifest, page_index: int) -> bytes:
    """Apply all sites of one page to a copy of the page and return the patched bytes."""

    page = bytearray(parsed.pages_data[parsed.pages[page_index].data_offset:
                                       parsed.pages[page_index].data_offset + PAGE_SIZE])
    for site in parsed.sites:
        if site.page_index != page_index:
            continue
        page[site.offset:site.offset + site.size] = site.replace
    return bytes(page)


# --- Test helpers ------------------------------------------------------------------------------


class FixtureTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._tmpdir = tempfile.TemporaryDirectory(prefix="userpatch-data-tests-")
        cls.tmp_root = Path(cls._tmpdir.name)
        cls.out_root = cls.tmp_root / "PatchData"
        cls.build_dir = generator.write_build(FIXTURE_SPEC, cls.out_root)
        cls.manifest, cls.pages, cls.document, cls.parsed = load_generated(cls.build_dir)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmpdir.cleanup()

    def copy_fixture(self) -> Path:
        destination = Path(tempfile.mkdtemp(dir=self.tmp_root, prefix="fixture-")) / "fixture"
        shutil.copytree(FIXTURE_DIR, destination)
        return destination

    def read_spec(self, root: Path) -> dict[str, Any]:
        return json.loads((root / "spec.json").read_text(encoding="utf-8"))

    def write_spec(self, root: Path, spec: dict[str, Any]) -> Path:
        path = root / "spec.json"
        path.write_text(json.dumps(spec, indent=2) + "\n", encoding="utf-8")
        return path

    def expect_spec_error(self, root: Path, fragment: str) -> str:
        with self.assertRaises(generator.SpecError) as context:
            generator.write_build(root / "spec.json", root / "out")
        message = str(context.exception)
        self.assertIn(fragment, message)
        return message

    def rechecksum(self, manifest: bytes) -> bytes:
        data = bytearray(manifest)
        data[HEADER_CHECKSUM_OFFSET:HEADER_CHECKSUM_OFFSET + 8] = b"\x00" * 8
        struct.pack_into("<Q", data, HEADER_CHECKSUM_OFFSET, fnv1a64(bytes(data)))
        return bytes(data)

    def expect_invalid(self, manifest: bytes, pages: bytes | None = None, fragment: str = "") -> None:
        with self.assertRaises(ValidationError) as context:
            parse_manifest(manifest, self.pages if pages is None else pages)
        if fragment:
            self.assertIn(fragment, str(context.exception))


# --- Generated fixture: structural validation --------------------------------------------------


class GeneratedFixtureTest(FixtureTestCase):
    def test_generator_constants_match_documented_contract(self) -> None:
        self.assertEqual(generator.PAGE_SIZE, PAGE_SIZE)
        self.assertEqual(generator.MAGIC, MAGIC)
        self.assertEqual(generator.FORMAT_VERSION, VERSION)
        self.assertEqual(generator.HEADER_SIZE, HEADER_SIZE)
        self.assertEqual(generator.TABLE_RECORD_SIZE, TABLE_RECORD_SIZE)
        self.assertEqual(generator.PAGE_RECORD_SIZE, PAGE_RECORD_SIZE)
        self.assertEqual(generator.SITE_RECORD_SIZE, SITE_RECORD_SIZE)
        self.assertEqual(generator.MAX_TABLES, MAX_TABLES)
        self.assertEqual(generator.MAX_PAGES, MAX_PAGES)
        self.assertEqual(generator.MAX_SITES, MAX_SITES)
        self.assertEqual(generator.MAX_MANIFEST_SIZE, MAX_MANIFEST_SIZE)
        self.assertEqual(generator.BUILD_MAX_LENGTH, BUILD_MAX_LENGTH)

    def test_output_files_and_sizes(self) -> None:
        self.assertEqual(sorted(path.name for path in self.build_dir.iterdir()),
                         ["manifest.bin", "manifest.json", "pages.bin"])
        self.assertEqual(len(self.manifest), FIXTURE_MANIFEST_SIZE)
        self.assertEqual(len(self.manifest), 472)  # 72 + 2*24 + 3*16 + 4*76
        self.assertEqual(len(self.pages), FIXTURE_PAGES_SIZE)
        self.assertEqual(len(self.pages), 12288)
        self.assertEqual(self.build_dir.name, "24H32")

    def test_header_layout_is_packed_and_little_endian(self) -> None:
        self.assertEqual(self.manifest[0:4], b"NRPD")
        self.assertEqual(struct.unpack_from("<H", self.manifest, 4)[0], 1)
        self.assertEqual(struct.unpack_from("<H", self.manifest, 6)[0], 72)
        self.assertEqual(self.manifest[8:24], b"24H32" + b"\x00" * 11)
        self.assertEqual(struct.unpack_from("<HHH", self.manifest, 24), (24, 6, 0))
        self.assertEqual(struct.unpack_from("<H", self.manifest, 30)[0], 0)  # reserved
        self.assertEqual(struct.unpack_from("<I", self.manifest, 32)[0], 0x3F)  # apuMask
        self.assertEqual(struct.unpack_from("<III", self.manifest, 36),
                         (FIXTURE_TABLES, FIXTURE_PAGES, FIXTURE_SITES))
        self.assertEqual(struct.unpack_from("<I", self.manifest, 48)[0], FIXTURE_MANIFEST_SIZE)
        self.assertEqual(struct.unpack_from("<I", self.manifest, 52)[0], FIXTURE_PAGES_SIZE)
        self.assertEqual(struct.unpack_from("<I", self.manifest, 60)[0], 0)  # reserved2
        self.assertEqual(struct.unpack_from("<Q", self.manifest, 64)[0], self.parsed.manifest_checksum)

    def test_checksums(self) -> None:
        self.assertEqual(self.parsed.pages_checksum, fnv1a32(self.pages))
        checksum_view = bytearray(self.manifest)
        checksum_view[64:72] = b"\x00" * 8
        self.assertEqual(self.parsed.manifest_checksum, fnv1a64(bytes(checksum_view)))

    def test_tables_are_canonical(self) -> None:
        self.assertEqual([table.kind for table in self.parsed.tables], [1, 2])
        self.assertEqual(self.parsed.tables[0], TableRecord(1, 0, 2, 0, 2))
        self.assertEqual(self.parsed.tables[1], TableRecord(2, 2, 1, 2, 2))

    def test_page_array(self) -> None:
        self.assertEqual([page.data_offset for page in self.parsed.pages], [0, 4096, 8192])
        self.assertEqual([page.data_size for page in self.parsed.pages], [4096, 4096, 4096])
        spec = self.read_spec(FIXTURE_DIR)
        expected_sources = [page["source"] for table in spec["tables"] for page in table["pages"]]
        expected_hashes = [page["sha256"] for table in spec["tables"] for page in table["pages"]]
        self.assertEqual(len(expected_sources), FIXTURE_PAGES)
        for index, (page, source, digest) in enumerate(zip(self.parsed.pages, expected_sources, expected_hashes)):
            page_bytes = self.pages[page.data_offset:page.data_offset + PAGE_SIZE]
            self.assertEqual(page_bytes, (FIXTURE_DIR / source).read_bytes(),
                             f"pages.bin page {index} differs from {source}")
            self.assertEqual(hashlib.sha256(page_bytes).hexdigest(), digest)

    def test_site_array(self) -> None:
        self.assertEqual([site.page_index for site in self.parsed.sites], list(FIXTURE_SITE_PAGE_INDICES))
        self.assertEqual([site.offset for site in self.parsed.sites], list(FIXTURE_PAGE_OFFSETS))
        self.assertEqual([site.size for site in self.parsed.sites], list(FIXTURE_SITE_SIZES))
        self.assertEqual(self.parsed.sites[0].find, bytes.fromhex("c7477804000000"))
        self.assertEqual(self.parsed.sites[0].replace, bytes.fromhex("c7477801000000"))
        self.assertEqual(self.parsed.sites[1].find, bytes.fromhex("83e0fe"))
        self.assertEqual(self.parsed.sites[1].replace, bytes.fromhex("83c801"))
        self.assertEqual(self.parsed.sites[2].find, bytes.fromhex("750b"))
        self.assertEqual(self.parsed.sites[2].replace, bytes.fromhex("eb0b"))
        self.assertEqual(self.parsed.sites[3].find, bytes.fromhex("0f94c0"))
        self.assertEqual(self.parsed.sites[3].replace, bytes.fromhex("31c090"))

    def test_site_records_are_not_padded_with_garbage(self) -> None:
        for index in range(FIXTURE_SITES):
            site_start = SITE_ARRAY_OFFSET + index * SITE_RECORD_SIZE
            find_raw = self.manifest[site_start + 8:site_start + 40]
            replace_raw = self.manifest[site_start + 40:site_start + 72]
            size = self.manifest[site_start + 72]
            self.assertTrue(all(byte == 0 for byte in find_raw[size:]))
            self.assertTrue(all(byte == 0 for byte in replace_raw[size:]))
            self.assertEqual(self.manifest[site_start + 73:site_start + 76], b"\x00\x00\x00")

    def test_apply_sites_produces_expected_bytes(self) -> None:
        gl_hwinfo = apply_sites(self.parsed, 0)
        self.assertEqual(gl_hwinfo[0x81:0x88], bytes.fromhex("c7477801000000"))
        self.assertEqual(gl_hwinfo[0xCC:0xD3], bytes.fromhex("c7477804000000"))  # ambiguous, untouched
        self.assertEqual(gl_hwinfo[0x109:0x110], bytes.fromhex("c7477804000000"))  # ambiguous, untouched

        gl_dualquad = apply_sites(self.parsed, 1)
        self.assertEqual(gl_dualquad[0x160:0x163], bytes.fromhex("83c801"))
        self.assertEqual(gl_dualquad[0x68:0x6B], bytes.fromhex("83e0fe"))  # ambiguous, untouched

        metal = apply_sites(self.parsed, 2)
        self.assertEqual(metal[0x164:0x166], bytes.fromhex("eb0b"))
        self.assertEqual(metal[0x198:0x19B], bytes.fromhex("31c090"))
        self.assertEqual(metal[0x722:0x725], bytes.fromhex("0f94c0"))  # ambiguous, untouched

    def test_ambiguous_find_occurrences_are_pinned(self) -> None:
        all_page_sites = [site for page in self.document["pages"] for site in page["sites"]]
        self.assertEqual([site["findOccurrence"] for site in all_page_sites],
                         list(FIXTURE_OCCURRENCE_INDICES))
        self.assertEqual([site["occurrences"] for site in all_page_sites], list(FIXTURE_OCCURRENCES))
        for site in all_page_sites:
            page = self.pages[
                self.parsed.pages[site["pageIndex"]].data_offset:
                self.parsed.pages[site["pageIndex"]].data_offset + PAGE_SIZE]
            occurrence_index = find_all(page, bytes.fromhex(site["find"])).index(site["offset"])
            self.assertEqual(site["findOccurrence"], occurrence_index)

    def test_manifest_json_is_consistent_and_readable(self) -> None:
        self.assertEqual(self.document["format"], "NootedRedUserPatch manifest.bin")
        self.assertEqual(self.document["build"], "24H32")
        self.assertEqual(self.document["apuMask"], 0x3F)
        self.assertEqual(self.document["darwin"], {"major": 24, "minor": 6, "patch": 0})
        self.assertEqual(self.document["counts"], {"tables": 2, "pages": 3, "sites": 4})
        self.assertEqual(self.document["sizes"], {"manifest": 472, "pages": 12288})
        self.assertEqual(self.document["checksums"]["pages"], f"0x{fnv1a32(self.pages):08x}")
        self.assertEqual(self.document["checksums"]["manifest"],
                         f"0x{self.parsed.manifest_checksum:016x}")
        self.assertIn("provenance", self.document)
        self.assertEqual(self.document["provenance"]["sourceFiles"][0]["path"],
                         "NootedRed/UserPatches.cpp")
        self.assertEqual(self.document["pages"][0]["source"], "pages/gl-driver-hwinfo-0xE000.bin")

    def test_deterministic_output(self) -> None:
        other_root = self.tmp_root / "PatchData-again"
        other_build = generator.write_build(FIXTURE_SPEC, other_root)
        for name in ("manifest.bin", "pages.bin", "manifest.json"):
            self.assertEqual((other_build / name).read_bytes(), (self.build_dir / name).read_bytes(),
                             f"{name} is not deterministic")

    def test_new_build_directory_requires_no_source_edits(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["build"] = "24H99"
        spec["apuMask"] = 0x01
        self.write_spec(root, spec)
        out_root = self.tmp_root / "PatchData-new-build"
        build_dir = generator.write_build(root / "spec.json", out_root)
        manifest, pages, document, parsed = load_generated(build_dir)
        self.assertEqual(build_dir.name, "24H99")
        self.assertEqual(parsed.build, "24H99")
        self.assertEqual(parsed.apu_mask, 0x01)
        self.assertEqual(len(pages), FIXTURE_PAGES_SIZE)
        self.assertEqual(document["build"], "24H99")

    def test_cli_generates_the_fixture(self) -> None:
        out_root = self.tmp_root / "PatchData-cli"
        result = subprocess.run(
            [sys.executable, str(GENERATOR), "--spec", str(FIXTURE_SPEC), "--out", str(out_root)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("manifest.bin", result.stdout)
        load_generated(out_root / "24H32")


# --- Fixture provenance ------------------------------------------------------------------------


class FixtureProvenanceTest(unittest.TestCase):
    def test_checked_in_fixture_matches_master_source(self) -> None:
        # D7 regression: master's UserPatches.cpp is deleted at HEAD, so the fixture provenance must
        # come from the pinned snapshot instead of silently skipping.
        source = SOURCE_CPP if SOURCE_CPP.is_file() else PINNED_SOURCE
        self.assertTrue(source.is_file(), f"no master UserPatches.cpp (live or pinned) at {source}")
        try:
            result = fixture_extractor.extract(source)
        except fixture_extractor.FixtureError as error:
            self.fail(f"cannot derive fixture from master source: {error}")
        checked_in = json.loads(FIXTURE_SPEC.read_text(encoding="utf-8"))
        self.assertEqual(result["spec"], checked_in,
                         "tools/fixtures/master-15.8.1/spec.json is stale; "
                         "rerun tools/extract_userpatch_fixture.py")
        for file_name, expected in result["pages"].items():
            self.assertEqual((FIXTURE_DIR / "pages" / file_name).read_bytes(), expected,
                             f"fixture page {file_name} is stale; rerun the extractor")
        self.assertEqual(fixture_extractor.check_fixture(FIXTURE_DIR, source), [])
        self.assertEqual(len(checked_in["tables"]), 2)
        self.assertEqual(sum(len(table["pages"]) for table in checked_in["tables"]), FIXTURE_PAGES)
        self.assertEqual(sum(len(page["sites"]) for table in checked_in["tables"]
                             for page in table["pages"]), FIXTURE_SITES)


class PinnedMasterSourceTest(unittest.TestCase):
    """The pinned snapshot is the provenance for fixtures, specs and PatchData (D7)."""

    def test_pinned_snapshot_is_intact(self) -> None:
        self.assertEqual(master_source.verify_pin(), [])

    def test_pinned_snapshot_matches_git_master(self) -> None:
        try:
            subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", "master:NootedRed/UserPatches.cpp"],
                           check=True, capture_output=True)
        except (OSError, subprocess.CalledProcessError):
            self.skipTest("git history with the master revision is not available")
        manifest = master_source.load_pin()
        for entry in manifest["files"]:
            with self.subTest(path=entry["path"]):
                historical = subprocess.check_output(
                    ["git", "-C", str(ROOT), "show", f"master:{entry['path']}"])
                self.assertEqual((master_source.PINNED_ROOT / entry["path"]).read_bytes(), historical,
                                 f"pinned {entry['path']} differs from master")
        self.assertEqual(manifest["sourceCommit"],
                         subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "master"],
                                                 text=True).strip())

    def test_fixture_provenance_uses_the_pinned_bytes(self) -> None:
        checked_in = json.loads(FIXTURE_SPEC.read_text(encoding="utf-8"))
        source_entry = checked_in["provenance"]["sourceFiles"][0]
        self.assertEqual(source_entry["path"], "NootedRed/UserPatches.cpp")
        self.assertEqual(source_entry["sha256"],
                         hashlib.sha256(PINNED_SOURCE.read_bytes()).hexdigest())


DEPLOYED_BUILDS: dict[str, dict[str, Any]] = {
    "24H32": {
        "kinds": [1, 2, 3, 4],
        "darwin": (24, 6, 0),
        "apu_mask": 0x3F,
        "pages": 12,
        "sites": 17,
        "manifest_sha256": "0fa570203ee7de4287216e3a6356816b867cb133794133af2914a3d4a1bee860",
        "pages_sha256": "39197623e8bac51ef71423a2b9c6ad6aa724a806d054219b7b49239117ffb86c",
    },
    "23J631": {
        "kinds": [3, 4],
        "darwin": (23, 6, 0),
        "apu_mask": 0x38,
        "pages": 9,
        "sites": 13,
        "manifest_sha256": "67d05b169c034a04af5955f29eb0ccaf3173a24c9c6905c6e79720de19d4a700",
        "pages_sha256": "6d3867c68dda0b9fe10fd23e77b4e61a5da5746017ac820e5f5a8ee7f4ace940",
    },
    "25G241": {
        "kinds": [1, 2, 3, 4],
        "darwin": (25, 6, 0),
        "apu_mask": 0x3F,
        "pages": 11,
        "sites": 17,
        "manifest_sha256": "d7cfbdcbf2c15cbd9b2148bab993c7a92ad78f194fbef5f4f5a11d4b1a90c8a2",
        "pages_sha256": "5f2469e184168e1b71141f32c51e463c49a7b0881f1ac688ef9e688efec46a4a",
    },
}

VDA_SOURCES = {
    "24H32": {"vda": "NootedRed/VDAVAData.hpp", "gva": "NootedRed/VDAGVAData.hpp"},
    "23J631": {"vda": "NootedRed/VDAVADataSonoma.hpp", "gva": "NootedRed/VDAGVADataSonoma.hpp"},
    "25G241": {"vda": "NootedRed/VDAVADataTahoe.hpp", "gva": "NootedRed/VDAGVADataTahoe.hpp"},
}


class DeployablePatchDataTest(unittest.TestCase):
    """The committed PatchData build sets must be real, complete for their documented kinds, and current."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.pin_commit = master_source.pin_commit()

    def test_only_documented_builds_are_deployed(self) -> None:
        builds = sorted(path.name for path in PATCHDATA_DIR.iterdir() if path.is_dir())
        self.assertEqual(builds, sorted(DEPLOYED_BUILDS))

    def test_each_deployed_build_is_valid(self) -> None:
        for build, expected in DEPLOYED_BUILDS.items():
            with self.subTest(build=build):
                build_dir = PATCHDATA_DIR / build
                manifest, pages, document, parsed = load_generated(build_dir)
                self.assertEqual(parsed.build, build)
                self.assertEqual(parsed.darwin, expected["darwin"])
                self.assertEqual(parsed.apu_mask, expected["apu_mask"])
                self.assertEqual([table.kind for table in parsed.tables], expected["kinds"])
                self.assertEqual(len(parsed.pages), expected["pages"])
                self.assertEqual(len(parsed.sites), expected["sites"])
                self.assertEqual(hashlib.sha256(manifest).hexdigest(), expected["manifest_sha256"],
                                 f"{build}/manifest.bin changed; regenerate with the converter")
                self.assertEqual(hashlib.sha256(pages).hexdigest(), expected["pages_sha256"],
                                 f"{build}/pages.bin changed; regenerate with the converter")
                self.assertEqual(document["provenance"]["pinnedMasterCommit"], self.pin_commit)
                self.assertIn("gaps", document["provenance"])
                registration = document["provenance"]["registration"]
                self.assertEqual(registration["api"], "UserPatches::registerVDAFix")
                self.assertEqual({entry["header"] for entry in registration["headers"]},
                                 {VDA_SOURCES[build]["vda"], VDA_SOURCES[build]["gva"]})

                spec = json.loads((SPECS_DIR / build / "spec.json").read_text(encoding="utf-8"))
                spec_pages = [page for table in spec["tables"] for page in table["pages"]]
                self.assertEqual(len(spec_pages), len(parsed.pages))
                for index, (page_record, page_spec) in enumerate(zip(parsed.pages, spec_pages)):
                    page_bytes = pages[page_record.data_offset:page_record.data_offset + PAGE_SIZE]
                    spec_file = SPECS_DIR / build / page_spec["source"]
                    self.assertTrue(spec_file.is_file(), f"missing spec page {spec_file}")
                    self.assertEqual(spec_file.read_bytes(), page_bytes,
                                     f"{build}: page {index} differs from its spec source")
                    self.assertEqual(hashlib.sha256(page_bytes).hexdigest(), page_spec["sha256"])

    def test_vda_and_apple_gva_pages_are_master_arrays(self) -> None:
        for build, sources in VDA_SOURCES.items():
            with self.subTest(build=build):
                _, pages, _, parsed = load_generated(PATCHDATA_DIR / build)
                kinds = {table.kind: table for table in parsed.tables}
                self.assertIn(3, kinds)
                self.assertIn(4, kinds)

                vda_text = (master_source.PINNED_ROOT / sources["vda"]).read_text(encoding="utf-8")
                gva_text = (master_source.PINNED_ROOT / sources["gva"]).read_text(encoding="utf-8")
                vda_arrays = master_tables.parse_byte_arrays(vda_text, sources["vda"])
                gva_arrays = master_tables.parse_byte_arrays(gva_text, sources["gva"])

                vda_pages = [parsed.pages[index] for index in
                             range(kinds[3].page_index, kinds[3].page_index + kinds[3].page_count)]
                gva_pages = [parsed.pages[index] for index in
                             range(kinds[4].page_index, kinds[4].page_index + kinds[4].page_count)]
                self.assertEqual(len(vda_pages), 8 if build != "25G241" else 7)
                self.assertEqual(len(gva_pages), 1)
                for index, page_record in enumerate(vda_pages):
                    page_bytes = pages[page_record.data_offset:page_record.data_offset + PAGE_SIZE]
                    self.assertEqual(page_bytes, vda_arrays[f"Page{index}"],
                                     f"{build}: VDA page {index} is not master's Page{index}")
                page_bytes = pages[gva_pages[0].data_offset:gva_pages[0].data_offset + PAGE_SIZE]
                self.assertEqual(page_bytes, gva_arrays["Page0"],
                                 f"{build}: AppleGVA page is not master's Page0")

    def test_gl_and_metal_pages_are_master_arrays(self) -> None:
        # 24H32 GL/Metal pages are the same real bytes as the checked-in 15.8.1 fixture.
        fixture = json.loads(FIXTURE_SPEC.read_text(encoding="utf-8"))
        fixture_pages = [page for table in fixture["tables"] for page in table["pages"]]
        _, pages, _, parsed = load_generated(PATCHDATA_DIR / "24H32")
        for index, page_spec in enumerate(fixture_pages):
            page_bytes = pages[parsed.pages[index].data_offset:parsed.pages[index].data_offset + PAGE_SIZE]
            self.assertEqual(page_bytes, (FIXTURE_DIR / page_spec["source"]).read_bytes())
            self.assertEqual(hashlib.sha256(page_bytes).hexdigest(), page_spec["sha256"])

        # 25G241 GL/Metal pages are master's Tahoe arrays.
        tahoe = (master_source.PINNED_ROOT / "NootedRed/TahoePatchData.hpp").read_text(encoding="utf-8")
        arrays = master_tables.parse_byte_arrays(tahoe, "TahoePatchData.hpp")
        _, pages, _, parsed = load_generated(PATCHDATA_DIR / "25G241")
        expected_names = ("kTahoeGLHwInfoPage", "kTahoeGLDualQuadPage", "kTahoeMTLControlPage")
        for index, array_name in enumerate(expected_names):
            page_bytes = pages[parsed.pages[index].data_offset:parsed.pages[index].data_offset + PAGE_SIZE]
            self.assertEqual(page_bytes, arrays[array_name],
                             f"25G241: page {index} is not master's {array_name}")

    def test_14x_gl_metal_gap_is_documented_not_fabricated(self) -> None:
        spec = json.loads((SPECS_DIR / "23J631" / "spec.json").read_text(encoding="utf-8"))
        kinds = [table["kind"] for table in spec["tables"]]
        self.assertEqual(kinds, [3, 4])
        gaps = spec["provenance"]["gaps"]
        self.assertTrue(any("GL/Metal" in gap for gap in gaps), gaps)

    def test_converter_regeneration_is_deterministic_and_current(self) -> None:
        problems = converter.check(None, converter.DEFAULT_SPECS_DIR, converter.DEFAULT_PATCHDATA_DIR)
        self.assertEqual(problems, [])

    def test_converter_report_lists_all_builds_and_gaps(self) -> None:
        commit, specs = converter.load_specs(None)
        self.assertEqual(commit, self.pin_commit)
        self.assertEqual(sorted(specs), sorted(DEPLOYED_BUILDS))
        for build in specs:
            self.assertTrue(specs[build]["spec"]["provenance"]["gaps"])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(converter.report(None), 0)


class MinimalFixtureTest(unittest.TestCase):
    """1-table/1-page/1-site loader test vector (apuMask bit 5, build 24H32)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls._tmpdir = tempfile.TemporaryDirectory(prefix="userpatch-minimal-tests-")
        cls.tmp_root = Path(cls._tmpdir.name)
        cls.build_dir = generator.write_build(MINIMAL_SPEC, cls.tmp_root / "PatchData")
        cls.manifest, cls.pages, cls.document, cls.parsed = load_generated(cls.build_dir)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmpdir.cleanup()

    def test_minimal_layout(self) -> None:
        self.assertEqual(self.build_dir.name, "24H32")
        self.assertEqual(len(self.manifest), 188)  # 72 + 24 + 16 + 76
        self.assertEqual(len(self.pages), 4096)
        self.assertEqual(self.parsed.build, "24H32")
        self.assertEqual(self.parsed.darwin, (24, 6, 0))
        self.assertEqual(self.parsed.apu_mask, 0x20)  # bit 5 GreenSardine
        self.assertEqual(len(self.parsed.tables), 1)
        self.assertEqual(self.parsed.tables[0], TableRecord(1, 0, 1, 0, 1))
        self.assertEqual(len(self.parsed.pages), 1)
        self.assertEqual(self.parsed.pages[0], PageRecord(0, 4096))
        self.assertEqual(len(self.parsed.sites), 1)
        self.assertEqual(self.parsed.sites[0], SiteRecord(0, 0x160, bytes.fromhex("83e0fe"),
                                                          bytes.fromhex("83c801"), 3))
        self.assertEqual(self.document["counts"], {"tables": 1, "pages": 1, "sites": 1})
        self.assertEqual(self.document["apuMask"], 0x20)

    def test_minimal_fixture_is_a_real_subset_of_master_15_8_1(self) -> None:
        master_spec = json.loads(FIXTURE_SPEC.read_text(encoding="utf-8"))
        master_page = (FIXTURE_DIR / "pages" / "gl-driver-dualquad-0x8000.bin").read_bytes()
        minimal_page = (MINIMAL_FIXTURE_DIR / "pages" / "gl-driver-dualquad-0x8000.bin").read_bytes()
        self.assertEqual(minimal_page, master_page)
        master_sites = [site for table in master_spec["tables"] for page in table["pages"]
                        for site in page["sites"] if site["offset"] == 0x160]
        self.assertEqual(len(master_sites), 1)
        minimal_site = self.document["pages"][0]["sites"][0]
        for key in ("offset", "find", "replace", "findOccurrence"):
            self.assertEqual(minimal_site[key], master_sites[0][key])


# --- Generator rejection tests -----------------------------------------------------------------


class GeneratorRejectionTest(FixtureTestCase):
    def test_page_not_4096_bytes(self) -> None:
        root = self.copy_fixture()
        page = root / "pages" / "gl-driver-hwinfo-0xE000.bin"
        page.write_bytes(page.read_bytes()[:100])
        self.expect_spec_error(root, "exactly 4096 required")

    def test_page_sha256_mismatch(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][0]["pages"][0]["sha256"] = "0" * 64
        self.write_spec(root, spec)
        self.expect_spec_error(root, "page sha256 mismatch")

    def test_missing_page_file(self) -> None:
        root = self.copy_fixture()
        (root / "pages" / "gl-driver-hwinfo-0xE000.bin").unlink()
        self.expect_spec_error(root, "cannot read page image")

    def test_source_path_escapes_spec_directory(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][0]["pages"][0]["source"] = "../escape.bin"
        self.write_spec(root, spec)
        self.expect_spec_error(root, "stay inside the spec directory")

    def test_find_bytes_absent_at_offset(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][0]["pages"][0]["sites"][0]["find"] = "c7477805000000"
        self.write_spec(root, spec)
        self.expect_spec_error(root, "not present at page offset")

    def test_ambiguous_find_requires_occurrence(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        del spec["tables"][0]["pages"][1]["sites"][0]["findOccurrence"]
        self.write_spec(root, spec)
        self.expect_spec_error(root, 'add "findOccurrence": 1')

    def test_wrong_find_occurrence(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][0]["pages"][1]["sites"][0]["findOccurrence"] = 0
        self.write_spec(root, spec)
        self.expect_spec_error(root, "occurrence 1")

    def test_find_and_replace_length_mismatch(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][0]["pages"][1]["sites"][0]["replace"] = "83c8"
        self.write_spec(root, spec)
        self.expect_spec_error(root, "must have the same length")

    def test_noop_site(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][0]["pages"][0]["sites"][0]["replace"] = \
            spec["tables"][0]["pages"][0]["sites"][0]["find"]
        self.write_spec(root, spec)
        self.expect_spec_error(root, "no-op site")

    def test_overlapping_sites(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        page = (root / "pages" / "gl-driver-dualquad-0x8000.bin").read_bytes()
        offset = 0x15F  # starts one byte before the existing 0x160 site
        overlap_find = page[offset:offset + 4]
        overlapping = {
            "offset": offset,
            "find": overlap_find.hex(),
            "replace": bytes(byte ^ 0xFF for byte in overlap_find).hex(),
        }
        occurrences = find_all(page, overlap_find)
        if len(occurrences) > 1:
            overlapping["findOccurrence"] = occurrences.index(offset)
        spec["tables"][0]["pages"][1]["sites"].append(overlapping)
        self.write_spec(root, spec)
        self.expect_spec_error(root, "overlapping patch sites")

    def test_unknown_table_kind(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][0]["kind"] = 5
        self.write_spec(root, spec)
        self.expect_spec_error(root, "unknown table kind")

    def test_duplicate_table_kind(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][1]["kind"] = 1
        self.write_spec(root, spec)
        self.expect_spec_error(root, "duplicate table kind")

    def test_empty_table(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][0]["pages"] = []
        self.write_spec(root, spec)
        self.expect_spec_error(root, "non-empty list")

    def test_page_without_sites(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][0]["pages"][0]["sites"] = []
        self.write_spec(root, spec)
        self.expect_spec_error(root, "non-empty list")

    def test_too_many_pages(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        page = spec["tables"][0]["pages"][0]
        spec["tables"][0]["pages"] = [dict(page) for _ in range(MAX_PAGES + 1)]
        self.write_spec(root, spec)
        self.expect_spec_error(root, f"{MAX_PAGES}-page limit")

    def test_too_many_sites(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        site = spec["tables"][0]["pages"][0]["sites"][0]
        spec["tables"][0]["pages"][0]["sites"] = [dict(site) for _ in range(MAX_SITES + 1)]
        self.write_spec(root, spec)
        self.expect_spec_error(root, f"{MAX_SITES}-site limit")

    def test_build_string_too_long(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["build"] = "A" * (BUILD_MAX_LENGTH + 1)
        self.write_spec(root, spec)
        self.expect_spec_error(root, f"1..{BUILD_MAX_LENGTH} characters")

    def test_build_string_invalid_characters(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["build"] = "24H32!"
        self.write_spec(root, spec)
        self.expect_spec_error(root, "may only contain")

    def test_zero_apu_mask(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["apuMask"] = 0
        self.write_spec(root, spec)
        self.expect_spec_error(root, "apuMask")

    def test_apu_mask_outside_supported_bits(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["apuMask"] = 0x40
        self.write_spec(root, spec)
        self.expect_spec_error(root, "apuMask")

    def test_zero_darwin_major(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["darwin"] = [0, 6, 0]
        self.write_spec(root, spec)
        self.expect_spec_error(root, "darwin")

    def test_unknown_top_level_field(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["bogus"] = 1
        self.write_spec(root, spec)
        self.expect_spec_error(root, "unknown field")

    def test_unknown_site_field(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][0]["pages"][0]["sites"][0]["bogus"] = 1
        self.write_spec(root, spec)
        self.expect_spec_error(root, "unknown field")

    def test_relative_source_required(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][0]["pages"][0]["source"] = "/absolute/page.bin"
        self.write_spec(root, spec)
        self.expect_spec_error(root, "must be relative")

    def test_undeclared_driver_reference(self) -> None:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        spec["tables"][0]["pages"][0]["driver"] = "missing"
        self.write_spec(root, spec)
        self.expect_spec_error(root, "not declared under drivers")


class GeneratorDriverIdentityTest(FixtureTestCase):
    """Exercise the optional full-driver hash/offset verification with fixture page bytes."""

    def make_driver_fixture(self) -> tuple[Path, Path]:
        root = self.copy_fixture()
        spec = self.read_spec(root)
        hwinfo = (root / "pages" / "gl-driver-hwinfo-0xE000.bin").read_bytes()
        dualquad = (root / "pages" / "gl-driver-dualquad-0x8000.bin").read_bytes()
        driver = bytearray(0x10000)
        driver[0x8000:0x8000 + PAGE_SIZE] = dualquad
        driver[0xE000:0xE000 + PAGE_SIZE] = hwinfo
        (root / "gl-driver.bin").write_bytes(bytes(driver))
        digest = hashlib.sha256(bytes(driver)).hexdigest()
        spec["drivers"] = {"gl-driver": {"path": "gl-driver.bin", "sha256": digest}}
        for page in spec["tables"][0]["pages"]:
            page["driver"] = "gl-driver"
        self.write_spec(root, spec)
        return root, root / "gl-driver.bin"

    def test_full_driver_identity_and_slice_are_verified(self) -> None:
        root, _ = self.make_driver_fixture()
        build_dir = generator.write_build(root / "spec.json", root / "out")
        _, _, document, _ = load_generated(build_dir)
        self.assertEqual([page.get("fileOffset") for page in document["pages"]],
                         [0xE000, 0x8000, None])
        self.assertEqual([page.get("driver") for page in document["pages"]],
                         ["gl-driver", "gl-driver", None])

    def test_driver_hash_mismatch(self) -> None:
        root, driver_path = self.make_driver_fixture()
        data = bytearray(driver_path.read_bytes())
        data[0] ^= 0xFF
        driver_path.write_bytes(bytes(data))
        self.expect_spec_error(root, "sha256 mismatch")

    def test_driver_slice_mismatch(self) -> None:
        root, driver_path = self.make_driver_fixture()
        spec = self.read_spec(root)
        hwinfo = (root / "pages" / "gl-driver-hwinfo-0xE000.bin").read_bytes()
        dualquad = (root / "pages" / "gl-driver-dualquad-0x8000.bin").read_bytes()
        driver = bytearray(0x10000)  # swap the two pages: hashes match, slices do not
        driver[0x8000:0x8000 + PAGE_SIZE] = hwinfo
        driver[0xE000:0xE000 + PAGE_SIZE] = dualquad
        driver_path.write_bytes(bytes(driver))
        spec["drivers"]["gl-driver"]["sha256"] = hashlib.sha256(bytes(driver)).hexdigest()
        self.write_spec(root, spec)
        self.expect_spec_error(root, "do not match driver")

    def test_driver_file_missing(self) -> None:
        root, driver_path = self.make_driver_fixture()
        driver_path.unlink()
        self.expect_spec_error(root, "cannot read")


# --- Malformed binary rejection tests ----------------------------------------------------------


class MalformedManifestTest(FixtureTestCase):
    def patched(self, offset: int, payload: bytes) -> bytes:
        data = bytearray(self.manifest)
        data[offset:offset + len(payload)] = payload
        return bytes(data)

    def test_bad_magic(self) -> None:
        self.expect_invalid(self.patched(0, b"XRPD"), fragment="magic")

    def test_unsupported_version(self) -> None:
        self.expect_invalid(self.rechecksum(self.patched(4, struct.pack("<H", 2))), fragment="version")

    def test_bad_header_size(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<H", data, 6, 64)  # the old, wrong doc value
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="headerSize")

    def test_nonzero_header_reserved(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<H", data, 30, 1)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="reserved")

    def test_nonzero_header_reserved2(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, 60, 1)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="reserved")

    def test_build_not_nul_padded(self) -> None:
        data = bytearray(self.manifest)
        data[8:24] = b"A" * 16
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="build")

    def test_build_with_invalid_character(self) -> None:
        data = bytearray(self.manifest)
        data[8] = 0x20  # space
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="build")

    def test_zero_darwin_major(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<H", data, 24, 0)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="Darwin")

    def test_zero_apu_mask(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, 32, 0)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="apuMask")

    def test_apu_mask_unknown_bit(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, 32, 0x40)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="apuMask")

    def test_manifest_size_mismatch(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, 48, FIXTURE_MANIFEST_SIZE + 1)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="manifestSize")

    def test_truncated_manifest(self) -> None:
        self.expect_invalid(self.manifest[:-1], fragment="manifestSize")

    def test_trailing_manifest_bytes(self) -> None:
        self.expect_invalid(self.manifest + b"\x00", fragment="manifestSize")

    def test_truncated_header(self) -> None:
        self.expect_invalid(self.manifest[:71], fragment="too short")

    def test_pages_size_mismatch(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, 52, FIXTURE_PAGES_SIZE + 4096)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="pagesSize")

    def test_pages_checksum_mismatch(self) -> None:
        data = bytearray(self.manifest)
        current = struct.unpack_from("<I", data, 56)[0]
        struct.pack_into("<I", data, 56, current ^ 1)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="pagesChecksum")

    def test_manifest_checksum_mismatch(self) -> None:
        data = bytearray(self.manifest)
        current = struct.unpack_from("<Q", data, 64)[0]
        struct.pack_into("<Q", data, 64, current ^ 1)
        self.expect_invalid(bytes(data), fragment="manifestChecksum")

    def test_truncated_pages(self) -> None:
        self.expect_invalid(self.manifest, self.pages[:-1], fragment="pagesSize")

    def test_extra_pages_bytes(self) -> None:
        self.expect_invalid(self.manifest, self.pages + b"\x00" * 4096, fragment="pagesSize")

    def test_manifest_over_size_limit(self) -> None:
        oversized = bytearray(MAX_MANIFEST_SIZE + 1)
        oversized[0:4] = MAGIC
        struct.pack_into("<H", oversized, 4, VERSION)
        struct.pack_into("<H", oversized, 6, HEADER_SIZE)
        self.expect_invalid(bytes(oversized), fragment="too large")

    def test_pages_over_size_limit(self) -> None:
        self.expect_invalid(self.manifest, self.pages + b"\x00" * (MAX_PAGES_SIZE - len(self.pages) + 1),
                            fragment="too large")

    def test_unknown_table_kind(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, HEADER_SIZE, 9)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="unknown kind")

    def test_table_kinds_not_ascending(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, HEADER_SIZE, 2)
        struct.pack_into("<I", data, HEADER_SIZE + TABLE_RECORD_SIZE, 1)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="ascending")

    def test_duplicate_table_kind(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, HEADER_SIZE + TABLE_RECORD_SIZE, 1)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="ascending")

    def test_table_page_range_overflow(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, HEADER_SIZE + 8, 4)  # pageCount 2 -> 4
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="contiguous")

    def test_table_site_range_overflow(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, HEADER_SIZE + 16, 3)  # siteCount 2 -> 3
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="contiguous")

    def test_table_page_range_gap(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, HEADER_SIZE + TABLE_RECORD_SIZE + 4, 3)  # table1 pageIndex 2 -> 3
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="contiguous")

    def test_table_reserved_nonzero(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, HEADER_SIZE + 20, 1)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="reserved")

    def test_page_data_size_not_4096(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, PAGE_ARRAY_OFFSET + 4, 4095)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="dataSize")

    def test_page_data_offset_unaligned(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, PAGE_ARRAY_OFFSET, 1)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="aligned")

    def test_page_data_offset_out_of_range(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, PAGE_ARRAY_OFFSET, FIXTURE_PAGES_SIZE)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="exceeds pages.bin")

    def test_pages_size_exceeds_page_count(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, 52, (FIXTURE_PAGES + 1) * PAGE_SIZE)
        self.expect_invalid(self.rechecksum(bytes(data)), self.pages + b"\x00" * PAGE_SIZE,
                            fragment="pageCount")

    def test_site_overlap(self) -> None:
        data = bytearray(self.manifest)
        # site[3] is on page 2 at 0x198; move it onto site[2]'s range [0x164, 0x166).
        struct.pack_into("<I", data, SITE_ARRAY_OFFSET + 3 * SITE_RECORD_SIZE + 4, 0x165)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="overlaps")

    def test_page_record_reserved_nonzero(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, PAGE_ARRAY_OFFSET + 8, 1)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="reserved")

    def test_site_page_index_out_of_range(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, SITE_ARRAY_OFFSET, 99)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="pageIndex")

    def test_site_size_zero(self) -> None:
        data = bytearray(self.manifest)
        data[SITE_ARRAY_OFFSET + 72] = 0
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="size")

    def test_site_size_over_32(self) -> None:
        data = bytearray(self.manifest)
        data[SITE_ARRAY_OFFSET + 72] = 33
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="size")

    def test_site_offset_out_of_page(self) -> None:
        data = bytearray(self.manifest)
        struct.pack_into("<I", data, SITE_ARRAY_OFFSET + 4, PAGE_SIZE - 1)
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="exceeds the 4 KiB page")

    def test_site_find_padding_nonzero(self) -> None:
        data = bytearray(self.manifest)
        data[SITE_ARRAY_OFFSET + 8 + FIXTURE_SITE_SIZES[0]] = 0xAA
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="padding")

    def test_site_replace_padding_nonzero(self) -> None:
        data = bytearray(self.manifest)
        data[SITE_ARRAY_OFFSET + 40 + FIXTURE_SITE_SIZES[0]] = 0xAA
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="padding")

    def test_site_reserved_nonzero(self) -> None:
        data = bytearray(self.manifest)
        data[SITE_ARRAY_OFFSET + 73] = 1
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="reserved")

    def test_site_find_not_present_in_page(self) -> None:
        data = bytearray(self.manifest)
        data[SITE_ARRAY_OFFSET + 8] ^= 0xFF  # corrupt the first find byte
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="not present")

    def test_site_noop_patch(self) -> None:
        data = bytearray(self.manifest)
        start = SITE_ARRAY_OFFSET + 8
        replace_start = SITE_ARRAY_OFFSET + 40
        size = FIXTURE_SITE_SIZES[0]
        data[replace_start:replace_start + size] = data[start:start + size]
        self.expect_invalid(self.rechecksum(bytes(data)), fragment="no-op")

    def test_mutated_manifest_document_is_detected(self) -> None:
        document = json.loads((self.build_dir / "manifest.json").read_text(encoding="utf-8"))
        document["pages"][1]["sites"][0]["findOccurrence"] = 0  # dual-quad site is occurrence 1
        with self.assertRaises(ValidationError) as context:
            validate_manifest_document(self.parsed, document, self.pages)
        self.assertIn("findOccurrence", str(context.exception))

        document = json.loads((self.build_dir / "manifest.json").read_text(encoding="utf-8"))
        document["pages"][0]["sha256"] = "0" * 64
        with self.assertRaises(ValidationError) as context:
            validate_manifest_document(self.parsed, document, self.pages)
        self.assertIn("sha256", str(context.exception))

    def test_parser_accepts_real_embedded_15_8_1_offsets(self) -> None:
        # Regression guard: the real master table has ambiguous find sequences. A validator that
        # demanded find uniqueness would reject this data.
        page0 = self.pages[0:PAGE_SIZE]
        self.assertEqual(find_all(page0, bytes.fromhex("c7477804000000")), [0x81, 0xCC, 0x109])
        page1 = self.pages[4096:2 * 4096]
        self.assertEqual(find_all(page1, bytes.fromhex("83e0fe")), [0x68, 0x160])
        page2 = self.pages[2 * 4096:3 * 4096]
        self.assertEqual(find_all(page2, bytes.fromhex("750b")), [0x164])
        self.assertEqual(find_all(page2, bytes.fromhex("0f94c0")), [0x198, 0x722])


# --- Entry point -------------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    verbosity = 1
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    for case in (GeneratedFixtureTest, FixtureProvenanceTest, PinnedMasterSourceTest,
                 DeployablePatchDataTest, MinimalFixtureTest, GeneratorRejectionTest,
                 GeneratorDriverIdentityTest, MalformedManifestTest):
        suite.addTests(loader.loadTestsFromTestCase(case))
    result = unittest.TextTestRunner(verbosity=verbosity).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
