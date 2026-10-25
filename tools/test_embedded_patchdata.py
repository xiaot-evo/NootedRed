#!/usr/bin/env python3
"""Host checks for the generated embedded PatchData arrays.

Verifies that `NootedRedUserPatch/PatchDataBlob.{hpp,cpp}`:

* are byte-identical to a fresh `tools/embed_patchdata.py` render;
* contain byte arrays that round-trip exactly to `PatchData/<build>/{manifest.bin,pages.bin}`;
* expose an index table whose mirrored metadata (build, Darwin, APU mask, counts, checksums, sizes)
  matches the independently parsed v1 manifest;
* contain no runtime file-system/path/plist access (the kext must not read files);
* compile as standalone C++ and recompute consistent checksums at runtime.

Run with::

    python3 tools/test_embedded_patchdata.py

This does not build the kext; the satellite build is task-12's responsibility.
"""

from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
ROOT = TOOLS_DIR.parent
PATCHDATA_DIR = ROOT / "PatchData"
NRED_DIR = ROOT / "NootedRedUserPatch"
HPP = NRED_DIR / "PatchDataBlob.hpp"
CPP = NRED_DIR / "PatchDataBlob.cpp"

sys.path.insert(0, str(TOOLS_DIR))
import embed_patchdata as embed  # noqa: E402
import test_userpatch_data as format_tests  # noqa: E402

EXPECTED_BUILDS = {"24H32", "25G241", "23J631"}
PAGE_SIZE = format_tests.PAGE_SIZE

ARRAY_RE = re.compile(r"const uint8_t (kManifest_\w+|kPages_\w+)\[\] = \{(.*?)\};", re.S)
HEX_BYTE_RE = re.compile(r"0x([0-9A-Fa-f]{2})")
TABLE_RE = re.compile(r"extern const EmbeddedBuild kBuilds\[\] = \{(.*?)\n\};", re.S)
ROW_RE = re.compile(
    r"\{\s*\"([0-9A-Za-z._-]+)\",\s*"
    r"(kManifest_\w+),\s*sizeof\(\2\),\s*"
    r"(kPages_\w+),\s*sizeof\(\3\),\s*"
    r"(0x[0-9A-F]+)U,\s*"
    r"(0x[0-9A-F]+)ULL,\s*"
    r"(\d+),\s*(\d+),\s*(\d+),\s*"
    r"(0x[0-9A-F]+)U,\s*"
    r"(\d+)U,\s*(\d+)U,\s*(\d+)U,\s*\}",
    re.S,
)
FORBIDDEN_RUNTIME_TOKENS = (
    "/Library",
    "Application Support",
    "readFile",
    "fopen",
    "vnode",
    "sysctl",
    "PlistBuild",
    "kern.osrelease",
)


def parse_arrays(source: str) -> dict[str, bytes]:
    arrays: dict[str, bytes] = {}
    for match in ARRAY_RE.finditer(source):
        name = match.group(1)
        if name in arrays:
            raise AssertionError(f"duplicate generated array {name}")
        arrays[name] = bytes(int(value, 16) for value in HEX_BYTE_RE.findall(match.group(2)))
    return arrays


def parse_table(source: str) -> list[dict]:
    table = TABLE_RE.search(source)
    if table is None:
        raise AssertionError("kBuilds[] table not found")
    rows = []
    for match in ROW_RE.finditer(table.group(1)):
        build, manifest_symbol, pages_symbol, pages_checksum, manifest_checksum, \
            darwin_major, darwin_minor, darwin_patch, apu_mask, table_count, page_count, site_count = \
            match.groups()
        rows.append({
            "build": build,
            "manifestSymbol": manifest_symbol,
            "pagesSymbol": pages_symbol,
            "pagesChecksum": int(pages_checksum, 16),
            "manifestChecksum": int(manifest_checksum, 16),
            "darwin": (int(darwin_major), int(darwin_minor), int(darwin_patch)),
            "apuMask": int(apu_mask, 16),
            "tableCount": int(table_count),
            "pageCount": int(page_count),
            "siteCount": int(site_count),
        })
    return rows


def patchdata_builds() -> list[str]:
    return sorted(path.name for path in PATCHDATA_DIR.iterdir()
                  if path.is_dir() and (path / "manifest.bin").is_file() and (path / "pages.bin").is_file())


class EmbeddedPatchDataTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.hpp_text = HPP.read_text(encoding="utf-8")
        cls.cpp_text = CPP.read_text(encoding="utf-8")

    def test_generated_files_are_current(self) -> None:
        self.assertEqual(embed.check(), [])

    def test_build_set(self) -> None:
        self.assertEqual(set(patchdata_builds()), EXPECTED_BUILDS)
        rows = parse_table(self.cpp_text)
        self.assertEqual([row["build"] for row in rows], patchdata_builds())
        self.assertIn("extern const size_t kBuildCount = sizeof(kBuilds) / sizeof(kBuilds[0]);",
                      self.cpp_text)
        self.assertIn("extern const EmbeddedBuild kBuilds[];", self.hpp_text)
        self.assertIn("namespace NRedUserPatchData", self.hpp_text)

    def test_arrays_round_trip_to_patchdata(self) -> None:
        arrays = parse_arrays(self.cpp_text)
        rows = parse_table(self.cpp_text)
        self.assertEqual(len(arrays), 2 * len(rows))
        for row in rows:
            with self.subTest(build=row["build"]):
                manifest = (PATCHDATA_DIR / row["build"] / "manifest.bin").read_bytes()
                pages = (PATCHDATA_DIR / row["build"] / "pages.bin").read_bytes()
                self.assertEqual(arrays[row["manifestSymbol"]], manifest)
                self.assertEqual(arrays[row["pagesSymbol"]], pages)
                self.assertEqual(hashlib.sha256(manifest).hexdigest(), embed.sha256_hex(manifest))
                self.assertEqual(len(arrays[row["manifestSymbol"]]), len(manifest))
                self.assertEqual(len(arrays[row["pagesSymbol"]]), len(pages))

    def test_index_metadata_matches_parsed_manifest(self) -> None:
        rows = {row["build"]: row for row in parse_table(self.cpp_text)}
        for build in patchdata_builds():
            with self.subTest(build=build):
                manifest = (PATCHDATA_DIR / build / "manifest.bin").read_bytes()
                pages = (PATCHDATA_DIR / build / "pages.bin").read_bytes()
                parsed = format_tests.parse_manifest(manifest, pages)
                row = rows[build]
                self.assertEqual(row["darwin"], parsed.darwin)
                self.assertEqual(row["apuMask"], parsed.apu_mask)
                self.assertEqual(row["tableCount"], len(parsed.tables))
                self.assertEqual(row["pageCount"], len(parsed.pages))
                self.assertEqual(row["siteCount"], len(parsed.sites))
                self.assertEqual(row["pagesChecksum"], parsed.pages_checksum)
                self.assertEqual(row["manifestChecksum"], parsed.manifest_checksum)

    def test_no_runtime_io_contract_in_generated_files(self) -> None:
        for path, text in ((HPP, self.hpp_text), (CPP, self.cpp_text)):
            for token in FORBIDDEN_RUNTIME_TOKENS:
                with self.subTest(path=path.name, token=token):
                    self.assertNotIn(token, text)
        self.assertNotIn("#include <Headers/", self.hpp_text)
        self.assertNotIn("#include <libkern/", self.hpp_text)
        includes = set(re.findall(r"#include <([^>]+)>", self.hpp_text))
        self.assertEqual(includes, {"stddef.h", "stdint.h"})

    def test_deterministic_render(self) -> None:
        header_a, source_a, builds_a = embed.render()
        header_b, source_b, builds_b = embed.render()
        self.assertEqual(header_a, header_b)
        self.assertEqual(source_a, source_b)
        self.assertEqual([blob.build for blob in builds_a], [blob.build for blob in builds_b])
        self.assertEqual(header_a, HPP.read_bytes())
        self.assertEqual(source_a, CPP.read_bytes())

    def test_check_detects_stale_generated_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="nred-blob-stale-") as tmp:
            tmp_path = Path(tmp)
            hpp = tmp_path / "PatchDataBlob.hpp"
            cpp = tmp_path / "PatchDataBlob.cpp"
            shutil.copyfile(HPP, hpp)
            shutil.copyfile(CPP, cpp)
            original = bytearray(cpp.read_bytes())
            original[len(original) // 2] ^= 0x01
            cpp.write_bytes(bytes(original))
            problems = embed.check(hpp, cpp)
            self.assertTrue(any("stale" in problem for problem in problems), problems)

    def test_generator_rejects_missing_or_corrupt_patchdata(self) -> None:
        with tempfile.TemporaryDirectory(prefix="nred-blob-src-") as tmp:
            tmp_path = Path(tmp)
            source = tmp_path / "PatchData"
            shutil.copytree(PATCHDATA_DIR, source)
            (source / "24H32" / "pages.bin").unlink()
            with self.assertRaises(embed.EmbedError):
                embed.render(source)

            shutil.copyfile(PATCHDATA_DIR / "24H32" / "pages.bin", source / "24H32" / "pages.bin")
            pages = bytearray((source / "24H32" / "pages.bin").read_bytes())
            pages[0] ^= 0xFF
            (source / "24H32" / "pages.bin").write_bytes(bytes(pages))
            with self.assertRaises(embed.EmbedError):
                embed.render(source)

    def test_host_compile_and_checksum_round_trip(self) -> None:
        compiler = next((shutil.which(name) for name in ("clang++", "g++", "c++") if shutil.which(name)), None)
        if compiler is None:
            self.skipTest("no host C++ compiler available")

        main_source = r"""
#include "PatchDataBlob.hpp"
#include <cstdio>
#include <cstring>
#include <cstdint>

static uint32_t fnv32(const uint8_t* data, size_t size)
{
    uint32_t value = 0x811C9DC5u;
    for (size_t i = 0; i < size; ++i) { value ^= data[i]; value *= 0x01000193u; }
    return value;
}

static uint64_t fnv64Zeroed(const uint8_t* data, size_t size)
{
    uint64_t value = 0xCBF29CE484222325ull;
    for (size_t i = 0; i < size; ++i)
    {
        const uint8_t byte = (i >= 64 && i < 72) ? 0 : data[i];
        value ^= byte;
        value *= 0x100000001B3ull;
    }
    return value;
}

static uint32_t readU32(const uint8_t* p)
{
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

int main()
{
    int failures = 0;
    for (size_t i = 0; i < NRedUserPatchData::kBuildCount; ++i)
    {
        const auto& build = NRedUserPatchData::kBuilds[i];
        if (build.build == nullptr || build.build[0] == '\0') { std::fprintf(stderr, "empty build\n"); ++failures; }
        if (build.manifestSize < 72) { std::fprintf(stderr, "%s: manifest too short\n", build.build); ++failures; continue; }
        if (std::memcmp(build.manifest, "NRPD", 4) != 0) { std::fprintf(stderr, "%s: magic\n", build.build); ++failures; }
        if (build.pagesSize == 0 || (build.pagesSize % 4096) != 0) { std::fprintf(stderr, "%s: pages size\n", build.build); ++failures; }
        if (readU32(build.manifest + 52) != build.pagesSize) { std::fprintf(stderr, "%s: pagesSize field\n", build.build); ++failures; }
        if (fnv32(build.pages, build.pagesSize) != build.pagesChecksum) { std::fprintf(stderr, "%s: pages checksum\n", build.build); ++failures; }
        if (fnv64Zeroed(build.manifest, build.manifestSize) != build.manifestChecksum) { std::fprintf(stderr, "%s: manifest checksum\n", build.build); ++failures; }
        if (build.pageCount != build.pagesSize / 4096) { std::fprintf(stderr, "%s: pageCount\n", build.build); ++failures; }
    }
    if (failures != 0) { return 1; }
    std::printf("embedded builds ok: %zu\n", NRedUserPatchData::kBuildCount);
    return 0;
}
"""
        with tempfile.TemporaryDirectory(prefix="nred-blob-host-") as tmp:
            tmp_path = Path(tmp)
            main_path = tmp_path / "main.cc"
            exe_path = tmp_path / "blob_test"
            main_path.write_text(main_source, encoding="utf-8")
            compile_command = [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                               "-I", str(NRED_DIR), str(CPP), str(main_path), "-o", str(exe_path)]
            completed = subprocess.run(compile_command, capture_output=True, text=True, check=False)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            run = subprocess.run([str(exe_path)], capture_output=True, text=True, check=False)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn(f"embedded builds ok: {len(EXPECTED_BUILDS)}", run.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
