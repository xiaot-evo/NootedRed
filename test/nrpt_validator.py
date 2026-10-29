#!/usr/bin/env python3
# NootedRed NRPT v3 offline validator
#
# Independent, host-side simulation of the NootedRedUserPatch hook-only page/range engine.
# Normative contract: docs/PatchProfile-Spec.md (NRPT v3, frozen 2026-10-29).
#
# What it does:
#   1. Strictly decodes one NRPT v3 profile (all E001..E041 rules) and/or an `NRedProfiles`
#      bundle (E050..E053), and selects exactly one profile for the target identity.
#   2. Applies the profile to a CLEAN fixture (extracted macOS tree) with the exact hook
#      semantics: mode routing (PAGE via _cs_validate_page, DYLD via _cs_validate_range),
#      optional vnode-name gate, full-page FNV-1a-64 + all site finds identity (no offset
#      identity), atomic writes, applied-once, and the already-patched pass.
#   3. Re-resolves each record's target image/page evidence against the fixture (image kind,
#      path, __TEXT geometry, subcache mapping, pageVmOffset/pageFileOffset consistency) and
#      verifies the clean page content.
#   4. Reports per-page/per-site results, false-positive/duplicate-content findings, route
#      simulations, mutation rejection and bundle selection.
#
# Usage:
#   python3 test/nrpt_validator.py --profile <profile.nrpt> --fixtures version-fixtures/15.8.2 \
#       --expected-build 24H232 --device-id 0x1638 --report build/report.json --mutation-sweep
#   python3 test/nrpt_validator.py --bundle-plist <NRedProfiles.plist> --fixtures ... \
#       --expected-build 24H232 --device-id 0x1638 --report build/report.json
#
# Exit: 0 = PASS (deployable), 1 = FAIL, 2 = usage/IO error.
#
# No Apple binaries are embedded or checked in; the fixture images are read in place.

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from typing import Callable, Optional, Sequence

__version__ = "3.0"

# ---------------------------------------------------------------------------
# NRPT v3 constants (docs/PatchProfile-Spec.md sections 1-8)
# ---------------------------------------------------------------------------

MAGIC = b"NRPT"
VERSION = 3
HEADER_SIZE = 64
PAGE_RECORD_SIZE = 32
SITE_RECORD_SIZE = 40
IMAGE_ENTRY_HEADER_SIZE = 16
PAGE_SIZE = 4096

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
H_RESERVED0 = 48
H_IMAGE_COUNT = 52
H_IMAGE_TABLE_SIZE = 54
H_RESERVED1 = 58
H_RESERVED1_SIZE = 6

P_PAGE_FILE_OFFSET = 0
P_PAGE_HASH = 8
P_FIRST_SITE = 16
P_SITE_COUNT = 20
P_MODE = 22
P_FLAGS = 23
P_IMAGE_INDEX = 24
P_RESERVED = 26
P_PAGE_VM_OFFSET = 28

MAX_PROFILE_SIZE = 64 * 1024
MAX_PAGES = 256
MAX_SITES = 1024
MAX_SITES_PER_PAGE = 64
MAX_SITE_PATCH_SIZE = 16
MAX_IMAGES = 16
MAX_IMAGE_PATH_LENGTH = 200
MAX_IMAGE_VM_SIZE = 0xFFFFF000
MAX_IMAGE_TABLE_SIZE = 16 * (16 + 204)  # 3520
MAX_BUNDLE_ENTRIES = 16
KNOWN_APU_MASK = 0x3F
BUILD_FIELD_SIZE = 16
MAX_BUILD_BYTES = 15
BUILD_ALPHABET = frozenset(
    b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-"
)

MODE_PAGE = 1
MODE_DYLD = 2
MODE_RESOLVER = 3
MODE_NAMES = {MODE_PAGE: "PAGE", MODE_DYLD: "DYLD", MODE_RESOLVER: "RESOLVER"}

IMAGE_KIND_STANDALONE = 0
IMAGE_KIND_SHARED_CACHE = 1
IMAGE_KIND_NAMES = {IMAGE_KIND_STANDALONE: "standalone-file", IMAGE_KIND_SHARED_CACHE: "dyld-shared-cache"}

BUNDLE_ROOT_KEY = "NRedProfiles"
BUNDLE_ENTRY_KEYS = ("Build", "APUMask", "DeviceID", "Profile")

ERROR_NAMES = {
    "E001": "truncated",
    "E002": "badMagic",
    "E003": "unsupportedVersion",
    "E004": "invalidHeaderSize",
    "E005": "invalidBuild",
    "E006": "invalidApuMask",
    "E007": "invalidDeviceID",
    "E008": "reservedHeaderFieldNotZero",
    "E009": "reservedHeaderBytesNotZero",
    "E010": "profileTooLarge",
    "E011": "pageTableSizeMismatch",
    "E012": "siteTableSizeMismatch",
    "E013": "totalSizeMismatch",
    "E014": "payloadChecksumMismatch",
    "E015": "pageCountOutOfRange",
    "E016": "siteCountOutOfRange",
    "E017": "pageFileOffsetMisaligned",
    "E018": "unsupportedPageMode",
    "E019": "pageModeImageKindMismatch",
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
    "E033": "invalidPageSize",
    "E034": "invalidImageCount",
    "E035": "invalidImageEntry",
    "E036": "imageTableSizeMismatch",
    "E037": "invalidImagePath",
    "E038": "invalidPageMetadata",
    "E039": "duplicateImagePath",
    "E040": "invalidPageVmOffset",
    "E041": "invalidImageGeometry",
    "E050": "bundleCountOutOfRange",
    "E051": "duplicateBundleBuild",
    "E052": "bundleEntryProfileMismatch",
    "E053": "invalidBundleEntry",
}

# PCI device ID -> candidate APU family mask (spec section 3.2).
DEVICE_CANDIDATE_MASK = {
    0x15DD: 1 << 0,
    0x15D8: (1 << 1) | (1 << 2),
    0x1636: (1 << 3) | (1 << 4),
    0x164C: (1 << 3) | (1 << 4),
    0x15E7: (1 << 3) | (1 << 5),
    0x1638: (1 << 3) | (1 << 5),
}


class NRPTCodecError(Exception):
    """Stable NRPT v3 validation error."""

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
# Integer / hash helpers
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


def round_up4(value: int) -> int:
    return (value + 3) & ~3


def fnv1a32(data: bytes) -> int:
    value = 0x811C9DC5
    for byte in data:
        value = ((value ^ byte) * 0x01000193) & 0xFFFFFFFF
    return value


def fnv1a64(data: bytes) -> int:
    value = 0xCBF29CE484222325
    for byte in data:
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return value


def page_hash(page: bytes) -> int:
    if len(page) != PAGE_SIZE:
        raise NRPTCodecError("E033", f"pageHash input must be exactly {PAGE_SIZE} bytes")
    return fnv1a64(page)


# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------


@dataclass
class Site:
    site_in_page: int
    find: bytes
    replace: bytes
    flags: int = 0

    @property
    def size(self) -> int:
        return len(self.find)


@dataclass
class Image:
    kind: int
    path: str
    unslid_vmaddr: int
    vm_size: int

    @property
    def path_bytes(self) -> bytes:
        return self.path.encode("utf-8")

    @property
    def entry_size(self) -> int:
        return IMAGE_ENTRY_HEADER_SIZE + round_up4(len(self.path_bytes) + 1)

    @property
    def basename(self) -> str:
        return self.path.rsplit("/", 1)[-1]


@dataclass
class Page:
    page_file_offset: int
    page_hash: int
    mode: int
    image_index: int
    page_vm_offset: int
    sites: list[Site] = field(default_factory=list)


@dataclass
class Header:
    build: str
    apu_mask: int
    device_id: int


@dataclass
class Profile:
    header: Header
    images: list[Image] = field(default_factory=list)
    pages: list[Page] = field(default_factory=list)

    @property
    def page_count(self) -> int:
        return len(self.pages)

    @property
    def site_count(self) -> int:
        return sum(len(page.sites) for page in self.pages)

    @property
    def image_table_size(self) -> int:
        return sum(image.entry_size for image in self.images)

    @property
    def encoded_size(self) -> int:
        return (
            HEADER_SIZE
            + self.page_count * PAGE_RECORD_SIZE
            + self.site_count * SITE_RECORD_SIZE
            + self.image_table_size
        )


# ---------------------------------------------------------------------------
# Build field helpers (spec section 3.1)
# ---------------------------------------------------------------------------


def encode_build_field(build: str) -> bytes:
    raw = build.encode("utf-8")
    if not 1 <= len(raw) <= MAX_BUILD_BYTES:
        raise NRPTCodecError("E005", f"build must be 1..{MAX_BUILD_BYTES} bytes")
    if any(byte not in BUILD_ALPHABET for byte in raw):
        raise NRPTCodecError("E005", f"build contains a forbidden character: {build!r}")
    return raw + b"\x00" * (BUILD_FIELD_SIZE - len(raw))


def decode_build_field(field: bytes) -> str:
    if len(field) != BUILD_FIELD_SIZE:
        raise NRPTCodecError("E005", "build field must be 16 bytes")
    nul = field.find(b"\x00")
    if nul < 0:
        raise NRPTCodecError("E005", "build field has no NUL terminator")
    if nul < 1 or nul > MAX_BUILD_BYTES:
        raise NRPTCodecError("E005", f"build string must be 1..{MAX_BUILD_BYTES} bytes")
    if any(byte != 0 for byte in field[nul:]):
        raise NRPTCodecError("E005", "build field has non-zero bytes after the NUL")
    raw = field[:nul]
    if any(byte not in BUILD_ALPHABET for byte in raw):
        raise NRPTCodecError("E005", f"build contains a forbidden character: {raw!r}")
    return raw.decode("ascii")


# ---------------------------------------------------------------------------
# Profile model validation (spec sections 3-7)
# ---------------------------------------------------------------------------


def _is_printable(byte: int) -> bool:
    return 0x20 <= byte <= 0x7E


def validate_image_path(path: str, context: str = "image") -> None:
    raw = path.encode("utf-8")
    if not 1 <= len(raw) <= MAX_IMAGE_PATH_LENGTH:
        raise NRPTCodecError("E037", f"{context}: path length {len(raw)}")
    if not raw.startswith(b"/"):
        raise NRPTCodecError("E037", f"{context}: path is not absolute")
    if not all(_is_printable(byte) for byte in raw):
        raise NRPTCodecError("E037", f"{context}: non-printable path byte")


def validate_header_model(header: Header) -> None:
    encode_build_field(header.build)
    if header.apu_mask == 0 or (header.apu_mask & ~KNOWN_APU_MASK) != 0:
        raise NRPTCodecError("E006", f"apuMask=0x{header.apu_mask:08X}")
    if header.device_id > 0xFFFF:
        raise NRPTCodecError("E007", f"deviceID=0x{header.device_id:08X}")


def validate_images_model(profile: Profile) -> None:
    if not 1 <= len(profile.images) <= MAX_IMAGES:
        raise NRPTCodecError("E034", f"imageCount={len(profile.images)}")
    if profile.image_table_size > MAX_IMAGE_TABLE_SIZE:
        raise NRPTCodecError("E034", f"imageTableSize={profile.image_table_size}")
    for image_index, image in enumerate(profile.images):
        context = f"image[{image_index}]"
        if image.kind not in (IMAGE_KIND_STANDALONE, IMAGE_KIND_SHARED_CACHE):
            raise NRPTCodecError("E041", f"{context}: kind={image.kind}")
        validate_image_path(image.path, context)
        if not 0 < image.vm_size <= MAX_IMAGE_VM_SIZE:
            raise NRPTCodecError("E041", f"{context}: imageVmSize={image.vm_size}")
        if image.kind == IMAGE_KIND_SHARED_CACHE and image.unslid_vmaddr == 0:
            raise NRPTCodecError("E041", f"{context}: shared-cache image has unslidVmaddr 0")
        for other_index in range(image_index):
            other = profile.images[other_index]
            if other.kind == image.kind and other.path == image.path:
                raise NRPTCodecError("E039", f"{context} duplicates image[{other_index}]")


def validate_model(profile: Profile) -> None:
    """All model-level rules; raises the first violation with its stable v3 code."""
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
    validate_images_model(profile)
    if profile.encoded_size > MAX_PROFILE_SIZE:
        raise NRPTCodecError("E010", f"encoded size {profile.encoded_size}")

    global_site_index = 0
    for page_index, page in enumerate(profile.pages):
        if (page.page_file_offset & 0x0FFF) != 0:
            raise NRPTCodecError("E017", f"page[{page_index}] pageFileOffset not 4 KiB aligned")
        if page.mode not in (MODE_PAGE, MODE_DYLD):
            raise NRPTCodecError("E018", f"page[{page_index}] mode={page.mode}")
        if not 0 <= page.image_index < len(profile.images):
            raise NRPTCodecError(
                "E038", f"page[{page_index}] imageIndex={page.image_index} imageCount={len(profile.images)}"
            )
        image = profile.images[page.image_index]
        if page.mode == MODE_PAGE and image.kind != IMAGE_KIND_STANDALONE:
            raise NRPTCodecError("E019", f"page[{page_index}] PAGE mode with cache image kind")
        if page.mode == MODE_DYLD and image.kind != IMAGE_KIND_SHARED_CACHE:
            raise NRPTCodecError("E019", f"page[{page_index}] DYLD mode with standalone image kind")
        if not 1 <= len(page.sites) <= MAX_SITES_PER_PAGE:
            raise NRPTCodecError(
                "E023", f"page[{page_index}] siteCount={len(page.sites)} (allowed 1..{MAX_SITES_PER_PAGE})"
            )
        if (page.page_vm_offset & 0x0FFF) != 0 or page.page_vm_offset + PAGE_SIZE > image.vm_size:
            raise NRPTCodecError(
                "E040",
                f"page[{page_index}] pageVmOffset=0x{page.page_vm_offset:X} imageVmSize=0x{image.vm_size:X}",
            )

        writes: list[tuple[int, int, int]] = []
        for local_index, site in enumerate(page.sites):
            site_index = global_site_index + local_index
            find_size = len(site.find)
            replace_size = len(site.replace)
            if not 1 <= find_size <= MAX_SITE_PATCH_SIZE or not 1 <= replace_size <= MAX_SITE_PATCH_SIZE:
                raise NRPTCodecError(
                    "E024", f"site[{site_index}] findSize={find_size} replaceSize={replace_size}"
                )
            if find_size != replace_size:
                raise NRPTCodecError(
                    "E025", f"site[{site_index}] findSize={find_size} replaceSize={replace_size}"
                )
            if site.site_in_page + find_size > PAGE_SIZE:
                raise NRPTCodecError(
                    "E026", f"site[{site_index}] siteInPage=0x{site.site_in_page:X} size={find_size}"
                )
            if site.find == site.replace:
                raise NRPTCodecError("E028", f"site[{site_index}] find equals replace")
            if site.flags != 0:
                raise NRPTCodecError("E029", f"site[{site_index}] flags=0x{site.flags:08X}")
            writes.append((site.site_in_page, site.site_in_page + replace_size, site_index))

        ordered = sorted(writes)
        for previous, current in zip(ordered, ordered[1:]):
            if current[0] < previous[1]:
                raise NRPTCodecError("E030", f"page[{page_index}] overlapping site writes")
        global_site_index += len(page.sites)

    # Duplicate page identity: same pageHash in the same mode is invalid (spec 6.3).
    for page_index in range(len(profile.pages)):
        page = profile.pages[page_index]
        for other_index in range(page_index):
            other = profile.pages[other_index]
            if page.mode == other.mode and page.page_hash == other.page_hash:
                raise NRPTCodecError(
                    "E031",
                    f"page[{page_index}] duplicates page[{other_index}] identity in mode {MODE_NAMES[page.mode]}",
                )


# ---------------------------------------------------------------------------
# Canonical encoder
# ---------------------------------------------------------------------------


def encode(profile: Profile) -> bytes:
    """Canonical NRPT v3 encoder; derives counts, table sizes and the payload checksum."""
    validate_model(profile)

    page_table = bytearray()
    site_table = bytearray()
    first_site = 0
    for page in profile.pages:
        page_table += _p64(page.page_file_offset)
        page_table += _p64(page.page_hash)
        page_table += _p32(first_site)
        page_table += _p16(len(page.sites))
        page_table += bytes((page.mode, 0))
        page_table += _p16(page.image_index)
        page_table += _p16(0)
        page_table += _p32(page.page_vm_offset)
        first_site += len(page.sites)

        for site in page.sites:
            find_size = len(site.find)
            replace_size = len(site.replace)
            site_table += _p16(site.site_in_page)
            site_table += bytes((find_size, replace_size))
            site_table += site.find + b"\x00" * (MAX_SITE_PATCH_SIZE - find_size)
            site_table += site.replace + b"\x00" * (MAX_SITE_PATCH_SIZE - replace_size)
            site_table += _p32(site.flags)

    image_table = bytearray()
    for image in profile.images:
        path = image.path_bytes
        image_table += bytes((image.kind, 0))
        image_table += _p16(len(path))
        image_table += _p64(image.unslid_vmaddr)
        image_table += _p32(image.vm_size)
        image_table += path + b"\x00" * (round_up4(len(path) + 1) - len(path))

    payload = bytes(page_table) + bytes(site_table) + bytes(image_table)
    output = bytearray()
    output += MAGIC
    output += _p16(VERSION)
    output += _p16(HEADER_SIZE)
    output += encode_build_field(profile.header.build)
    output += _p32(profile.header.apu_mask)
    output += _p32(profile.header.device_id)
    output += _p16(len(profile.pages))
    output += _p16(first_site)
    output += _p32(len(page_table))
    output += _p32(len(site_table))
    output += _p32(fnv1a32(payload))
    output += _p32(0)  # reserved0
    output += _p16(len(profile.images))
    output += _p32(len(image_table))
    output += b"\x00" * H_RESERVED1_SIZE
    output += payload
    if len(output) != profile.encoded_size:
        raise NRPTCodecError("E013", "encoder produced an inconsistent size")
    return bytes(output)


# ---------------------------------------------------------------------------
# Strict decoder
# ---------------------------------------------------------------------------


def _parse_image_table(data: bytes, base: int, image_count: int, image_table_size: int) -> list[Image]:
    cursor = base
    end = base + image_table_size
    if end > len(data):
        raise NRPTCodecError("E035", "image table extends past the profile")
    images: list[Image] = []
    for image_index in range(image_count):
        if end - cursor < IMAGE_ENTRY_HEADER_SIZE:
            raise NRPTCodecError("E035", f"image[{image_index}]: truncated entry header")
        kind = data[cursor]
        reserved = data[cursor + 1]
        path_length = _u16(data, cursor + 2)
        unslid_vmaddr = _u64(data, cursor + 4)
        vm_size = _u32(data, cursor + 12)
        if (
            reserved != 0
            or kind not in (IMAGE_KIND_STANDALONE, IMAGE_KIND_SHARED_CACHE)
            or not 1 <= path_length <= MAX_IMAGE_PATH_LENGTH
        ):
            raise NRPTCodecError("E035", f"image[{image_index}]: invalid entry header")
        entry_size = IMAGE_ENTRY_HEADER_SIZE + round_up4(path_length + 1)
        if end - cursor < entry_size:
            raise NRPTCodecError("E035", f"image[{image_index}]: entry exceeds image table")
        path_base = cursor + IMAGE_ENTRY_HEADER_SIZE
        if data[path_base + path_length] != 0 or data[path_base] != ord("/"):
            raise NRPTCodecError("E037", f"image[{image_index}]: path is not NUL-terminated absolute")
        for index in range(path_length):
            if not _is_printable(data[path_base + index]):
                raise NRPTCodecError("E037", f"image[{image_index}]: non-printable path byte")
        for index in range(path_length + 1, round_up4(path_length + 1)):
            if data[path_base + index] != 0:
                raise NRPTCodecError("E035", f"image[{image_index}]: path padding not zero")
        path = data[path_base : path_base + path_length].decode("ascii")
        if not 0 < vm_size <= MAX_IMAGE_VM_SIZE or (
            kind == IMAGE_KIND_SHARED_CACHE and unslid_vmaddr == 0
        ):
            raise NRPTCodecError("E041", f"image[{image_index}]: invalid image geometry")
        for other in images:
            if other.kind == kind and other.path == path:
                raise NRPTCodecError("E039", f"image[{image_index}]: duplicate image path")
        images.append(Image(kind=kind, path=path, unslid_vmaddr=unslid_vmaddr, vm_size=vm_size))
        cursor += entry_size
    if cursor != end:
        raise NRPTCodecError("E036", f"imageTableSize {image_table_size} != derived {cursor - base}")
    return images


def decode(data: bytes) -> Profile:
    """Strict, all-or-nothing NRPT v3 decoder (v1/v2 are rejected with E003)."""
    if len(data) < HEADER_SIZE:
        raise NRPTCodecError("E001", f"{len(data)} bytes < {HEADER_SIZE}")
    if data[H_MAGIC : H_MAGIC + 4] != MAGIC:
        raise NRPTCodecError("E002", f"magic={data[H_MAGIC:H_MAGIC + 4]!r}")
    version = _u16(data, H_VERSION)
    if version != VERSION:
        raise NRPTCodecError("E003", f"version={version}")
    header_size = _u16(data, H_HEADER_SIZE)
    if header_size != HEADER_SIZE:
        raise NRPTCodecError("E004", f"headerSize={header_size}")

    build = decode_build_field(data[H_BUILD : H_BUILD + BUILD_FIELD_SIZE])
    apu_mask = _u32(data, H_APU_MASK)
    if apu_mask == 0 or (apu_mask & ~KNOWN_APU_MASK) != 0:
        raise NRPTCodecError("E006", f"apuMask=0x{apu_mask:08X}")
    device_id = _u32(data, H_DEVICE_ID)
    if device_id > 0xFFFF:
        raise NRPTCodecError("E007", f"deviceID=0x{device_id:08X}")
    if any(byte != 0 for byte in data[H_RESERVED0 : H_RESERVED0 + 4]):
        raise NRPTCodecError("E008", "header bytes 48-51 are not zero")
    if any(byte != 0 for byte in data[H_RESERVED1 : H_RESERVED1 + H_RESERVED1_SIZE]):
        raise NRPTCodecError("E009", "header bytes 58-63 are not zero")

    if len(data) > MAX_PROFILE_SIZE:
        raise NRPTCodecError("E010", f"actual size {len(data)} > {MAX_PROFILE_SIZE}")

    page_count = _u16(data, H_PAGE_COUNT)
    site_count = _u16(data, H_SITE_COUNT)
    if page_count == 0:
        raise NRPTCodecError("E032", f"pageCount={page_count}")
    if page_count > MAX_PAGES:
        raise NRPTCodecError("E015", f"pageCount={page_count}")
    if site_count < 1 or site_count > MAX_SITES:
        raise NRPTCodecError("E016", f"siteCount={site_count}")
    image_count = _u16(data, H_IMAGE_COUNT)
    image_table_size = _u32(data, H_IMAGE_TABLE_SIZE)
    if not 1 <= image_count <= MAX_IMAGES:
        raise NRPTCodecError("E034", f"imageCount={image_count}")
    if image_table_size < image_count * IMAGE_ENTRY_HEADER_SIZE or image_table_size > MAX_IMAGE_TABLE_SIZE:
        raise NRPTCodecError("E035", f"imageTableSize={image_table_size}")

    stored_page_table_size = _u32(data, H_PAGE_TABLE_SIZE)
    expected_page_table_size = page_count * PAGE_RECORD_SIZE
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
    encoded_size = HEADER_SIZE + expected_page_table_size + expected_site_table_size + image_table_size
    if encoded_size > MAX_PROFILE_SIZE:
        raise NRPTCodecError("E010", f"computed size {encoded_size} > {MAX_PROFILE_SIZE}")
    if len(data) != encoded_size:
        raise NRPTCodecError("E013", f"actual size {len(data)} expected {encoded_size}")
    stored_checksum = _u32(data, H_PAYLOAD_CHECKSUM)
    computed_checksum = fnv1a32(data[HEADER_SIZE:])
    if stored_checksum != computed_checksum:
        raise NRPTCodecError(
            "E014", f"stored=0x{stored_checksum:08X} computed=0x{computed_checksum:08X}"
        )

    images = _parse_image_table(
        data, HEADER_SIZE + expected_page_table_size + expected_site_table_size, image_count, image_table_size
    )

    pages: list[Page] = []
    running_first_site = 0
    for page_index in range(page_count):
        record = HEADER_SIZE + page_index * PAGE_RECORD_SIZE
        page_file_offset = _u64(data, record + P_PAGE_FILE_OFFSET)
        page_content_hash = _u64(data, record + P_PAGE_HASH)
        first_site = _u32(data, record + P_FIRST_SITE)
        page_sites = _u16(data, record + P_SITE_COUNT)
        mode = data[record + P_MODE]
        flags = data[record + P_FLAGS]
        image_index = _u16(data, record + P_IMAGE_INDEX)
        reserved = _u16(data, record + P_RESERVED)
        page_vm_offset = _u32(data, record + P_PAGE_VM_OFFSET)

        if (page_file_offset & 0x0FFF) != 0:
            raise NRPTCodecError("E017", f"page[{page_index}] pageFileOffset not 4 KiB aligned")
        if mode not in (MODE_PAGE, MODE_DYLD):
            raise NRPTCodecError("E018", f"page[{page_index}] mode={mode}")
        if flags != 0 or reserved != 0 or image_index >= image_count:
            raise NRPTCodecError(
                "E038",
                f"page[{page_index}] flags={flags} reserved={reserved} imageIndex={image_index}",
            )
        image = images[image_index]
        if mode == MODE_PAGE and image.kind != IMAGE_KIND_STANDALONE:
            raise NRPTCodecError("E019", f"page[{page_index}] PAGE mode with cache image kind")
        if mode == MODE_DYLD and image.kind != IMAGE_KIND_SHARED_CACHE:
            raise NRPTCodecError("E019", f"page[{page_index}] DYLD mode with standalone image kind")
        if first_site != running_first_site:
            raise NRPTCodecError("E021", f"page[{page_index}] firstSite={first_site} expected {running_first_site}")
        if first_site + page_sites > site_count:
            raise NRPTCodecError(
                "E020",
                f"page[{page_index}] firstSite={first_site} siteCount={page_sites} header={site_count}",
            )
        if not 1 <= page_sites <= MAX_SITES_PER_PAGE:
            raise NRPTCodecError("E023", f"page[{page_index}] siteCount={page_sites}")
        if (page_vm_offset & 0x0FFF) != 0 or page_vm_offset + PAGE_SIZE > image.vm_size:
            raise NRPTCodecError(
                "E040", f"page[{page_index}] pageVmOffset=0x{page_vm_offset:X} imageVmSize=0x{image.vm_size:X}"
            )

        sites: list[Site] = []
        for local_index in range(page_sites):
            global_index = running_first_site + local_index
            site_base = HEADER_SIZE + expected_page_table_size + global_index * SITE_RECORD_SIZE
            site_in_page = _u16(data, site_base)
            find_size = data[site_base + 2]
            replace_size = data[site_base + 3]
            if not 1 <= find_size <= MAX_SITE_PATCH_SIZE or not 1 <= replace_size <= MAX_SITE_PATCH_SIZE:
                raise NRPTCodecError(
                    "E024", f"site[{global_index}] findSize={find_size} replaceSize={replace_size}"
                )
            if find_size != replace_size:
                raise NRPTCodecError(
                    "E025", f"site[{global_index}] findSize={find_size} replaceSize={replace_size}"
                )
            if site_in_page + find_size > PAGE_SIZE:
                raise NRPTCodecError(
                    "E026", f"site[{global_index}] siteInPage=0x{site_in_page:X} size={find_size}"
                )
            find_field = data[site_base + 4 : site_base + 20]
            replace_field = data[site_base + 20 : site_base + 36]
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
                mode=mode,
                image_index=image_index,
                page_vm_offset=page_vm_offset,
                sites=sites,
            )
        )
        running_first_site += page_sites

    if running_first_site != site_count:
        raise NRPTCodecError("E022", f"summed site count {running_first_site} != header {site_count}")

    profile = Profile(
        header=Header(build=build, apu_mask=apu_mask, device_id=device_id),
        images=images,
        pages=pages,
    )
    validate_model(profile)
    return profile


# ===========================================================================
# Part 2 follows: bundle model/selection, hook simulation, fixture validation, CLI.
# ===========================================================================

# ---------------------------------------------------------------------------
# NRedProfiles bundle model and selection (spec section 8)
# ---------------------------------------------------------------------------


@dataclass
class BundleEntry:
    build: str
    apu_mask: int
    device_id: int
    profile_data: bytes
    source: str = ""

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.profile_data).hexdigest()


@dataclass
class Bundle:
    entries: list[BundleEntry] = field(default_factory=list)

    def profiles(self) -> list[Profile]:
        return [decode(entry.profile_data) for entry in self.entries]


@dataclass
class Selection:
    status: str  # selected | unsupportedBuild | apuMismatch | deviceMismatch
    index: Optional[int] = None
    profile: Optional[Profile] = None

    @property
    def selected(self) -> bool:
        return self.status == "selected"


def validate_bundle_model(bundle: Bundle) -> None:
    """E050-E053 bundle rules; each profile must also decode structurally."""
    if not 1 <= len(bundle.entries) <= MAX_BUNDLE_ENTRIES:
        raise NRPTCodecError("E050", f"profileCount={len(bundle.entries)}")
    seen_builds: set[str] = set()
    for index, entry in enumerate(bundle.entries):
        try:
            decode_build_field(encode_build_field(entry.build))
        except NRPTCodecError as error:
            raise NRPTCodecError("E053", f"bundle[{index}]: invalid Build: {error}") from error
        if entry.build in seen_builds:
            raise NRPTCodecError("E051", f"bundle[{index}]: duplicate Build {entry.build!r}")
        seen_builds.add(entry.build)
        if not 1 <= entry.apu_mask <= KNOWN_APU_MASK or (entry.apu_mask & ~KNOWN_APU_MASK) != 0:
            raise NRPTCodecError("E053", f"bundle[{index}]: invalid APUMask=0x{entry.apu_mask:08X}")
        if entry.device_id > 0xFFFF:
            raise NRPTCodecError("E053", f"bundle[{index}]: invalid DeviceID=0x{entry.device_id:08X}")
        try:
            profile = decode(entry.profile_data)
        except NRPTCodecError:
            raise
        if profile.header.build != entry.build:
            raise NRPTCodecError(
                "E052",
                f"bundle[{index}]: Build {entry.build!r} != profile build {profile.header.build!r}",
            )
        if profile.header.apu_mask != entry.apu_mask:
            raise NRPTCodecError(
                "E052",
                f"bundle[{index}]: APUMask 0x{entry.apu_mask:08X} != profile 0x{profile.header.apu_mask:08X}",
            )
        if profile.header.device_id != entry.device_id:
            raise NRPTCodecError(
                "E052",
                f"bundle[{index}]: DeviceID 0x{entry.device_id:04X} != profile 0x{profile.header.device_id:04X}",
            )


def decode_bundle_plist(data: bytes) -> Bundle:
    """Decode the `NRedProfiles` Info.plist array (exact keys; E053 on structure)."""
    try:
        root = plistlib.loads(data)
    except Exception as error:  # plistlib raises several exception types
        raise NRPTCodecError("E053", f"bundle is not a plist: {error}") from error
    if not isinstance(root, dict) or set(root.keys()) != {BUNDLE_ROOT_KEY}:
        raise NRPTCodecError("E053", f"bundle root must be a dict with the single key {BUNDLE_ROOT_KEY!r}")
    raw_entries = root[BUNDLE_ROOT_KEY]
    if not isinstance(raw_entries, list):
        raise NRPTCodecError("E053", f"{BUNDLE_ROOT_KEY} must be an array")
    entries: list[BundleEntry] = []
    for index, raw in enumerate(raw_entries):
        if not isinstance(raw, dict):
            raise NRPTCodecError("E053", f"bundle[{index}] is not a dictionary")
        if set(raw.keys()) != set(BUNDLE_ENTRY_KEYS):
            raise NRPTCodecError(
                "E053", f"bundle[{index}] keys must be exactly {list(BUNDLE_ENTRY_KEYS)}"
            )
        build = raw["Build"]
        apu_mask = raw["APUMask"]
        device_id = raw["DeviceID"]
        profile_data = raw["Profile"]
        if not isinstance(build, str):
            raise NRPTCodecError("E053", f"bundle[{index}].Build must be a string")
        if isinstance(apu_mask, bool) or not isinstance(apu_mask, int):
            raise NRPTCodecError("E053", f"bundle[{index}].APUMask must be an integer")
        if isinstance(device_id, bool) or not isinstance(device_id, int):
            raise NRPTCodecError("E053", f"bundle[{index}].DeviceID must be an integer")
        if not isinstance(profile_data, (bytes, bytearray)):
            raise NRPTCodecError("E053", f"bundle[{index}].Profile must be a data value")
        entries.append(
            BundleEntry(
                build=build,
                apu_mask=apu_mask,
                device_id=device_id,
                profile_data=bytes(profile_data),
            )
        )
    bundle = Bundle(entries=entries)
    validate_bundle_model(bundle)
    return bundle


def bundle_plist_dict(bundle: Bundle) -> dict:
    return {
        BUNDLE_ROOT_KEY: [
            {
                "Build": entry.build,
                "APUMask": entry.apu_mask,
                "DeviceID": entry.device_id,
                "Profile": entry.profile_data,
            }
            for entry in bundle.entries
        ]
    }


def encode_bundle_plist(bundle: Bundle) -> bytes:
    """Deterministic XML plist for `NRedProfiles` (used by the injection tool and tests)."""
    validate_bundle_model(bundle)
    return plistlib.dumps(bundle_plist_dict(bundle), fmt=plistlib.FMT_XML, sort_keys=False)


def select_profile(bundle: Bundle, build: str, apu_mask: int, device_id: int) -> Selection:
    """Spec section 8: exact build, then APU-mask intersection, then device ID (when gated)."""
    entry_index = next((index for index, entry in enumerate(bundle.entries) if entry.build == build), None)
    if entry_index is None:
        return Selection(status="unsupportedBuild")
    entry = bundle.entries[entry_index]
    profile = decode(entry.profile_data)
    if (entry.apu_mask & apu_mask) == 0:
        return Selection(status="apuMismatch", index=entry_index, profile=profile)
    if profile.header.device_id != 0 and profile.header.device_id != device_id:
        return Selection(status="deviceMismatch", index=entry_index, profile=profile)
    return Selection(status="selected", index=entry_index, profile=profile)


def candidate_apu_mask(device_id: int) -> Optional[int]:
    return DEVICE_CANDIDATE_MASK.get(device_id)


# ---------------------------------------------------------------------------
# Hook matching simulation (spec section 9; no offset identity)
# ---------------------------------------------------------------------------


@dataclass
class ChunkResult:
    status: str  # applied | siteFindMismatch | alreadyApplied | alreadyPatched | noMatch
    page_index: Optional[int] = None
    site_index: Optional[int] = None
    data: Optional[bytes] = None
    writes: list[dict] = field(default_factory=list)

    @property
    def applied(self) -> bool:
        return self.status == "applied"


def vnode_gate_accepts(profile: Profile, page: Page, vnode_name: Optional[str]) -> bool:
    """Defense-in-depth vnode gate (spec 9.1); never identity."""
    if vnode_name is None:
        return True
    image = profile.images[page.image_index]
    if page.mode == MODE_PAGE:
        return image.basename in vnode_name
    return "dyld_shared_cache" in vnode_name or "dyld" in vnode_name


def sites_identity_matches(page: Page, data: bytes) -> tuple[bool, Optional[int]]:
    for site_index, site in enumerate(page.sites):
        start = site.site_in_page
        if data[start : start + site.size] != site.find:
            return False, site_index
    return True, None


def apply_chunk(
    profile: Profile,
    data: bytes,
    mode: int,
    *,
    chunk_base: Optional[int] = None,
    vnode_name: Optional[str] = None,
    vnode_gate: bool = True,
    applied: Optional[set[int]] = None,
    already_patched: Optional[set[int]] = None,
) -> ChunkResult:
    """Simulate one delivered 4 KiB chunk through one validation hook domain."""
    applied = applied if applied is not None else set()
    already_patched = already_patched if already_patched is not None else set()
    if len(data) != PAGE_SIZE:
        return ChunkResult(status="noMatch")

    # First matching record in table order is authoritative for this chunk.
    for page_index, page in enumerate(profile.pages):
        if page.mode != mode:
            continue
        if vnode_gate and not vnode_gate_accepts(profile, page, vnode_name):
            continue
        if fnv1a64(data) != page.page_hash:
            continue
        if page_index in applied:
            return ChunkResult(status="alreadyApplied", page_index=page_index)
        matched, bad_site = sites_identity_matches(page, data)
        if not matched:
            return ChunkResult(status="siteFindMismatch", page_index=page_index, site_index=bad_site)
        patched = bytearray(data)
        writes: list[dict] = []
        for site in page.sites:
            start = site.site_in_page
            end = start + site.size
            patched[start:end] = site.replace
            writes.append(
                {
                    "siteInPage": site.site_in_page,
                    "findSize": site.size,
                    "findHex": site.find.hex(),
                    "replaceHex": site.replace.hex(),
                    "originalHex": bytes(data[start:end]).hex(),
                }
            )
        applied.add(page_index)
        return ChunkResult(status="applied", page_index=page_index, data=bytes(patched), writes=writes)

    # No original-page identity matched: recognise an already-patched delivery (no write).
    for page_index, page in enumerate(profile.pages):
        if page.mode != mode:
            continue
        if vnode_gate and not vnode_gate_accepts(profile, page, vnode_name):
            continue
        if all(data[site.site_in_page : site.site_in_page + site.size] == site.replace for site in page.sites):
            applied.add(page_index)
            already_patched.add(page_index)
            return ChunkResult(status="alreadyPatched", page_index=page_index)

    return ChunkResult(status="noMatch")


def apply_range(
    profile: Profile,
    data: bytes,
    range_base: int,
    mode: int = MODE_DYLD,
    *,
    vnode_name: Optional[str] = None,
    vnode_gate: bool = True,
    applied: Optional[set[int]] = None,
    already_patched: Optional[set[int]] = None,
) -> list[ChunkResult]:
    applied = applied if applied is not None else set()
    already_patched = already_patched if already_patched is not None else set()
    results: list[ChunkResult] = []
    for index in range(len(data) // PAGE_SIZE):
        start = index * PAGE_SIZE
        results.append(
            apply_chunk(
                profile,
                data[start : start + PAGE_SIZE],
                mode,
                chunk_base=range_base + start,
                vnode_name=vnode_name,
                vnode_gate=vnode_gate,
                applied=applied,
                already_patched=already_patched,
            )
        )
    return results


# ---------------------------------------------------------------------------
# Fixture discovery and NRPT v3 metadata re-resolution
# ---------------------------------------------------------------------------

LC_SEGMENT_64 = 0x19
MACHO_MAGIC_64 = 0xFEEDFACF

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


def parse_macho_segments(read_at: Callable[[int, int], bytes]) -> list[MachOSegment]:
    header = read_at(0, 32)
    if len(header) != 32:
        raise ValueError("truncated Mach-O header")
    if int.from_bytes(header[0:4], "little") != MACHO_MAGIC_64:
        raise ValueError("unexpected Mach-O magic")
    ncmds = int.from_bytes(header[16:20], "little")
    sizeofcmds = int.from_bytes(header[20:24], "little")
    if not 0 < ncmds <= 4096 or sizeofcmds > 1024 * 1024:
        raise ValueError("implausible Mach-O load commands")
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
                raise ValueError("invalid section count")
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


def segment_containing(segments: Sequence[MachOSegment], address: int) -> Optional[MachOSegment]:
    for segment in segments:
        if segment.vmaddr <= address < segment.vmaddr + segment.vmsize:
            return segment
    return None


def discover_images(fixture_root: str) -> list[FixtureImage]:
    seen: set[str] = set()
    images: list[FixtureImage] = []
    candidates: list[str] = []
    for pattern in DEFAULT_IMAGE_GLOBS:
        candidates.extend(glob.glob(os.path.join(fixture_root, pattern)))
    for candidate in sorted(candidates):
        resolved = os.path.realpath(candidate)
        if resolved in seen:
            continue
        seen.add(resolved)
        if not os.path.isfile(resolved):
            continue
        name = os.path.basename(resolved)
        if name.endswith((".map", ".atlas", ".symbols", ".dylddata")) or name.startswith("_"):
            continue
        size = os.path.getsize(resolved)
        if size < PAGE_SIZE:
            continue
        images.append(FixtureImage(path=resolved, name=name, size=size))
    images.sort(key=lambda image: (image.name, image.path))
    return images


def read_chunk(path: str, offset: int, size: int = PAGE_SIZE) -> bytes:
    with open(path, "rb") as handle:
        handle.seek(offset)
        return handle.read(size)


@dataclass
class ImageResolution:
    index: int
    kind: int
    path: str
    unslid_vmaddr: int
    vm_size: int
    text_vmaddr: int
    text_vmsize: int
    file: str
    verified: bool


@dataclass
class PageResolution:
    page_index: int
    image_index: int
    image_kind: int
    image_path: str
    mode: int
    page_file_offset: int
    page_vm_offset: int
    page_start: int
    resolved_file: str
    resolved_offset: int
    evidence_consistent: bool
    segment: str
    section: Optional[str]
    page: bytes


class FixtureCatalog:
    def __init__(self, fixture_root: str, profile: Profile) -> None:
        self.fixture_root = fixture_root
        self.profile = profile
        self.images = discover_images(fixture_root)
        self.cache_files = [
            image
            for image in self.images
            if image.name.startswith("dyld_shared_cache_x86_64h")
            and not image.name.endswith((".map", ".atlas", ".symbols"))
        ]
        self._mappings: Optional[list[CacheMapping]] = None
        self._image_texts: Optional[list[CacheImageText]] = None
        self.image_resolutions: list[ImageResolution] = []
        self.page_resolutions: dict[int, PageResolution] = {}

    # -- dyld cache helpers -------------------------------------------------

    def _load_mappings(self) -> list[CacheMapping]:
        if self._mappings is not None:
            return self._mappings
        mappings: list[CacheMapping] = []
        for cache_file in self.cache_files:
            header = read_chunk(cache_file.path, 0, 0x300)
            if len(header) != 0x300 or header[:4] != b"dyld":
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
        self._mappings = mappings
        return mappings

    def _load_image_texts(self) -> list[CacheImageText]:
        if self._image_texts is not None:
            return self._image_texts
        texts: list[CacheImageText] = []
        main = next(
            (image for image in self.cache_files if image.name == "dyld_shared_cache_x86_64h"), None
        )
        if main is not None:
            header = read_chunk(main.path, 0, 0x100)
            if len(header) == 0x100:
                images_offset = _u64(header, 0x88)
                images_count = _u64(header, 0x90)
                if 0 < images_count < 100000 and images_offset > 0:
                    raw = read_chunk(main.path, images_offset, images_count * 32)
                    if len(raw) == images_count * 32:
                        for index in range(images_count):
                            base = index * 32
                            texts.append(
                                CacheImageText(
                                    load_address=_u64(raw, base + 16),
                                    text_size=_u32(raw, base + 24),
                                    path=_cstring(read_chunk(main.path, _u32(raw, base + 28), 512)),
                                )
                            )
        self._image_texts = texts
        return texts

    def _mapping(self, address: int) -> Optional[CacheMapping]:
        for mapping in self._load_mappings():
            if mapping.va <= address < mapping.va + mapping.size:
                return mapping
        return None

    def _cache_reader(self, mapping: CacheMapping, base: int) -> Callable[[int, int], bytes]:
        def read_at(offset: int, size: int) -> bytes:
            with open(mapping.path, "rb") as handle:
                handle.seek(base + offset)
                return handle.read(size)

        return read_at

    # -- verification -------------------------------------------------------

    def _standalone_file(self, image: Image) -> str:
        return os.path.join(self.fixture_root, image.path.lstrip("/"))

    def verify_image(self, image_index: int) -> ImageResolution:
        image = self.profile.images[image_index]
        if image.kind == IMAGE_KIND_STANDALONE:
            fixture_path = self._standalone_file(image)
            if not os.path.isfile(fixture_path):
                raise NRPTCodecError(
                    "E037", f"image[{image_index}] {image.path} not present in fixture ({fixture_path})"
                )
            with open(fixture_path, "rb") as handle:
                segments = parse_macho_segments(lambda offset, size: (handle.seek(offset), handle.read(size))[1])
            text = next((segment for segment in segments if segment.name == "__TEXT"), None)
            if text is None or text.vmaddr != image.unslid_vmaddr or text.vmsize != image.vm_size:
                raise NRPTCodecError(
                    "E041", f"image[{image_index}] fixture __TEXT geometry does not match the profile image"
                )
            resolution = ImageResolution(
                index=image_index,
                kind=image.kind,
                path=image.path,
                unslid_vmaddr=image.unslid_vmaddr,
                vm_size=image.vm_size,
                text_vmaddr=text.vmaddr,
                text_vmsize=text.vmsize,
                file=fixture_path,
                verified=True,
            )
        elif image.kind == IMAGE_KIND_SHARED_CACHE:
            match = next(
                (
                    text
                    for text in self._load_image_texts()
                    if text.load_address == image.unslid_vmaddr
                    and (text.path == image.path or text.path.endswith(image.path))
                ),
                None,
            )
            if match is None:
                raise NRPTCodecError(
                    "E041",
                    f"image[{image_index}] {image.path} (unslid 0x{image.unslid_vmaddr:X}) "
                    "not in the fixture dyld cache image-text list",
                )
            if match.text_size != image.vm_size:
                raise NRPTCodecError(
                    "E041",
                    f"image[{image_index}] fixture __TEXT vmsize 0x{match.text_size:X} != profile 0x{image.vm_size:X}",
                )
            mapping = self._mapping(image.unslid_vmaddr)
            if mapping is None:
                raise NRPTCodecError("E041", f"image[{image_index}] unslid address not in any fixture mapping")
            header_base = mapping.file_offset + (image.unslid_vmaddr - mapping.va)
            segments = parse_macho_segments(self._cache_reader(mapping, header_base))
            text = next((segment for segment in segments if segment.name == "__TEXT"), None)
            if text is None or text.vmaddr != image.unslid_vmaddr or text.vmsize != image.vm_size:
                raise NRPTCodecError(
                    "E041", f"image[{image_index}] fixture Mach-O __TEXT geometry does not match the profile image"
                )
            resolution = ImageResolution(
                index=image_index,
                kind=image.kind,
                path=image.path,
                unslid_vmaddr=image.unslid_vmaddr,
                vm_size=image.vm_size,
                text_vmaddr=text.vmaddr,
                text_vmsize=text.vmsize,
                file=mapping.path,
                verified=True,
            )
        else:  # pragma: no cover - model validation rejects unknown kinds
            raise NRPTCodecError("E041", f"image[{image_index}] unsupported kind")

        self.image_resolutions.append(resolution)
        return resolution

    def resolve_page(self, page_index: int) -> PageResolution:
        page = self.profile.pages[page_index]
        image = self.profile.images[page.image_index]
        page_start = image.unslid_vmaddr + page.page_vm_offset
        if page_start + PAGE_SIZE > image.unslid_vmaddr + image.vm_size:
            raise NRPTCodecError(
                "E040", f"page[{page_index}] pageStart 0x{page_start:X} leaves the image extent"
            )

        if image.kind == IMAGE_KIND_STANDALONE:
            fixture_path = self._standalone_file(image)
            with open(fixture_path, "rb") as handle:
                segments = parse_macho_segments(lambda offset, size: (handle.seek(offset), handle.read(size))[1])
            segment = segment_containing(segments, page_start)
            section = next(
                (
                    section
                    for segment_candidate in segments
                    for section in segment_candidate.sections
                    if section.addr <= page_start < section.addr + section.size
                ),
                None,
            )
            if segment is None:
                raise NRPTCodecError("E040", f"page[{page_index}] pageStart is not inside a fixture segment")
            resolved_offset = segment.fileoff + (page_start - segment.vmaddr)
            resolved_file = fixture_path
        else:
            mapping = self._mapping(page_start)
            if mapping is None:
                raise NRPTCodecError("E040", f"page[{page_index}] pageStart is not in a fixture cache mapping")
            resolved_offset = mapping.file_offset + (page_start - mapping.va)
            resolved_file = mapping.path
            segment = MachOSegment(name="__TEXT", vmaddr=image.unslid_vmaddr, vmsize=image.vm_size,
                                   fileoff=0, filesize=image.vm_size)
            section = MachOSection(name="__text", segname="__TEXT", addr=page_start, size=PAGE_SIZE, offset=0)
            header_mapping = self._mapping(image.unslid_vmaddr)
            if header_mapping is None:
                raise NRPTCodecError("E041", f"page[{page_index}] image header address not mapped")
            header_base = header_mapping.file_offset + (image.unslid_vmaddr - header_mapping.va)
            segments = parse_macho_segments(self._cache_reader(header_mapping, header_base))
            real_segment = segment_containing(segments, page_start)
            if real_segment is not None:
                segment = real_segment
                section = next(
                    (
                        candidate
                        for segment_candidate in segments
                        for candidate in segment_candidate.sections
                        if candidate.addr <= page_start < candidate.addr + candidate.size
                    ),
                    section,
                )

        page_bytes = read_chunk(resolved_file, resolved_offset, PAGE_SIZE)
        if len(page_bytes) != PAGE_SIZE:
            raise NRPTCodecError("E040", f"page[{page_index}] fixture page read is truncated")
        if fnv1a64(page_bytes) != page.page_hash:
            raise NRPTCodecError(
                "E040",
                f"page[{page_index}] clean fixture page hash 0x{fnv1a64(page_bytes):016X} != "
                f"profile pageHash 0x{page.page_hash:016X}",
            )
        resolution = PageResolution(
            page_index=page_index,
            image_index=page.image_index,
            image_kind=image.kind,
            image_path=image.path,
            mode=page.mode,
            page_file_offset=page.page_file_offset,
            page_vm_offset=page.page_vm_offset,
            page_start=page_start,
            resolved_file=resolved_file,
            resolved_offset=resolved_offset,
            evidence_consistent=(page.page_file_offset == resolved_offset),
            segment=segment.name,
            section=section.name if section is not None else None,
            page=page_bytes,
        )
        self.page_resolutions[page_index] = resolution
        return resolution


# ---------------------------------------------------------------------------
# Full-fixture content scan (false-positive / duplicate check)
# ---------------------------------------------------------------------------

NATIVE_SCAN_THRESHOLD_BYTES = 64 * 1024 * 1024
HASH_SCAN_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hash_scan.c")


def native_hash_scan_binary() -> Optional[str]:
    if not os.path.isfile(HASH_SCAN_SOURCE):
        return None
    compiler = shutil.which("clang") or shutil.which("cc") or shutil.which("gcc")
    if compiler is None:
        return None
    with open(HASH_SCAN_SOURCE, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()[:16]
    binary_path = os.path.join(tempfile.gettempdir(), f"nrpt_hash_scan_{digest}")
    if os.path.isfile(binary_path) and os.access(binary_path, os.X_OK):
        return binary_path
    try:
        completed = subprocess.run(
            [compiler, "-O2", "-o", binary_path, HASH_SCAN_SOURCE],
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0 or not os.path.isfile(binary_path):
        return None
    return binary_path


def python_page_hash_scan(
    files: Sequence[str], queries: Sequence[int]
) -> dict[int, list[tuple[str, int]]]:
    wanted = set(queries)
    results: dict[int, list[tuple[str, int]]] = {query: [] for query in wanted}
    for path in files:
        offset = 0
        size = os.path.getsize(path)
        with open(path, "rb") as handle:
            while offset + PAGE_SIZE <= size:
                chunk = handle.read(PAGE_SIZE)
                if len(chunk) != PAGE_SIZE:
                    break
                digest = fnv1a64(chunk)
                if digest in results:
                    results[digest].append((path, offset))
                offset += PAGE_SIZE
    return results


def native_page_hash_scan(
    files: Sequence[str], queries: Sequence[int], binary_path: str
) -> Optional[dict[int, list[tuple[str, int]]]]:
    wanted = sorted(set(queries))
    if not wanted:
        return {}
    handle = tempfile.NamedTemporaryFile(mode="w", prefix="nrpt-v3-queries-", suffix=".txt", delete=False)
    try:
        for query in wanted:
            handle.write(f"{query:016x}\n")
        handle.close()
        completed = subprocess.run(
            [binary_path, handle.name] + list(files), capture_output=True, text=True, timeout=900
        )
        if completed.returncode != 0:
            return None
        results: dict[int, list[tuple[str, int]]] = {query: [] for query in wanted}
        for line in completed.stdout.splitlines():
            fields = line.split("\t")
            if len(fields) != 3:
                continue
            try:
                digest = int(fields[0], 16)
                file_index = int(fields[1])
                offset = int(fields[2], 16)
            except ValueError:
                continue
            if digest in results and 0 <= file_index < len(files):
                results[digest].append((files[file_index], offset))
        return results
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        if not handle.closed:
            handle.close()
        try:
            os.unlink(handle.name)
        except OSError:
            pass


def scan_fixture_page_hashes(
    files: Sequence[str], queries: Sequence[int], *, allow_native: bool = True
) -> tuple[dict[int, list[tuple[str, int]]], str]:
    total = sum(os.path.getsize(path) for path in files)
    if allow_native and total > NATIVE_SCAN_THRESHOLD_BYTES:
        binary = native_hash_scan_binary()
        if binary is not None:
            print(
                f"hash scan: {len(set(queries))} hash(es) over {len(files)} file(s) "
                f"({total / 1e9:.2f} GB) via native helper",
                file=sys.stderr,
            )
            results = native_page_hash_scan(files, queries, binary)
            if results is not None:
                return results, "native"
            print("hash scan: native helper failed; using Python", file=sys.stderr)
    print(
        f"hash scan: {len(set(queries))} hash(es) over {len(files)} file(s) "
        f"({total / 1e9:.2f} GB) via Python (may be slow)",
        file=sys.stderr,
    )
    return python_page_hash_scan(files, queries), "python"


# ---------------------------------------------------------------------------
# Offline validation against a clean fixture
# ---------------------------------------------------------------------------


class ValidationFailure(Exception):
    def __init__(self, code: str, detail: str) -> None:
        self.code = code
        self.detail = detail
        super().__init__(f"{code}: {detail}")


def fixture_build(fixture_root: str) -> Optional[str]:
    for candidate in (
        os.path.join(fixture_root, "System/Library/CoreServices/SystemVersion.plist"),
        os.path.join(fixture_root, "SystemVersion.plist"),
    ):
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


def vnode_name_for(page: Page, profile: Profile, resolution: PageResolution) -> str:
    image = profile.images[page.image_index]
    if page.mode == MODE_PAGE:
        return image.basename
    return os.path.basename(resolution.resolved_file)


def validate_profile_against_fixture(
    profile: Profile,
    *,
    profile_path: str,
    profile_bytes: bytes,
    fixture_root: str,
    expected_build: Optional[str] = None,
    device_id: Optional[int] = None,
    expected_apu_mask: Optional[int] = None,
    bundle: Optional[Bundle] = None,
    selection: Optional[Selection] = None,
    mutation_sweep: bool = False,
    route_simulation: bool = True,
    native_hash_scan: bool = True,
    strict_false_positives: bool = False,
) -> dict:
    report: dict = {
        "tool": "test/nrpt_validator.py",
        "toolVersion": __version__,
        "profile": {
            "path": profile_path,
            "size": len(profile_bytes),
            "sha256": hashlib.sha256(profile_bytes).hexdigest(),
            "magic": MAGIC.decode(),
            "version": VERSION,
            "build": profile.header.build,
            "apuMask": f"0x{profile.header.apu_mask:08X}",
            "deviceID": f"0x{profile.header.device_id:04X}",
            "pageCount": profile.page_count,
            "siteCount": profile.site_count,
            "modePageCount": sum(1 for page in profile.pages if page.mode == MODE_PAGE),
            "modeDyldCount": sum(1 for page in profile.pages if page.mode == MODE_DYLD),
            "payloadChecksum": f"0x{fnv1a32(profile_bytes[HEADER_SIZE:]):08X}",
            "checksumOk": True,
            "imageCount": len(profile.images),
        },
        "fixture": {"root": fixture_root, "build": None, "imageCount": 0, "images": []},
        "identity": {},
        "bundle": None,
        "selection": None,
        "images": [],
        "pages": [],
        "falsePositiveChecks": [],
        "duplicateContent": [],
        "routeSimulation": {},
        "mutationSweep": [],
        "warnings": [],
        "summary": {},
        "result": "PASS",
    }

    images = discover_images(fixture_root)
    report["fixture"]["imageCount"] = len(images)
    report["fixture"]["images"] = [{"name": image.name, "size": image.size} for image in images]
    if not images:
        raise ValidationFailure("E037", f"no candidate fixture images under {fixture_root}")

    # --- identity gates -----------------------------------------------------
    fixture_version = fixture_build(fixture_root)
    report["fixture"]["build"] = fixture_version
    expected = expected_build or fixture_version
    build_check: dict = {"expected": expected, "profile": profile.header.build}
    if expected is None:
        build_check["status"] = "unknown"
        report["warnings"].append("fixture build unknown; build gate not verified offline")
    elif expected == profile.header.build:
        build_check["status"] = "pass"
    else:
        report["result"] = "FAIL"
        raise ValidationFailure(
            "E005", f"profile build {profile.header.build!r} != expected build {expected!r}"
        )
    report["identity"]["build"] = build_check

    running_apu_mask = expected_apu_mask
    if running_apu_mask is None and device_id is not None:
        running_apu_mask = candidate_apu_mask(device_id)
    apu_check: dict = {
        "apuMask": f"0x{profile.header.apu_mask:08X}",
        "deviceID": f"0x{profile.header.device_id:04X}",
        "runningDeviceID": f"0x{device_id:04X}" if device_id is not None else None,
        "runningApuMask": f"0x{running_apu_mask:08X}" if running_apu_mask is not None else None,
        "status": "unknown",
    }
    if running_apu_mask is not None:
        if running_apu_mask == 0:
            apu_check["status"] = "fail"
            report["result"] = "FAIL"
            raise ValidationFailure("E006", "running APU family mask is unknown (0)")
        if (profile.header.apu_mask & running_apu_mask) == 0:
            apu_check["status"] = "fail"
            report["result"] = "FAIL"
            raise ValidationFailure(
                "E006",
                f"apuMask 0x{profile.header.apu_mask:08X} does not intersect running mask "
                f"0x{running_apu_mask:08X}",
            )
        if profile.header.device_id != 0 and device_id is not None and profile.header.device_id != device_id:
            apu_check["status"] = "fail"
            report["result"] = "FAIL"
            raise ValidationFailure(
                "E007",
                f"profile deviceID 0x{profile.header.device_id:04X} != running device 0x{device_id:04X}",
            )
        apu_check["status"] = "pass"
    else:
        report["warnings"].append("running APU/device identity not supplied; APU/device gate not verified")
    report["identity"]["apuAndDevice"] = apu_check

    # --- bundle/selection report -------------------------------------------
    if bundle is not None:
        report["bundle"] = {
            "profileCount": len(bundle.entries),
            "entries": [
                {
                    "index": index,
                    "build": entry.build,
                    "apuMask": f"0x{entry.apu_mask:08X}",
                    "deviceID": f"0x{entry.device_id:04X}",
                    "profileSha256": entry.sha256,
                    "profileSize": len(entry.profile_data),
                }
                for index, entry in enumerate(bundle.entries)
            ],
        }
    if selection is not None:
        report["selection"] = {
            "status": selection.status,
            "index": selection.index,
            "build": bundle.entries[selection.index].build if (bundle and selection.index is not None) else None,
        }
        if not selection.selected:
            report["result"] = "FAIL"
            raise ValidationFailure("E050", f"bundle selection failed: {selection.status}")

    # --- fixture metadata + page resolution --------------------------------
    catalog = FixtureCatalog(fixture_root, profile)
    for image_index in range(len(profile.images)):
        try:
            resolution = catalog.verify_image(image_index)
        except NRPTCodecError as error:
            report["result"] = "FAIL"
            raise ValidationFailure(error.code, error.detail) from error
        report["images"].append(
            {
                "index": resolution.index,
                "kind": IMAGE_KIND_NAMES[resolution.kind],
                "path": resolution.path,
                "unslidVmaddr": f"0x{resolution.unslid_vmaddr:X}",
                "vmSize": f"0x{resolution.vm_size:X}",
                "textVmaddr": f"0x{resolution.text_vmaddr:X}",
                "textVmSize": f"0x{resolution.text_vmsize:X}",
                "file": os.path.basename(resolution.file),
                "verified": resolution.verified,
            }
        )

    resolved: list[PageResolution] = []
    for page_index in range(profile.page_count):
        try:
            resolution = catalog.resolve_page(page_index)
        except NRPTCodecError as error:
            report["result"] = "FAIL"
            raise ValidationFailure(error.code, error.detail) from error
        resolved.append(resolution)
        page = profile.pages[page_index]
        page_report: dict = {
            "index": page_index,
            "mode": MODE_NAMES[page.mode],
            "pageFileOffset": f"0x{page.page_file_offset:08X}",
            "pageVmOffset": f"0x{page.page_vm_offset:08X}",
            "pageHash": f"0x{page.page_hash:016X}",
            "imageIndex": page.image_index,
            "imageKind": IMAGE_KIND_NAMES[resolution.image_kind],
            "imagePath": resolution.image_path,
            "pageStart": f"0x{resolution.page_start:X}",
            "resolvedFile": os.path.basename(resolution.resolved_file),
            "resolvedOffset": f"0x{resolution.resolved_offset:08X}",
            "evidenceConsistent": resolution.evidence_consistent,
            "segment": resolution.segment,
            "section": resolution.section,
            "vnodeName": vnode_name_for(page, profile, resolution),
            "sites": [],
            "applied": False,
        }
        if not resolution.evidence_consistent:
            report["warnings"].append(
                f"page[{page_index}] pageFileOffset evidence 0x{page.page_file_offset:X} != resolved "
                f"offset 0x{resolution.resolved_offset:X} (diagnostic only; identity is content)"
            )
        report["pages"].append(page_report)

    # --- hook-domain application: PAGE mode via page hook, DYLD via range ---
    applied: set[int] = set()
    already_patched: set[int] = set()
    for page_index, page in enumerate(profile.pages):
        resolution = resolved[page_index]
        vnode_name = vnode_name_for(page, profile, resolution)
        result = apply_chunk(
            profile,
            resolution.page,
            page.mode,
            vnode_name=vnode_name,
            applied=applied,
            already_patched=already_patched,
        )
        page_report = report["pages"][page_index]
        if result.status != "applied" or result.page_index != page_index:
            page_report["status"] = result.status
            report["result"] = "FAIL"
            raise ValidationFailure(
                "E020",
                f"page[{page_index}] did not apply through the {MODE_NAMES[page.mode]} domain: "
                f"status={result.status} matchedRecord={result.page_index} site={result.site_index}",
            )
        page_report["status"] = "applied"
        page_report["applied"] = True
        page_report["matchedRecordIndex"] = result.page_index
        page_report["bytesChanged"] = sum(1 for before, after in zip(resolution.page, result.data) if before != after)
        page_report["patchedPageHash"] = f"0x{fnv1a64(result.data):016X}"
        write_by_site = {write["siteInPage"]: write for write in result.writes}
        for site_index, site in enumerate(page.sites):
            start = site.site_in_page
            end = start + site.size
            page_report["sites"].append(
                {
                    "index": site_index,
                    "siteInPage": f"0x{start:04X}",
                    "findHex": site.find.hex(),
                    "replaceHex": site.replace.hex(),
                    "findMatched": True,
                    "written": result.data[start:end] == site.replace,
                    "write": write_by_site.get(start),
                }
            )
        repeat = apply_chunk(
            profile,
            resolution.page,
            page.mode,
            vnode_name=vnode_name,
            applied=applied,
            already_patched=already_patched,
        )
        page_report["secondDelivery"] = repeat.status
        if repeat.status != "alreadyApplied":
            report["result"] = "FAIL"
            raise ValidationFailure(
                "E031", f"page[{page_index}] applied-once bit not honoured on repeat delivery"
            )

    # --- already-patched pass (no write) -----------------------------------
    for page_index, page in enumerate(profile.pages):
        resolution = resolved[page_index]
        patched_page = bytearray(resolution.page)
        for site in page.sites:
            patched_page[site.site_in_page : site.site_in_page + site.size] = site.replace
        patched_applied: set[int] = set()
        patched_already: set[int] = set()
        result = apply_chunk(
            profile,
            bytes(patched_page),
            page.mode,
            vnode_name=vnode_name_for(page, profile, resolution),
            applied=patched_applied,
            already_patched=patched_already,
        )
        ok = result.status == "alreadyPatched" and result.page_index == page_index and not result.data
        report["pages"][page_index]["alreadyPatchedDelivery"] = result.status
        if not ok:
            report["result"] = "FAIL"
            raise ValidationFailure(
                "E031", f"page[{page_index}] already-patched delivery not recognised (status={result.status})"
            )

    # --- false positives / duplicate content -------------------------------
    # Candidate space is mode+vnode-domain scoped: PAGE scans only the target standalone file
    # (the vnode gate accepts that basename), DYLD scans the dyld cache files (any dyld vnode).
    # Byte-identical duplicates are therefore same-domain identity ambiguity, not route confusion;
    # they are a warning by default and a failure only with --strict-false-positives.
    scan_files: set[str] = set()
    for page_index, page in enumerate(profile.pages):
        if page.mode == MODE_PAGE:
            scan_files.add(resolved[page_index].resolved_file)
        else:
            scan_files.update(cache.path for cache in catalog.cache_files)
    page_files = sorted(scan_files)
    page_hashes = {page.page_hash for page in profile.pages}
    hash_matches, scan_mode = scan_fixture_page_hashes(
        page_files, sorted(page_hashes), allow_native=native_hash_scan
    )
    report["falsePositiveChecks"] = []
    for page_index, page in enumerate(profile.pages):
        resolution = resolved[page_index]
        unintended: list[dict] = []
        for file_path, offset in hash_matches.get(page.page_hash, []):
            if file_path == resolution.resolved_file and offset == resolution.resolved_offset:
                continue
            chunk = read_chunk(file_path, offset)
            if len(chunk) != PAGE_SIZE:
                continue
            matched, _bad = sites_identity_matches(page, chunk)
            if not matched:
                continue  # same content hash implies same bytes; a site mismatch is impossible unless profile sites disagree
            unintended.append(
                {
                    "file": os.path.basename(file_path),
                    "offset": f"0x{offset:08X}",
                    "mode": MODE_NAMES[page.mode],
                }
            )
        entry: dict = {
            "record": page_index,
            "mode": MODE_NAMES[page.mode],
            "intendedFile": os.path.basename(resolution.resolved_file),
            "intendedOffset": f"0x{resolution.resolved_offset:08X}",
            "contentIdentityMatches": len(hash_matches.get(page.page_hash, [])),
            "unintendedMatches": unintended,
        }
        if unintended:
            report["duplicateContent"].append(entry)
            report["warnings"].append(
                f"page[{page_index}] content identity also matches {len(unintended)} other fixture page(s) "
                f"in the {MODE_NAMES[page.mode]} domain (byte-identical content; the patch writes are identical)"
            )
            entry["status"] = "warning"
        else:
            entry["status"] = "pass"
        report["falsePositiveChecks"].append(entry)
    if report["duplicateContent"] and strict_false_positives:
        report["result"] = "FAIL"
        raise ValidationFailure(
            "E031",
            f"{len(report['duplicateContent'])} record(s) match unintended fixture content in their mode domain",
        )

    # --- route simulation (mode-domain separation) -------------------------
    if route_simulation:
        route: dict = {"pageMode": [], "dyldMode": [], "modeSeparation": []}
        for page_index, page in enumerate(profile.pages):
            if page.mode != MODE_PAGE:
                continue
            resolution = resolved[page_index]
            page_route_applied: set[int] = set()
            result = apply_chunk(
                profile,
                resolution.page,
                MODE_PAGE,
                vnode_name=profile.images[page.image_index].basename,
                applied=page_route_applied,
            )
            other_mode = apply_chunk(
                profile,
                resolution.page,
                MODE_DYLD,
                vnode_name=os.path.basename(resolution.resolved_file),
                applied=set(),
            )
            wrong_vnode = apply_chunk(
                profile,
                resolution.page,
                MODE_PAGE,
                vnode_name="unrelated-binary",
                applied=set(),
            )
            entry = {
                "record": page_index,
                "mode": MODE_NAMES[page.mode],
                "pageRoute": result.status,
                "wrongMode": other_mode.status,
                "wrongVnode": wrong_vnode.status,
            }
            route["pageMode"].append(entry)
            if result.status != "applied" or other_mode.status != "noMatch" or wrong_vnode.status != "noMatch":
                report["result"] = "FAIL"
                raise ValidationFailure(
                    "E019",
                    f"page[{page_index}] PAGE route simulation failed: {entry}",
                )
        # DYLD: contiguous range containing each intended page, delivered through the range hook.
        dyld_groups: dict[str, list[int]] = {}
        for page_index, page in enumerate(profile.pages):
            if page.mode == MODE_DYLD:
                dyld_groups.setdefault(resolved[page_index].resolved_file, []).append(page_index)
        max_range_bytes = 4 * 1024 * 1024
        for file_path, page_indices in dyld_groups.items():
            offsets = sorted((resolved[index].resolved_offset, index) for index in page_indices)
            clusters: list[list[tuple[int, int]]] = []
            current: list[tuple[int, int]] = []
            for offset, index in offsets:
                if current and offset + PAGE_SIZE - current[0][0] > max_range_bytes:
                    clusters.append(current)
                    current = []
                current.append((offset, index))
            if current:
                clusters.append(current)
            for cluster in clusters:
                base = cluster[0][0]
                end = cluster[-1][0] + PAGE_SIZE
                size = end - base
                expected = {index for _offset, index in cluster}
                range_data = read_chunk(file_path, base, size)
                if len(range_data) != size:
                    report["result"] = "FAIL"
                    raise ValidationFailure(
                        "E040",
                        f"DYLD route simulation cannot read 0x{size:X} bytes at 0x{base:X} from "
                        f"{os.path.basename(file_path)}",
                    )
                range_applied: set[int] = set()
                results = apply_range(
                    profile,
                    range_data,
                    base,
                    MODE_DYLD,
                    vnode_name=os.path.basename(file_path),
                    applied=range_applied,
                )
                got = {result.page_index for result in results if result.status == "applied"}
                entry = {
                    "file": os.path.basename(file_path),
                    "rangeBase": f"0x{base:08X}",
                    "chunks": len(results),
                    "expectedRecords": sorted(expected),
                    "appliedRecords": sorted(got),
                    "modeSeparation": "pass" if got == expected else "fail",
                }
                route["dyldMode"].append(entry)
                if got != expected:
                    report["result"] = "FAIL"
                    raise ValidationFailure(
                        "E019",
                        f"DYLD route simulation for {os.path.basename(file_path)} applied {sorted(got)} "
                        f"expected {sorted(expected)}",
                    )
        report["routeSimulation"] = route

    # --- mutation rejection ------------------------------------------------
    if mutation_sweep:
        for page_index, page in enumerate(profile.pages):
            resolution = resolved[page_index]
            mutated = bytearray(resolution.page)
            mutated[(page_index * 97 + 13) % PAGE_SIZE] ^= 0xFF
            result = apply_chunk(
                profile,
                bytes(mutated),
                page.mode,
                vnode_name=vnode_name_for(page, profile, resolution),
                applied=set(),
            )
            report["mutationSweep"].append(
                {
                    "record": page_index,
                    "mode": MODE_NAMES[page.mode],
                    "mutatedByte": (page_index * 97 + 13) % PAGE_SIZE,
                    "status": result.status,
                }
            )
            if result.status == "applied":
                report["result"] = "FAIL"
                raise ValidationFailure("E031", f"page[{page_index}] mutated content was still applied")

    total_sites = sum(len(page["sites"]) for page in report["pages"])
    report["hashScan"] = {"mode": scan_mode, "files": len(page_files), "queries": len(page_hashes)}
    report["summary"] = {
        "intendedPages": profile.page_count,
        "resolvedPages": len(resolved),
        "appliedPages": sum(1 for page in report["pages"] if page["applied"]),
        "intendedSites": profile.site_count,
        "reportedSites": total_sites,
        "modePageCount": report["profile"]["modePageCount"],
        "modeDyldCount": report["profile"]["modeDyldCount"],
        "falsePositives": 0,
        "identityWarnings": len(report["duplicateContent"]),
        "mutationRejects": len([entry for entry in report["mutationSweep"] if entry["status"] != "applied"]),
        "warnings": len(report["warnings"]),
        "hashScanMode": scan_mode,
        "result": "PASS",
    }
    return report


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def print_human_report(report: dict) -> None:
    profile = report["profile"]
    print(f"NRPT profile: {profile['path']} ({profile['size']} bytes, sha256 {profile['sha256']})")
    print(
        f"  format=v{profile['version']} build={profile['build']} apuMask={profile['apuMask']} "
        f"deviceID={profile['deviceID']} pages={profile['pageCount']} sites={profile['siteCount']} "
        f"PAGE={profile['modePageCount']} DYLD={profile['modeDyldCount']} "
        f"checksum={profile['payloadChecksum']} (OK)"
    )
    fixture = report["fixture"]
    print(f"fixture: {fixture['root']} build={fixture['build']} images={fixture['imageCount']}")
    for name, check in report["identity"].items():
        print(f"identity {name}: {check['status']}")
    if report.get("selection"):
        print(f"bundle selection: {report['selection']}")
    for image in report["images"]:
        print(
            f"image[{image['index']}]: {image['kind']} {image['path']} unslid={image['unslidVmaddr']} "
            f"vmSize={image['vmSize']} verified={image['verified']}"
        )
    print("pages:")
    for page in report["pages"]:
        print(
            f"  [{page['index']:>2}] {page['mode']:<4} vmOff={page['pageVmOffset']} "
            f"hash={page['pageHash']} image={page['imageKind']} "
            f"{page['resolvedFile']}@{page['resolvedOffset']} "
            f"seg={page['segment']}/{page['section']} vnode={page['vnodeName']} status={page['status']}"
        )
        for site in page["sites"]:
            print(
                f"        site {site['index']}: @{site['siteInPage']} {site['findHex']} -> "
                f"{site['replaceHex']} find={site['findMatched']} written={site['written']}"
            )
    for check in report["falsePositiveChecks"]:
        if check["unintendedMatches"]:
            print(
                f"duplicate-content record {check['record']} ({check['mode']}): "
                f"{len(check['unintendedMatches'])} unintended identical-content match(es) [{check['status']}]"
            )
    if report.get("routeSimulation"):
        for entry in report["routeSimulation"].get("pageMode", []):
            print(f"route PAGE record {entry['record']}: {entry['pageRoute']} (wrongMode={entry['wrongMode']}, wrongVnode={entry['wrongVnode']})")
        for entry in report["routeSimulation"].get("dyldMode", []):
            print(f"route DYLD {entry['file']}: {entry['modeSeparation']} ({entry['chunks']} chunks)")
    if report["mutationSweep"]:
        print(f"mutation sweep: {len(report['mutationSweep'])} page(s) rejected as expected")
    summary = report["summary"]
    print(
        f"summary: pages={summary['appliedPages']}/{summary['intendedPages']} "
        f"sites={summary['reportedSites']}/{summary['intendedSites']} "
        f"PAGE={summary['modePageCount']} DYLD={summary['modeDyldCount']} "
        f"falsePositives={summary['falsePositives']} warnings={summary['warnings']}"
    )
    for warning in report["warnings"]:
        print(f"warning: {warning}")
    print(f"RESULT: {report['result']}")


def _parse_int(value: str) -> int:
    return int(value, 0)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="NRPT v3 offline validator: bundle selection + exact hook-domain simulation "
        "(PAGE/DYLD modes, vnode gate, full-page hash identity, no offset identity)."
    )
    source = parser.add_argument_group("profile source")
    source.add_argument("--profile", help="NRPT v3 profile file")
    source.add_argument("--bundle-plist", help="NRedProfiles bundle plist to validate and select from")
    parser.add_argument("--fixtures", default="/", help="clean fixture root (default: /)")
    parser.add_argument("--report", help="write a machine-readable JSON report")
    parser.add_argument("--expected-build", help="expected running build string (e.g. 24H232)")
    parser.add_argument("--device-id", type=_parse_int, help="running iGPU PCI device ID (e.g. 0x1638)")
    parser.add_argument("--expected-apumask", type=_parse_int, help="override the running APU family mask")
    parser.add_argument("--mutation-sweep", action="store_true", help="reject one mutated byte per page")
    parser.add_argument("--strict-false-positives", action="store_true",
                        help="treat byte-identical duplicate content in the same mode as a failure")
    parser.add_argument("--no-route-simulation", action="store_true", help="skip route/mode simulation")
    parser.add_argument("--no-native-hash-scan", action="store_true", help="force pure-Python hash scanning")
    parser.add_argument("--quiet", action="store_true", help="suppress human output")
    args = parser.parse_args(argv)

    if bool(args.profile) == bool(args.bundle_plist):
        print("error: exactly one of --profile or --bundle-plist is required", file=sys.stderr)
        return 2

    bundle: Optional[Bundle] = None
    selection: Optional[Selection] = None
    if args.bundle_plist:
        try:
            with open(args.bundle_plist, "rb") as handle:
                bundle = decode_bundle_plist(handle.read())
        except OSError as error:
            print(f"error: cannot read bundle: {error}", file=sys.stderr)
            return 2
        except NRPTCodecError as error:
            print(f"BUNDLE REJECTED: {error}", file=sys.stderr)
            return 1
        if args.expected_build is None:
            print("error: --bundle-plist requires --expected-build for selection", file=sys.stderr)
            return 2
        running_mask = args.expected_apumask
        if running_mask is None and args.device_id is not None:
            running_mask = candidate_apu_mask(args.device_id)
        if running_mask is None:
            print("error: bundle selection needs --device-id or --expected-apumask", file=sys.stderr)
            return 2
        selection = select_profile(bundle, args.expected_build, running_mask, args.device_id or 0)
        if not selection.selected:
            print(f"SELECTION FAILED: {selection.status}", file=sys.stderr)
            return 1
        profile_bytes = bundle.entries[selection.index].profile_data
        profile = selection.profile
        profile_path = f"{args.bundle_plist}#{selection.index}"
    else:
        try:
            with open(args.profile, "rb") as handle:
                profile_bytes = handle.read()
        except OSError as error:
            print(f"error: cannot read profile: {error}", file=sys.stderr)
            return 2
        profile_path = args.profile
        try:
            profile = decode(profile_bytes)
        except NRPTCodecError as error:
            print(f"NRPT PROFILE REJECTED: {error}", file=sys.stderr)
            return 1

    if not os.path.isdir(args.fixtures):
        print(f"error: fixture root is not a directory: {args.fixtures}", file=sys.stderr)
        return 2

    try:
        report = validate_profile_against_fixture(
            profile,
            profile_path=profile_path,
            profile_bytes=profile_bytes,
            fixture_root=args.fixtures,
            expected_build=args.expected_build,
            device_id=args.device_id,
            expected_apu_mask=args.expected_apumask,
            bundle=bundle,
            selection=selection,
            mutation_sweep=args.mutation_sweep,
            route_simulation=not args.no_route_simulation,
            native_hash_scan=not args.no_native_hash_scan,
            strict_false_positives=args.strict_false_positives,
        )
    except ValidationFailure as failure:
        print(f"VALIDATION FAILED: {failure}", file=sys.stderr)
        return 1

    if not args.quiet:
        print_human_report(report)
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
