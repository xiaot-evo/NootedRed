#!/usr/bin/env python3
# Unit tests for the independent NRPT v3 offline validator (test/nrpt_validator.py).
#
# Covers: codec round trip/canonical size/determinism, every stable error code E001-E041 and
# E050-E053, page modes, hook-domain simulation (PAGE/DYLD), vnode gate model, offset-free
# identity, applied-once/already-patched semantics, fixture metadata re-resolution, bundle
# selection matrix, cross-implementation golden parity and the CLI end to end.

import hashlib
import json
import os
import plistlib
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import nrpt_validator as V  # noqa: E402

COVERED_CODES: set[str] = set()

GL_REL = "System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver"
MTL_REL = "System/Library/Extensions/AMDRadeonX5000MTLDriver.bundle/Contents/MacOS/AMDRadeonX5000MTLDriver"
CACHE_REL = "System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64h"
GL_PATH = "/" + GL_REL
MTL_PATH = "/" + MTL_REL
CACHE_PATH = "/" + CACHE_REL
MTL_UNSLID = 0x7FFB00001000


def cover(code: str) -> None:
    COVERED_CODES.add(code)


def deterministic_page(seed: bytes) -> bytes:
    out = bytearray(V.PAGE_SIZE)
    digest = hashlib.sha256(seed).digest()
    for index in range(V.PAGE_SIZE):
        out[index] = digest[index % len(digest)] ^ (index & 0xFF)
    return bytes(out)


def make_page(seed: bytes, site_specs) -> tuple[bytes, list[V.Site]]:
    page = bytearray(deterministic_page(seed))
    sites: list[V.Site] = []
    for offset, size in site_specs:
        find = bytes(page[offset : offset + size])
        replace = bytes(byte ^ 0xFF for byte in find)
        sites.append(V.Site(site_in_page=offset, find=find, replace=replace))
    return bytes(page), sites


def encode_macho(segments: list[dict]) -> bytes:
    commands = bytearray()
    for segment in segments:
        sections = segment.get("sections", [])
        command_size = 72 + len(sections) * 80
        commands += (0x19).to_bytes(4, "little") + command_size.to_bytes(4, "little")
        commands += segment["name"].encode().ljust(16, b"\x00")
        commands += segment["vmaddr"].to_bytes(8, "little") + segment["vmsize"].to_bytes(8, "little")
        commands += segment.get("fileoff", 0).to_bytes(8, "little")
        commands += segment.get("filesize", segment["vmsize"]).to_bytes(8, "little")
        commands += b"\x00" * 8
        commands += len(sections).to_bytes(4, "little") + b"\x00" * 4
        for section in sections:
            commands += section["name"].encode().ljust(16, b"\x00")
            commands += segment["name"].encode().ljust(16, b"\x00")
            commands += section["addr"].to_bytes(8, "little") + section["size"].to_bytes(8, "little")
            commands += section.get("offset", 0).to_bytes(4, "little") + b"\x00" * 28
    header = bytearray()
    header += (0xFEEDFACF).to_bytes(4, "little")
    header += (0x01000007).to_bytes(4, "little")
    header += (3).to_bytes(4, "little")
    header += (6).to_bytes(4, "little")
    header += len(segments).to_bytes(4, "little")
    header += len(commands).to_bytes(4, "little")
    header += b"\x00" * 8
    return bytes(header + commands)


def write_fixture(root: str, files: dict[str, bytes]) -> None:
    for relative, content in files.items():
        path = os.path.join(root, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(content)


def build_synthetic_fixture(root: str, duplicates: bool = False) -> tuple[V.Profile, bytes, bytes, bytes]:
    """Clean fixture: one standalone GL Mach-O + one split-dyld-cache MTL image."""
    page0, sites0 = make_page(b"nrpt-v3-gl-page", [(0x100, 4), (0x800, 2)])
    page1, sites1 = make_page(b"nrpt-v3-mtl-page", [(0x200, 3), (0x810, 2)])

    gl_macho = encode_macho(
        [
            {"name": "__TEXT", "vmaddr": 0, "vmsize": 0x4000, "fileoff": 0,
             "sections": [{"name": "__text", "addr": 0, "size": 0x4000, "offset": 0}]},
            {"name": "__LINKEDIT", "vmaddr": 0x4000, "vmsize": 0x1000, "fileoff": 0x4000},
        ]
    )
    gl_file = bytearray(0x4000)
    gl_file[0 : len(gl_macho)] = gl_macho
    gl_file[0x1000 : 0x2000] = page0
    if duplicates:
        gl_file[0x2000 : 0x3000] = page0

    cache = bytearray(0x4000)
    cache[0:16] = b"dyld_v1 x86_64h\x00"
    cache[0x10:0x14] = (0x228).to_bytes(4, "little")
    cache[0x14:0x18] = (1).to_bytes(4, "little")
    cache[0x88:0x90] = (0x300).to_bytes(8, "little")
    cache[0x90:0x98] = (1).to_bytes(8, "little")
    cache[0x228:0x230] = (0x7FFB00000000).to_bytes(8, "little")
    cache[0x230:0x238] = (0x4000).to_bytes(8, "little")
    cache[0x238:0x240] = (0).to_bytes(8, "little")
    image_text = bytearray(32)
    image_text[16:24] = MTL_UNSLID.to_bytes(8, "little")
    image_text[24:28] = (0x2000).to_bytes(4, "little")
    image_text[28:32] = (0x320).to_bytes(4, "little")
    cache[0x300:0x320] = image_text
    encoded_path = MTL_PATH.encode()
    cache[0x320 : 0x320 + len(encoded_path)] = encoded_path
    cache_macho = encode_macho(
        [{"name": "__TEXT", "vmaddr": MTL_UNSLID, "vmsize": 0x2000, "fileoff": 0x1000,
          "sections": [{"name": "__text", "addr": MTL_UNSLID, "size": 0x2000, "offset": 0x1000}]}]
    )
    cache[0x1000 : 0x1000 + len(cache_macho)] = cache_macho
    cache[0x2000:0x3000] = page1

    files = {
        GL_REL: bytes(gl_file),
        CACHE_REL: bytes(cache),
        "System/Library/CoreServices/SystemVersion.plist": plistlib.dumps(
            {"ProductBuildVersion": "24H232", "ProductVersion": "15.8.2"}
        ),
    }
    if duplicates:
        subcache = bytearray(0x2000)
        subcache[0x1000:0x2000] = page1
        files[CACHE_REL + ".01"] = bytes(subcache)
    write_fixture(root, files)

    images = [
        V.Image(kind=V.IMAGE_KIND_STANDALONE, path=GL_PATH, unslid_vmaddr=0, vm_size=0x4000),
        V.Image(kind=V.IMAGE_KIND_SHARED_CACHE, path=MTL_PATH, unslid_vmaddr=MTL_UNSLID, vm_size=0x2000),
    ]
    pages = [
        V.Page(page_file_offset=0x1000, page_hash=V.fnv1a64(page0), mode=V.MODE_PAGE,
               image_index=0, page_vm_offset=0x1000, sites=sites0),
        V.Page(page_file_offset=0x2000, page_hash=V.fnv1a64(page1), mode=V.MODE_DYLD,
               image_index=1, page_vm_offset=0x1000, sites=sites1),
    ]
    profile = V.Profile(header=V.Header(build="24H232", apu_mask=0x28, device_id=0x1638),
                        images=images, pages=pages)
    return profile, V.encode(profile), page0, page1


def valid_model() -> V.Profile:
    """Structurally valid 2-image / 2-page model used for codec and error-vector tests."""
    images = [
        V.Image(kind=V.IMAGE_KIND_STANDALONE, path=GL_PATH, unslid_vmaddr=0, vm_size=0x4000),
        V.Image(kind=V.IMAGE_KIND_SHARED_CACHE, path=MTL_PATH, unslid_vmaddr=MTL_UNSLID, vm_size=0x2000),
    ]
    pages = [
        V.Page(page_file_offset=0x1000, page_hash=0x1111222233334444, mode=V.MODE_PAGE,
               image_index=0, page_vm_offset=0x1000,
               sites=[V.Site(0x100, b"\x11\x22\x33", b"\x11\x22\x44")]),
        V.Page(page_file_offset=0x2000, page_hash=0xAAAABBBBCCCCDDDD, mode=V.MODE_DYLD,
               image_index=1, page_vm_offset=0x1000,
               sites=[V.Site(0x200, b"\x75\x0b", b"\xeb\x0b"),
                      V.Site(0x810, b"\x01\x02", b"\x01\x03")]),
    ]
    return V.Profile(header=V.Header(build="24H232", apu_mask=0x28, device_id=0x1638),
                     images=images, pages=pages)


def golden_model() -> V.Profile:
    images = [
        V.Image(kind=V.IMAGE_KIND_STANDALONE,
                path="/System/Library/Extensions/SyntheticGL.bundle/Contents/MacOS/SyntheticGL",
                unslid_vmaddr=0, vm_size=0x5000),
        V.Image(kind=V.IMAGE_KIND_SHARED_CACHE,
                path="/System/Library/Extensions/SyntheticMTL.bundle/Contents/MacOS/SyntheticMTL",
                unslid_vmaddr=0x7FFB00000000, vm_size=0x4000),
    ]
    pages = [
        V.Page(page_file_offset=0x2000, page_hash=0x1111222233334444, mode=V.MODE_PAGE,
               image_index=0, page_vm_offset=0x2000,
               sites=[V.Site(0x0100, bytes.fromhex("112233"), bytes.fromhex("112244"))]),
        V.Page(page_file_offset=0x87000, page_hash=0xAAAABBBBCCCCDDDD, mode=V.MODE_DYLD,
               image_index=1, page_vm_offset=0x1000,
               sites=[V.Site(0x0160, bytes.fromhex("83e0fe"), bytes.fromhex("83c801")),
                      V.Site(0x0200, bytes.fromhex("750b"), bytes.fromhex("eb0b"))]),
    ]
    return V.Profile(header=V.Header(build="24H232", apu_mask=0x28, device_id=0x1638),
                     images=images, pages=pages)


class HelperTests(unittest.TestCase):
    def test_fnv_vectors(self) -> None:
        self.assertEqual(V.fnv1a32(b""), 0x811C9DC5)
        self.assertEqual(V.fnv1a32(b"a"), 0xE40C292C)
        self.assertEqual(V.fnv1a64(b""), 0xCBF29CE484222325)
        self.assertEqual(V.fnv1a64(b"a"), 0xAF63DC4C8601EC8C)

    def test_page_hash_requires_full_page(self) -> None:
        cover("E033")
        with self.assertRaises(V.NRPTCodecError) as context:
            V.page_hash(b"x" * 1024)
        self.assertEqual(context.exception.code, "E033")
        page = deterministic_page(b"hash")
        self.assertEqual(V.page_hash(page), V.fnv1a64(page))

    def test_build_field_round_trip(self) -> None:
        self.assertEqual(V.decode_build_field(V.encode_build_field("24H232")), "24H232")
        cover("E005")
        with self.assertRaises(V.NRPTCodecError):
            V.encode_build_field("bad build")
        with self.assertRaises(V.NRPTCodecError):
            V.encode_build_field("")


class CodecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.model = valid_model()
        cls.base = V.encode(cls.model)

    def test_round_trip_and_size(self) -> None:
        decoded = V.decode(self.base)
        self.assertEqual(decoded, self.model)
        self.assertEqual(
            len(self.base),
            V.HEADER_SIZE
            + 2 * V.PAGE_RECORD_SIZE
            + 3 * V.SITE_RECORD_SIZE
            + self.model.image_table_size,
        )
        self.assertEqual(V.encode(decoded), self.base)
        self.assertEqual(V.encode(self.model), self.base)

    def test_header_fields_and_checksum(self) -> None:
        self.assertEqual(self.base[0:4], b"NRPT")
        self.assertEqual(V._u16(self.base, 4), 3)
        self.assertEqual(V._u16(self.base, 6), 64)
        self.assertEqual(V.decode_build_field(self.base[8:24]), "24H232")
        self.assertEqual(V._u32(self.base, 24), 0x28)
        self.assertEqual(V._u32(self.base, 28), 0x1638)
        self.assertEqual(V._u16(self.base, 32), 2)
        self.assertEqual(V._u16(self.base, 34), 3)
        self.assertEqual(V._u32(self.base, 36), 64)
        self.assertEqual(V._u32(self.base, 40), 120)
        self.assertEqual(V._u32(self.base, 44), V.fnv1a32(self.base[64:]))
        self.assertEqual(V._u16(self.base, 52), 2)
        self.assertEqual(V._u32(self.base, 54), self.model.image_table_size)

    def test_page_record_layout(self) -> None:
        page0 = self.base[64:96]
        self.assertEqual(V._u64(page0, 0), 0x1000)
        self.assertEqual(V._u64(page0, 8), 0x1111222233334444)
        self.assertEqual(V._u32(page0, 16), 0)
        self.assertEqual(V._u16(page0, 20), 1)
        self.assertEqual(page0[22], V.MODE_PAGE)
        self.assertEqual(page0[23], 0)
        self.assertEqual(V._u16(page0, 24), 0)
        self.assertEqual(V._u16(page0, 26), 0)
        self.assertEqual(V._u32(page0, 28), 0x1000)
        page1 = self.base[96:128]
        self.assertEqual(page1[22], V.MODE_DYLD)
        self.assertEqual(V._u16(page1, 20), 2)
        self.assertEqual(V._u32(page1, 16), 1)

    def test_canonical_and_deterministic(self) -> None:
        self.assertEqual(V.encode(self.model), V.encode(valid_model()))
        self.assertEqual(hashlib.sha256(self.base).hexdigest(),
                         hashlib.sha256(V.encode(valid_model())).hexdigest())

    def test_v1_and_v2_are_rejected(self) -> None:
        for version, code in ((1, "E003"), (2, "E003")):
            data = bytearray(self.base)
            data[4:6] = V._p16(version)
            cover(code)
            with self.assertRaises(V.NRPTCodecError) as context:
                V.decode(bytes(data))
            self.assertEqual(context.exception.code, "E003")


class StructuralErrorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.model = valid_model()
        cls.base = V.encode(cls.model)
        cls.page_table = V.HEADER_SIZE
        cls.site_table = V.HEADER_SIZE + 2 * V.PAGE_RECORD_SIZE
        cls.image_table = cls.site_table + 3 * V.SITE_RECORD_SIZE
        cls.image1_base = cls.image_table + cls.model.images[0].entry_size

    def mutate(self, changes: dict[int, bytes], *, append: bytes = b"", fix_checksum: bool = True) -> bytes:
        data = bytearray(self.base + append)
        for offset, replacement in changes.items():
            data[offset : offset + len(replacement)] = replacement
        if fix_checksum:
            data[V.H_PAYLOAD_CHECKSUM : V.H_PAYLOAD_CHECKSUM + 4] = V._p32(V.fnv1a32(bytes(data[V.HEADER_SIZE:])))
        return bytes(data)

    def expect(self, code: str, data: bytes) -> None:
        cover(code)
        with self.assertRaises(V.NRPTCodecError) as context:
            V.decode(data)
        self.assertEqual(context.exception.code, code, f"expected {code}, got {context.exception}")

    def test_header_errors(self) -> None:
        self.expect("E001", self.base[:32])
        self.expect("E002", self.mutate({0: b"XNRP"}))
        self.expect("E003", self.mutate({4: V._p16(2)}))
        self.expect("E004", self.mutate({6: V._p16(32)}))
        self.expect("E005", self.mutate({8: b"\x00" * 16}))
        self.expect("E006", self.mutate({24: V._p32(0)}))
        self.expect("E007", self.mutate({28: V._p32(0x10000)}))
        self.expect("E008", self.mutate({48: b"\x01"}))
        self.expect("E009", self.mutate({58: b"\x01"}))
        self.expect("E010", self.base + b"\x00" * V.MAX_PROFILE_SIZE)
        self.expect("E011", self.mutate({36: V._p32(0)}))
        self.expect("E012", self.mutate({40: V._p32(0)}))
        self.expect("E013", self.mutate({}, append=b"\x00", fix_checksum=False))
        self.expect("E014", self.mutate({44: V._p32(V._u32(self.base, 44) ^ 1)}, fix_checksum=False))
        self.expect("E015", self.mutate({32: V._p16(V.MAX_PAGES + 1)}))
        self.expect("E016", self.mutate({34: V._p16(0)}))
        self.expect("E032", self.mutate({32: V._p16(0)}))
        self.expect("E034", self.mutate({52: V._p16(0)}))

    def test_image_table_errors(self) -> None:
        self.expect("E035", self.mutate({self.image_table + 1: b"\x01"}))
        self.expect(
            "E036",
            self.mutate(
                {54: V._p32(V._u32(self.base, 54) + 4)}, append=b"\x00" * 4
            ),
        )
        self.expect("E037", self.mutate({self.image_table + 16: b"X"}))
        self.expect("E041", self.mutate({self.image_table + 12: V._p32(0)}))
        self.expect(
            "E041",
            self.mutate({self.image1_base + 4: b"\x00" * 8}),
        )

    def test_page_record_errors(self) -> None:
        page0 = self.page_table
        self.expect("E017", self.mutate({page0: V._p64(0x1001)}))
        self.expect("E018", self.mutate({page0 + 22: b"\x03"}))
        self.expect("E019", self.mutate({page0 + 22: b"\x02"}))
        self.expect("E019", self.mutate({page0 + 24: V._p16(1)}))
        self.expect("E038", self.mutate({page0 + 24: V._p16(2)}))
        self.expect("E038", self.mutate({page0 + 23: b"\x01"}))
        self.expect("E038", self.mutate({page0 + 26: b"\x01"}))
        self.expect("E040", self.mutate({page0 + 28: V._p32(0x1001)}))
        self.expect("E040", self.mutate({page0 + 28: V._p32(0x4000)}))
        self.expect("E021", self.mutate({page0 + 16: V._p32(1)}))
        self.expect("E023", self.mutate({page0 + 20: V._p16(0)}))
        page1 = self.page_table + V.PAGE_RECORD_SIZE
        self.expect("E020", self.mutate({page1 + 20: V._p16(4)}))
        self.expect("E022", self.mutate({page1 + 20: V._p16(1)}))

    def test_site_table_errors(self) -> None:
        site0 = self.site_table
        self.expect("E024", self.mutate({site0 + 2: b"\x00"}))
        self.expect("E025", self.mutate({site0 + 3: b"\x02"}))
        self.expect("E026", self.mutate({site0: V._p16(0x1000)}))
        self.expect("E027", self.mutate({site0 + 7: b"\x01"}))
        self.expect("E028", self.mutate({site0 + 20: b"\x11\x22\x33"}))
        self.expect("E029", self.mutate({site0 + 36: V._p32(1)}))


class ModelErrorTests(unittest.TestCase):
    def expect_model(self, code: str, model: V.Profile) -> None:
        cover(code)
        with self.assertRaises(V.NRPTCodecError) as context:
            V.encode(model)
        self.assertEqual(context.exception.code, code, str(context.exception))

    def test_model_errors(self) -> None:
        model = valid_model()
        model.header.apu_mask = 0
        self.expect_model("E006", model)
        model = valid_model()
        model.header.device_id = 0x10000
        self.expect_model("E007", model)
        model = valid_model()
        model.header.build = "bad build"
        self.expect_model("E005", model)

        model = valid_model()
        model.pages[0].sites.append(V.Site(0x102, b"\xAA\xBB", b"\xAA\xBC"))
        self.expect_model("E030", model)
        model = valid_model()
        model.pages[1].page_hash = model.pages[0].page_hash
        model.pages[1].mode = V.MODE_PAGE
        model.pages[1].image_index = 0
        self.expect_model("E031", model)
        model = valid_model()
        model.images.append(V.Image(V.IMAGE_KIND_STANDALONE, GL_PATH, 0, 0x4000))
        self.expect_model("E039", model)
        model = valid_model()
        model.images = []
        self.expect_model("E034", model)
        model = valid_model()
        model.pages = []
        self.expect_model("E032", model)
        model = valid_model()
        model.pages[0].mode = V.MODE_RESOLVER
        self.expect_model("E018", model)
        model = valid_model()
        model.pages[0].image_index = 1
        self.expect_model("E019", model)
        model = valid_model()
        model.pages[0].page_vm_offset = 0x1001
        self.expect_model("E040", model)
        model = valid_model()
        model.pages[0].page_file_offset = 0x1001
        self.expect_model("E017", model)
        model = valid_model()
        model.pages[0].sites = [V.Site(0x100, b"\x01", b"\x01")]
        self.expect_model("E028", model)
        model = valid_model()
        model.pages[0].sites[0].flags = 1
        self.expect_model("E029", model)
        model = valid_model()
        model.pages[0].sites = [V.Site(0x100, b"", b"")]
        self.expect_model("E024", model)
        model = valid_model()
        model.pages[0].sites = [V.Site(0x100, b"\x01\x02", b"\x03")]
        self.expect_model("E025", model)
        model = valid_model()
        model.pages[0].sites = [V.Site(0xFFF, b"\x01\x02", b"\x03\x04")]
        self.expect_model("E026", model)


class BundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.profile = valid_model()
        cls.second = V.decode(V.encode(valid_model()))
        cls.second.header.build = "25A999"
        cls.second.header.device_id = 0
        cls.bundle = V.Bundle(
            [
                V.BundleEntry("24H232", 0x28, 0x1638, V.encode(cls.profile)),
                V.BundleEntry("25A999", 0x28, 0, V.encode(cls.second)),
            ]
        )

    def test_plist_round_trip(self) -> None:
        encoded = V.encode_bundle_plist(self.bundle)
        self.assertEqual(encoded, V.encode_bundle_plist(self.bundle))
        decoded = V.decode_bundle_plist(encoded)
        self.assertEqual([entry.build for entry in decoded.entries], ["24H232", "25A999"])
        self.assertEqual(decoded.entries[0].apu_mask, 0x28)
        self.assertEqual(decoded.entries[0].device_id, 0x1638)
        self.assertEqual(hashlib.sha256(decoded.entries[0].profile_data).hexdigest(),
                         hashlib.sha256(V.encode(self.profile)).hexdigest())

    def test_selection_matrix(self) -> None:
        self.assertEqual(V.select_profile(self.bundle, "24H232", 0x28, 0x1638).status, "selected")
        self.assertEqual(V.select_profile(self.bundle, "24H232", 0x28, 0x1638).index, 0)
        self.assertEqual(V.select_profile(self.bundle, "25A999", 0x28, 0x15DD).status, "selected")
        self.assertEqual(V.select_profile(self.bundle, "24H232", 0x28, 0x15DD).status, "deviceMismatch")
        self.assertEqual(V.select_profile(self.bundle, "24H232", 0x01, 0x1638).status, "apuMismatch")
        self.assertEqual(V.select_profile(self.bundle, "26C000", 0x28, 0x1638).status, "unsupportedBuild")

    def test_bundle_count_errors(self) -> None:
        cover("E050")
        with self.assertRaises(V.NRPTCodecError):
            V.encode_bundle_plist(V.Bundle([]))
        entries = [V.BundleEntry(f"24H23{index % 10}", 0x28, 0, V.encode(self.profile))
                   for index in range(V.MAX_BUNDLE_ENTRIES + 1)]
        with self.assertRaises(V.NRPTCodecError) as context:
            V.encode_bundle_plist(V.Bundle(entries))
        self.assertEqual(context.exception.code, "E050")

    def test_duplicate_build(self) -> None:
        cover("E051")
        bundle = V.Bundle(
            [
                V.BundleEntry("24H232", 0x28, 0x1638, V.encode(self.profile)),
                V.BundleEntry("24H232", 0x28, 0x1638, V.encode(self.profile)),
            ]
        )
        with self.assertRaises(V.NRPTCodecError) as context:
            V.encode_bundle_plist(bundle)
        self.assertEqual(context.exception.code, "E051")

    def test_entry_profile_mismatch(self) -> None:
        cover("E052")
        for entry in (
            V.BundleEntry("24H233", 0x28, 0x1638, V.encode(self.profile)),
            V.BundleEntry("24H232", 0x01, 0x1638, V.encode(self.profile)),
            V.BundleEntry("24H232", 0x28, 0x15DD, V.encode(self.profile)),
        ):
            with self.assertRaises(V.NRPTCodecError) as context:
                V.encode_bundle_plist(V.Bundle([entry]))
            self.assertEqual(context.exception.code, "E052")

    def test_invalid_bundle_plist(self) -> None:
        cover("E053")
        valid = V.bundle_plist_dict(self.bundle)
        vectors = [
            {"Wrong": valid[V.BUNDLE_ROOT_KEY]},
            {"NRedProfiles": valid[V.BUNDLE_ROOT_KEY][0]},
            {"NRedProfiles": [{"Build": "24H232", "APUMask": 0x28, "DeviceID": 0x1638}]},
            {"NRedProfiles": [{"Build": "24H232", "APUMask": 0x28, "DeviceID": 0x1638,
                               "Profile": b"x", "Extra": 1}]},
            {"NRedProfiles": [{"Build": "24H232", "APUMask": "0x28", "DeviceID": 0x1638,
                               "Profile": b"x"}]},
            {"NRedProfiles": [{"Build": "24H232", "APUMask": 0x28, "DeviceID": 0x1638,
                               "Profile": "not-data"}]},
        ]
        for vector in vectors:
            data = plistlib.dumps(vector)
            with self.assertRaises(V.NRPTCodecError) as context:
                V.decode_bundle_plist(data)
            self.assertEqual(context.exception.code, "E053")


class HookSimulationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.page0, cls.sites0 = make_page(b"hook-page-0", [(0x100, 4), (0x800, 2)])
        cls.page1, cls.sites1 = make_page(b"hook-page-1", [(0x200, 3)])
        cls.profile = V.Profile(
            header=V.Header("24H232", 0x28, 0x1638),
            images=[
                V.Image(V.IMAGE_KIND_STANDALONE, GL_PATH, 0, 0x4000),
                V.Image(V.IMAGE_KIND_SHARED_CACHE, MTL_PATH, MTL_UNSLID, 0x2000),
            ],
            pages=[
                V.Page(0x1000, V.fnv1a64(cls.page0), V.MODE_PAGE, 0, 0x1000, cls.sites0),
                V.Page(0x2000, V.fnv1a64(cls.page1), V.MODE_DYLD, 1, 0x1000, cls.sites1),
            ],
        )

    def test_page_route_apply(self) -> None:
        result = V.apply_chunk(self.profile, self.page0, V.MODE_PAGE,
                               vnode_name="AMDRadeonX5000GLDriver")
        self.assertEqual(result.status, "applied")
        self.assertEqual(result.page_index, 0)
        self.assertEqual(len(result.writes), 2)
        for site in self.sites0:
            start = site.site_in_page
            self.assertEqual(result.data[start : start + site.size], site.replace)

    def test_dyld_route_apply(self) -> None:
        results = V.apply_range(self.profile, self.page1, 0xDEAD0000, V.MODE_DYLD,
                                vnode_name="dyld_shared_cache_x86_64h.03")
        self.assertEqual([result.status for result in results], ["applied"])
        self.assertEqual(results[0].page_index, 1)

    def test_mode_domain_separation(self) -> None:
        self.assertEqual(
            V.apply_chunk(self.profile, self.page0, V.MODE_DYLD,
                          vnode_name="dyld_shared_cache_x86_64h.03").status,
            "noMatch",
        )
        self.assertEqual(
            V.apply_chunk(self.profile, self.page1, V.MODE_PAGE,
                          vnode_name="AMDRadeonX5000MTLDriver").status,
            "noMatch",
        )

    def test_vnode_gate(self) -> None:
        self.assertEqual(
            V.apply_chunk(self.profile, self.page0, V.MODE_PAGE, vnode_name="unrelated").status, "noMatch"
        )
        self.assertEqual(
            V.apply_chunk(self.profile, self.page0, V.MODE_PAGE, vnode_name="unrelated",
                          vnode_gate=False).status,
            "applied",
        )
        self.assertEqual(
            V.apply_chunk(self.profile, self.page1, V.MODE_DYLD, vnode_name="unrelated").status, "noMatch"
        )
        self.assertEqual(
            V.apply_chunk(self.profile, self.page1, V.MODE_DYLD,
                          vnode_name="dyld_shared_cache_x86_64h.03").status,
            "applied",
        )

    def test_no_offset_identity(self) -> None:
        # A different kernel-reported chunk base must not affect matching or the write.
        first = V.apply_chunk(self.profile, self.page0, V.MODE_PAGE, chunk_base=0x1000,
                              vnode_name="AMDRadeonX5000GLDriver")
        second = V.apply_chunk(self.profile, self.page0, V.MODE_PAGE, chunk_base=0xDEADB000,
                               vnode_name="AMDRadeonX5000GLDriver")
        self.assertEqual(first.status, "applied")
        self.assertEqual(second.status, "applied")
        self.assertEqual(first.data, second.data)

    def test_applied_once(self) -> None:
        applied: set[int] = set()
        first = V.apply_chunk(self.profile, self.page0, V.MODE_PAGE,
                              vnode_name="AMDRadeonX5000GLDriver", applied=applied)
        second = V.apply_chunk(self.profile, self.page0, V.MODE_PAGE,
                               vnode_name="AMDRadeonX5000GLDriver", applied=applied)
        self.assertEqual(first.status, "applied")
        self.assertEqual(second.status, "alreadyApplied")

    def test_site_find_mismatch_writes_nothing(self) -> None:
        profile = V.decode(V.encode(self.profile))
        profile.pages[0].sites[0].find = b"\xAA\xBB\xCC\xDD"
        result = V.apply_chunk(profile, self.page0, V.MODE_PAGE,
                               vnode_name="AMDRadeonX5000GLDriver")
        self.assertEqual(result.status, "siteFindMismatch")
        self.assertEqual(result.page_index, 0)
        self.assertEqual(result.site_index, 0)
        self.assertIsNone(result.data)

    def test_already_patched_pass(self) -> None:
        patched = bytearray(self.page0)
        for site in self.sites0:
            patched[site.site_in_page : site.site_in_page + site.size] = site.replace
        result = V.apply_chunk(self.profile, bytes(patched), V.MODE_PAGE,
                               vnode_name="AMDRadeonX5000GLDriver")
        self.assertEqual(result.status, "alreadyPatched")
        self.assertEqual(result.page_index, 0)
        self.assertIsNone(result.data)

    def test_mutation_rejected(self) -> None:
        mutated = bytearray(self.page0)
        mutated[3] ^= 0xFF
        self.assertEqual(
            V.apply_chunk(self.profile, bytes(mutated), V.MODE_PAGE,
                          vnode_name="AMDRadeonX5000GLDriver").status,
            "noMatch",
        )


class FixtureValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._tmpdir = tempfile.TemporaryDirectory(prefix="nrpt-v3-fixture-")
        cls.root = cls._tmpdir.name
        cls.profile, cls.profile_bytes, cls.page0, cls.page1 = build_synthetic_fixture(cls.root)
        cls.images = V.discover_images(cls.root)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmpdir.cleanup()

    def validate(self, profile: V.Profile, **kwargs) -> dict:
        return V.validate_profile_against_fixture(
            profile,
            profile_path="synthetic-v3.nrpt",
            profile_bytes=V.encode(profile),
            fixture_root=self.root,
            expected_build="24H232",
            device_id=0x1638,
            mutation_sweep=kwargs.pop("mutation_sweep", True),
            native_hash_scan=False,
            **kwargs,
        )

    def test_clean_fixture_pass(self) -> None:
        report = self.validate(self.profile)
        self.assertEqual(report["result"], "PASS")
        self.assertEqual(report["profile"]["version"], 3)
        self.assertEqual(report["profile"]["pageCount"], 2)
        self.assertEqual(report["profile"]["modePageCount"], 1)
        self.assertEqual(report["profile"]["modeDyldCount"], 1)
        self.assertEqual(report["fixture"]["build"], "24H232")
        self.assertTrue(all(image["verified"] for image in report["images"]))
        self.assertEqual(len(report["pages"]), 2)
        for page in report["pages"]:
            self.assertTrue(page["applied"])
            self.assertTrue(page["evidenceConsistent"])
            self.assertEqual(page["secondDelivery"], "alreadyApplied")
            self.assertEqual(page["alreadyPatchedDelivery"], "alreadyPatched")
        page0 = report["pages"][0]
        self.assertEqual(page0["mode"], "PAGE")
        self.assertEqual(page0["resolvedFile"], "AMDRadeonX5000GLDriver")
        self.assertEqual(int(page0["resolvedOffset"], 16), 0x1000)
        self.assertEqual(page0["vnodeName"], "AMDRadeonX5000GLDriver")
        page1 = report["pages"][1]
        self.assertEqual(page1["mode"], "DYLD")
        self.assertEqual(page1["resolvedFile"], "dyld_shared_cache_x86_64h")
        self.assertEqual(int(page1["resolvedOffset"], 16), 0x2000)
        self.assertTrue(page1["vnodeName"].startswith("dyld_shared_cache"))
        self.assertEqual(report["routeSimulation"]["pageMode"][0]["wrongMode"], "noMatch")
        self.assertEqual(report["routeSimulation"]["pageMode"][0]["wrongVnode"], "noMatch")
        self.assertEqual(report["routeSimulation"]["dyldMode"][0]["modeSeparation"], "pass")
        self.assertEqual(report["summary"]["falsePositives"], 0)
        self.assertEqual(report["mutationSweep"][0]["status"], "noMatch")
        self.assertEqual(report["identity"]["build"]["status"], "pass")
        self.assertEqual(report["identity"]["apuAndDevice"]["status"], "pass")

    def test_evidence_offset_mismatch_is_warning_only(self) -> None:
        model = V.decode(V.encode(self.profile))
        model.pages[0].page_file_offset = 0x2000
        report = self.validate(model)
        self.assertEqual(report["result"], "PASS")
        self.assertFalse(report["pages"][0]["evidenceConsistent"])
        self.assertTrue(any("pageFileOffset evidence" in warning for warning in report["warnings"]))

    def test_wrong_page_hash_rejected(self) -> None:
        model = V.decode(V.encode(self.profile))
        model.pages[0].page_hash ^= 0xFFFFFFFFFFFFFFFF
        with self.assertRaises(V.ValidationFailure) as context:
            self.validate(model)
        self.assertIn("E040", str(context.exception))

    def test_missing_image_path_rejected(self) -> None:
        model = V.decode(V.encode(self.profile))
        model.images[0].path = "/System/Library/Extensions/Missing.bundle/Contents/MacOS/Missing"
        with self.assertRaises(V.ValidationFailure) as context:
            self.validate(model)
        self.assertIn("E037", str(context.exception))

    def test_vm_size_mismatch_rejected(self) -> None:
        model = V.decode(V.encode(self.profile))
        model.images[0].vm_size = 0x3000
        with self.assertRaises(V.ValidationFailure) as context:
            self.validate(model)
        self.assertIn("E041", str(context.exception))

    def test_duplicate_content_warning_and_strict_failure(self) -> None:
        with tempfile.TemporaryDirectory(prefix="nrpt-v3-duplicate-") as duplicate_root:
            duplicate_profile, _duplicate_bytes, _p0, _p1 = build_synthetic_fixture(duplicate_root, duplicates=True)
            report = V.validate_profile_against_fixture(
                duplicate_profile,
                profile_path="synthetic-v3-duplicate.nrpt",
                profile_bytes=V.encode(duplicate_profile),
                fixture_root=duplicate_root,
                expected_build="24H232",
                device_id=0x1638,
                native_hash_scan=False,
                mutation_sweep=False,
            )
            self.assertEqual(report["result"], "PASS")
            self.assertEqual(len(report["duplicateContent"]), 2)
            self.assertEqual(report["summary"]["identityWarnings"], 2)
            with self.assertRaises(V.ValidationFailure) as context:
                V.validate_profile_against_fixture(
                    duplicate_profile,
                    profile_path="synthetic-v3-duplicate.nrpt",
                    profile_bytes=V.encode(duplicate_profile),
                    fixture_root=duplicate_root,
                    expected_build="24H232",
                    device_id=0x1638,
                    native_hash_scan=False,
                    mutation_sweep=False,
                    strict_false_positives=True,
                )
            self.assertIn("E031", str(context.exception))

    def test_bundle_selection_validation(self) -> None:
        second = V.decode(V.encode(self.profile))
        second.header.build = "25A999"
        second.header.device_id = 0
        bundle = V.Bundle(
            [
                V.BundleEntry("24H232", 0x28, 0x1638, V.encode(self.profile)),
                V.BundleEntry("25A999", 0x28, 0, V.encode(second)),
            ]
        )
        selection = V.select_profile(bundle, "24H232", 0x28, 0x1638)
        self.assertTrue(selection.selected)
        report = V.validate_profile_against_fixture(
            selection.profile,
            profile_path="bundle#0",
            profile_bytes=bundle.entries[selection.index].profile_data,
            fixture_root=self.root,
            expected_build="24H232",
            device_id=0x1638,
            bundle=bundle,
            selection=selection,
            native_hash_scan=False,
            mutation_sweep=False,
        )
        self.assertEqual(report["result"], "PASS")
        self.assertEqual(report["selection"]["status"], "selected")
        self.assertEqual(report["selection"]["index"], 0)
        self.assertEqual(report["bundle"]["profileCount"], 2)


class GoldenV3Tests(unittest.TestCase):
    GOLDEN_PATH = os.path.join(HERE, "golden", "synthetic-2page-v3.nrpt")
    GOLDEN_SHA256 = "4f6fd501d417842f641df4da586d2c4752521134d8a0f295e06d69e9e786823f"

    def test_reference_codec_golden_is_byte_identical(self) -> None:
        with open(self.GOLDEN_PATH, "rb") as handle:
            golden = handle.read()
        self.assertEqual(len(golden), 432)
        self.assertEqual(hashlib.sha256(golden).hexdigest(), self.GOLDEN_SHA256)
        self.assertEqual(V.decode(golden), golden_model())
        self.assertEqual(V.encode(golden_model()), golden)
        self.assertEqual(V.encode(V.decode(golden)), golden)

    def test_golden_modes_and_images(self) -> None:
        with open(self.GOLDEN_PATH, "rb") as handle:
            profile = V.decode(handle.read())
        self.assertEqual(profile.pages[0].mode, V.MODE_PAGE)
        self.assertEqual(profile.pages[1].mode, V.MODE_DYLD)
        self.assertEqual(profile.images[0].kind, V.IMAGE_KIND_STANDALONE)
        self.assertEqual(profile.images[1].kind, V.IMAGE_KIND_SHARED_CACHE)
        self.assertEqual(profile.header.device_id, 0x1638)


class CLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._tmpdir = tempfile.TemporaryDirectory(prefix="nrpt-v3-cli-")
        cls.root = cls._tmpdir.name
        cls.fixture_root = os.path.join(cls.root, "fixture")
        cls.profile, cls.profile_bytes, _p0, _p1 = build_synthetic_fixture(cls.fixture_root)
        cls.profile_path = os.path.join(cls.root, "synthetic-v3.nrpt")
        with open(cls.profile_path, "wb") as handle:
            handle.write(cls.profile_bytes)
        cls.report_path = os.path.join(cls.root, "report.json")
        second = V.decode(V.encode(cls.profile))
        second.header.build = "25A999"
        second.header.device_id = 0
        cls.bundle = V.Bundle(
            [
                V.BundleEntry("24H232", 0x28, 0x1638, cls.profile_bytes),
                V.BundleEntry("25A999", 0x28, 0, V.encode(second)),
            ]
        )
        cls.bundle_path = os.path.join(cls.root, "NRedProfiles.plist")
        with open(cls.bundle_path, "wb") as handle:
            handle.write(V.encode_bundle_plist(cls.bundle))

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmpdir.cleanup()

    def test_single_profile_cli_pass(self) -> None:
        if os.path.exists(self.report_path):
            os.unlink(self.report_path)
        rc = V.main(
            [
                "--profile", self.profile_path,
                "--fixtures", self.fixture_root,
                "--expected-build", "24H232",
                "--device-id", "0x1638",
                "--report", self.report_path,
                "--mutation-sweep",
                "--quiet",
            ]
        )
        self.assertEqual(rc, 0)
        with open(self.report_path, encoding="utf-8") as handle:
            report = json.load(handle)
        self.assertEqual(report["result"], "PASS")
        self.assertEqual(report["profile"]["version"], 3)
        self.assertEqual(report["summary"]["appliedPages"], 2)

    def test_bundle_cli_selection_pass(self) -> None:
        report_path = os.path.join(self.root, "bundle-report.json")
        rc = V.main(
            [
                "--bundle-plist", self.bundle_path,
                "--fixtures", self.fixture_root,
                "--expected-build", "24H232",
                "--device-id", "0x1638",
                "--report", report_path,
                "--quiet",
            ]
        )
        self.assertEqual(rc, 0)
        with open(report_path, encoding="utf-8") as handle:
            report = json.load(handle)
        self.assertEqual(report["selection"]["status"], "selected")
        self.assertEqual(report["selection"]["index"], 0)
        self.assertEqual(report["bundle"]["profileCount"], 2)

    def test_cli_rejects_wrong_device(self) -> None:
        rc = V.main(
            [
                "--profile", self.profile_path,
                "--fixtures", self.fixture_root,
                "--expected-build", "24H232",
                "--device-id", "0x15DD",
                "--quiet",
            ]
        )
        self.assertEqual(rc, 1)

    def test_cli_usage_errors(self) -> None:
        self.assertEqual(V.main(["--quiet"]), 2)
        self.assertEqual(
            V.main(["--profile", self.profile_path, "--bundle-plist", self.bundle_path, "--quiet"]), 2
        )


class ZZCoverageTests(unittest.TestCase):
    def test_every_stable_error_code_has_a_vector(self) -> None:
        expected = {f"E{index:03d}" for index in range(1, 42)} | {"E050", "E051", "E052", "E053"}
        missing = expected - COVERED_CODES
        self.assertEqual(missing, set(), f"missing crafted-vector coverage: {sorted(missing)}")
        self.assertTrue(COVERED_CODES <= expected, f"unexpected codes: {sorted(COVERED_CODES - expected)}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
