#!/usr/bin/env python3
# Unit tests for the independent NRPT v1 offline validator (test/nrpt_validator.py).
#
# No Apple binaries are used or committed: every fixture here is synthetic, generated
# deterministically at test time. The real-profile end-to-end run lives in
# test/run-validation.sh (it reads the host's clean images in place).
#
# Coverage:
#   - FNV-1a reference vectors (docs/PatchProfile-Spec.md section 16.1/16.2)
#   - encode/decode round trip, canonical size, determinism (section 16.3/16.4/16.5)
#   - every stable error code E001..E032 (+ E033 pageHash length) (section 11/16.6)
#   - kext algorithm semantics: offset gate, hash gate, all-site atomic apply,
#     applied-once, first-matching-record authoritative / no try-next-record (section 8)
#   - fixture resolution, false-positive rejection, mutation sweep, range simulation

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nrpt_validator as V  # noqa: E402

COVERED_CODES: set[str] = set()

GL_DRIVER_REL = (
    "System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/"
    "AMDRadeonX5000GLDriver"
)
MTL_DRIVER_REL = (
    "System/Library/Extensions/AMDRadeonX5000MTLDriver.bundle/Contents/MacOS/"
    "AMDRadeonX5000MTLDriver"
)


# ---------------------------------------------------------------------------
# Deterministic synthetic fixture helpers
# ---------------------------------------------------------------------------


def deterministic_page(seed: bytes) -> bytes:
    return hashlib.shake_256(seed).digest(V.PAGE_SIZE)


def deterministic_image(page_count: int, seed: bytes) -> bytes:
    return b"".join(
        deterministic_page(seed + index.to_bytes(8, "little")) for index in range(page_count)
    )


def page_of(image: bytes, page_index: int) -> bytes:
    start = page_index * V.PAGE_SIZE
    return image[start : start + V.PAGE_SIZE]


def make_site(page: bytes, site_in_page: int, size: int, *, salt: int = 0x5A) -> V.Site:
    find = page[site_in_page : site_in_page + size]
    replace = bytes((find[0] ^ salt,)) + find[1:]
    if replace == find:  # pragma: no cover - salting always changes byte 0
        replace = bytes((find[0] ^ 0x01,)) + find[1:]
    return V.Site(site_in_page=site_in_page, find=find, replace=replace)


def make_profile_for_image(
    image: bytes,
    targets: list[tuple[int, list[tuple[int, int]]]],
    *,
    build: str = "24H232",
    apu_mask: int = V.APU_RENOIR | V.APU_GREEN_SARDINE,
    device_id: int = 0,
    header_flags: int = 0,
) -> V.Profile:
    pages: list[V.Page] = []
    for page_index, sites in targets:
        page = page_of(image, page_index)
        site_models = [make_site(page, offset, size) for offset, size in sites]
        pages.append(
            V.Page(
                page_file_offset=page_index * V.PAGE_SIZE,
                page_hash=V.fnv1a64(page),
                match_flags=V.DEFAULT_MATCH_FLAGS,
                sites=site_models,
            )
        )
    return V.Profile(
        header=V.Header(
            build=build, apu_mask=apu_mask, device_id=device_id, flags=header_flags
        ),
        pages=pages,
    )


def write_fixture(root: str, images: dict[str, bytes]) -> None:
    for relative_path, data in images.items():
        target = os.path.join(root, relative_path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as handle:
            handle.write(data)


# Base synthetic world: image A has 10 pages, image B has 6 pages.
IMAGE_A = deterministic_image(10, b"synthetic-gl-driver")
IMAGE_B = deterministic_image(6, b"synthetic-mtl-driver")


def base_image_bytes() -> dict[str, bytes]:
    return {GL_DRIVER_REL: IMAGE_A, MTL_DRIVER_REL: IMAGE_B}


def base_profile() -> V.Profile:
    return make_profile_for_image(
        IMAGE_A,
        [
            (2, [(0x100, 6)]),
            (5, [(0x200, 3), (0x340, 8)]),
            (8, [(0x3F0, 16)]),
        ],
    )


def raw_profile(
    pages: list[dict],
    sites: list[dict],
    *,
    magic: bytes = V.MAGIC,
    version: int = V.VERSION,
    header_size: int = V.HEADER_SIZE,
    build_field: bytes = b"24H232" + b"\x00" * 10,
    apu_mask: int = 0x28,
    device_id: int = 0,
    header_flags: int = 0,
    page_count: int = None,
    site_count: int = None,
    page_table_size: int = None,
    site_table_size: int = None,
    checksum: int = None,
    reserved: bytes = b"\x00" * V.H_RESERVED_SIZE,
    trailing: bytes = b"",
) -> bytes:
    """Build raw NRPT bytes without model validation (for crafted error vectors)."""
    page_table = bytearray()
    for page in pages:
        page_table += V._p64(page["offset"])
        page_table += V._p64(page["hash"])
        page_table += V._p32(page.get("first", 0))
        page_table += V._p16(page.get("count", 1))
        page_table += V._p16(page.get("match_flags", V.DEFAULT_MATCH_FLAGS))
    site_table = bytearray()
    for site in sites:
        find = site["find"]
        replace = site["replace"]
        site_table += V._p16(site.get("site_in_page", 0))
        site_table += bytes((site.get("find_size", len(find)), site.get("replace_size", len(replace))))
        find_field = bytearray(find + b"\x00" * (V.MAX_SITE_PATCH_SIZE - len(find)))
        replace_field = bytearray(replace + b"\x00" * (V.MAX_SITE_PATCH_SIZE - len(replace)))
        if "find_padding_dirty" in site:
            find_field[len(find)] = site["find_padding_dirty"]
        site_table += find_field
        site_table += replace_field
        site_table += V._p32(site.get("flags", 0))
    payload = bytes(page_table) + bytes(site_table)
    actual_page_count = len(pages) if page_count is None else page_count
    actual_site_count = len(sites) if site_count is None else site_count
    actual_page_table_size = len(page_table) if page_table_size is None else page_table_size
    actual_site_table_size = len(site_table) if site_table_size is None else site_table_size
    actual_checksum = V.fnv1a32(payload) if checksum is None else checksum
    header = (
        magic
        + V._p16(version)
        + V._p16(header_size)
        + build_field
        + V._p32(apu_mask)
        + V._p32(device_id)
        + V._p16(actual_page_count)
        + V._p16(actual_site_count)
        + V._p32(actual_page_table_size)
        + V._p32(actual_site_table_size)
        + V._p32(actual_checksum)
        + V._p32(header_flags)
        + reserved
    )
    assert len(header) == V.HEADER_SIZE
    return header + payload + trailing


def simple_page_record(offset: int, page_hash: int, *, first: int = 0, count: int = 1,
                       match_flags: int = V.DEFAULT_MATCH_FLAGS) -> dict:
    return {"offset": offset, "hash": page_hash, "first": first, "count": count,
            "match_flags": match_flags}


def simple_site(site_in_page: int, find: bytes, replace: bytes, **kwargs) -> dict:
    return {"site_in_page": site_in_page, "find": find, "replace": replace, **kwargs}


class ValidatorTestCase(unittest.TestCase):
    """Shared fixture setup: a temporary synthetic fixture tree + base valid profile/bytes."""

    @classmethod
    def setUpClass(cls) -> None:
        cls._tmpdir = tempfile.TemporaryDirectory(prefix="nrpt-selftest-")
        cls.fixture_root = cls._tmpdir.name
        write_fixture(cls.fixture_root, base_image_bytes())
        cls.profile = base_profile()
        cls.profile_bytes = V.encode(cls.profile)
        cls.images = V.discover_images(cls.fixture_root)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmpdir.cleanup()

    # -- helpers ------------------------------------------------------------

    def expect_decode_code(self, data: bytes, code: str) -> None:
        COVERED_CODES.add(code)
        with self.assertRaises(V.NRPTCodecError) as context:
            V.decode(data)
        self.assertEqual(context.exception.code, code, f"expected {code}, got {context.exception}")

    def expect_encode_code(self, profile: V.Profile, code: str) -> None:
        COVERED_CODES.add(code)
        with self.assertRaises(V.NRPTCodecError) as context:
            V.encode(profile)
        self.assertEqual(context.exception.code, code, f"expected {code}, got {context.exception}")

    def mutate(self, base: bytes, changes: dict[int, bytes], *, fix_checksum: bool = True) -> bytes:
        data = bytearray(base)
        for offset, replacement in changes.items():
            data[offset : offset + len(replacement)] = replacement
        if fix_checksum:
            data[V.H_PAYLOAD_CHECKSUM : V.H_PAYLOAD_CHECKSUM + 4] = V._p32(
                V.fnv1a32(bytes(data[V.HEADER_SIZE :]))
            )
        return bytes(data)

    @property
    def page_table_base(self) -> int:
        return V.HEADER_SIZE

    @property
    def site_table_base(self) -> int:
        return V.HEADER_SIZE + len(self.profile.pages) * V.PAGE_RECORD_SIZE

    def site_record_offset(self, index: int) -> int:
        return self.site_table_base + index * V.SITE_RECORD_SIZE

    def page_record_offset(self, index: int) -> int:
        return self.page_table_base + index * V.PAGE_RECORD_SIZE


# ---------------------------------------------------------------------------
# Codec tests (spec sections 1.1, 2-7, 16.1-16.5)
# ---------------------------------------------------------------------------


class CodecTests(ValidatorTestCase):
    def test_fnv1a32_reference_vectors(self) -> None:
        self.assertEqual(V.fnv1a32(b""), 0x811C9DC5)
        self.assertEqual(V.fnv1a32(b"a"), 0xE40C292C)
        self.assertEqual(V.fnv1a32(b"foobar"), 0xBF9CF968)

    def test_fnv1a64_reference_vectors(self) -> None:
        self.assertEqual(V.fnv1a64(b""), 0xCBF29CE484222325)
        self.assertEqual(V.fnv1a64(b"a"), 0xAF63DC4C8601EC8C)
        self.assertEqual(V.fnv1a64(b"foobar"), 0x85944171F73967E8)

    def test_page_hash_rejects_wrong_lengths(self) -> None:
        COVERED_CODES.add("E033")
        with self.assertRaises(V.NRPTCodecError) as context:
            V.page_hash(b"\x00" * 4095)
        self.assertEqual(context.exception.code, "E033")
        with self.assertRaises(V.NRPTCodecError) as context:
            V.page_hash(b"\x00" * 4097)
        self.assertEqual(context.exception.code, "E033")
        self.assertEqual(V.page_hash(b"\x00" * 4096), V.fnv1a64(b"\x00" * 4096))

    def test_encode_decode_round_trip(self) -> None:
        decoded = V.decode(self.profile_bytes)
        self.assertEqual(decoded, self.profile)
        self.assertEqual(decoded.header, self.profile.header)
        for actual, expected in zip(decoded.pages, self.profile.pages):
            self.assertEqual(actual.page_file_offset, expected.page_file_offset)
            self.assertEqual(actual.page_hash, expected.page_hash)
            self.assertEqual(actual.match_flags, expected.match_flags)
            self.assertEqual(len(actual.sites), len(expected.sites))
            for actual_site, expected_site in zip(actual.sites, expected.sites):
                self.assertEqual(actual_site.site_in_page, expected_site.site_in_page)
                self.assertEqual(actual_site.find, expected_site.find)
                self.assertEqual(actual_site.replace, expected_site.replace)

    def test_encode_is_deterministic(self) -> None:
        self.assertEqual(V.encode(self.profile), V.encode(base_profile()))
        self.assertEqual(V.encode(V.decode(self.profile_bytes)), self.profile_bytes)

    def test_encoded_size_formula(self) -> None:
        self.assertEqual(
            len(self.profile_bytes),
            V.HEADER_SIZE
            + self.profile.page_count * V.PAGE_RECORD_SIZE
            + self.profile.site_count * V.SITE_RECORD_SIZE,
        )
        # Spec 16.5: a 13-page/18-site profile encodes to 64 + 312 + 720 = 1096 bytes.
        big_image = deterministic_image(13, b"thirteen-page-image")
        distribution = [2, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 4]
        self.assertEqual(sum(distribution), 18)
        targets: list[tuple[int, list[tuple[int, int]]]] = []
        for page_index, site_count in enumerate(distribution):
            targets.append((page_index, [(0x40 * (site + 1), 4) for site in range(site_count)]))
        big_profile = make_profile_for_image(big_image, targets)
        self.assertEqual(big_profile.page_count, 13)
        self.assertEqual(big_profile.site_count, 18)
        self.assertEqual(len(V.encode(big_profile)), 1096)

    def test_build_field_encoding(self) -> None:
        self.assertEqual(V.encode_build_field("24H232"), b"24H232" + b"\x00" * 10)
        self.assertEqual(V.decode_build_field(b"24H232" + b"\x00" * 10), "24H232")

    def test_default_flags_constant(self) -> None:
        self.assertEqual(V.DEFAULT_MATCH_FLAGS, 0x0007)
        self.assertEqual(V.REQUIRED_MATCH_FLAGS, 0x0006)


# ---------------------------------------------------------------------------
# Structural error-vector tests (spec section 11 / 16.6)
# ---------------------------------------------------------------------------


class StructuralTests(ValidatorTestCase):
    def test_e001_truncated_header(self) -> None:
        self.expect_decode_code(self.profile_bytes[:63], "E001")

    def test_e002_bad_magic(self) -> None:
        self.expect_decode_code(self.mutate(self.profile_bytes, {0: b"NRPX"}), "E002")

    def test_e003_unsupported_version(self) -> None:
        # v2 is supported now; an unknown version must still be rejected as E003.
        self.expect_decode_code(self.mutate(self.profile_bytes, {4: V._p16(3)}), "E003")

    def test_e004_invalid_header_size(self) -> None:
        self.expect_decode_code(self.mutate(self.profile_bytes, {6: V._p16(63)}), "E004")

    def test_e005_invalid_build_variants(self) -> None:
        # empty build string (all NUL)
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {8: b"\x00" * 16}), "E005"
        )
        # 16 non-NUL bytes (no terminator)
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {8: b"24H232ABCDEFGHIJ"}), "E005"
        )
        # forbidden character
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {8: b"24!232".ljust(16, b"\x00")}), "E005"
        )
        # non-zero bytes after the first NUL
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {8: b"24H232" + b"\x00\x00\x01" + b"\x00" * 7}),
            "E005",
        )

    def test_e006_invalid_apu_mask(self) -> None:
        self.expect_decode_code(self.mutate(self.profile_bytes, {24: V._p32(0)}), "E006")
        self.expect_decode_code(self.mutate(self.profile_bytes, {24: V._p32(0x40)}), "E006")

    def test_e007_invalid_device_id_variants(self) -> None:
        # device ID non-zero without REQUIRE_DEVICE_ID
        self.expect_decode_code(self.mutate(self.profile_bytes, {28: V._p32(0x1638)}), "E007")
        # REQUIRE_DEVICE_ID with zero device ID
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {28: V._p32(0), 48: V._p32(1)}), "E007"
        )
        # REQUIRE_DEVICE_ID with out-of-range device ID
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {28: V._p32(0x10000), 48: V._p32(1)}), "E007"
        )
        # high bits of deviceID must be zero
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {28: V._p32(0x10000), 48: V._p32(0)}), "E007"
        )

    def test_e008_unsupported_header_flags(self) -> None:
        self.expect_decode_code(self.mutate(self.profile_bytes, {48: V._p32(2)}), "E008")

    def test_e009_header_reserved_not_zero(self) -> None:
        self.expect_decode_code(self.mutate(self.profile_bytes, {52: b"\x01"}), "E009")

    def test_e010_profile_too_large(self) -> None:
        oversized = self.profile_bytes + b"\x00" * (V.MAX_PROFILE_SIZE + 1 - len(self.profile_bytes))
        self.expect_decode_code(oversized, "E010")

    def test_e011_page_table_size_mismatch(self) -> None:
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {36: V._p32(len(self.profile.pages) * 24 + 8)}),
            "E011",
        )

    def test_e012_site_table_size_mismatch(self) -> None:
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {40: V._p32(self.profile.site_count * 40 + 8)}),
            "E012",
        )

    def test_e013_total_size_mismatch(self) -> None:
        self.expect_decode_code(self.profile_bytes + b"\x00", "E013")

    def test_e014_payload_checksum_mismatch(self) -> None:
        data = bytearray(self.profile_bytes)
        data[V.H_PAYLOAD_CHECKSUM] ^= 0xFF
        self.expect_decode_code(bytes(data), "E014")

    def test_e015_page_count_out_of_range(self) -> None:
        self.expect_decode_code(
            raw_profile(
                [{"offset": 0x1000, "hash": 1, "first": 0, "count": 1}],
                [simple_site(0x10, b"\x01\x02\x03\x04", b"\x01\x02\x03\x05")],
                page_count=V.MAX_PAGES + 1,
            ),
            "E015",
        )

    def test_e016_site_count_out_of_range(self) -> None:
        pages = [{"offset": 0x1000, "hash": 1, "first": 0, "count": 1}]
        sites = [simple_site(0x10, b"\x01\x02\x03\x04", b"\x01\x02\x03\x05")]
        self.expect_decode_code(raw_profile(pages, sites, site_count=0), "E016")
        self.expect_decode_code(raw_profile(pages, sites, site_count=V.MAX_SITES + 1), "E016")

    def test_e017_page_offset_misaligned(self) -> None:
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {self.page_record_offset(0): V._p64(0x2001)}),
            "E017",
        )

    def test_e018_unsupported_page_match_flags(self) -> None:
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {self.page_record_offset(0) + 22: V._p16(0x000E)}),
            "E018",
        )

    def test_e019_required_page_match_flag_missing(self) -> None:
        # offset + sites but no hash gate
        self.expect_decode_code(
            self.mutate(
                self.profile_bytes,
                {self.page_record_offset(0) + 22: V._p16(V.MATCH_REQUIRE_OFFSET | V.MATCH_REQUIRE_SITES)},
            ),
            "E019",
        )

    def test_e020_page_site_range_invalid(self) -> None:
        self.expect_decode_code(
            raw_profile(
                [
                    {"offset": 0x1000, "hash": 0x11, "first": 0, "count": 2},
                    {"offset": 0x2000, "hash": 0x22, "first": 2, "count": 3},
                ],
                [
                    simple_site(0x10, b"\x01\x02", b"\x01\x03"),
                    simple_site(0x20, b"\x04\x05", b"\x04\x06"),
                    simple_site(0x30, b"\x07\x08", b"\x07\x09"),
                    simple_site(0x40, b"\x0A\x0B", b"\x0A\x0C"),
                ],
            ),
            "E020",
        )

    def test_e021_non_canonical_site_range(self) -> None:
        self.expect_decode_code(
            raw_profile(
                [{"offset": 0x1000, "hash": 0x11, "first": 1, "count": 1}],
                [
                    simple_site(0x10, b"\x01\x02", b"\x01\x03"),
                    simple_site(0x20, b"\x04\x05", b"\x04\x06"),
                ],
            ),
            "E021",
        )

    def test_e022_site_count_sum_mismatch(self) -> None:
        self.expect_decode_code(
            raw_profile(
                [{"offset": 0x1000, "hash": 0x11, "first": 0, "count": 1}],
                [
                    simple_site(0x10, b"\x01\x02", b"\x01\x03"),
                    simple_site(0x20, b"\x04\x05", b"\x04\x06"),
                ],
            ),
            "E022",
        )

    def test_e023_sites_per_page_exceeded(self) -> None:
        self.expect_decode_code(
            raw_profile(
                [{"offset": 0x1000, "hash": 0x11, "first": 0, "count": 0}],
                [simple_site(0x10, b"\x01\x02", b"\x01\x03")],
            ),
            "E023",
        )

    def test_e024_invalid_site_patch_size(self) -> None:
        site_base = self.site_record_offset(0)
        self.expect_decode_code(self.mutate(self.profile_bytes, {site_base + 2: b"\x00"}), "E024")
        self.expect_decode_code(self.mutate(self.profile_bytes, {site_base + 2: b"\x11"}), "E024")

    def test_e025_find_replace_size_mismatch(self) -> None:
        site_base = self.site_record_offset(0)
        self.expect_decode_code(self.mutate(self.profile_bytes, {site_base + 3: b"\x07"}), "E025")

    def test_e026_site_out_of_page_bounds(self) -> None:
        site_base = self.site_record_offset(0)
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {site_base: V._p16(4095)}), "E026"
        )

    def test_e027_site_padding_not_zero(self) -> None:
        site = self.profile.pages[0].sites[0]
        site_base = self.site_record_offset(0)
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {site_base + 4 + site.find_size: b"\x01"}), "E027"
        )

    def test_e028_no_op_site(self) -> None:
        site = self.profile.pages[0].sites[0]
        site_base = self.site_record_offset(0)
        self.expect_decode_code(
            self.mutate(self.profile_bytes, {site_base + 20: site.find}), "E028"
        )

    def test_e029_unsupported_site_flags(self) -> None:
        site_base = self.site_record_offset(0)
        self.expect_decode_code(self.mutate(self.profile_bytes, {site_base + 36: V._p32(1)}), "E029")

    def test_e030_overlapping_site_writes(self) -> None:
        self.expect_decode_code(
            raw_profile(
                [{"offset": 0x1000, "hash": 0x11, "first": 0, "count": 2}],
                [
                    simple_site(0x100, b"\x01\x02\x03\x04\x05\x06\x07\x08", b"\x11\x02\x03\x04\x05\x06\x07\x08"),
                    simple_site(0x102, b"\x21\x22\x23\x24\x25\x26\x27\x28", b"\x31\x22\x23\x24\x25\x26\x27\x28"),
                ],
            ),
            "E030",
        )

    def test_e031_duplicate_page_identity(self) -> None:
        # Identical offset and hash.
        self.expect_decode_code(
            raw_profile(
                [
                    {"offset": 0x1000, "hash": 0xDEAD, "first": 0, "count": 1},
                    {"offset": 0x1000, "hash": 0xDEAD, "first": 1, "count": 1},
                ],
                [
                    simple_site(0x10, b"\x01\x02", b"\x01\x03"),
                    simple_site(0x20, b"\x04\x05", b"\x04\x06"),
                ],
            ),
            "E031",
        )
        # Identical hash, offset not required on one record.
        self.expect_decode_code(
            raw_profile(
                [
                    {"offset": 0x1000, "hash": 0xDEAD, "first": 0, "count": 1,
                     "match_flags": V.DEFAULT_MATCH_FLAGS},
                    {"offset": 0x2000, "hash": 0xDEAD, "first": 1, "count": 1,
                     "match_flags": V.MATCH_REQUIRE_HASH | V.MATCH_REQUIRE_SITES},
                ],
                [
                    simple_site(0x10, b"\x01\x02", b"\x01\x03"),
                    simple_site(0x20, b"\x04\x05", b"\x04\x06"),
                ],
            ),
            "E031",
        )

    def test_same_hash_different_offsets_is_legal(self) -> None:
        data = raw_profile(
            [
                {"offset": 0x1000, "hash": 0xDEAD, "first": 0, "count": 1},
                {"offset": 0x2000, "hash": 0xDEAD, "first": 1, "count": 1},
            ],
            [
                simple_site(0x10, b"\x01\x02", b"\x01\x03"),
                simple_site(0x20, b"\x04\x05", b"\x04\x06"),
            ],
        )
        profile = V.decode(data)
        self.assertEqual(profile.page_count, 2)

    def test_e032_empty_profile(self) -> None:
        COVERED_CODES.add("E032")
        with self.assertRaises(V.NRPTCodecError) as context:
            V.encode(V.Profile(header=V.Header(build="24H232", apu_mask=0x28, device_id=0), pages=[]))
        self.assertEqual(context.exception.code, "E032")
        # Decoding a zero-page header is also rejected as emptyProfile.
        data = raw_profile([], [simple_site(0x10, b"\x01\x02", b"\x01\x03")], page_count=0)
        self.expect_decode_code(data, "E032")

    def test_encode_model_limits(self) -> None:
        # E005: 16-byte build string
        self.expect_encode_code(
            V.Profile(
                header=V.Header(build="A" * 16, apu_mask=0x28, device_id=0),
                pages=[V.Page(0x1000, 0x11, V.DEFAULT_MATCH_FLAGS,
                              [V.Site(0x10, b"\x01\x02", b"\x01\x03")])],
            ),
            "E005",
        )
        # E006: unknown APU bit
        self.expect_encode_code(
            V.Profile(
                header=V.Header(build="24H232", apu_mask=0x40, device_id=0),
                pages=[V.Page(0x1000, 0x11, V.DEFAULT_MATCH_FLAGS,
                              [V.Site(0x10, b"\x01\x02", b"\x01\x03")])],
            ),
            "E006",
        )
        # E018: unknown match flag bit
        self.expect_encode_code(
            V.Profile(
                header=V.Header(build="24H232", apu_mask=0x28, device_id=0),
                pages=[V.Page(0x1000, 0x11, 0x0F,
                              [V.Site(0x10, b"\x01\x02", b"\x01\x03")])],
            ),
            "E018",
        )
        # E015: 257 pages
        many_pages = [
            V.Page(index * V.PAGE_SIZE, index + 1, V.DEFAULT_MATCH_FLAGS,
                   [V.Site(0x10, b"\x01\x02", b"\x01\x03")])
            for index in range(V.MAX_PAGES + 1)
        ]
        self.expect_encode_code(
            V.Profile(header=V.Header(build="24H232", apu_mask=0x28, device_id=0),
                      pages=many_pages),
            "E015",
        )
        # E016: > 1024 total sites
        many_sites_pages = []
        for page_index in range(18):
            sites = [
                V.Site(0x40 + site_index * 8, bytes((page_index, site_index, 1)),
                       bytes((page_index, site_index, 2)))
                for site_index in range(60)
            ]
            many_sites_pages.append(
                V.Page(page_index * V.PAGE_SIZE, page_index + 1, V.DEFAULT_MATCH_FLAGS, sites)
            )
        self.assertGreater(
            sum(len(page.sites) for page in many_sites_pages), V.MAX_SITES
        )
        self.expect_encode_code(
            V.Profile(header=V.Header(build="24H232", apu_mask=0x28, device_id=0),
                      pages=many_sites_pages),
            "E016",
        )
        # E023: 65 sites on one page
        too_many_sites = [
            V.Site(0x40 + site_index * 8, bytes((site_index, 1)), bytes((site_index, 2)))
            for site_index in range(V.MAX_SITES_PER_PAGE + 1)
        ]
        self.expect_encode_code(
            V.Profile(
                header=V.Header(build="24H232", apu_mask=0x28, device_id=0),
                pages=[V.Page(0x1000, 0x11, V.DEFAULT_MATCH_FLAGS, too_many_sites)],
            ),
            "E023",
        )


# ---------------------------------------------------------------------------
# Kext-algorithm semantics (spec section 8)
# ---------------------------------------------------------------------------


class ApplicationTests(ValidatorTestCase):
    def test_apply_page_writes_only_replace_bytes(self) -> None:
        page_index = 0
        page = self.profile.pages[page_index]
        clean = page_of(IMAGE_A, 2)
        applied: set[int] = set()
        result = V.apply_chunk(self.profile, clean, page.page_file_offset, applied)
        self.assertEqual(result.status, "applied")
        self.assertEqual(result.page_index, page_index)
        changed = {offset for offset in range(V.PAGE_SIZE) if clean[offset] != result.data[offset]}
        expected: set[int] = set()
        for site in page.sites:
            for index, (before, after) in enumerate(zip(site.find, site.replace)):
                if before != after:
                    expected.add(site.site_in_page + index)
        self.assertEqual(changed, expected)
        for site in page.sites:
            start = site.site_in_page
            self.assertEqual(
                result.data[start : start + site.replace_size], site.replace
            )
        self.assertEqual(applied, {page_index})

    def test_hash_gate_rejects_mutated_page(self) -> None:
        page = self.profile.pages[0]
        mutated = bytearray(page_of(IMAGE_A, 2))
        mutated[0] ^= 0xFF
        applied: set[int] = set()
        result = V.apply_chunk(self.profile, bytes(mutated), page.page_file_offset, applied)
        self.assertEqual(result.status, "noMatch")
        self.assertEqual(applied, set())

    def test_offset_gate(self) -> None:
        page = self.profile.pages[0]
        clean = page_of(IMAGE_A, 2)
        # wrong base offset -> rejected when REQUIRE_OFFSET is set
        applied: set[int] = set()
        result = V.apply_chunk(self.profile, clean, page.page_file_offset + V.PAGE_SIZE, set())
        self.assertEqual(result.status, "noMatch")
        # unaligned base offset -> rejected
        result = V.apply_chunk(self.profile, clean, page.page_file_offset + 1, set())
        self.assertEqual(result.status, "noMatch")
        # clearing REQUIRE_OFFSET makes content alone authoritative
        profile = V.Profile(
            header=self.profile.header,
            pages=[V.Page(page.page_file_offset, page.page_hash,
                          V.MATCH_REQUIRE_HASH | V.MATCH_REQUIRE_SITES, page.sites)],
        )
        result = V.apply_chunk(profile, clean, 0xDEAD0000, set())
        self.assertEqual(result.status, "applied")
        self.assertEqual(result.data, V.apply_chunk(profile, clean, None, set()).data)

    def test_site_mismatch_is_atomic(self) -> None:
        page = self.profile.pages[1]  # two sites
        broken_sites = [
            V.Site(page.sites[0].site_in_page, page.sites[0].find, page.sites[0].replace),
            V.Site(page.sites[1].site_in_page, b"\xAA\xBB\xCC", b"\xAA\xBB\xCD"),
        ]
        broken_profile = V.Profile(
            header=self.profile.header,
            pages=[V.Page(5 * V.PAGE_SIZE, page.page_hash, V.DEFAULT_MATCH_FLAGS, broken_sites)],
        )
        clean = page_of(IMAGE_A, 5)
        applied: set[int] = set()
        result = V.apply_chunk(broken_profile, clean, 5 * V.PAGE_SIZE, applied)
        self.assertEqual(result.status, "siteFindMismatch")
        self.assertEqual(result.page_index, 0)
        self.assertEqual(result.site_index, 1)
        self.assertIsNone(result.data)
        self.assertEqual(applied, set())

    def test_applied_once(self) -> None:
        page = self.profile.pages[0]
        clean = page_of(IMAGE_A, 2)
        applied: set[int] = set()
        first = V.apply_chunk(self.profile, clean, page.page_file_offset, applied)
        self.assertEqual(first.status, "applied")
        second = V.apply_chunk(self.profile, clean, page.page_file_offset, applied)
        self.assertEqual(second.status, "alreadyApplied")
        self.assertIsNone(second.data)

    def test_first_matching_record_is_authoritative(self) -> None:
        # Two records with the same hash but different offsets are a legal canonical profile.
        page = self.profile.pages[0]
        broken_first = V.Page(
            page.page_file_offset,
            page.page_hash,
            V.DEFAULT_MATCH_FLAGS,
            [V.Site(page.sites[0].site_in_page, b"\xAA\xBB\xCC", b"\xAA\xBB\xCD")],
        )
        second = V.Page(
            page.page_file_offset + V.PAGE_SIZE,
            page.page_hash,
            V.DEFAULT_MATCH_FLAGS,
            [V.Site(page.sites[0].site_in_page, b"\x01\x02\x03", b"\x01\x02\x04")],
        )
        profile = V.Profile(header=self.profile.header, pages=[broken_first, second])
        clean = page_of(IMAGE_A, 2)
        applied: set[int] = set()
        result = V.apply_chunk(profile, clean, page.page_file_offset, applied)
        # The first identity-matched record fails its find check; no fallback to record 1.
        self.assertEqual(result.status, "siteFindMismatch")
        self.assertEqual(result.page_index, 0)
        self.assertEqual(applied, set())

    def test_non_page_input_is_ignored(self) -> None:
        result = V.apply_chunk(self.profile, b"\x00" * 1024, 0, set())
        self.assertEqual(result.status, "noMatch")

    def test_range_delivery(self) -> None:
        # Range covering image pages 2..8: records target pages 2, 5 and 8.
        range_base = 2 * V.PAGE_SIZE
        range_data = IMAGE_A[range_base : 9 * V.PAGE_SIZE]
        applied: set[int] = set()
        results = V.apply_range(self.profile, range_data, range_base, applied)
        self.assertEqual(len(results), 7)
        statuses = [result.status for result in results]
        self.assertEqual(statuses[0], "applied")
        self.assertEqual(statuses[3], "applied")
        self.assertEqual(statuses[6], "applied")
        for index in (1, 2, 4, 5):
            self.assertEqual(statuses[index], "noMatch")
        self.assertEqual(applied, {0, 1, 2})

    def test_range_ignores_trailing_partial_chunk(self) -> None:
        range_base = 2 * V.PAGE_SIZE
        range_data = IMAGE_A[range_base : 9 * V.PAGE_SIZE] + b"\x00" * 100
        results = V.apply_range(self.profile, range_data, range_base, set())
        self.assertEqual(len(results), 7)


# ---------------------------------------------------------------------------
# Fixture resolution and end-to-end offline validation
# ---------------------------------------------------------------------------


class OfflineValidationTests(ValidatorTestCase):
    def validate(self, **kwargs) -> dict:
        return V.validate_profile_against_fixture(
            kwargs.pop("profile", self.profile),
            self.images,
            profile_path="synthetic.nrpt",
            profile_bytes=kwargs.pop("profile_bytes", self.profile_bytes),
            fixture_root=self.fixture_root,
            expected_build="24H232",
            device_id=0x1638,
            **kwargs,
        )

    def test_end_to_end_pass(self) -> None:
        report = self.validate(mutation_sweep=True)
        self.assertEqual(report["result"], "PASS")
        self.assertEqual(report["summary"]["intendedPages"], 3)
        self.assertEqual(report["summary"]["appliedPages"], 3)
        self.assertEqual(report["summary"]["intendedSites"], 4)
        self.assertEqual(report["summary"]["reportedSites"], 4)
        self.assertEqual(report["summary"]["siteFindMismatches"], 0)
        self.assertEqual(report["summary"]["falsePositives"], 0)
        self.assertEqual(report["identity"]["build"]["status"], "pass")
        self.assertEqual(report["identity"]["apuAndDevice"]["status"], "pass")
        for page in report["pages"]:
            self.assertEqual(page["status"], "applied")
            self.assertNotEqual(page["patchedPageHash"], page["cleanPageHash"])
            self.assertEqual(page["secondDelivery"], "alreadyApplied")
            for site in page["sites"]:
                self.assertTrue(site["findMatched"])
                self.assertTrue(site["written"])
                self.assertNotEqual(site["findHex"], site["replaceHex"])
        self.assertEqual(len(report["mutationSweep"]), 3)
        self.assertTrue(all(not entry["wrote"] for entry in report["mutationSweep"]))
        self.assertTrue(report["falsePositiveChecks"])
        self.assertTrue(all(check["status"] == "pass" for check in report["falsePositiveChecks"]))
        self.assertTrue(report["rangeSimulation"])
        self.assertTrue(all(sim["status"] == "pass" for sim in report["rangeSimulation"]))

    def test_report_is_deterministic(self) -> None:
        report_a = self.validate()
        report_b = self.validate()
        self.assertEqual(
            json.dumps(report_a, sort_keys=True), json.dumps(report_b, sort_keys=True)
        )

    def test_wrong_expected_build_rejected(self) -> None:
        with self.assertRaises(V.ValidationFailure):
            V.validate_profile_against_fixture(
                self.profile,
                self.images,
                profile_path="synthetic.nrpt",
                profile_bytes=self.profile_bytes,
                fixture_root=self.fixture_root,
                expected_build="25A123",
                device_id=0x1638,
            )

    def test_wrong_device_apu_gate_rejected(self) -> None:
        profile = make_profile_for_image(
            IMAGE_A,
            [(2, [(0x100, 6)])],
            apu_mask=V.APU_RAVEN,  # no intersection with 0x1638 candidate mask (Renoir|GS)
        )
        with self.assertRaises(V.ValidationFailure):
            V.validate_profile_against_fixture(
                profile,
                self.images,
                profile_path="synthetic.nrpt",
                profile_bytes=V.encode(profile),
                fixture_root=self.fixture_root,
                expected_build="24H232",
                device_id=0x1638,
            )

    def test_require_device_id_mismatch_rejected(self) -> None:
        image = deterministic_image(1, b"device-gate")
        profile = V.Profile(
            header=V.Header(
                build="24H232",
                apu_mask=V.APU_RENOIR | V.APU_GREEN_SARDINE,
                device_id=0x15DD,  # Raven, != running 0x1638
                flags=V.HEADER_FLAG_REQUIRE_DEVICE_ID,
            ),
            pages=[V.Page(0, V.fnv1a64(page_of(image, 0)), V.DEFAULT_MATCH_FLAGS,
                          [make_site(page_of(image, 0), 0x100, 4)])],
        )
        with self.assertRaises(V.ValidationFailure):
            V.validate_profile_against_fixture(
                profile,
                self.images,
                profile_path="synthetic.nrpt",
                profile_bytes=V.encode(profile),
                fixture_root=self.fixture_root,
                expected_build="24H232",
                device_id=0x1638,
            )

    def test_unresolved_page_rejected(self) -> None:
        page = self.profile.pages[0]
        fake_hash = page.page_hash ^ 0xFFFFFFFFFFFFFFFF
        mutated = self.mutate(
            self.profile_bytes,
            {self.page_record_offset(0) + 8: V._p64(fake_hash)},
        )
        profile = V.decode(mutated)
        with self.assertRaises(V.ValidationFailure):
            self.validate(profile=profile, profile_bytes=mutated)

    def test_hash_only_record_resolution_and_ambiguity(self) -> None:
        # Duplicate a page of image A into two candidate images: hash-only identity becomes
        # ambiguous because the same 4 KiB content occurs at two different file offsets.
        target_page = page_of(IMAGE_A, 2)
        duplicated_gl = deterministic_image(2, b"hash-only-gl") + target_page
        duplicated_mtl = deterministic_image(1, b"hash-only-mtl") + target_page
        with tempfile.TemporaryDirectory(prefix="nrpt-ambiguous-") as root:
            write_fixture(root, {GL_DRIVER_REL: duplicated_gl, MTL_DRIVER_REL: duplicated_mtl})
            ambiguous_images = V.discover_images(root)
            page = self.profile.pages[0]
            hash_only = V.Page(page.page_file_offset, page.page_hash,
                               V.MATCH_REQUIRE_HASH | V.MATCH_REQUIRE_SITES, page.sites)
            profile = V.Profile(header=self.profile.header, pages=[hash_only])
            matches = V.resolve_page(hash_only, ambiguous_images)
            self.assertEqual(len(matches), 2)
            with self.assertRaises(V.ValidationFailure):
                V.validate_profile_against_fixture(
                    profile,
                    ambiguous_images,
                    profile_path="ambiguous.nrpt",
                    profile_bytes=V.encode(profile),
                    fixture_root=root,
                    expected_build="24H232",
                    device_id=0x1638,
                )
        # Without the duplicate, the same hash-only record resolves and applies.
        page = self.profile.pages[0]
        hash_only = V.Page(page.page_file_offset, page.page_hash,
                           V.MATCH_REQUIRE_HASH | V.MATCH_REQUIRE_SITES, page.sites)
        report = V.validate_profile_against_fixture(
            V.Profile(header=self.profile.header, pages=[hash_only]),
            self.images,
            profile_path="hash-only.nrpt",
            profile_bytes=V.encode(V.Profile(header=self.profile.header, pages=[hash_only])),
            fixture_root=self.fixture_root,
            expected_build="24H232",
            device_id=0x1638,
        )
        self.assertEqual(report["result"], "PASS")

    def test_content_duplicate_analysis_with_offset_gate(self) -> None:
        # Identical 4 KiB content in two images at different offsets: an offset-gated identity is
        # unambiguous (different chunk base), but the duplicate must be reported as evidence.
        target = page_of(IMAGE_A, 2)
        duplicate_image = deterministic_image(1, b"duplicate-content-mtl") + target
        with tempfile.TemporaryDirectory(prefix="nrpt-duplicate-") as root:
            write_fixture(root, {GL_DRIVER_REL: IMAGE_A, MTL_DRIVER_REL: duplicate_image})
            images = V.discover_images(root)
            profile = make_profile_for_image(IMAGE_A, [(2, [(0x100, 6)])])
            report = V.validate_profile_against_fixture(
                profile,
                images,
                profile_path="duplicate.nrpt",
                profile_bytes=V.encode(profile),
                fixture_root=root,
                expected_build="24H232",
                device_id=0x1638,
                duplicate_content_scan=True,
            )
            self.assertEqual(report["result"], "PASS")
            self.assertEqual(report["hashScan"]["mode"], "python")
            self.assertEqual(len(report["duplicateContent"]), 1)
            duplicate = report["duplicateContent"][0]
            self.assertTrue(duplicate["requiresOffset"])
            self.assertFalse(duplicate["identityAmbiguous"])
            self.assertEqual(len(duplicate["unintendedIdenticalContent"]), 1)
            self.assertEqual(duplicate["unintendedIdenticalContent"][0]["image"],
                             os.path.basename(MTL_DRIVER_REL))
            self.assertTrue(any("byte-identical content" in warning for warning in report["warnings"]))

    def test_cli_end_to_end(self) -> None:
        with tempfile.TemporaryDirectory(prefix="nrpt-cli-") as workdir:
            profile_path = os.path.join(workdir, "synthetic.nrpt")
            report_path = os.path.join(workdir, "report.json")
            with open(profile_path, "wb") as handle:
                handle.write(self.profile_bytes)
            command = [
                sys.executable,
                os.path.join(os.path.dirname(os.path.abspath(__file__)), "nrpt_validator.py"),
                "--profile",
                profile_path,
                "--fixtures",
                self.fixture_root,
                "--expected-build",
                "24H232",
                "--device-id",
                "0x1638",
                "--report",
                report_path,
                "--mutation-sweep",
                "--quiet",
            ]
            completed = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            with open(report_path, encoding="utf-8") as handle:
                report = json.load(handle)
            self.assertEqual(report["result"], "PASS")
            # A structurally broken profile must exit nonzero and print the stable code.
            corrupted = bytearray(self.profile_bytes)
            corrupted[0] = 0
            corrupted_path = os.path.join(workdir, "corrupted.nrpt")
            with open(corrupted_path, "wb") as handle:
                handle.write(bytes(corrupted))
            completed = subprocess.run(
                [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                              "nrpt_validator.py"),
                 "--profile", corrupted_path, "--fixtures", self.fixture_root, "--quiet"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 1)
            self.assertIn("E002", completed.stderr)


# ---------------------------------------------------------------------------
# Cross-implementation golden fixture (spec section 16.9)
# ---------------------------------------------------------------------------

GOLDEN_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden",
                           "synthetic-2page.nrpt")
GOLDEN_SHA256 = "eacb108ff1f88f4d2c3b7de5b37e2f5f3a9f4764ec9a2425e11326b5f59c0e70"


def golden_model() -> V.Profile:
    return V.Profile(
        header=V.Header(build="24H232", apu_mask=0x28, device_id=0),
        pages=[
            V.Page(
                page_file_offset=0xE000,
                page_hash=0xE18DB215D6994568,
                match_flags=V.DEFAULT_MATCH_FLAGS,
                sites=[V.Site(0x0081, bytes.fromhex("c7477804000000"),
                              bytes.fromhex("c7477801000000"))],
            ),
            V.Page(
                page_file_offset=0x1000,
                page_hash=0x1111222233334444,
                match_flags=V.MATCH_REQUIRE_HASH | V.MATCH_REQUIRE_SITES,
                sites=[
                    V.Site(0x0160, bytes.fromhex("83e0fe"), bytes.fromhex("83c801")),
                    V.Site(0x0200, bytes.fromhex("750b"), bytes.fromhex("eb0b")),
                ],
            ),
        ],
    )


class GoldenParityTests(unittest.TestCase):
    def test_reference_codec_golden_is_byte_identical(self) -> None:
        with open(GOLDEN_PATH, "rb") as handle:
            golden = handle.read()
        self.assertEqual(len(golden), 232)
        self.assertEqual(hashlib.sha256(golden).hexdigest(), GOLDEN_SHA256)
        self.assertEqual(V.decode(golden), golden_model())
        # The independent Python encoder must reproduce the reference codec's bytes exactly.
        self.assertEqual(V.encode(golden_model()), golden)
        # And a decode/encode round trip must be a byte-level no-op.
        self.assertEqual(V.encode(V.decode(golden)), golden)


# ---------------------------------------------------------------------------
# Full-fixture hash scan helper (native C accelerator with Python fallback)
# ---------------------------------------------------------------------------


class HashScanHelperTests(unittest.TestCase):
    def test_native_scan_matches_python_scan(self) -> None:
        binary = V.native_hash_scan_binary()
        if binary is None:
            self.skipTest("no C compiler available for the native hash scan helper")
        with tempfile.TemporaryDirectory(prefix="nrpt-scan-") as root:
            write_fixture(root, {GL_DRIVER_REL: IMAGE_A, MTL_DRIVER_REL: IMAGE_B})
            images = V.discover_images(root)
            queries = {
                V.fnv1a64(page_of(IMAGE_A, 0)),
                V.fnv1a64(page_of(IMAGE_A, 3)),
                V.fnv1a64(page_of(IMAGE_A, 7)),
                V.fnv1a64(page_of(IMAGE_B, 1)),
            }
            python_results = V.python_page_hash_scan(images, queries)
            native_results = V.native_page_hash_scan(images, queries, binary)
            self.assertIsNotNone(native_results)
            self.assertEqual(native_results, python_results)
            # Each queried page occurs exactly once in exactly one image.
            for query in queries:
                self.assertEqual(len(python_results[query]), 1)

    def test_scan_mode_selection(self) -> None:
        with tempfile.TemporaryDirectory(prefix="nrpt-scan-mode-") as root:
            write_fixture(root, {GL_DRIVER_REL: IMAGE_A})
            images = V.discover_images(root)
            query = V.fnv1a64(page_of(IMAGE_A, 2))
            results, mode = V.scan_fixture_page_hashes(images, {query})
            self.assertEqual(mode, "python")  # tiny fixture: never compiles the helper
            self.assertEqual(results[query], [(images[0].path, 2 * V.PAGE_SIZE)])

    def test_discover_images_excludes_atlas_and_map(self) -> None:
        with tempfile.TemporaryDirectory(prefix="nrpt-atlas-") as root:
            write_fixture(root, {GL_DRIVER_REL: IMAGE_A})
            dyld_dir = os.path.join(root, "System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld")
            os.makedirs(dyld_dir, exist_ok=True)
            with open(os.path.join(dyld_dir, "dyld_shared_cache_x86_64h.atlas"), "wb") as handle:
                handle.write(b"AA01not-a-cache" + b"\x00" * (V.PAGE_SIZE))
            with open(os.path.join(dyld_dir, "dyld_shared_cache_x86_64h.map"), "wb") as handle:
                handle.write(b"z" * V.PAGE_SIZE)
            images = V.discover_images(root)
            self.assertEqual([image.name for image in images],
                             [os.path.basename(GL_DRIVER_REL)])


# ---------------------------------------------------------------------------
# Cross-engine golden vectors (independent C++ engine harness, synthetic data)
# ---------------------------------------------------------------------------

CROSSCHECK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden",
                              "engine-crosscheck")


class CrossEngineGoldenTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        with open(os.path.join(CROSSCHECK_DIR, "golden.nrpt"), "rb") as handle:
            cls.profile_bytes = handle.read()
        cls.profile = V.decode(cls.profile_bytes)
        cls.pages = []
        cls.patched = []
        for index in (0, 1):
            with open(os.path.join(CROSSCHECK_DIR, f"golden.page{index}.bin"), "rb") as handle:
                cls.pages.append(handle.read())
            with open(os.path.join(CROSSCHECK_DIR, f"golden.page{index}.patched.bin"), "rb") as handle:
                cls.patched.append(handle.read())

    def test_profile_shape(self) -> None:
        self.assertEqual(len(self.profile_bytes), 64 + 2 * 24 + 3 * 40)
        self.assertEqual(self.profile.header.build, "24H232")
        self.assertEqual(self.profile.header.apu_mask, 0x20)
        self.assertEqual(self.profile.header.device_id, 0x1638)
        self.assertEqual(self.profile.header.flags, V.HEADER_FLAG_REQUIRE_DEVICE_ID)
        self.assertEqual(self.profile.page_count, 2)
        self.assertEqual(self.profile.site_count, 3)
        self.assertTrue(self.profile.pages[0].match_flags & V.MATCH_REQUIRE_OFFSET)
        self.assertFalse(self.profile.pages[1].match_flags & V.MATCH_REQUIRE_OFFSET)

    def test_engine_output_is_byte_identical(self) -> None:
        applied: set[int] = set()
        result0 = V.apply_chunk(self.profile, self.pages[0], 0x8000, applied)
        self.assertEqual(result0.status, "applied")
        self.assertEqual(result0.page_index, 0)
        self.assertEqual(result0.data, self.patched[0])
        result1 = V.apply_chunk(self.profile, self.pages[1], 0x9000, applied)
        self.assertEqual(result1.status, "applied")
        self.assertEqual(result1.page_index, 1)
        self.assertEqual(result1.data, self.patched[1])
        self.assertEqual(applied, {0, 1})

    def test_repeat_delivery_writes_nothing(self) -> None:
        applied: set[int] = set()
        self.assertEqual(V.apply_chunk(self.profile, self.pages[0], 0x8000, applied).status, "applied")
        repeat = V.apply_chunk(self.profile, self.pages[0], 0x8000, applied)
        self.assertEqual(repeat.status, "alreadyApplied")
        self.assertIsNone(repeat.data)

    def test_offset_gate_on_page0_and_content_identity_on_page1(self) -> None:
        # Page 0 requires the exact offset; same content at a different chunk base is not ours.
        result = V.apply_chunk(self.profile, self.pages[0], 0x8000 + V.PAGE_SIZE, set())
        self.assertEqual(result.status, "noMatch")
        # Page 1 has no REQUIRE_OFFSET: content alone matches regardless of chunk base.
        result = V.apply_chunk(self.profile, self.pages[1], 0xDEAD0000, {0})
        self.assertEqual(result.status, "applied")
        self.assertEqual(result.page_index, 1)


# ---------------------------------------------------------------------------
# NRPT v2: synthetic image builders, codec/structural tests, metadata re-resolution
# ---------------------------------------------------------------------------


def encode_macho(segments: list[dict]) -> bytes:
    """Build a minimal 64-bit Mach-O with LC_SEGMENT_64 commands (synthetic fixture data)."""
    commands = bytearray()
    for segment in segments:
        sections = segment.get("sections", [])
        command_size = 72 + len(sections) * 80
        commands += (0x19).to_bytes(4, "little") + command_size.to_bytes(4, "little")
        commands += segment["name"].encode().ljust(16, b"\x00")
        commands += segment["vmaddr"].to_bytes(8, "little") + segment["vmsize"].to_bytes(8, "little")
        commands += segment.get("fileoff", 0).to_bytes(8, "little")
        commands += segment.get("filesize", segment["vmsize"]).to_bytes(8, "little")
        commands += b"\x00" * 8  # maxprot/initprot
        commands += len(sections).to_bytes(4, "little") + b"\x00" * 4
        for section in sections:
            commands += section["name"].encode().ljust(16, b"\x00")
            commands += segment["name"].encode().ljust(16, b"\x00")
            commands += section["addr"].to_bytes(8, "little") + section["size"].to_bytes(8, "little")
            commands += section.get("offset", 0).to_bytes(4, "little") + b"\x00" * 28
        assert len(commands) >= command_size
    header = bytearray()
    header += (0xFEEDFACF).to_bytes(4, "little")
    header += (0x01000007).to_bytes(4, "little")  # CPU_TYPE_X86_64
    header += (3).to_bytes(4, "little")  # CPU_SUBTYPE_X86_64_ALL
    header += (6).to_bytes(4, "little")  # MH_DYLIB
    header += len(segments).to_bytes(4, "little")
    header += len(commands).to_bytes(4, "little")
    header += b"\x00" * 8  # flags + reserved (mach_header_64 is 32 bytes)
    return bytes(header + commands)


GL_FIXTURE_REL = "System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver"
MTL_FIXTURE_REL = "System/Library/Extensions/AMDRadeonX5000MTLDriver.bundle/Contents/MacOS/AMDRadeonX5000MTLDriver"
CACHE_FIXTURE_REL = "System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64h"


def build_synthetic_v2_fixture(root: str) -> tuple[V.Profile, bytes]:
    """Create a clean fixture (one standalone Mach-O + one dyld-cache image) and its v2 profile."""
    gl_page = deterministic_page(b"synthetic-v2-gl-page")
    mtl_page = deterministic_page(b"synthetic-v2-mtl-page")
    gl_macho = encode_macho(
        [
            {"name": "__TEXT", "vmaddr": 0, "vmsize": 0x4000, "fileoff": 0,
             "sections": [{"name": "__text", "addr": 0, "size": 0x4000, "offset": 0}]},
            {"name": "__LINKEDIT", "vmaddr": 0x4000, "vmsize": 0x1000, "fileoff": 0x4000,
             "sections": []},
        ]
    )
    gl_file = bytearray(0x4000)
    gl_file[0 : len(gl_macho)] = gl_macho
    gl_file[0x1000 : 0x2000] = gl_page
    write_fixture(root, {GL_FIXTURE_REL: bytes(gl_file)})

    cache_path = "/System/Library/Extensions/AMDRadeonX5000MTLDriver.bundle/Contents/MacOS/" \
                 "AMDRadeonX5000MTLDriver"
    cache = bytearray(0x4000)
    cache[0:16] = b"dyld_v1 x86_64h\x00"
    cache[0x10:0x14] = (0x228).to_bytes(4, "little")
    cache[0x14:0x18] = (1).to_bytes(4, "little")
    cache[0x228:0x230] = (0x7FFB00000000).to_bytes(8, "little")
    cache[0x230:0x238] = (0x4000).to_bytes(8, "little")
    cache[0x238:0x240] = (0).to_bytes(8, "little")
    cache[0x88:0x90] = (0x300).to_bytes(8, "little")
    cache[0x90:0x98] = (1).to_bytes(8, "little")
    image_text_array = bytearray(32)
    image_text_array[16:24] = (0x7FFB00001000).to_bytes(8, "little")
    image_text_array[24:28] = (0x2000).to_bytes(4, "little")
    image_text_array[28:32] = (0x320).to_bytes(4, "little")
    cache[0x300:0x320] = image_text_array
    encoded_path = cache_path.encode()
    cache[0x320 : 0x320 + len(encoded_path)] = encoded_path
    cache_macho = encode_macho(
        [{"name": "__TEXT", "vmaddr": 0x7FFB00001000, "vmsize": 0x2000, "fileoff": 0x1000,
          "sections": [{"name": "__text", "addr": 0x7FFB00001000, "size": 0x2000, "offset": 0x1000}]}]
    )
    cache[0x1000 : 0x1000 + len(cache_macho)] = cache_macho
    cache[0x2000:0x3000] = mtl_page
    write_fixture(root, {CACHE_FIXTURE_REL: bytes(cache)})

    images = [
        V.Image(kind=V.IMAGE_KIND_STANDALONE, path="/" + GL_FIXTURE_REL, unslid_vmaddr=0,
                vm_size=0x4000, segments=["__TEXT", "__LINKEDIT"], sections=["__text"]),
        V.Image(kind=V.IMAGE_KIND_SHARED_CACHE, path=cache_path, unslid_vmaddr=0x7FFB00001000,
                vm_size=0x2000, segments=["__TEXT"], sections=["__text"]),
    ]
    pages = [
        V.Page(page_file_offset=0x1000, page_hash=V.fnv1a64(gl_page),
               match_flags=V.DEFAULT_MATCH_FLAGS,
               sites=[make_site(gl_page, 0x100, 6)], image_index=0, page_vm_offset=0x1000),
        V.Page(page_file_offset=0x2000, page_hash=V.fnv1a64(mtl_page),
               match_flags=V.DEFAULT_MATCH_FLAGS,
               sites=[make_site(mtl_page, 0x200, 3)], image_index=1, page_vm_offset=0x1000),
    ]
    profile = V.Profile(
        header=V.Header(build="24H232", apu_mask=0x28, device_id=0, version=V.VERSION_V2),
        pages=pages, version=V.VERSION_V2, images=images,
    )
    return profile, V.encode(profile)


def v2_structural_model() -> V.Profile:
    """Small valid v2 profile with short synthetic paths (structural/E-code tests)."""
    site = V.Site(0x100, b"\x01\x02\x03\x04", b"\x01\x02\x03\x05")
    images = [
        V.Image(kind=V.IMAGE_KIND_STANDALONE, path="/A", unslid_vmaddr=0, vm_size=0x2000,
                segments=["__TEXT"], sections=["__text"]),
        V.Image(kind=V.IMAGE_KIND_STANDALONE, path="/B", unslid_vmaddr=0, vm_size=0x2000,
                segments=["__TEXT"], sections=["__text"]),
    ]
    pages = [
        V.Page(page_file_offset=0x1000, page_hash=0x1111, match_flags=V.DEFAULT_MATCH_FLAGS,
               sites=[V.Site(0x100, b"\x11\x12", b"\x11\x13")], image_index=0, page_vm_offset=0x1000),
        V.Page(page_file_offset=0x3000, page_hash=0x2222, match_flags=V.DEFAULT_MATCH_FLAGS,
               sites=[V.Site(0x200, b"\x21\x22", b"\x21\x23")], image_index=1, page_vm_offset=0x1000),
    ]
    return V.Profile(
        header=V.Header(build="24H232", apu_mask=0x28, device_id=0, version=V.VERSION_V2),
        pages=pages, version=V.VERSION_V2, images=images,
    )


class V2CodecTests(unittest.TestCase):
    def test_v2_round_trip_and_size(self) -> None:
        model = v2_structural_model()
        data = V.encode(model)
        self.assertEqual(len(data), 64 + 2 * 32 + 2 * 40 + model.image_table_size)
        self.assertEqual(V.decode(data), model)
        self.assertEqual(V.encode(V.decode(data)), data)
        self.assertEqual(V.encode(model), data)
        self.assertEqual(data[4:6], (2).to_bytes(2, "little"))

    def test_v1_and_v2_are_distinct(self) -> None:
        v1 = V.encode(base_profile())
        self.assertEqual(V.decode(v1).version, V.VERSION_V1)
        v2 = V.encode(v2_structural_model())
        self.assertEqual(V.decode(v2).version, V.VERSION_V2)
        self.assertNotEqual(len(v1), len(v2))

    def test_v2_image_table_model_limits(self) -> None:
        model = v2_structural_model()
        model.images[0].flags = 0
        with self.assertRaises(V.NRPTCodecError) as context:
            V.encode(model)
        self.assertEqual(context.exception.code, "E035")


class V2StructuralTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.model = v2_structural_model()
        cls.base = V.encode(cls.model)
        cls.page_table_base = 64
        cls.image_table_base = 64 + 2 * 32 + 2 * 40
        cls.image1_base = cls.image_table_base + cls.model.images[0].entry_size

    def mutate(self, changes: dict[int, bytes], *, append: bytes = b"", fix_checksum: bool = True) -> bytes:
        data = bytearray(self.base + append)
        for offset, replacement in changes.items():
            data[offset : offset + len(replacement)] = replacement
        if fix_checksum:
            data[44:48] = V._p32(V.fnv1a32(bytes(data[64:])))
        return bytes(data)

    def expect_code(self, data: bytes, code: str) -> None:
        COVERED_CODES.add(code)
        with self.assertRaises(V.NRPTCodecError) as context:
            V.decode(data)
        self.assertEqual(context.exception.code, code, f"expected {code}, got {context.exception}")

    def test_e034_invalid_image_count(self) -> None:
        self.expect_code(self.mutate({52: V._p16(0)}), "E034")

    def test_e035_invalid_image_entry(self) -> None:
        self.expect_code(self.mutate({self.image_table_base + 1: b"\x00"}), "E035")

    def test_e036_image_table_size_mismatch(self) -> None:
        self.expect_code(
            self.mutate({54: V._p32(self.model.image_table_size + 4)}, append=b"\x00\x00\x00\x00"),
            "E036",
        )

    def test_e037_invalid_image_path(self) -> None:
        self.expect_code(self.mutate({self.image_table_base + 20: b"X"}), "E037")

    def test_e038_invalid_page_metadata(self) -> None:
        self.expect_code(self.mutate({self.page_table_base + 24: V._p16(2)}), "E038")
        self.expect_code(self.mutate({self.page_table_base + 26: V._p16(1)}), "E038")

    def test_e039_duplicate_image_path(self) -> None:
        path_offset = self.image1_base + 20
        self.expect_code(self.mutate({path_offset: b"/A"}), "E039")

    def test_e040_invalid_page_vm_offset(self) -> None:
        self.expect_code(self.mutate({self.page_table_base + 28: V._p32(0x1001)}), "E040")

    def test_e041_invalid_image_geometry(self) -> None:
        self.expect_code(self.mutate({self.image_table_base + 12: V._p32(0)}), "E041")


class V2MetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._tmpdir = tempfile.TemporaryDirectory(prefix="nrpt-v2-fixture-")
        cls.root = cls._tmpdir.name
        cls.profile, cls.profile_bytes = build_synthetic_v2_fixture(cls.root)
        cls.images = V.discover_images(cls.root)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmpdir.cleanup()

    def validate(self, profile: V.Profile, *, expected_build: str = "24H232") -> dict:
        return V.validate_profile_against_fixture(
            profile,
            self.images,
            profile_path="synthetic-v2.nrpt",
            profile_bytes=V.encode(profile),
            fixture_root=self.root,
            expected_build=expected_build,
            device_id=0x1638,
        )

    def test_metadata_re_resolution_pass(self) -> None:
        report = self.validate(self.profile)
        self.assertEqual(report["result"], "PASS")
        self.assertEqual(report["profile"]["version"], 2)
        self.assertEqual(len(report["images"]), 2)
        self.assertTrue(all(image["verified"] for image in report["images"]))
        for page in report["pages"]:
            metadata = page["metadata"]
            self.assertTrue(metadata["verified"])
            image_unslid = next(
                image["unslidVmaddr"] for image in report["images"]
                if image["index"] == metadata["imageIndex"]
            )
            self.assertEqual(
                int(metadata["pageStart"], 16),
                int(image_unslid, 16) + int(metadata["pageVmOffset"], 16),
            )
        gl_page = report["pages"][0]["metadata"]
        self.assertEqual(gl_page["namespace"], "standalone-file-offset")
        self.assertEqual(gl_page["segment"], "__TEXT")
        self.assertEqual(gl_page["section"], "__text")
        self.assertEqual(int(gl_page["fileOffset"], 16), 0x1000)
        mtl_page = report["pages"][1]["metadata"]
        self.assertEqual(mtl_page["namespace"], "subcache-file-offset")
        self.assertTrue(mtl_page["file"].endswith("dyld_shared_cache_x86_64h"))
        self.assertEqual(report["summary"]["appliedPages"], 2)

    def test_metadata_wrong_page_vm_offset_rejected(self) -> None:
        model = V.decode(V.encode(self.profile))
        model.pages[0].page_vm_offset = 0x2000
        with self.assertRaises(V.ValidationFailure) as context:
            self.validate(model)
        self.assertIn("E040", str(context.exception))

    def test_metadata_wrong_page_hash_rejected(self) -> None:
        model = V.decode(V.encode(self.profile))
        model.pages[0].page_hash ^= 0xFFFFFFFFFFFFFFFF
        with self.assertRaises(V.ValidationFailure) as context:
            self.validate(model)
        self.assertIn("E040", str(context.exception))

    def test_metadata_missing_image_path_rejected(self) -> None:
        model = V.decode(V.encode(self.profile))
        model.images[0].path = "/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/Missing"
        with self.assertRaises(V.ValidationFailure) as context:
            self.validate(model)
        self.assertIn("E037", str(context.exception))

    def test_metadata_bogus_segment_rejected(self) -> None:
        model = V.decode(V.encode(self.profile))
        model.images[0].segments = ["__TEXT", "__LINKEDIT", "__BOGUS"]
        with self.assertRaises(V.ValidationFailure) as context:
            self.validate(model)
        self.assertIn("E041", str(context.exception))

    def test_metadata_vm_size_mismatch_rejected(self) -> None:
        model = V.decode(V.encode(self.profile))
        model.images[0].vm_size = 0x3000
        with self.assertRaises(V.ValidationFailure) as context:
            self.validate(model)
        self.assertIn("E041", str(context.exception))


class GoldenV2ParityTests(unittest.TestCase):
    GOLDEN_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden",
                               "synthetic-2page-v2.nrpt")
    GOLDEN_SHA256 = "6a36b368f1c03d1e3205eb274e455dde99d52b9d6cb49155153612c346671e85"

    def golden_model(self) -> V.Profile:
        site0 = V.Site(0x0100, bytes.fromhex("c7477804000000"), bytes.fromhex("c7477801000000"))
        site1 = V.Site(0x0160, bytes.fromhex("83e0fe"), bytes.fromhex("83c801"))
        site2 = V.Site(0x0200, bytes.fromhex("750b"), bytes.fromhex("eb0b"))
        images = [
            V.Image(kind=V.IMAGE_KIND_STANDALONE,
                    path="/System/Library/Extensions/SyntheticGL.bundle/Contents/MacOS/SyntheticGL",
                    unslid_vmaddr=0, vm_size=0x5000, segments=["__TEXT", "__LINKEDIT"],
                    sections=["__text"]),
            V.Image(kind=V.IMAGE_KIND_SHARED_CACHE,
                    path="/System/Library/Extensions/SyntheticMTL.bundle/Contents/MacOS/SyntheticMTL",
                    unslid_vmaddr=0x7FFB00000000, vm_size=0x4000, segments=["__TEXT"],
                    sections=["__text"]),
        ]
        pages = [
            V.Page(0x2000, 0x1111222233334444, V.DEFAULT_MATCH_FLAGS, [site0],
                   image_index=0, page_vm_offset=0x2000),
            V.Page(0x87000, 0xAAAABBBBCCCCDDDD, V.DEFAULT_MATCH_FLAGS, [site1, site2],
                   image_index=1, page_vm_offset=0x1000),
        ]
        return V.Profile(
            header=V.Header(build="24H232", apu_mask=0x28, device_id=0, version=V.VERSION_V2),
            pages=pages, version=V.VERSION_V2, images=images,
        )

    def test_reference_codec_golden_is_byte_identical(self) -> None:
        with open(self.GOLDEN_PATH, "rb") as handle:
            golden = handle.read()
        self.assertEqual(len(golden), 520)
        self.assertEqual(hashlib.sha256(golden).hexdigest(), self.GOLDEN_SHA256)
        self.assertEqual(V.decode(golden), self.golden_model())
        self.assertEqual(V.encode(self.golden_model()), golden)
        self.assertEqual(V.encode(V.decode(golden)), golden)


# ---------------------------------------------------------------------------
# Meta coverage: every stable error code has at least one crafted-byte test
# ---------------------------------------------------------------------------


class ZZCoverageTests(unittest.TestCase):
    def test_all_stable_codes_covered(self) -> None:
        expected = {f"E{index:03d}" for index in range(1, 42)}
        self.assertEqual(
            COVERED_CODES,
            expected,
            f"missing error-code coverage: {sorted(expected - COVERED_CODES)}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
