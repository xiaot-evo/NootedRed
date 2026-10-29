#!/usr/bin/env python3
# NootedRed NRPT v1 offline validator
#
# Independent, host-side simulation of the NootedRedUserPatch page-matching engine.
# Normative contract: docs/PatchProfile-Spec.md (NRPT v1, frozen 2026-10-29), sections
# 1-13 in particular. This file is intentionally an independent implementation (Python,
# stdlib only) of the same algorithm the kext must execute, so that a generator bug
# cannot "validate itself" against the Swift reference codec.
#
# What it does:
#   1. Strictly decodes an NRPT v1 profile (all E001..E032 rules, stable error codes).
#   2. Resolves every page record against a CLEAN fixture (real macOS tree via --fixtures,
#      or a synthetic tree in the unit tests) by locating the exact 4 KiB window whose
#      FNV-1a-64 equals pageHash. Apple binaries are read in place, never copied.
#   3. Simulates the kext matching algorithm EXACTLY (spec section 8): per-page offset gate,
#      full-page FNV-1a-64 hash gate, all site finds, replace writes, applied-once bitmap,
#      first-matching-record authoritative / no try-next-record after a site mismatch.
#   4. Reports per page and per site: identity results, find matches, bytes written,
#      resulting page hash, and false-positive checks for unintended fixture pages.
#   5. Rejects false positives and any partial application (atomic per page).
#
# Usage:
#   python3 test/nrpt_validator.py --profile <profile.nrpt> --fixtures / \
#       --expected-build 24H232 --device-id 0x1638 --report build/validation-report.json
#
# Exit code: 0 = PASS (deployable), 1 = FAIL, 2 = usage/IO error.
#
# No Apple binaries are embedded or required at test time; synthetic fixtures are generated
# by test/test_nrpt_validator.py. The full-cache hash scan uses an optional native helper
# (test/hash_scan.c, compiled on demand with clang) because pure-Python FNV-1a over a multi-GB
# dyld shared cache is too slow; a pure-Python fallback keeps the tool dependency-free.

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from typing import Callable, Iterable, Iterator, Optional, Sequence

__version__ = "1.0"

# ---------------------------------------------------------------------------
# NRPT v1 constants (docs/PatchProfile-Spec.md sections 2-7)
# ---------------------------------------------------------------------------

MAGIC = b"NRPT"
VERSION = 1  # default/back-compat alias; see VERSION_V1/VERSION_V2
VERSION_V1 = 1
VERSION_V2 = 2
HEADER_SIZE = 64
PAGE_RECORD_SIZE = 24  # v1
PAGE_RECORD_SIZE_V1 = 24
PAGE_RECORD_SIZE_V2 = 32
SITE_RECORD_SIZE = 40
PAGE_SIZE = 4096
BUILD_FIELD_SIZE = 16
MAX_BUILD_BYTES = 15
MAX_PROFILE_SIZE = 64 * 1024
MAX_PAGES = 256
MAX_SITES = 1024
MAX_SITES_PER_PAGE = 64
MAX_SITE_PATCH_SIZE = 16
KNOWN_APU_MASK = 0x3F

HEADER_FLAG_REQUIRE_DEVICE_ID = 0x0001
KNOWN_HEADER_FLAGS = HEADER_FLAG_REQUIRE_DEVICE_ID

MATCH_REQUIRE_OFFSET = 0x0001
MATCH_REQUIRE_HASH = 0x0002
MATCH_REQUIRE_SITES = 0x0004
KNOWN_MATCH_FLAGS = 0x0007
REQUIRED_MATCH_FLAGS = MATCH_REQUIRE_HASH | MATCH_REQUIRE_SITES
DEFAULT_MATCH_FLAGS = MATCH_REQUIRE_OFFSET | MATCH_REQUIRE_HASH | MATCH_REQUIRE_SITES

# NRPT v2 target-image metadata (spec section 0).
H_IMAGE_COUNT = 52
H_IMAGE_TABLE_SIZE = 54
H_RESERVED_V2 = 58
H_RESERVED_V2_SIZE = 6
MAX_IMAGES = 16
MAX_IMAGE_PATH_LENGTH = 200
IMAGE_ENTRY_HEADER_SIZE = 20
MAX_SEGMENTS_PER_IMAGE = 16
MAX_SECTIONS_PER_IMAGE = 16
SEGMENT_NAME_SIZE = 16
SECTION_NAME_SIZE = 16
MAX_IMAGE_VM_SIZE = 0xFFFFF000
IMAGE_KIND_STANDALONE = 0
IMAGE_KIND_SHARED_CACHE = 1
IMAGE_FLAG_SUFFIX_MATCH = 0x01
KNOWN_IMAGE_FLAGS = IMAGE_FLAG_SUFFIX_MATCH


def round_up4(value: int) -> int:
    return (value + 3) & ~3


MAX_IMAGE_TABLE_SIZE = MAX_IMAGES * (
    IMAGE_ENTRY_HEADER_SIZE
    + round_up4(MAX_IMAGE_PATH_LENGTH + 1)
    + MAX_SEGMENTS_PER_IMAGE * SEGMENT_NAME_SIZE
    + MAX_SECTIONS_PER_IMAGE * SECTION_NAME_SIZE
)

BUILD_ALPHABET = frozenset(
    b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-"
)

# Header field offsets (spec section 3).
H_MAGIC = 0
H_VERSION = 4
H_HEADER_SIZE = 6
H_BUILD = 8
H_APU_MASK = 24
H_DEVICE_ID = 28
H_PAGE_COUNT = 32
H_SITE_COUNT = 34
H_PAGE_TABLE_SIZE = 36
H_SITE_TABLE_SIZE = 40
H_PAYLOAD_CHECKSUM = 44
H_FLAGS = 48
H_RESERVED = 52
H_RESERVED_SIZE = 12

# APU family masks (spec section 3.2).
APU_RAVEN = 1 << 0
APU_RAVEN2 = 1 << 1
APU_PICASSO = 1 << 2
APU_RENOIR = 1 << 3
APU_RENOIR_E = 1 << 4
APU_GREEN_SARDINE = 1 << 5

# PCI device ID -> candidate APU family mask (spec section 3.2, mainline selectPatchSet rule).
DEVICE_CANDIDATE_MASK = {
    0x15DD: APU_RAVEN,
    0x15D8: APU_RAVEN2 | APU_PICASSO,
    0x1636: APU_RENOIR | APU_RENOIR_E,
    0x164C: APU_RENOIR | APU_RENOIR_E,
    0x15E7: APU_RENOIR | APU_GREEN_SARDINE,
    0x1638: APU_RENOIR | APU_GREEN_SARDINE,
}

ERROR_NAMES = {
    "E001": "truncated",
    "E002": "badMagic",
    "E003": "unsupportedVersion",
    "E004": "invalidHeaderSize",
    "E005": "invalidBuild",
    "E006": "invalidApuMask",
    "E007": "invalidDeviceID",
    "E008": "unsupportedHeaderFlags",
    "E009": "headerReservedNotZero",
    "E010": "profileTooLarge",
    "E011": "pageTableSizeMismatch",
    "E012": "siteTableSizeMismatch",
    "E013": "totalSizeMismatch",
    "E014": "payloadChecksumMismatch",
    "E015": "pageCountOutOfRange",
    "E016": "siteCountOutOfRange",
    "E017": "pageOffsetMisaligned",
    "E018": "unsupportedPageMatchFlags",
    "E019": "requiredPageMatchFlagMissing",
    "E020": "pageSiteRangeInvalid",
    "E021": "nonCanonicalSiteRange",
    "E022": "siteCountSumMismatch",
    "E023": "sitesPerPageExceeded",
    "E024": "invalidSitePatchSize",
    "E025": "findReplaceSizeMismatch",
    "E026": "siteOutOfPageBounds",
    "E027": "sitePaddingNotZero",
    "E028": "noOpSite",
    "E029": "unsupportedSiteFlags",
    "E030": "overlappingSiteWrites",
    "E031": "duplicatePageIdentity",
    "E032": "emptyProfile",
    "E033": "invalidPageHashInput",  # codec-level helper (pageHash length)
    # NRPT v2 target-image metadata (spec section 0.5).
    "E034": "invalidImageCount",
    "E035": "invalidImageEntry",
    "E036": "imageTableSizeMismatch",
    "E037": "invalidImagePath",
    "E038": "invalidPageMetadata",
    "E039": "duplicateImagePath",
    "E040": "invalidPageVmOffset",
    "E041": "invalidImageGeometry",
}


class NRPTCodecError(Exception):
    """Stable NRPT v1 validation error (spec section 11)."""

    def __init__(self, code: str, detail: str = "") -> None:
        if code not in ERROR_NAMES:
            raise ValueError(f"unknown NRPT error code {code!r}")
        self.code = code
        self.name = ERROR_NAMES[code]
        self.detail = detail
        message = f"{code} {self.name}"
        if detail:
            message += f": {detail}"
        super().__init__(message)


# ---------------------------------------------------------------------------
# Small integer helpers
# ---------------------------------------------------------------------------


def _u16(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 2], "little")


def _u32(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 4], "little")


def _u64(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 8], "little")


def _p16(value: int) -> bytes:
    return int(value).to_bytes(2, "little")


def _p32(value: int) -> bytes:
    return int(value).to_bytes(4, "little")


def _p64(value: int) -> bytes:
    return int(value).to_bytes(8, "little")


# ---------------------------------------------------------------------------
# Hash functions (spec section 1.1)
# ---------------------------------------------------------------------------


def fnv1a32(data: bytes) -> int:
    """Standard FNV-1a 32-bit."""
    value = 0x811C9DC5
    for byte in data:
        value = ((value ^ byte) * 0x01000193) & 0xFFFFFFFF
    return value


def fnv1a64(data: bytes) -> int:
    """Standard FNV-1a 64-bit."""
    value = 0xCBF29CE484222325
    for byte in data:
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value


def page_hash(page: bytes) -> int:
    """FNV-1a-64 over exactly one 4 KiB page (spec section 1.1 / 4)."""
    if len(page) != PAGE_SIZE:
        raise NRPTCodecError(
            "E033", f"pageHash input must be exactly {PAGE_SIZE} bytes, got {len(page)}"
        )
    return fnv1a64(page)


# ---------------------------------------------------------------------------
# Model (mirrors ProfileCodec.swift types)
# ---------------------------------------------------------------------------


@dataclass
class Site:
    site_in_page: int
    find: bytes
    replace: bytes
    flags: int = 0

    @property
    def find_size(self) -> int:
        return len(self.find)

    @property
    def replace_size(self) -> int:
        return len(self.replace)


@dataclass
class Page:
    page_file_offset: int
    page_hash: int
    match_flags: int
    sites: list[Site] = field(default_factory=list)
    # NRPT v2 target-image metadata (ignored for v1 profiles).
    image_index: int = 0
    page_vm_offset: int = 0


@dataclass
class Header:
    build: str
    apu_mask: int
    device_id: int
    flags: int = 0
    version: int = VERSION_V1
    # Derived v2 header metadata (not part of model equality; decoded profiles expose it for reports).
    image_count: int = field(default=0, compare=False)
    image_table_size: int = field(default=0, compare=False)


@dataclass
class Image:
    """NRPT v2 target-image table entry (spec section 0.4)."""

    kind: int
    path: str
    unslid_vmaddr: int
    vm_size: int
    segments: list[str] = field(default_factory=list)
    sections: list[str] = field(default_factory=list)
    flags: int = IMAGE_FLAG_SUFFIX_MATCH

    @property
    def path_bytes(self) -> bytes:
        return self.path.encode("utf-8")

    @property
    def entry_size(self) -> int:
        return (
            IMAGE_ENTRY_HEADER_SIZE
            + round_up4(len(self.path_bytes) + 1)
            + len(self.segments) * SEGMENT_NAME_SIZE
            + len(self.sections) * SECTION_NAME_SIZE
        )


@dataclass
class Profile:
    header: Header
    pages: list[Page] = field(default_factory=list)
    version: int = VERSION_V1
    images: list[Image] = field(default_factory=list)

    @property
    def page_count(self) -> int:
        return len(self.pages)

    @property
    def site_count(self) -> int:
        return sum(len(page.sites) for page in self.pages)

    @property
    def page_record_size(self) -> int:
        return PAGE_RECORD_SIZE_V2 if self.version == VERSION_V2 else PAGE_RECORD_SIZE_V1

    @property
    def image_table_size(self) -> int:
        if self.version != VERSION_V2:
            return 0
        return sum(image.entry_size for image in self.images)

    @property
    def encoded_size(self) -> int:
        return (
            HEADER_SIZE
            + self.page_count * self.page_record_size
            + self.site_count * SITE_RECORD_SIZE
            + self.image_table_size
        )


# ---------------------------------------------------------------------------
# Build field helpers (spec section 3.1)
# ---------------------------------------------------------------------------


def encode_build_field(build: str) -> bytes:
    raw = build.encode("utf-8")
    if len(raw) < 1 or len(raw) > MAX_BUILD_BYTES:
        raise NRPTCodecError("E005", f"build must be 1..{MAX_BUILD_BYTES} bytes, got {len(raw)}")
    if any(byte not in BUILD_ALPHABET for byte in raw):
        raise NRPTCodecError("E005", f"build contains a forbidden character: {build!r}")
    return raw + b"\x00" * (BUILD_FIELD_SIZE - len(raw))


def decode_build_field(field: bytes) -> str:
    if len(field) != BUILD_FIELD_SIZE:
        raise NRPTCodecError("E005", f"build field must be {BUILD_FIELD_SIZE} bytes")
    nul = field.find(b"\x00")
    if nul < 0:
        raise NRPTCodecError("E005", "build field has no NUL terminator")
    if nul < 1 or nul > MAX_BUILD_BYTES:
        raise NRPTCodecError("E005", f"build string must be 1..{MAX_BUILD_BYTES} bytes")
    if any(byte != 0 for byte in field[nul:]):
        raise NRPTCodecError("E005", "build field has non-zero bytes after the NUL terminator")
    raw = field[:nul]
    if any(byte not in BUILD_ALPHABET for byte in raw):
        raise NRPTCodecError("E005", f"build contains a forbidden character: {raw!r}")
    return raw.decode("ascii")


# ---------------------------------------------------------------------------
# Model validation (spec sections 3-7; mirrors ProfileCodec.validate order)
# ---------------------------------------------------------------------------


def _is_allowed_image_path_byte(byte: int) -> bool:
    return 0x20 <= byte <= 0x7E


def validate_image_path(path: str, context: str = "image") -> None:
    """Spec section 0.4: absolute canonical path, 1...200 printable ASCII bytes."""
    raw = path.encode("utf-8")
    if not 1 <= len(raw) <= MAX_IMAGE_PATH_LENGTH:
        raise NRPTCodecError("E037", f"{context}: path length {len(raw)}")
    if not raw.startswith(b"/"):
        raise NRPTCodecError("E037", f"{context}: path is not absolute")
    if not all(_is_allowed_image_path_byte(byte) for byte in raw):
        raise NRPTCodecError("E037", f"{context}: path has a non-printable byte")


def is_valid_fixed_name(raw: bytes, capacity: int) -> bool:
    """A 16-byte NUL-padded, 1...15 printable-ASCII unique image/segment/section name."""
    if len(raw) != capacity:
        return False
    nul = raw.find(b"\x00")
    if nul < 1 or nul > capacity - 1:
        return False
    if any(byte != 0 for byte in raw[nul:]):
        return False
    return all(_is_allowed_image_path_byte(byte) for byte in raw[:nul])


def validate_image_name_model(name: str, capacity: int, context: str) -> None:
    raw = name.encode("utf-8")
    if not is_valid_fixed_name(raw.ljust(capacity, b"\x00"), capacity):
        raise NRPTCodecError("E038", f"{context}: invalid name {name!r}")


def validate_images_model(profile: Profile) -> None:
    """NRPT v2 image-table model rules (spec sections 0.4 and 0.5)."""
    if not 1 <= len(profile.images) <= MAX_IMAGES:
        raise NRPTCodecError("E034", f"imageCount={len(profile.images)}")
    if profile.image_table_size > MAX_IMAGE_TABLE_SIZE:
        raise NRPTCodecError("E034", f"imageTableSize={profile.image_table_size}")
    for image_index, image in enumerate(profile.images):
        context = f"image[{image_index}]"
        if image.kind not in (IMAGE_KIND_STANDALONE, IMAGE_KIND_SHARED_CACHE):
            raise NRPTCodecError("E035", f"{context}: kind={image.kind}")
        if (image.flags & ~KNOWN_IMAGE_FLAGS) != 0 or (image.flags & IMAGE_FLAG_SUFFIX_MATCH) == 0:
            raise NRPTCodecError("E035", f"{context}: flags=0x{image.flags:02X}")
        validate_image_path(image.path, context)
        if not 1 <= len(image.segments) <= MAX_SEGMENTS_PER_IMAGE:
            raise NRPTCodecError("E035", f"{context}: segmentCount={len(image.segments)}")
        if not 0 <= len(image.sections) <= MAX_SECTIONS_PER_IMAGE:
            raise NRPTCodecError("E035", f"{context}: sectionCount={len(image.sections)}")
        seen: set[str] = set()
        for name in image.segments:
            validate_image_name_model(name, SEGMENT_NAME_SIZE, context + " segment")
            if name in seen:
                raise NRPTCodecError("E038", f"{context}: duplicate segment name {name!r}")
            seen.add(name)
        seen.clear()
        for name in image.sections:
            validate_image_name_model(name, SECTION_NAME_SIZE, context + " section")
            if name in seen:
                raise NRPTCodecError("E038", f"{context}: duplicate section name {name!r}")
            seen.add(name)
        if not 0 < image.vm_size <= MAX_IMAGE_VM_SIZE:
            raise NRPTCodecError("E041", f"{context}: imageVmSize={image.vm_size}")
        if image.kind == IMAGE_KIND_SHARED_CACHE and image.unslid_vmaddr == 0:
            raise NRPTCodecError("E041", f"{context}: shared-cache image has unslidVmaddr 0")
        for other_index in range(image_index):
            other = profile.images[other_index]
            if other.kind == image.kind and other.path == image.path:
                raise NRPTCodecError("E039", f"{context} duplicates image[{other_index}]")


def validate_header_model(header: Header) -> None:
    encode_build_field(header.build)  # E005
    if header.apu_mask == 0 or (header.apu_mask & ~KNOWN_APU_MASK) != 0:
        raise NRPTCodecError("E006", f"apuMask=0x{header.apu_mask:08X}")
    if header.flags & HEADER_FLAG_REQUIRE_DEVICE_ID:
        if not 1 <= header.device_id <= 0xFFFF:
            raise NRPTCodecError(
                "E007", f"deviceID=0x{header.device_id:08X} invalid with REQUIRE_DEVICE_ID"
            )
    else:
        if header.device_id != 0:
            raise NRPTCodecError(
                "E007", f"deviceID=0x{header.device_id:08X} non-zero without REQUIRE_DEVICE_ID"
            )
    if (header.flags & ~KNOWN_HEADER_FLAGS) != 0:
        raise NRPTCodecError("E008", f"header flags=0x{header.flags:08X}")


def validate_model(profile: Profile) -> None:
    """All model-level rules; raises the first violation (spec section 11 codes)."""
    if profile.version not in (VERSION_V1, VERSION_V2):
        raise NRPTCodecError("E003", f"version={profile.version}")
    validate_header_model(profile.header)

    if not profile.pages:
        raise NRPTCodecError("E032", "profile has zero pages")
    if profile.page_count > MAX_PAGES:
        raise NRPTCodecError("E015", f"pageCount={profile.page_count}")
    total_sites = profile.site_count
    if total_sites > MAX_SITES:
        raise NRPTCodecError("E016", f"siteCount={total_sites}")
    if total_sites < 1:
        raise NRPTCodecError("E016", f"siteCount={total_sites}")
    if profile.version == VERSION_V2:
        validate_images_model(profile)
    if profile.encoded_size > MAX_PROFILE_SIZE:
        raise NRPTCodecError("E010", f"encoded size {profile.encoded_size}")

    global_site_index = 0
    for page_index, page in enumerate(profile.pages):
        if (page.page_file_offset & 0x0FFF) != 0:
            raise NRPTCodecError(
                "E017",
                f"page[{page_index}] pageFileOffset=0x{page.page_file_offset:X} is not 4 KiB aligned",
            )
        if (page.match_flags & ~KNOWN_MATCH_FLAGS) != 0:
            raise NRPTCodecError(
                "E018", f"page[{page_index}] matchFlags=0x{page.match_flags:04X}"
            )
        if (page.match_flags & REQUIRED_MATCH_FLAGS) != REQUIRED_MATCH_FLAGS:
            raise NRPTCodecError(
                "E019", f"page[{page_index}] matchFlags=0x{page.match_flags:04X}"
            )
        if not 1 <= len(page.sites) <= MAX_SITES_PER_PAGE:
            raise NRPTCodecError(
                "E023", f"page[{page_index}] siteCount={len(page.sites)} (allowed 1..{MAX_SITES_PER_PAGE})"
            )
        if profile.version == VERSION_V2:
            if not 0 <= page.image_index < len(profile.images):
                raise NRPTCodecError(
                    "E038", f"page[{page_index}] imageIndex={page.image_index} imageCount={len(profile.images)}"
                )
            target_image = profile.images[page.image_index]
            if (page.page_vm_offset & 0x0FFF) != 0 or page.page_vm_offset + PAGE_SIZE > target_image.vm_size:
                raise NRPTCodecError(
                    "E040",
                    f"page[{page_index}] pageVmOffset=0x{page.page_vm_offset:X} imageVmSize=0x{target_image.vm_size:X}",
                )

        writes: list[tuple[int, int, int]] = []
        for local_index, site in enumerate(page.sites):
            site_index = global_site_index + local_index
            find_size = site.find_size
            replace_size = site.replace_size
            if not 1 <= find_size <= MAX_SITE_PATCH_SIZE or not 1 <= replace_size <= MAX_SITE_PATCH_SIZE:
                raise NRPTCodecError(
                    "E024",
                    f"site[{site_index}] findSize={find_size} replaceSize={replace_size}",
                )
            if find_size != replace_size:
                raise NRPTCodecError(
                    "E025", f"site[{site_index}] findSize={find_size} replaceSize={replace_size}"
                )
            if site.site_in_page + find_size > PAGE_SIZE or site.site_in_page + replace_size > PAGE_SIZE:
                raise NRPTCodecError(
                    "E026",
                    f"site[{site_index}] siteInPage=0x{site.site_in_page:X} size={find_size}",
                )
            if site.find == site.replace:
                raise NRPTCodecError("E028", f"site[{site_index}] find equals replace")
            if site.flags != 0:
                raise NRPTCodecError("E029", f"site[{site_index}] flags=0x{site.flags:08X}")
            writes.append((site.site_in_page, site.site_in_page + replace_size, site_index))

        ordered = sorted(writes)
        for previous, current in zip(ordered, ordered[1:]):
            if current[0] < previous[1]:
                raise NRPTCodecError(
                    "E030",
                    f"page[{page_index}] sites {previous[2]} and {current[2]} overlap "
                    f"[0x{previous[0]:X},0x{previous[1]:X}) / [0x{current[0]:X},0x{current[1]:X})",
                )

        global_site_index += len(page.sites)

    # Identity uniqueness (spec section 6 rule 5).
    for page_index in range(len(profile.pages)):
        page = profile.pages[page_index]
        for other_index in range(page_index):
            other = profile.pages[other_index]
            if page.page_hash != other.page_hash:
                continue
            both_require_offset = (
                (page.match_flags & MATCH_REQUIRE_OFFSET) != 0
                and (other.match_flags & MATCH_REQUIRE_OFFSET) != 0
            )
            if page.page_file_offset == other.page_file_offset or not both_require_offset:
                raise NRPTCodecError(
                    "E031",
                    f"page[{page_index}] duplicates the identity of page[{other_index}] "
                    f"(hash=0x{page.page_hash:016X})",
                )


# ---------------------------------------------------------------------------
# Decode (spec sections 2-7 and 11; mirrors ProfileCodec.decode order)
# ---------------------------------------------------------------------------


def _parse_image_table(
    data: bytes, base: int, image_count: int, image_table_size: int
) -> list[Image]:
    """NRPT v2 image table (spec section 0.4); raises the stable E034-E041 codes."""
    cursor = base
    end = base + image_table_size
    if end > len(data):
        raise NRPTCodecError("E035", f"image table extends past profile ({image_table_size} bytes)")
    images: list[Image] = []
    for image_index in range(image_count):
        if end - cursor < IMAGE_ENTRY_HEADER_SIZE:
            raise NRPTCodecError("E035", f"image[{image_index}]: truncated entry header")
        kind = data[cursor]
        flags = data[cursor + 1]
        path_length = _u16(data, cursor + 2)
        unslid_vmaddr = _u64(data, cursor + 4)
        vm_size = _u32(data, cursor + 12)
        segment_count = data[cursor + 16]
        section_count = data[cursor + 17]
        reserved = _u16(data, cursor + 18)

        if (
            reserved != 0
            or (flags & ~KNOWN_IMAGE_FLAGS) != 0
            or (flags & IMAGE_FLAG_SUFFIX_MATCH) == 0
            or kind not in (IMAGE_KIND_STANDALONE, IMAGE_KIND_SHARED_CACHE)
            or not 1 <= path_length <= MAX_IMAGE_PATH_LENGTH
            or not 1 <= segment_count <= MAX_SEGMENTS_PER_IMAGE
            or section_count > MAX_SECTIONS_PER_IMAGE
        ):
            raise NRPTCodecError("E035", f"image[{image_index}]: invalid entry header")

        path_field_size = round_up4(path_length + 1)
        entry_size = (
            IMAGE_ENTRY_HEADER_SIZE
            + path_field_size
            + segment_count * SEGMENT_NAME_SIZE
            + section_count * SECTION_NAME_SIZE
        )
        if end - cursor < entry_size:
            raise NRPTCodecError("E035", f"image[{image_index}]: entry exceeds image table")

        path_base = cursor + IMAGE_ENTRY_HEADER_SIZE
        if data[path_base + path_length] != 0 or data[path_base] != ord("/"):
            raise NRPTCodecError("E037", f"image[{image_index}]: path is not NUL-terminated absolute")
        for index in range(path_length):
            if not _is_allowed_image_path_byte(data[path_base + index]):
                raise NRPTCodecError("E037", f"image[{image_index}]: non-printable path byte")
        for index in range(path_length + 1, path_field_size):
            if data[path_base + index] != 0:
                raise NRPTCodecError("E035", f"image[{image_index}]: path padding not zero")
        path = data[path_base : path_base + path_length].decode("ascii")

        names = path_base + path_field_size
        segments: list[str] = []
        seen_segments: set[str] = set()
        for segment in range(segment_count):
            raw = data[names + segment * SEGMENT_NAME_SIZE : names + (segment + 1) * SEGMENT_NAME_SIZE]
            if not is_valid_fixed_name(raw, SEGMENT_NAME_SIZE):
                raise NRPTCodecError("E038", f"image[{image_index}]: invalid segment name")
            name = raw.split(b"\x00", 1)[0].decode("ascii")
            if name in seen_segments:
                raise NRPTCodecError("E038", f"image[{image_index}]: duplicate segment name {name!r}")
            seen_segments.add(name)
            segments.append(name)
        names += segment_count * SEGMENT_NAME_SIZE
        sections: list[str] = []
        seen_sections: set[str] = set()
        for section in range(section_count):
            raw = data[names + section * SECTION_NAME_SIZE : names + (section + 1) * SECTION_NAME_SIZE]
            if not is_valid_fixed_name(raw, SECTION_NAME_SIZE):
                raise NRPTCodecError("E038", f"image[{image_index}]: invalid section name")
            name = raw.split(b"\x00", 1)[0].decode("ascii")
            if name in seen_sections:
                raise NRPTCodecError("E038", f"image[{image_index}]: duplicate section name {name!r}")
            seen_sections.add(name)
            sections.append(name)

        if vm_size == 0 or vm_size > MAX_IMAGE_VM_SIZE or (
            kind == IMAGE_KIND_SHARED_CACHE and unslid_vmaddr == 0
        ):
            raise NRPTCodecError("E041", f"image[{image_index}]: invalid image geometry")
        for other in images:
            if other.kind == kind and other.path == path:
                raise NRPTCodecError("E039", f"image[{image_index}]: duplicate image path")
        images.append(
            Image(
                kind=kind,
                path=path,
                unslid_vmaddr=unslid_vmaddr,
                vm_size=vm_size,
                segments=segments,
                sections=sections,
                flags=flags,
            )
        )
        cursor += entry_size

    if cursor != end:
        raise NRPTCodecError("E036", f"imageTableSize {image_table_size} != derived {cursor - base}")
    return images


def decode(data: bytes) -> Profile:
    """Strict, all-or-nothing NRPT decoder (v1 back-compatibility, v2 image metadata)."""
    if len(data) < HEADER_SIZE:
        raise NRPTCodecError("E001", f"{len(data)} bytes < {HEADER_SIZE}")

    if data[H_MAGIC : H_MAGIC + 4] != MAGIC:
        raise NRPTCodecError("E002", f"magic={data[H_MAGIC:H_MAGIC + 4]!r}")

    version = _u16(data, H_VERSION)
    if version not in (VERSION_V1, VERSION_V2):
        raise NRPTCodecError("E003", f"version={version}")

    header_size = _u16(data, H_HEADER_SIZE)
    if header_size != HEADER_SIZE:
        raise NRPTCodecError("E004", f"headerSize={header_size}")

    build = decode_build_field(data[H_BUILD : H_BUILD + BUILD_FIELD_SIZE])

    apu_mask = _u32(data, H_APU_MASK)
    if apu_mask == 0 or (apu_mask & ~KNOWN_APU_MASK) != 0:
        raise NRPTCodecError("E006", f"apuMask=0x{apu_mask:08X}")

    header_flags = _u32(data, H_FLAGS)
    device_id = _u32(data, H_DEVICE_ID)
    if header_flags & HEADER_FLAG_REQUIRE_DEVICE_ID:
        if not 1 <= device_id <= 0xFFFF:
            raise NRPTCodecError(
                "E007", f"deviceID=0x{device_id:08X} invalid with REQUIRE_DEVICE_ID"
            )
    else:
        if device_id != 0:
            raise NRPTCodecError(
                "E007", f"deviceID=0x{device_id:08X} non-zero without REQUIRE_DEVICE_ID"
            )
    if (header_flags & ~KNOWN_HEADER_FLAGS) != 0:
        raise NRPTCodecError("E008", f"header flags=0x{header_flags:08X}")

    if version == VERSION_V2:
        reserved = data[H_RESERVED_V2 : H_RESERVED_V2 + H_RESERVED_V2_SIZE]
    else:
        reserved = data[H_RESERVED : H_RESERVED + H_RESERVED_SIZE]
    if any(byte != 0 for byte in reserved):
        raise NRPTCodecError("E009", "header reserved bytes are not all zero")

    if len(data) > MAX_PROFILE_SIZE:
        raise NRPTCodecError("E010", f"actual size {len(data)} > {MAX_PROFILE_SIZE}")

    page_count = _u16(data, H_PAGE_COUNT)
    site_count = _u16(data, H_SITE_COUNT)
    if page_count < 1:
        raise NRPTCodecError("E032", f"pageCount={page_count}")
    if page_count > MAX_PAGES:
        raise NRPTCodecError("E015", f"pageCount={page_count}")
    if site_count < 1 or site_count > MAX_SITES:
        raise NRPTCodecError("E016", f"siteCount={site_count}")

    image_count = 0
    stored_image_table_size = 0
    page_record_size = PAGE_RECORD_SIZE_V1
    if version == VERSION_V2:
        image_count = _u16(data, H_IMAGE_COUNT)
        stored_image_table_size = _u32(data, H_IMAGE_TABLE_SIZE)
        page_record_size = PAGE_RECORD_SIZE_V2
        if not 1 <= image_count <= MAX_IMAGES:
            raise NRPTCodecError("E034", f"imageCount={image_count}")
        if (
            stored_image_table_size < image_count * IMAGE_ENTRY_HEADER_SIZE
            or stored_image_table_size > MAX_IMAGE_TABLE_SIZE
        ):
            raise NRPTCodecError("E035", f"imageTableSize={stored_image_table_size}")

    encoded_size = HEADER_SIZE + page_count * page_record_size + site_count * SITE_RECORD_SIZE + stored_image_table_size
    if encoded_size > MAX_PROFILE_SIZE:
        raise NRPTCodecError("E010", f"computed size {encoded_size} > {MAX_PROFILE_SIZE}")

    stored_page_table_size = _u32(data, H_PAGE_TABLE_SIZE)
    expected_page_table_size = page_count * page_record_size
    if stored_page_table_size != expected_page_table_size:
        raise NRPTCodecError(
            "E011", f"pageTableSize={stored_page_table_size} expected {expected_page_table_size}"
        )

    stored_site_table_size = _u32(data, H_SITE_TABLE_SIZE)
    expected_site_table_size = site_count * SITE_RECORD_SIZE
    if stored_site_table_size != expected_site_table_size:
        raise NRPTCodecError(
            "E012", f"siteTableSize={stored_site_table_size} expected {expected_site_table_size}"
        )

    if len(data) != encoded_size:
        raise NRPTCodecError("E013", f"actual size {len(data)} expected {encoded_size}")

    stored_checksum = _u32(data, H_PAYLOAD_CHECKSUM)
    computed_checksum = fnv1a32(data[HEADER_SIZE:])
    if stored_checksum != computed_checksum:
        raise NRPTCodecError(
            "E014", f"stored=0x{stored_checksum:08X} computed=0x{computed_checksum:08X}"
        )

    pages_base = HEADER_SIZE
    site_table_base = pages_base + expected_page_table_size
    images: list[Image] = []
    if version == VERSION_V2:
        images = _parse_image_table(
            data,
            site_table_base + expected_site_table_size,
            image_count,
            stored_image_table_size,
        )

    pages: list[Page] = []
    running_first_site = 0
    for page_index in range(page_count):
        record = pages_base + page_index * page_record_size
        page_file_offset = _u64(data, record)
        page_content_hash = _u64(data, record + 8)
        first_site = _u32(data, record + 16)
        page_sites = _u16(data, record + 20)
        raw_match_flags = _u16(data, record + 22)
        image_index = 0
        page_vm_offset = 0
        if version == VERSION_V2:
            image_index = _u16(data, record + 24)
            page_reserved = _u16(data, record + 26)
            page_vm_offset = _u32(data, record + 28)

        if (page_file_offset & 0x0FFF) != 0:
            raise NRPTCodecError(
                "E017",
                f"page[{page_index}] pageFileOffset=0x{page_file_offset:X} is not 4 KiB aligned",
            )
        if (raw_match_flags & ~KNOWN_MATCH_FLAGS) != 0:
            raise NRPTCodecError("E018", f"page[{page_index}] matchFlags=0x{raw_match_flags:04X}")
        if (raw_match_flags & REQUIRED_MATCH_FLAGS) != REQUIRED_MATCH_FLAGS:
            raise NRPTCodecError("E019", f"page[{page_index}] matchFlags=0x{raw_match_flags:04X}")
        if not 1 <= page_sites <= MAX_SITES_PER_PAGE:
            raise NRPTCodecError("E023", f"page[{page_index}] siteCount={page_sites}")
        if first_site != running_first_site:
            raise NRPTCodecError(
                "E021",
                f"page[{page_index}] firstSite={first_site} expected {running_first_site}",
            )
        if first_site + page_sites > site_count:
            raise NRPTCodecError(
                "E020",
                f"page[{page_index}] firstSite={first_site} siteCount={page_sites} "
                f"header siteCount={site_count}",
            )
        if version == VERSION_V2:
            if page_reserved != 0 or image_index >= image_count:
                raise NRPTCodecError(
                    "E038",
                    f"page[{page_index}] imageIndex={image_index} reserved={page_reserved} imageCount={image_count}",
                )
            if (page_vm_offset & 0x0FFF) != 0 or page_vm_offset + PAGE_SIZE > images[image_index].vm_size:
                raise NRPTCodecError(
                    "E040",
                    f"page[{page_index}] pageVmOffset=0x{page_vm_offset:X} "
                    f"imageVmSize=0x{images[image_index].vm_size:X}",
                )

        sites: list[Site] = []
        for local_index in range(page_sites):
            global_index = running_first_site + local_index
            site_base = site_table_base + global_index * SITE_RECORD_SIZE
            site_in_page = _u16(data, site_base)
            find_size = data[site_base + 2]
            replace_size = data[site_base + 3]
            if not 1 <= find_size <= MAX_SITE_PATCH_SIZE or not 1 <= replace_size <= MAX_SITE_PATCH_SIZE:
                raise NRPTCodecError(
                    "E024",
                    f"site[{global_index}] findSize={find_size} replaceSize={replace_size}",
                )
            if find_size != replace_size:
                raise NRPTCodecError(
                    "E025", f"site[{global_index}] findSize={find_size} replaceSize={replace_size}"
                )
            if site_in_page + find_size > PAGE_SIZE:
                raise NRPTCodecError(
                    "E026", f"site[{global_index}] siteInPage=0x{site_in_page:X} size={find_size}"
                )
            find_base = site_base + 4
            replace_base = find_base + MAX_SITE_PATCH_SIZE
            find_field = data[find_base : find_base + MAX_SITE_PATCH_SIZE]
            replace_field = data[replace_base : replace_base + MAX_SITE_PATCH_SIZE]
            if any(byte != 0 for byte in find_field[find_size:]) or any(
                byte != 0 for byte in replace_field[replace_size:]
            ):
                raise NRPTCodecError("E027", f"site[{global_index}] find/replace padding not zero")
            find = bytes(find_field[:find_size])
            replace = bytes(replace_field[:replace_size])
            if find == replace:
                raise NRPTCodecError("E028", f"site[{global_index}] find equals replace")
            site_flags = _u32(data, site_base + 36)
            if site_flags != 0:
                raise NRPTCodecError("E029", f"site[{global_index}] flags=0x{site_flags:08X}")
            sites.append(Site(site_in_page=site_in_page, find=find, replace=replace, flags=site_flags))

        pages.append(
            Page(
                page_file_offset=page_file_offset,
                page_hash=page_content_hash,
                match_flags=raw_match_flags,
                sites=sites,
                image_index=image_index,
                page_vm_offset=page_vm_offset,
            )
        )
        running_first_site += page_sites

    if running_first_site != site_count:
        raise NRPTCodecError(
            "E022", f"summed site count {running_first_site} != header siteCount {site_count}"
        )

    profile = Profile(
        header=Header(
            build=build,
            apu_mask=apu_mask,
            device_id=device_id,
            flags=header_flags,
            version=version,
            image_count=image_count,
            image_table_size=stored_image_table_size,
        ),
        pages=pages,
        version=version,
        images=images,
    )
    validate_model(profile)
    return profile


# ---------------------------------------------------------------------------
# Encode (canonical bytes; used for test vectors and cross-checking the generator)
# ---------------------------------------------------------------------------


def encode_fixed_name(name: str, capacity: int) -> bytes:
    raw = name.encode("utf-8")
    if not is_valid_fixed_name(raw.ljust(capacity, b"\x00"), capacity):
        raise NRPTCodecError("E038", f"invalid image name {name!r}")
    return raw + b"\x00" * (capacity - len(raw))


def encode_image_table(images: Sequence[Image]) -> bytes:
    """Canonical NRPT v2 image table (spec section 0.4)."""
    table = bytearray()
    for image in images:
        path = image.path_bytes
        path_field_size = round_up4(len(path) + 1)
        table += bytes((image.kind, image.flags))
        table += _p16(len(path))
        table += _p64(image.unslid_vmaddr)
        table += _p32(image.vm_size)
        table += bytes((len(image.segments), len(image.sections)))
        table += _p16(0)  # reserved
        table += path
        table += b"\x00" * (path_field_size - len(path))
        for name in image.segments:
            table += encode_fixed_name(name, SEGMENT_NAME_SIZE)
        for name in image.sections:
            table += encode_fixed_name(name, SECTION_NAME_SIZE)
    return bytes(table)


def encode(profile: Profile) -> bytes:
    """Canonical NRPT encoder (v1 or v2 per profile.version). Derives all counts and checksum."""
    validate_model(profile)
    version = profile.version

    page_table = bytearray()
    site_table = bytearray()
    first_site = 0
    for page in profile.pages:
        page_table += _p64(page.page_file_offset)
        page_table += _p64(page.page_hash)
        page_table += _p32(first_site)
        page_table += _p16(len(page.sites))
        page_table += _p16(page.match_flags)
        if version == VERSION_V2:
            page_table += _p16(page.image_index)
            page_table += _p16(0)  # reserved
            page_table += _p32(page.page_vm_offset)
        first_site += len(page.sites)

        for site in page.sites:
            site_table += _p16(site.site_in_page)
            site_table += bytes((site.find_size, site.replace_size))
            site_table += site.find + b"\x00" * (MAX_SITE_PATCH_SIZE - site.find_size)
            site_table += site.replace + b"\x00" * (MAX_SITE_PATCH_SIZE - site.replace_size)
            site_table += _p32(site.flags)

    image_table = encode_image_table(profile.images) if version == VERSION_V2 else b""
    payload = bytes(page_table) + bytes(site_table) + image_table
    output = bytearray()
    output += MAGIC
    output += _p16(version)
    output += _p16(HEADER_SIZE)
    output += encode_build_field(profile.header.build)
    output += _p32(profile.header.apu_mask)
    output += _p32(profile.header.device_id)
    output += _p16(len(profile.pages))
    output += _p16(first_site)
    output += _p32(len(page_table))
    output += _p32(len(site_table))
    output += _p32(fnv1a32(payload))
    output += _p32(profile.header.flags)
    if version == VERSION_V2:
        output += _p16(len(profile.images))
        output += _p32(len(image_table))
        output += b"\x00" * H_RESERVED_V2_SIZE
    else:
        output += b"\x00" * H_RESERVED_SIZE
    output += payload
    if len(output) != profile.encoded_size:
        raise NRPTCodecError("E013", "encoder produced an inconsistent size")
    return bytes(output)


# ---------------------------------------------------------------------------
# Kext matching simulation (spec section 8)
# ---------------------------------------------------------------------------


@dataclass
class ChunkResult:
    """Result of simulating one delivered 4 KiB chunk through the kext algorithm."""

    status: str  # "applied" | "siteFindMismatch" | "alreadyApplied" | "noMatch"
    page_index: Optional[int] = None
    site_index: Optional[int] = None
    data: Optional[bytes] = None
    writes: list[dict] = field(default_factory=list)

    @property
    def applied(self) -> bool:
        return self.status == "applied"


def page_identity_matches(page: Page, data: bytes, chunk_base: Optional[int]) -> bool:
    """Spec section 8 identity gates (offset if required, then full-page hash)."""
    if len(data) != PAGE_SIZE:
        return False
    if page.match_flags & MATCH_REQUIRE_OFFSET:
        if chunk_base is None or (chunk_base & 0x0FFF) != 0:
            return False
        if page.page_file_offset != chunk_base:
            return False
    if page.match_flags & MATCH_REQUIRE_HASH:
        if fnv1a64(data) != page.page_hash:
            return False
    return True


def apply_chunk(
    profile: Profile,
    data: bytes,
    chunk_base: Optional[int],
    applied_pages: set[int],
) -> ChunkResult:
    """Simulate one `_cs_validate_page` delivery through the NRPT v1 engine.

    Exactly spec section 8:
      - records are tried in profile order;
      - identity = offset (when required) + FNV-1a-64 hash;
      - a matched but already-applied record stops with no write and no fallback;
      - a find mismatch on a matched record stops with ZERO writes for the chunk;
      - all replaces are written only after every find matched (atomic page).
    `applied_pages` is the boot-persistent applied bitmap and is mutated on success.
    """
    if len(data) != PAGE_SIZE:
        return ChunkResult(status="noMatch")

    for page_index, page in enumerate(profile.pages):
        if not page_identity_matches(page, data, chunk_base):
            continue

        if page_index in applied_pages:
            return ChunkResult(status="alreadyApplied", page_index=page_index)

        for site_index, site in enumerate(page.sites):
            start = site.site_in_page
            if data[start : start + site.find_size] != site.find:
                return ChunkResult(
                    status="siteFindMismatch", page_index=page_index, site_index=site_index
                )

        patched = bytearray(data)
        writes: list[dict] = []
        for site in page.sites:
            start = site.site_in_page
            end = start + site.replace_size
            patched[start:end] = site.replace
            writes.append(
                {
                    "siteInPage": site.site_in_page,
                    "findSize": site.find_size,
                    "findHex": site.find.hex(),
                    "replaceHex": site.replace.hex(),
                    "originalHex": bytes(data[start:end]).hex(),
                }
            )

        applied_pages.add(page_index)
        return ChunkResult(
            status="applied", page_index=page_index, data=bytes(patched), writes=writes
        )

    return ChunkResult(status="noMatch")


def apply_range(
    profile: Profile,
    data: bytes,
    range_base: int,
    applied_pages: set[int],
) -> list[ChunkResult]:
    """Simulate `_cs_validate_range` delivery: only whole 4 KiB chunks are processed (spec section 9)."""
    results: list[ChunkResult] = []
    chunk_count = len(data) // PAGE_SIZE
    for index in range(chunk_count):
        start = index * PAGE_SIZE
        chunk = data[start : start + PAGE_SIZE]
        results.append(apply_chunk(profile, chunk, range_base + start, applied_pages))
    return results


# ---------------------------------------------------------------------------
# Fixture discovery and page resolution (spec sections 4.3 and 13)
# ---------------------------------------------------------------------------

DEFAULT_IMAGE_GLOBS = (
    "System/Library/Extensions/AMD*GLDriver.bundle/Contents/MacOS/*",
    "System/Library/Extensions/AMD*MTLDriver.bundle/Contents/MacOS/*",
    "System/Library/Extensions/*VADriver*.bundle/Contents/MacOS/*",
    "System/Library/Extensions/*GVA*.bundle/Contents/MacOS/*",
    "System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64h*",
    "System/Library/dyld/dyld_shared_cache_x86_64h*",
)


@dataclass(frozen=True)
class FixtureImage:
    path: str
    name: str
    size: int


def discover_images(
    fixture_root: str, extra_images: Optional[Sequence[str]] = None
) -> list[FixtureImage]:
    """Discover clean candidate images under the fixture root (deterministic order)."""
    seen: set[str] = set()
    images: list[FixtureImage] = []
    candidates: list[str] = []
    for pattern in DEFAULT_IMAGE_GLOBS:
        candidates.extend(glob.glob(os.path.join(fixture_root, pattern)))
    for extra in extra_images or ():
        candidates.append(extra)

    for candidate in sorted(candidates):
        try:
            resolved = os.path.realpath(candidate)
        except OSError:
            continue
        if resolved in seen:
            continue
        seen.add(resolved)
        if not os.path.isfile(resolved):
            continue
        lower = os.path.basename(resolved).lower()
        if (
            lower.endswith(".map")
            or lower.endswith(".atlas")
            or lower.endswith(".symbols")
            or lower.endswith(".dylddata")
            or ".dsym" in resolved.lower()
            or lower.startswith("_")
        ):
            continue
        try:
            size = os.path.getsize(resolved)
        except OSError:
            continue
        if size < PAGE_SIZE:
            continue
        images.append(FixtureImage(path=resolved, name=os.path.basename(resolved), size=size))
    images.sort(key=lambda image: (image.name, image.path))
    return images


def read_chunk(path: str, offset: int, size: int = PAGE_SIZE) -> bytes:
    with open(path, "rb") as handle:
        handle.seek(offset)
        return handle.read(size)


def resolve_page(page: Page, images: Sequence[FixtureImage]) -> list[tuple[FixtureImage, int, bytes]]:
    """Resolve a page record to clean fixture content.

    Offset-required records only accept the exact chunk at `pageFileOffset`; hash-only records
    scan every aligned 4 KiB window of every candidate image (content identity, spec section 4.3).
    Returns all matches (normally exactly one).
    """
    matches: list[tuple[FixtureImage, int, bytes]] = []
    if page.match_flags & MATCH_REQUIRE_OFFSET:
        offset = page.page_file_offset
        for image in images:
            if offset + PAGE_SIZE > image.size:
                continue
            chunk = read_chunk(image.path, offset)
            if len(chunk) == PAGE_SIZE and fnv1a64(chunk) == page.page_hash:
                matches.append((image, offset, chunk))
        return matches

    for image in images:
        offset = 0
        with open(image.path, "rb") as handle:
            while offset + PAGE_SIZE <= image.size:
                chunk = handle.read(PAGE_SIZE)
                if len(chunk) != PAGE_SIZE:
                    break
                if fnv1a64(chunk) == page.page_hash:
                    matches.append((image, offset, chunk))
                offset += PAGE_SIZE
    return matches


# ---------------------------------------------------------------------------
# Full-fixture page hash scan (hash-only record identity, spec section 13)
# ---------------------------------------------------------------------------
#
# Hash-only records (REQUIRE_OFFSET cleared) identify a page by content alone, so the
# false-positive check must prove that no other aligned 4 KiB page of the fixture has the same
# FNV-1a-64. A real macOS fixture is several GB; pure-Python FNV-1a is ~4 MB/s, so a small C helper
# (test/hash_scan.c) is compiled on demand and used when available. The pure-Python fallback is
# exact and is used for small fixtures and for the unit tests.

NATIVE_SCAN_THRESHOLD_BYTES = 64 * 1024 * 1024
HASH_SCAN_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hash_scan.c")


def native_hash_scan_binary() -> Optional[str]:
    """Compile test/hash_scan.c on demand; return the binary path or None when unavailable."""
    if not os.path.isfile(HASH_SCAN_SOURCE):
        return None
    compiler = shutil.which("clang") or shutil.which("cc") or shutil.which("gcc")
    if compiler is None:
        return None
    try:
        with open(HASH_SCAN_SOURCE, "rb") as handle:
            source_digest = hashlib.sha256(handle.read()).hexdigest()[:16]
    except OSError:
        return None
    binary_path = os.path.join(tempfile.gettempdir(), f"nrpt_hash_scan_{source_digest}")
    if os.path.isfile(binary_path) and os.access(binary_path, os.X_OK):
        return binary_path
    try:
        completed = subprocess.run(
            [compiler, "-O2", "-o", binary_path, HASH_SCAN_SOURCE],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0 or not os.path.isfile(binary_path):
        return None
    return binary_path


def python_page_hash_scan(
    images: Sequence[FixtureImage], queries: Iterable[int]
) -> dict[int, list[tuple[str, int]]]:
    """Pure-Python exact scan: hash every aligned 4 KiB page of every candidate image."""
    wanted = set(queries)
    results: dict[int, list[tuple[str, int]]] = {query: [] for query in wanted}
    if not wanted:
        return results
    for image in images:
        offset = 0
        with open(image.path, "rb") as handle:
            while offset + PAGE_SIZE <= image.size:
                chunk = handle.read(PAGE_SIZE)
                if len(chunk) != PAGE_SIZE:
                    break
                digest = fnv1a64(chunk)
                if digest in results:
                    results[digest].append((image.path, offset))
                offset += PAGE_SIZE
    return results


def native_page_hash_scan(
    images: Sequence[FixtureImage], queries: Iterable[int], binary_path: str
) -> Optional[dict[int, list[tuple[str, int]]]]:
    """Exact scan through the compiled C helper; returns None when the helper fails."""
    wanted = sorted(set(queries))
    if not wanted:
        return {}
    query_handle = tempfile.NamedTemporaryFile(
        mode="w", prefix="nrpt-hash-queries-", suffix=".txt", delete=False
    )
    try:
        for query in wanted:
            query_handle.write(f"{query:016x}\n")
        query_handle.close()
        command = [binary_path, query_handle.name] + [image.path for image in images]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=900)
        if completed.returncode != 0:
            return None
        results: dict[int, list[tuple[str, int]]] = {query: [] for query in wanted}
        for line in completed.stdout.splitlines():
            fields = line.split("\t")
            if len(fields) != 3:
                continue
            try:
                digest = int(fields[0], 16)
                image_index = int(fields[1])
                offset = int(fields[2], 16)
            except ValueError:
                continue
            if digest not in results or not 0 <= image_index < len(images):
                continue
            results[digest].append((images[image_index].path, offset))
        return results
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        if not query_handle.closed:
            query_handle.close()
        try:
            os.unlink(query_handle.name)
        except OSError:
            pass


def scan_fixture_page_hashes(
    images: Sequence[FixtureImage],
    queries: Iterable[int],
    *,
    allow_native: bool = True,
) -> tuple[dict[int, list[tuple[str, int]]], str]:
    """Scan the fixture for the given page hashes. Returns (matches, mode)."""
    wanted = set(queries)
    total_bytes = sum(image.size for image in images)
    if allow_native and total_bytes > NATIVE_SCAN_THRESHOLD_BYTES:
        binary_path = native_hash_scan_binary()
        if binary_path is not None:
            print(
                f"hash scan: {len(wanted)} identity hash(es) over {len(images)} image(s) "
                f"({total_bytes / 1e9:.2f} GB) via native helper",
                file=sys.stderr,
            )
            results = native_page_hash_scan(images, wanted, binary_path)
            if results is not None:
                return results, "native"
            print("hash scan: native helper failed, falling back to Python", file=sys.stderr)
    print(
        f"hash scan: {len(wanted)} identity hash(es) over {len(images)} image(s) "
        f"({total_bytes / 1e9:.2f} GB) via Python (may be slow)",
        file=sys.stderr,
    )
    return python_page_hash_scan(images, wanted), "python"


# ---------------------------------------------------------------------------
# NRPT v2 metadata re-resolution against the clean fixture (spec section 0.6)
# ---------------------------------------------------------------------------
#
# The validator must not trust the profile's target-image metadata: it re-resolves every page's
# (imageIndex, pageVmOffset) into the clean fixture and verifies the file, segment, section, file
# offset and page hash. Standalone Mach-O images are parsed from the fixture file; shared-cache
# images are located through the dyld cache mapping tables and the cache image-text list.

LC_SEGMENT_64 = 0x19
MACHO_MAGIC_64 = 0xFEEDFACF


@dataclass
class MachOSection:
    name: str
    segname: str
    addr: int
    size: int
    offset: int


@dataclass
class MachOSegment:
    name: str
    vmaddr: int
    vmsize: int
    fileoff: int
    filesize: int
    sections: list[MachOSection] = field(default_factory=list)


@dataclass
class CacheMapping:
    path: str
    va: int
    size: int
    file_offset: int


@dataclass
class CacheImageText:
    load_address: int
    text_size: int
    path: str


def _cstring(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("ascii", "replace")


def parse_macho_header(read_at: Callable[[int, int], bytes]) -> list[MachOSegment]:
    """Minimal LC_SEGMENT_64 parser for fixture verification (raises ValueError)."""
    header = read_at(0, 32)
    if len(header) != 32:
        raise ValueError("truncated Mach-O header")
    magic = int.from_bytes(header[0:4], "little")
    if magic != MACHO_MAGIC_64:
        raise ValueError(f"unexpected Mach-O magic 0x{magic:08X}")
    ncmds = int.from_bytes(header[16:20], "little")
    sizeofcmds = int.from_bytes(header[20:24], "little")
    if not 0 < ncmds <= 4096 or sizeofcmds > 1024 * 1024:
        raise ValueError(f"implausible Mach-O load commands ({ncmds}/{sizeofcmds})")
    commands = read_at(32, sizeofcmds)
    if len(commands) != sizeofcmds:
        raise ValueError("truncated Mach-O load commands")
    segments: list[MachOSegment] = []
    cursor = 0
    for _ in range(ncmds):
        if cursor + 8 > len(commands):
            raise ValueError("truncated load command")
        cmd = int.from_bytes(commands[cursor : cursor + 4], "little")
        cmdsize = int.from_bytes(commands[cursor + 4 : cursor + 8], "little")
        if cmdsize < 8 or cursor + cmdsize > len(commands):
            raise ValueError("invalid load command size")
        if cmd == LC_SEGMENT_64:
            if cmdsize < 72:
                raise ValueError("truncated LC_SEGMENT_64")
            segment = MachOSegment(
                name=_cstring(commands[cursor + 8 : cursor + 24]),
                vmaddr=int.from_bytes(commands[cursor + 24 : cursor + 32], "little"),
                vmsize=int.from_bytes(commands[cursor + 32 : cursor + 40], "little"),
                fileoff=int.from_bytes(commands[cursor + 40 : cursor + 48], "little"),
                filesize=int.from_bytes(commands[cursor + 48 : cursor + 56], "little"),
            )
            nsects = int.from_bytes(commands[cursor + 64 : cursor + 68], "little")
            section_base = cursor + 72
            if nsects > 128 or section_base + nsects * 80 > cursor + cmdsize:
                raise ValueError("invalid section count in LC_SEGMENT_64")
            for section_index in range(nsects):
                base = section_base + section_index * 80
                segment.sections.append(
                    MachOSection(
                        name=_cstring(commands[base : base + 16]),
                        segname=_cstring(commands[base + 16 : base + 32]),
                        addr=int.from_bytes(commands[base + 32 : base + 40], "little"),
                        size=int.from_bytes(commands[base + 40 : base + 48], "little"),
                        offset=int.from_bytes(commands[base + 48 : base + 52], "little"),
                    )
                )
            segments.append(segment)
        cursor += cmdsize
    return segments


def _segment_containing(segments: Sequence[MachOSegment], address: int) -> Optional[MachOSegment]:
    for segment in segments:
        if segment.vmaddr <= address < segment.vmaddr + segment.vmsize:
            return segment
    return None


def _section_containing(segments: Sequence[MachOSegment], address: int) -> Optional[MachOSection]:
    for segment in segments:
        for section in segment.sections:
            if section.addr <= address < section.addr + section.size:
                return section
    return None


@dataclass
class ImageResolution:
    image_index: int
    kind: int
    path: str
    unslid_vmaddr: int
    vm_size: int
    segment_count: int
    section_count: int


@dataclass
class PageMetadataResolution:
    image_index: int
    image_kind: int
    image_path: str
    image_unslid_vmaddr: int
    image_vm_size: int
    page_vm_offset: int
    page_start: int
    segment: str
    section: Optional[str]
    file: str
    file_offset: int
    namespace: str
    page: bytes


class FixtureCatalog:
    """Fixture-side v2 image/page metadata re-resolution."""

    def __init__(self, fixture_root: str, images: Sequence[FixtureImage], profile: "Profile") -> None:
        self.fixture_root = fixture_root
        self.images = images
        self._profile = profile
        self.cache_files = [
            image
            for image in images
            if os.path.basename(image.path).startswith("dyld_shared_cache_x86_64h")
            and not os.path.basename(image.path).endswith((".map", ".atlas", ".symbols"))
        ]
        self._cache_mappings: Optional[list[CacheMapping]] = None
        self._cache_image_texts: Optional[list[CacheImageText]] = None
        self.image_resolutions: list[ImageResolution] = []
        self.page_resolutions: dict[int, PageMetadataResolution] = {}

    # -- dyld cache helpers -------------------------------------------------

    def _load_cache_mappings(self) -> list[CacheMapping]:
        if self._cache_mappings is not None:
            return self._cache_mappings
        mappings: list[CacheMapping] = []
        for cache_file in self.cache_files:
            header = read_chunk(cache_file.path, 0, 0x300)
            if len(header) != 0x300:
                continue
            if header[:4] != b"dyld":
                continue
            mapping_offset = _u32(header, 0x10)
            mapping_count = _u32(header, 0x14)
            if not 0 < mapping_count <= 64:
                continue
            raw = read_chunk(cache_file.path, mapping_offset, mapping_count * 32)
            if len(raw) != mapping_count * 32:
                continue
            for index in range(mapping_count):
                base = index * 32
                mappings.append(
                    CacheMapping(
                        path=cache_file.path,
                        va=_u64(raw, base),
                        size=_u64(raw, base + 8),
                        file_offset=_u64(raw, base + 16),
                    )
                )
        mappings.sort(key=lambda mapping: mapping.va)
        self._cache_mappings = mappings
        return mappings

    def _load_cache_image_texts(self) -> list[CacheImageText]:
        if self._cache_image_texts is not None:
            return self._cache_image_texts
        texts: list[CacheImageText] = []
        main_cache = next(
            (image for image in self.cache_files if os.path.basename(image.path) == "dyld_shared_cache_x86_64h"),
            None,
        )
        if main_cache is not None:
            header = read_chunk(main_cache.path, 0, 0x100)
            if len(header) == 0x100:
                images_offset = _u64(header, 0x88)
                images_count = _u64(header, 0x90)
                if 0 < images_count < 100000 and images_offset > 0:
                    raw = read_chunk(main_cache.path, images_offset, images_count * 32)
                    for index in range(images_count if len(raw) == images_count * 32 else 0):
                        base = index * 32
                        load_address = _u64(raw, base + 16)
                        text_size = _u32(raw, base + 24)
                        path_offset = _u32(raw, base + 28)
                        name_bytes = read_chunk(main_cache.path, path_offset, 512)
                        texts.append(
                            CacheImageText(
                                load_address=load_address,
                                text_size=text_size,
                                path=_cstring(name_bytes),
                            )
                        )
        self._cache_image_texts = texts
        return texts

    def _cache_file_offset(self, path: str, offset: int, size: int) -> bytes:
        with open(path, "rb") as handle:
            handle.seek(offset)
            return handle.read(size)

    def _mapping_for(self, address: int) -> Optional[CacheMapping]:
        for mapping in self._load_cache_mappings():
            if mapping.va <= address < mapping.va + mapping.size:
                return mapping
        return None

    # -- verification -------------------------------------------------------

    def verify_image(self, image_index: int) -> ImageResolution:
        image = self._image_model(image_index)
        if image.kind == IMAGE_KIND_STANDALONE:
            fixture_path = os.path.join(self.fixture_root, image.path.lstrip("/"))
            if not os.path.isfile(fixture_path):
                raise ValidationFailure(
                    "E037", f"image[{image_index}] {image.path} not present in fixture ({fixture_path})"
                )
            with open(fixture_path, "rb") as handle:
                def read_at(offset: int, size: int, _handle=handle) -> bytes:
                    _handle.seek(offset)
                    return _handle.read(size)

                segments = parse_macho_header(read_at)
            text = next((segment for segment in segments if segment.name == "__TEXT"), None)
            if text is None:
                raise ValidationFailure("E041", f"image[{image_index}] has no __TEXT segment")
            if text.vmaddr != image.unslid_vmaddr or text.vmsize != image.vm_size:
                raise ValidationFailure(
                    "E041",
                    f"image[{image_index}] __TEXT geometry mismatch: "
                    f"fixture vmaddr=0x{text.vmaddr:X} vmsize=0x{text.vmsize:X}, "
                    f"profile vmaddr=0x{image.unslid_vmaddr:X} vmsize=0x{image.vm_size:X}",
                )
        elif image.kind == IMAGE_KIND_SHARED_CACHE:
            texts = self._load_cache_image_texts()
            match = next(
                (
                    text
                    for text in texts
                    if text.load_address == image.unslid_vmaddr
                    and (text.path == image.path or text.path.endswith(image.path))
                ),
                None,
            )
            if match is None:
                raise ValidationFailure(
                    "E041",
                    f"image[{image_index}] {image.path} (unslid 0x{image.unslid_vmaddr:X}) "
                    "not found in the fixture dyld cache image-text list",
                )
            if match.text_size != image.vm_size:
                raise ValidationFailure(
                    "E041",
                    f"image[{image_index}] __TEXT vmsize mismatch: fixture 0x{match.text_size:X}, "
                    f"profile 0x{image.vm_size:X}",
                )
            mapping = self._mapping_for(image.unslid_vmaddr)
            if mapping is None:
                raise ValidationFailure(
                    "E041", f"image[{image_index}] unslid address is not in any fixture cache mapping"
                )
            header_offset = mapping.file_offset + (image.unslid_vmaddr - mapping.va)

            def read_at(offset: int, size: int, _path=mapping.path, _base=header_offset) -> bytes:
                return self._cache_file_offset(_path, _base + offset, size)

            segments = parse_macho_header(read_at)
            text = next((segment for segment in segments if segment.name == "__TEXT"), None)
            if text is None or text.vmaddr != image.unslid_vmaddr or text.vmsize != image.vm_size:
                raise ValidationFailure(
                    "E041", f"image[{image_index}] fixture Mach-O __TEXT geometry does not match metadata"
                )
        else:  # pragma: no cover - model validation rejects unknown kinds
            raise ValidationFailure("E041", f"image[{image_index}] has unsupported kind {image.kind}")

        self._verify_name_lists(image_index, segments)
        resolution = ImageResolution(
            image_index=image_index,
            kind=image.kind,
            path=image.path,
            unslid_vmaddr=image.unslid_vmaddr,
            vm_size=image.vm_size,
            segment_count=len(image.segments),
            section_count=len(image.sections),
        )
        self.image_resolutions.append(resolution)
        return resolution

    def _image_model(self, image_index: int) -> Image:
        return self._profile.images[image_index]

    def _verify_name_lists(self, image_index: int, segments: Sequence[MachOSegment]) -> None:
        image = self._image_model(image_index)
        parsed_segments = {segment.name for segment in segments}
        parsed_sections = {section.name for segment in segments for section in segment.sections}
        for name in image.segments:
            if name not in parsed_segments:
                raise ValidationFailure(
                    "E041", f"image[{image_index}] profile segment {name!r} is absent from the fixture image"
                )
        for name in image.sections:
            if name not in parsed_sections:
                raise ValidationFailure(
                    "E041", f"image[{image_index}] profile section {name!r} is absent from the fixture image"
                )
        if "__TEXT" not in image.segments:
            raise ValidationFailure("E041", f"image[{image_index}] profile segment list lacks __TEXT")

    def resolve_page(self, profile: Profile, page_index: int) -> PageMetadataResolution:
        page = profile.pages[page_index]
        image = profile.images[page.image_index]
        page_start = image.unslid_vmaddr + page.page_vm_offset

        if image.kind == IMAGE_KIND_STANDALONE:
            fixture_path = os.path.join(self.fixture_root, image.path.lstrip("/"))
            with open(fixture_path, "rb") as handle:
                def read_at(offset: int, size: int, _handle=handle) -> bytes:
                    _handle.seek(offset)
                    return _handle.read(size)

                segments = parse_macho_header(read_at)
                segment = _segment_containing(segments, page_start)
                section = _section_containing(segments, page_start)
                if segment is None or segment.name not in image.segments:
                    raise ValidationFailure(
                        "E040",
                        f"page[{page_index}] pageStart 0x{page_start:X} is not inside a profile segment",
                    )
                section_name = section.name if section is not None else None
                if section_name is not None and section_name not in image.sections:
                    raise ValidationFailure(
                        "E040",
                        f"page[{page_index}] pageStart 0x{page_start:X} lies in section {section_name!r} "
                        "which the profile's image metadata does not list",
                    )
                file_offset = segment.fileoff + (page_start - segment.vmaddr)
                if page.page_file_offset != file_offset:
                    raise ValidationFailure(
                        "E040",
                        f"page[{page_index}] profile pageFileOffset 0x{page.page_file_offset:X} != "
                        f"re-resolved standalone file offset 0x{file_offset:X}",
                    )
                page_bytes = self._cache_file_offset(fixture_path, file_offset, PAGE_SIZE)
                resolved_file, namespace = fixture_path, "standalone-file-offset"
        else:
            mapping = self._mapping_for(page_start)
            if mapping is None:
                raise ValidationFailure(
                    "E040", f"page[{page_index}] pageStart 0x{page_start:X} is not in a fixture cache mapping"
                )
            header_mapping = self._mapping_for(image.unslid_vmaddr)
            if header_mapping is None:
                raise ValidationFailure(
                    "E041",
                    f"image[{page.image_index}] unslid header address 0x{image.unslid_vmaddr:X} "
                    "is not in a fixture cache mapping",
                )
            header_offset = header_mapping.file_offset + (image.unslid_vmaddr - header_mapping.va)

            def read_at(offset: int, size: int, _path=header_mapping.path, _base=header_offset) -> bytes:
                return self._cache_file_offset(_path, _base + offset, size)

            segments = parse_macho_header(read_at)
            segment = _segment_containing(segments, page_start)
            section = _section_containing(segments, page_start)
            if segment is None or segment.name not in image.segments:
                raise ValidationFailure(
                    "E040",
                    f"page[{page_index}] pageStart 0x{page_start:X} is not inside a profile segment",
                )
            section_name = section.name if section is not None else None
            if section_name is not None and section_name not in image.sections:
                raise ValidationFailure(
                    "E040",
                    f"page[{page_index}] pageStart 0x{page_start:X} lies in section {section_name!r} "
                    "which the profile's image metadata does not list",
                )
            file_offset = mapping.file_offset + (page_start - mapping.va)
            if page.page_file_offset != file_offset:
                raise ValidationFailure(
                    "E040",
                    f"page[{page_index}] profile pageFileOffset 0x{page.page_file_offset:X} != "
                    f"re-resolved subcache file offset 0x{file_offset:X}",
                )
            page_bytes = self._cache_file_offset(mapping.path, file_offset, PAGE_SIZE)
            resolved_file, namespace = mapping.path, "subcache-file-offset"

        if len(page_bytes) != PAGE_SIZE:
            raise ValidationFailure(
                "E040", f"page[{page_index}] fixture page read at 0x{page.page_file_offset:X} is truncated"
            )
        if fnv1a64(page_bytes) != page.page_hash:
            raise ValidationFailure(
                "E040",
                f"page[{page_index}] clean fixture page hash 0x{fnv1a64(page_bytes):016X} != "
                f"profile pageHash 0x{page.page_hash:016X}",
            )
        resolution = PageMetadataResolution(
            image_index=page.image_index,
            image_kind=image.kind,
            image_path=image.path,
            image_unslid_vmaddr=image.unslid_vmaddr,
            image_vm_size=image.vm_size,
            page_vm_offset=page.page_vm_offset,
            page_start=page_start,
            segment=segment.name,
            section=section_name,
            file=resolved_file,
            file_offset=file_offset,
            namespace=namespace,
            page=page_bytes,
        )
        self.page_resolutions[page_index] = resolution
        return resolution


# ---------------------------------------------------------------------------
# Offline validation of a profile against a clean fixture
# ---------------------------------------------------------------------------


@dataclass
class ValidationFailure(Exception):
    code: str
    detail: str

    def __str__(self) -> str:  # pragma: no cover - trivial
        return f"{self.code}: {self.detail}"


def _fixture_build(fixture_root: str) -> Optional[str]:
    candidates = [
        os.path.join(fixture_root, "System/Library/CoreServices/SystemVersion.plist"),
        os.path.join(fixture_root, "SystemVersion.plist"),
    ]
    for candidate in candidates:
        if not os.path.isfile(candidate):
            continue
        try:
            with open(candidate, "rb") as handle:
                plist = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException):
            continue
        build = plist.get("ProductBuildVersion")
        if isinstance(build, str) and build:
            return build
    return None


def _candidate_apu_mask_for_device(device_id: int) -> Optional[int]:
    return DEVICE_CANDIDATE_MASK.get(device_id)


def validate_profile_against_fixture(
    profile: Profile,
    images: Sequence[FixtureImage],
    *,
    profile_path: str,
    profile_bytes: bytes,
    fixture_root: str,
    expected_build: Optional[str] = None,
    device_id: Optional[int] = None,
    mutation_sweep: bool = False,
    range_simulation: bool = True,
    hash_only_scan: bool = True,
    native_hash_scan: bool = True,
    duplicate_content_scan: bool = True,
) -> dict:
    """Apply `profile` to the clean fixture exactly like the kext and build a report dict.

    Raises ValidationFailure for deployability failures. Returns the report dict otherwise
    (identity warnings are reported inside, not raised).
    """
    report: dict = {
        "tool": "test/nrpt_validator.py",
        "toolVersion": __version__,
        "profile": {
            "path": profile_path,
            "size": len(profile_bytes),
            "sha256": hashlib.sha256(profile_bytes).hexdigest(),
            "magic": MAGIC.decode("ascii"),
            "version": profile.version,
            "format": f"v{profile.version}",
            "build": profile.header.build,
            "imageCount": len(profile.images),
            "apuMask": f"0x{profile.header.apu_mask:08X}",
            "deviceID": f"0x{profile.header.device_id:04X}",
            "headerFlags": f"0x{profile.header.flags:08X}",
            "pageCount": profile.page_count,
            "siteCount": profile.site_count,
            "payloadChecksum": f"0x{fnv1a32(profile_bytes[HEADER_SIZE:]):08X}",
            "checksumOk": True,
        },
        "fixture": {
            "root": fixture_root,
            "build": None,
            "imageCount": len(images),
            "images": [{"name": image.name, "size": image.size} for image in images],
        },
        "identity": {},
        "pages": [],
        "hashScan": {
            "mode": "not-needed",
            "queries": 0,
            "pagesHashed": 0,
            "candidateBytes": 0,
        },
        "images": [],
        "duplicateContent": [],
        "falsePositiveChecks": [],
        "mutationSweep": [],
        "rangeSimulation": [],
        "warnings": [],
        "summary": {},
        "result": "PASS",
    }

    # --- fixture build identity -------------------------------------------------
    fixture_build = _fixture_build(fixture_root)
    report["fixture"]["build"] = fixture_build
    effective_expected_build = expected_build or fixture_build
    build_check: dict = {"expected": effective_expected_build, "profile": profile.header.build}
    if effective_expected_build is None:
        build_check["status"] = "unknown"
        report["warnings"].append(
            "fixture build could not be determined; build gate not verified offline"
        )
    elif effective_expected_build == profile.header.build:
        build_check["status"] = "pass"
    else:
        build_check["status"] = "fail"
        raise ValidationFailure(
            "E005",
            f"profile build {profile.header.build!r} != fixture build {effective_expected_build!r}",
        )
    report["identity"]["build"] = build_check

    # --- APU / device identity --------------------------------------------------
    apu_check: dict = {
        "apuMask": f"0x{profile.header.apu_mask:08X}",
        "deviceID": f"0x{profile.header.device_id:04X}",
        "requireDeviceID": (profile.header.flags & HEADER_FLAG_REQUIRE_DEVICE_ID) != 0,
        "runningDeviceID": f"0x{device_id:04X}" if device_id is not None else None,
        "candidateMask": None,
        "status": "unknown",
    }
    if device_id is not None:
        candidate_mask = _candidate_apu_mask_for_device(device_id)
        apu_check["candidateMask"] = (
            f"0x{candidate_mask:08X}" if candidate_mask is not None else None
        )
        if candidate_mask is None:
            apu_check["status"] = "fail"
            raise ValidationFailure(
                "E007", f"running device 0x{device_id:04X} has no candidate APU family (fail closed)"
            )
        if (profile.header.apu_mask & candidate_mask) == 0:
            apu_check["status"] = "fail"
            raise ValidationFailure(
                "E006",
                f"apuMask 0x{profile.header.apu_mask:08X} does not intersect candidate mask "
                f"0x{candidate_mask:08X} for device 0x{device_id:04X}",
            )
        if apu_check["requireDeviceID"] and profile.header.device_id != device_id:
            apu_check["status"] = "fail"
            raise ValidationFailure(
                "E007",
                f"profile deviceID 0x{profile.header.device_id:04X} != running device "
                f"0x{device_id:04X} while REQUIRE_DEVICE_ID is set",
            )
        apu_check["status"] = "pass"
    else:
        report["warnings"].append(
            "running device ID not supplied (--device-id); APU/device gate not verified offline"
        )
    report["identity"]["apuAndDevice"] = apu_check

    # --- NRPT v2: re-resolve the target-image metadata against the clean fixture ----
    catalog: Optional[FixtureCatalog] = None
    if profile.version == VERSION_V2:
        catalog = FixtureCatalog(fixture_root, images, profile)
        try:
            for image_index in range(len(profile.images)):
                catalog.verify_image(image_index)
        except ValidationFailure:
            report["result"] = "FAIL"
            raise
        report["images"] = [
            {
                "index": resolution.image_index,
                "kind": "standalone-file" if resolution.kind == IMAGE_KIND_STANDALONE else "dyld-shared-cache",
                "path": resolution.path,
                "unslidVmaddr": f"0x{resolution.unslid_vmaddr:X}",
                "vmSize": f"0x{resolution.vm_size:X}",
                "segments": resolution.segment_count,
                "sections": resolution.section_count,
                "verified": True,
            }
            for resolution in catalog.image_resolutions
        ]

    # --- resolve every intended page against the clean fixture ------------------
    # Hash-only records (REQUIRE_OFFSET cleared) identify pages by content, so one full-fixture
    # scan answers both resolution and the false-positive obligation. The same scan doubles as the
    # content-duplicate analysis (identical 4 KiB pages elsewhere in the fixture): with
    # REQUIRE_OFFSET set such a duplicate is not an identity match (the offset differs), but it is
    # still useful deployability evidence.
    hash_only_indices = [
        index
        for index, page in enumerate(profile.pages)
        if not (page.match_flags & MATCH_REQUIRE_OFFSET)
    ]
    scan_needed = (bool(hash_only_indices) and hash_only_scan) or duplicate_content_scan
    hash_scan_results: dict[int, list[tuple[str, int]]] = {}
    hash_scan_mode = "not-needed"
    if scan_needed:
        if duplicate_content_scan:
            wanted = {page.page_hash for page in profile.pages}
        else:
            wanted = {profile.pages[index].page_hash for index in hash_only_indices}
        hash_scan_results, hash_scan_mode = scan_fixture_page_hashes(
            images, wanted, allow_native=native_hash_scan
        )
        report["hashScan"] = {
            "mode": hash_scan_mode,
            "queries": len(wanted),
            "pagesHashed": sum(image.size // PAGE_SIZE for image in images),
            "candidateBytes": sum(image.size for image in images),
            "duplicateContentScan": bool(duplicate_content_scan),
        }
    else:
        if hash_only_indices and not hash_only_scan:
            report["warnings"].append(
                "hash-only false-positive scan disabled (--no-hash-only-scan): profile not deployable"
            )
        report["hashScan"] = {
            "mode": "not-needed",
            "queries": 0,
            "pagesHashed": 0,
            "candidateBytes": sum(image.size for image in images),
            "duplicateContentScan": False,
        }
    scanned_hashes = set(hash_scan_results.keys())

    images_by_path = {image.path: image for image in images}
    resolved: list[Optional[tuple[FixtureImage, int, bytes]]] = []
    for page_index, page in enumerate(profile.pages):
        page_report: dict = {
            "index": page_index,
            "pageFileOffset": f"0x{page.page_file_offset:08X}",
            "pageHash": f"0x{page.page_hash:016X}",
            "matchFlags": f"0x{page.match_flags:04X}",
            "requiresOffset": (page.match_flags & MATCH_REQUIRE_OFFSET) != 0,
            "siteCount": len(page.sites),
            "resolutionMatches": 0,
            "image": None,
            "resolvedOffset": None,
            "cleanPageHash": None,
            "offsetGate": "n/a",
            "hashMatch": False,
            "matchedRecordIndex": None,
            "siteFindMismatches": 0,
            "applied": False,
            "sites": [],
        }
        if catalog is not None:
            # NRPT v2: metadata re-resolution is mandatory and authoritative for the fixture location.
            metadata = catalog.resolve_page(profile, page_index)
            resolved_path = os.path.realpath(metadata.file)
            image = FixtureImage(
                path=resolved_path, name=os.path.basename(resolved_path), size=os.path.getsize(resolved_path)
            )
            resolved_offset = metadata.file_offset
            clean = metadata.page
            page_report["metadata"] = {
                "imageIndex": metadata.image_index,
                "imageKind": "standalone-file" if metadata.image_kind == IMAGE_KIND_STANDALONE
                else "dyld-shared-cache",
                "imagePath": metadata.image_path,
                "imageUnslidVmaddr": f"0x{metadata.image_unslid_vmaddr:X}",
                "imageVmSize": f"0x{metadata.image_vm_size:X}",
                "pageVmOffset": f"0x{metadata.page_vm_offset:X}",
                "pageStart": f"0x{metadata.page_start:X}",
                "segment": metadata.segment,
                "section": metadata.section,
                "file": os.path.basename(metadata.file),
                "fileOffset": f"0x{metadata.file_offset:X}",
                "namespace": metadata.namespace,
                "verified": True,
            }
            page_report["resolutionMatches"] = 1
            page_report["offsetGate"] = "pass"
            page_report["hashMatch"] = True
            page_report["image"] = image.name
            page_report["resolvedOffset"] = f"0x{resolved_offset:08X}"
            page_report["cleanPageHash"] = f"0x{fnv1a64(clean):016X}"
            page_report["cleanPageSha256"] = hashlib.sha256(clean).hexdigest()
            resolved.append((image, resolved_offset, clean))
            report["pages"].append(page_report)
            continue

        if page.match_flags & MATCH_REQUIRE_OFFSET:
            matches = resolve_page(page, images)
            page_report["resolutionMatches"] = len(matches)
            if not matches:
                page_report["status"] = "unresolved"
                report["pages"].append(page_report)
                report["result"] = "FAIL"
                raise ValidationFailure(
                    "E030",
                    f"page[{page_index}] identity not found in clean fixture "
                    f"(offset=0x{page.page_file_offset:X} hash=0x{page.page_hash:016X})",
                )
            image, resolved_offset, clean = matches[0]
            page_report["offsetGate"] = "pass"
            if len(matches) > 1:
                report["warnings"].append(
                    f"page[{page_index}] identity also present in {len(matches) - 1} other fixture "
                    "image(s) at the same offset (identical content; runtime offset+hash gate cannot "
                    "distinguish them, but the writes are identical)"
                )
        else:
            # Prefer the generator-recorded offset when it resolves in the fixture; otherwise fall
            # back to the full-fixture hash scan. Content identity is authoritative either way.
            offset_matches: list[tuple[FixtureImage, int, bytes]] = []
            for candidate in images:
                if page.page_file_offset + PAGE_SIZE > candidate.size:
                    continue
                chunk = read_chunk(candidate.path, page.page_file_offset)
                if len(chunk) == PAGE_SIZE and fnv1a64(chunk) == page.page_hash:
                    offset_matches.append((candidate, page.page_file_offset, chunk))
            scan_matches = hash_scan_results.get(page.page_hash, [])
            page_report["resolutionMatches"] = max(len(scan_matches), len(offset_matches))
            page_report["offsetGate"] = "not-required"
            if offset_matches:
                image, resolved_offset, clean = offset_matches[0]
            elif len(scan_matches) == 1:
                image_path, offset = scan_matches[0]
                image = images_by_path[image_path]
                clean = read_chunk(image_path, offset)
                resolved_offset = offset
            elif not scan_matches:
                page_report["status"] = "unresolved"
                report["pages"].append(page_report)
                report["result"] = "FAIL"
                raise ValidationFailure(
                    "E030",
                    f"page[{page_index}] hash-only identity not found in clean fixture "
                    f"(hash=0x{page.page_hash:016X})",
                )
            else:
                page_report["status"] = "ambiguous"
                report["pages"].append(page_report)
                report["result"] = "FAIL"
                raise ValidationFailure(
                    "E031",
                    f"page[{page_index}] hash-only identity matches {len(scan_matches)} fixture pages "
                    f"(ambiguous, false-positive risk)",
                )
        page_report["image"] = image.name
        page_report["resolvedOffset"] = f"0x{resolved_offset:08X}"
        page_report["cleanPageHash"] = f"0x{fnv1a64(clean):016X}"
        page_report["cleanPageSha256"] = hashlib.sha256(clean).hexdigest()
        page_report["hashMatch"] = True
        resolved.append((image, resolved_offset, clean))
        report["pages"].append(page_report)

    # --- simulate per-page delivery through the full engine --------------------
    applied: set[int] = set()
    for page_index, (image, resolved_offset, clean) in enumerate(resolved):
        page_report = report["pages"][page_index]
        result = apply_chunk(profile, clean, profile.pages[page_index].page_file_offset, applied)
        if result.status != "applied" or result.page_index != page_index:
            page_report["status"] = result.status
            report["result"] = "FAIL"
            raise ValidationFailure(
                "E030",
                f"page[{page_index}] did not apply through the kext algorithm: "
                f"status={result.status} matchedRecord={result.page_index} "
                f"site={result.site_index}",
            )
        page_report["matchedRecordIndex"] = result.page_index
        page_report["applied"] = True
        page_report["bytesChanged"] = sum(
            1
            for before, after in zip(clean, result.data)
            if before != after
        )
        page_report["patchedPageHash"] = f"0x{fnv1a64(result.data):016X}"
        page_report["patchedPageSha256"] = hashlib.sha256(result.data).hexdigest()
        page_report["status"] = "applied"

        site_reports: list[dict] = []
        write_by_site = {write["siteInPage"]: write for write in result.writes}
        for site_index, site in enumerate(profile.pages[page_index].sites):
            start = site.site_in_page
            end = start + site.replace_size
            site_reports.append(
                {
                    "index": site_index,
                    "siteInPage": f"0x{start:04X}",
                    "findSize": site.find_size,
                    "findHex": site.find.hex(),
                    "replaceHex": site.replace.hex(),
                    "findMatched": True,
                    "written": result.data[start:end] == site.replace,
                    "originalHex": clean[start:end].hex(),
                    "patchedHex": result.data[start:end].hex(),
                    "write": write_by_site.get(start),
                }
            )
        page_report["sites"] = site_reports

        # Applied-once semantics: a second delivery of the clean page must not re-write.
        repeat = apply_chunk(profile, clean, profile.pages[page_index].page_file_offset, applied)
        page_report["secondDelivery"] = repeat.status
        if repeat.status != "alreadyApplied":
            report["result"] = "FAIL"
            raise ValidationFailure(
                "E030",
                f"page[{page_index}] applied-once bit not honoured on repeat delivery "
                f"(status={repeat.status})",
            )

    # --- false-positive checks --------------------------------------------------
    for page_index, page in enumerate(profile.pages):
        image, resolved_offset, _clean = resolved[page_index]
        unintended: list[dict] = []
        if page.match_flags & MATCH_REQUIRE_OFFSET:
            for other in images:
                if other.path == image.path:
                    continue
                if page.page_file_offset + PAGE_SIZE > other.size:
                    continue
                chunk = read_chunk(other.path, page.page_file_offset)
                if len(chunk) == PAGE_SIZE and fnv1a64(chunk) == page.page_hash:
                    unintended.append(
                        {
                            "image": other.name,
                            "offset": f"0x{page.page_file_offset:08X}",
                            "reason": "same offset and same full-page hash",
                        }
                    )
            check_status_skip = False
        elif page.page_hash in scanned_hashes:
            for match_path, match_offset in hash_scan_results.get(page.page_hash, []):
                if match_path == image.path and match_offset == resolved_offset:
                    continue
                unintended.append(
                    {
                        "image": images_by_path[match_path].name,
                        "offset": f"0x{match_offset:08X}",
                        "reason": "hash-only identity matches another fixture page",
                    }
                )
            check_status_skip = False
        else:
            check_status_skip = True
        check: dict = {
            "record": page_index,
            "intendedImage": image.name,
            "intendedOffset": f"0x{resolved_offset:08X}",
            "unintendedMatches": unintended,
        }
        if check_status_skip:
            check["status"] = "skipped"
        elif unintended:
            if page.match_flags & MATCH_REQUIRE_OFFSET:
                check["status"] = "warning"
                report["warnings"].append(
                    f"page[{page_index}] identity matches {len(unintended)} additional fixture "
                    "page(s) (identical content); offset+hash gate cannot distinguish them"
                )
            else:
                check["status"] = "fail"
                report["result"] = "FAIL"
                raise ValidationFailure(
                    "E031",
                    f"page[{page_index}] hash-only identity matches unintended fixture content "
                    f"({len(unintended)} page(s))",
                )
        else:
            check["status"] = "pass"
        report["falsePositiveChecks"].append(check)

    # --- content-duplicate analysis (informational for offset-gated identities) --
    if duplicate_content_scan and hash_scan_mode not in ("not-needed", "disabled"):
        duplicate_records: list[dict] = []
        for page_index, page in enumerate(profile.pages):
            image, resolved_offset, _clean = resolved[page_index]
            occurrences = [
                {
                    "image": images_by_path[match_path].name,
                    "offset": f"0x{match_offset:08X}",
                }
                for match_path, match_offset in hash_scan_results.get(page.page_hash, [])
            ]
            unintended_identical = [
                occurrence
                for occurrence in occurrences
                if not (
                    occurrence["image"] == image.name
                    and occurrence["offset"] == f"0x{resolved_offset:08X}"
                )
            ]
            if not unintended_identical:
                continue
            requires_offset = (page.match_flags & MATCH_REQUIRE_OFFSET) != 0
            duplicate_records.append(
                {
                    "record": page_index,
                    "pageHash": f"0x{page.page_hash:016X}",
                    "requiresOffset": requires_offset,
                    "intendedImage": image.name,
                    "intendedOffset": f"0x{resolved_offset:08X}",
                    "occurrences": occurrences,
                    "unintendedIdenticalContent": unintended_identical,
                    "identityAmbiguous": not requires_offset,
                }
            )
            if requires_offset:
                report["warnings"].append(
                    f"page[{page_index}] has byte-identical content at "
                    f"{len(unintended_identical)} other fixture offset(s); identity is offset-gated "
                    "so this is not a false positive, but the duplicate is recorded in the report"
                )
        report["duplicateContent"] = duplicate_records

    # --- mutation sweep (false-positive rejection) ------------------------------
    if mutation_sweep:
        for page_index, (_image, _offset, clean) in enumerate(resolved):
            mutated = bytearray(clean)
            mutated[(page_index * 97 + 13) % PAGE_SIZE] ^= 0xFF
            mutated_applied: set[int] = set(applied)
            # The applied bit of this record is set; a mutated page must not even be considered
            # as a write candidate, so use a fresh applied set (clean boot simulation).
            mutated_applied = set()
            result = apply_chunk(profile, bytes(mutated), profile.pages[page_index].page_file_offset,
                                 mutated_applied)
            sweep: dict = {
                "record": page_index,
                "mutatedByte": (page_index * 97 + 13) % PAGE_SIZE,
                "status": result.status,
                "wrote": result.status == "applied",
            }
            if result.status == "applied":
                report["result"] = "FAIL"
                raise ValidationFailure(
                    "E031",
                    f"page[{page_index}] mutated content was still applied (hash gate failed)",
                )
            report["mutationSweep"].append(sweep)

    # --- range simulation -------------------------------------------------------
    if range_simulation:
        by_image: dict[str, list[tuple[int, int]]] = {}
        for page_index, (image, offset, _clean) in enumerate(resolved):
            by_image.setdefault(image.path, []).append((offset, page_index))
        for image in images:
            entries = sorted(by_image.get(image.path, []))
            if len(entries) < 2:
                continue
            base = entries[0][0]
            last = entries[-1][0]
            size = last + PAGE_SIZE - base
            if size > 4 * 1024 * 1024:
                report["rangeSimulation"].append(
                    {
                        "image": image.name,
                        "status": "skipped",
                        "reason": "range span larger than 4 MiB",
                        "records": [index for _offset, index in entries],
                    }
                )
                continue
            range_data = read_chunk(image.path, base, size)
            if len(range_data) != size:
                continue
            range_applied: set[int] = set()
            results = apply_range(profile, range_data, base, range_applied)
            expected = {index for _offset, index in entries}
            applied_indices = {
                result.page_index for result in results if result.status == "applied"
            }
            simulation: dict = {
                "image": image.name,
                "rangeBase": f"0x{base:08X}",
                "chunks": len(results),
                "expectedRecords": sorted(expected),
                "appliedRecords": sorted(applied_indices),
                "status": "pass" if applied_indices == expected else "fail",
            }
            if applied_indices != expected:
                report["result"] = "FAIL"
                raise ValidationFailure(
                    "E030",
                    f"range simulation for {image.name} applied records "
                    f"{sorted(applied_indices)} expected {sorted(expected)}",
                )
            report["rangeSimulation"].append(simulation)

    # --- summary ----------------------------------------------------------------
    total_sites = sum(len(page["sites"]) for page in report["pages"])
    report["summary"] = {
        "intendedPages": profile.page_count,
        "resolvedPages": len(resolved),
        "appliedPages": sum(1 for page in report["pages"] if page["applied"]),
        "intendedSites": profile.site_count,
        "reportedSites": total_sites,
        "siteFindMismatches": 0,
        "falsePositives": sum(
            1
            for check in report["falsePositiveChecks"]
            if check["status"] == "fail" and check["unintendedMatches"]
        ),
        "identityWarnings": sum(
            1
            for check in report["falsePositiveChecks"]
            if check["status"] == "warning" and check["unintendedMatches"]
        ),
        "identityChecks": {
            key: value["status"] for key, value in report["identity"].items()
        },
        "hashScanMode": report["hashScan"]["mode"],
        "contentDuplicates": len(report["duplicateContent"]),
        "warnings": len(report["warnings"]),
    }
    report["summary"]["result"] = "PASS" if report["result"] == "PASS" else "FAIL"
    return report


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _print_human_report(report: dict) -> None:
    profile = report["profile"]
    print(
        f"NRPT profile: {profile['path']} ({profile['size']} bytes, "
        f"sha256 {profile['sha256']})"
    )
    print(
        f"  format={profile['format']} build={profile['build']} apuMask={profile['apuMask']} "
        f"deviceID={profile['deviceID']} pages={profile['pageCount']} sites={profile['siteCount']} "
        f"checksum={profile['payloadChecksum']} (OK)"
    )
    for image in report.get("images", []):
        print(
            f"  image {image['index']}: {image['kind']} {image['path']} "
            f"unslid={image['unslidVmaddr']} vmSize={image['vmSize']} "
            f"segments={image['segments']} sections={image['sections']} verified={image['verified']}"
        )
    fixture = report["fixture"]
    print(
        f"fixture: {fixture['root']} build={fixture['build']} "
        f"candidateImages={fixture['imageCount']}"
    )
    for name, check in report["identity"].items():
        print(f"identity {name}: {check['status']}")
    print("pages:")
    print("  idx  pageFileOffset    pageHash            image                          sites  bytes  status")
    for page in report["pages"]:
        print(
            f"  {page['index']:>3}  {page['pageFileOffset']:>16}  {page['pageHash']:>18}  "
            f"{(page['image'] or '-'):30.30}  {page['siteCount']:>5}  "
            f"{page.get('bytesChanged', '-'):>5}  {page['status']}"
        )
        metadata = page.get("metadata")
        if metadata:
            print(
                f"        metadata: image[{metadata['imageIndex']}] {metadata['imageKind']} "
                f"pageStart={metadata['pageStart']} segment={metadata['segment']} "
                f"section={metadata['section']} file={metadata['file']}@"
                f"{metadata['fileOffset']} ({metadata['namespace']}) verified={metadata['verified']}"
            )
        for site in page["sites"]:
            print(
                f"        site {site['index']}: @{site['siteInPage']} "
                f"{site['findHex']} -> {site['replaceHex']} "
                f"find={site['findMatched']} written={site['written']}"
            )
    for check in report["falsePositiveChecks"]:
        if check["unintendedMatches"]:
            print(
                f"false-positive check record {check['record']}: "
                f"{len(check['unintendedMatches'])} unintended match(es) [{check['status']}]"
            )
    for duplicate in report["duplicateContent"]:
        print(
            f"content duplicate record {duplicate['record']}: {duplicate['pageHash']} at "
            f"{len(duplicate['occurrences'])} offset(s), "
            f"unintended identical content={len(duplicate['unintendedIdenticalContent'])}, "
            f"offset-gated={duplicate['requiresOffset']}"
        )
    hash_scan = report.get("hashScan", {})
    if hash_scan.get("mode") not in (None, "not-needed"):
        print(
            f"hash scan: mode={hash_scan['mode']} queries={hash_scan['queries']} "
            f"pagesHashed={hash_scan['pagesHashed']}"
        )
    if report["mutationSweep"]:
        print(f"mutation sweep: {len(report['mutationSweep'])} page(s) rejected as expected")
    for simulation in report["rangeSimulation"]:
        print(
            f"range simulation {simulation['image']}: {simulation['status']} "
            f"({simulation.get('chunks', '?')} chunks)"
        )
    summary = report["summary"]
    print(
        f"summary: intended={summary['intendedPages']} resolved={summary['resolvedPages']} "
        f"applied={summary['appliedPages']} sites={summary['reportedSites']}/"
        f"{summary['intendedSites']} findMismatches={summary['siteFindMismatches']} "
        f"falsePositives={summary['falsePositives']} warnings={summary['warnings']}"
    )
    for warning in report["warnings"]:
        print(f"warning: {warning}")
    print(f"RESULT: {report['result']}")


def _parse_int(value: str) -> int:
    return int(value, 0)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="NRPT v1 offline validator: apply a profile to a clean fixture exactly "
        "like NootedRedUserPatch (offset gate + full 4 KiB FNV-1a-64 + all site finds + replace).",
    )
    parser.add_argument("--profile", required=True, help="NRPT v1 profile file")
    parser.add_argument(
        "--fixtures",
        default="/",
        help="fixture root containing System/Library/Extensions and dyld cache (default: /)",
    )
    parser.add_argument("--image", action="append", default=[], help="extra candidate image path")
    parser.add_argument("--report", help="write machine-readable JSON report to this path")
    parser.add_argument("--expected-build", help="expected build string (e.g. 24H232)")
    parser.add_argument(
        "--device-id", type=_parse_int, help="running iGPU PCI device ID (e.g. 0x1638)"
    )
    parser.add_argument(
        "--mutation-sweep",
        action="store_true",
        help="flip one byte per intended page and require hash-gate rejection",
    )
    parser.add_argument(
        "--no-range-simulation", action="store_true", help="skip _cs_validate_range simulation"
    )
    parser.add_argument(
        "--no-hash-only-scan",
        action="store_true",
        help="skip full-fixture scan for records without REQUIRE_OFFSET (not deployable)",
    )
    parser.add_argument(
        "--no-native-hash-scan",
        action="store_true",
        help="force the pure-Python page hash scan (very slow on a multi-GB fixture)",
    )
    parser.add_argument(
        "--no-duplicate-content-scan",
        action="store_true",
        help="skip the content-duplicate analysis (identical 4 KiB pages elsewhere in the fixture)",
    )
    parser.add_argument("--quiet", action="store_true", help="suppress human-readable output")
    args = parser.parse_args(argv)

    try:
        with open(args.profile, "rb") as handle:
            profile_bytes = handle.read()
    except OSError as error:
        print(f"error: cannot read profile: {error}", file=sys.stderr)
        return 2

    try:
        profile = decode(profile_bytes)
    except NRPTCodecError as error:
        print(f"NRPT PROFILE REJECTED: {error}", file=sys.stderr)
        return 1

    if not os.path.isdir(args.fixtures):
        print(f"error: fixture root is not a directory: {args.fixtures}", file=sys.stderr)
        return 2
    images = discover_images(args.fixtures, args.image)
    if not images:
        print(f"error: no candidate fixture images found under {args.fixtures}", file=sys.stderr)
        return 2

    try:
        report = validate_profile_against_fixture(
            profile,
            images,
            profile_path=args.profile,
            profile_bytes=profile_bytes,
            fixture_root=args.fixtures,
            expected_build=args.expected_build,
            device_id=args.device_id,
            mutation_sweep=args.mutation_sweep,
            range_simulation=not args.no_range_simulation,
            hash_only_scan=not args.no_hash_only_scan,
            native_hash_scan=not args.no_native_hash_scan,
            duplicate_content_scan=not args.no_duplicate_content_scan,
        )
    except ValidationFailure as failure:
        print(f"VALIDATION FAILED: {failure}", file=sys.stderr)
        return 1

    if not args.quiet:
        _print_human_report(report)
    if args.report:
        directory = os.path.dirname(os.path.abspath(args.report))
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(args.report, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
            handle.write("\n")
        if not args.quiet:
            print(f"report: {args.report}")
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
