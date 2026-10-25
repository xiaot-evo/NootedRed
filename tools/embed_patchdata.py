#!/usr/bin/env python3
"""Embed the committed external ``PatchData/`` sets into the satellite kext as static C++ arrays.

The satellite must not perform kernel VFS/file-system reads during early boot: a diagnostic boot showed
that forcing the external-data loader to read ``PatchData/<build>/manifest.bin`` + ``pages.bin`` hangs
the machine. The approved option is therefore to compile the data into the kext:

    Python generator (this file) -> NootedRedUserPatch/PatchDataBlob.{hpp,cpp} -> kext binary

The external ``PatchData/`` directory stays the source of truth for generation/host validation; the
kext consumes only the generated arrays. Adding or changing a build now requires running this generator
and rebuilding/re-signing the satellite (the approved stability trade-off).

The generator is fully deterministic: sorted build order, no timestamps or absolute paths, content
SHA-256 values only. ``NootedRedUserPatch/PatchDataBlob.hpp`` / ``.cpp`` are generated files and must
not be edited by hand.

Usage::

    python3 tools/embed_patchdata.py               # write the generated files
    python3 tools/embed_patchdata.py --check       # verify committed files are current
    python3 tools/embed_patchdata.py --report      # list builds, sizes and hashes

The generated output is also round-tripped internally: the rendered C++ arrays are decoded again and
compared byte-for-byte with ``PatchData/`` before anything is written or accepted.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

import userpatch_data as format_contract

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PATCHDATA = ROOT / "PatchData"
DEFAULT_HPP = ROOT / "NootedRedUserPatch" / "PatchDataBlob.hpp"
DEFAULT_CPP = ROOT / "NootedRedUserPatch" / "PatchDataBlob.cpp"

GENERATOR_VERSION = 1
PAGE_SIZE = format_contract.PAGE_SIZE
MANIFEST_HEADER = struct.Struct("<4sHH16sHHHHIIIIIIIIQ")

BYTE_ARRAY_RE = re.compile(r"const uint8_t (kManifest_\w+|kPages_\w+)\[\] = \{(.*?)\};", re.S)
HEX_BYTE_RE = re.compile(r"0x([0-9A-Fa-f]{2})")

HEADER_NAME_RE = re.compile(r"^[0-9A-Za-z._-]{1,15}$")


class EmbedError(Exception):
    """PatchData is missing/invalid or the generated source cannot be produced/verified."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise EmbedError(message)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _decode_build_name(raw: bytes) -> str:
    nul = raw.find(b"\x00")
    _require(nul > 0, "manifest build field is not NUL padded")
    _require(all(byte == 0 for byte in raw[nul:]), "manifest build field has non-zero padding")
    try:
        name = raw[:nul].decode("ascii")
    except UnicodeDecodeError as error:
        raise EmbedError(f"manifest build field is not ASCII: {error}") from error
    _require(HEADER_NAME_RE.fullmatch(name) is not None, f"invalid build string {name!r}")
    return name


@dataclass(frozen=True)
class BuildBlob:
    build: str
    manifest: bytes
    pages: bytes
    darwin: tuple[int, int, int]
    apu_mask: int
    table_count: int
    page_count: int
    site_count: int
    pages_checksum: int
    manifest_checksum: int

    @property
    def manifest_symbol(self) -> str:
        return f"kManifest_{self.build.replace('.', '_').replace('-', '_')}"

    @property
    def pages_symbol(self) -> str:
        return f"kPages_{self.build.replace('.', '_').replace('-', '_')}"

    @property
    def manifest_sha256(self) -> str:
        return sha256_hex(self.manifest)

    @property
    def pages_sha256(self) -> str:
        return sha256_hex(self.pages)


def load_builds(patchdata_root: Path) -> list[BuildBlob]:
    """Read and lightly validate every ``PatchData/<build>/{manifest,pages}.bin`` pair."""

    _require(patchdata_root.is_dir(), f"missing PatchData directory {patchdata_root}")
    builds: list[BuildBlob] = []
    for build_dir in sorted(patchdata_root.iterdir(), key=lambda path: path.name):
        if not build_dir.is_dir():
            continue
        manifest_path = build_dir / "manifest.bin"
        pages_path = build_dir / "pages.bin"
        _require(manifest_path.is_file() and pages_path.is_file(),
                 f"{build_dir}: expected both manifest.bin and pages.bin")
        manifest = manifest_path.read_bytes()
        pages = pages_path.read_bytes()
        _require(len(manifest) >= MANIFEST_HEADER.size,
                 f"{manifest_path}: {len(manifest)} bytes, expected at least {MANIFEST_HEADER.size}")
        (magic, version, header_size, build_raw, darwin_major, darwin_minor, darwin_patch,
         reserved, apu_mask, table_count, page_count, site_count, manifest_size,
         pages_size, pages_checksum, reserved2, manifest_checksum) = MANIFEST_HEADER.unpack_from(manifest)
        _require(magic == b"NRPD", f"{manifest_path}: bad magic {magic!r}")
        _require(version == format_contract.FORMAT_VERSION, f"{manifest_path}: unsupported version {version}")
        _require(header_size == format_contract.HEADER_SIZE,
                 f"{manifest_path}: headerSize {header_size} != {format_contract.HEADER_SIZE}")
        _require(reserved == 0 and reserved2 == 0, f"{manifest_path}: reserved fields must be zero")
        build = _decode_build_name(build_raw)
        _require(build == build_dir.name,
                 f"{manifest_path}: build {build!r} does not match directory {build_dir.name!r}")
        _require(manifest_size == len(manifest),
                 f"{manifest_path}: manifestSize {manifest_size} != file length {len(manifest)}")
        _require(pages_size == len(pages),
                 f"{pages_path}: pagesSize {pages_size} != file length {len(pages)}")
        _require(not (pages_size % PAGE_SIZE),
                 f"{pages_path}: pagesSize {pages_size} is not a multiple of {PAGE_SIZE}")
        _require(pages_checksum == format_contract.fnv1a32(pages),
                 f"{pages_path}: pagesChecksum does not match pages.bin")
        checksum_view = bytearray(manifest)
        checksum_view[format_contract.HEADER_CHECKSUM_OFFSET:
                      format_contract.HEADER_CHECKSUM_OFFSET + 8] = b"\x00" * 8
        _require(manifest_checksum == format_contract.fnv1a64(bytes(checksum_view)),
                 f"{manifest_path}: manifestChecksum does not match the manifest")
        _require(page_count == pages_size // PAGE_SIZE,
                 f"{build}: pageCount {page_count} != pagesSize/{PAGE_SIZE}")
        builds.append(BuildBlob(
            build=build,
            manifest=manifest,
            pages=pages,
            darwin=(darwin_major, darwin_minor, darwin_patch),
            apu_mask=apu_mask,
            table_count=table_count,
            page_count=page_count,
            site_count=site_count,
            pages_checksum=pages_checksum,
            manifest_checksum=manifest_checksum,
        ))
    _require(builds, f"{patchdata_root}: no PatchData build directories found")
    names = [blob.build for blob in builds]
    _require(len(set(names)) == len(names), f"duplicate embedded build names: {names}")
    _require(len({blob.manifest_symbol for blob in builds}) == len(builds), "manifest symbol collision")
    _require(len({blob.pages_symbol for blob in builds}) == len(builds), "pages symbol collision")
    return builds


def _format_bytes(name: str, data: bytes, description: str) -> str:
    lines = [
        f"// {description} ({len(data)} bytes)",
        f"const uint8_t {name}[] = {{",
    ]
    for offset in range(0, len(data), 16):
        chunk = ", ".join(f"0x{byte:02X}" for byte in data[offset:offset + 16])
        lines.append(f"    {chunk},")
    lines.append("};")
    return "\n".join(lines)


def _render_header(builds: list[BuildBlob], provenance: str) -> str:
    lines = [
        "// NootedRedUserPatch embedded PatchData - GENERATED FILE, DO NOT EDIT BY HAND.",
        "//",
        "// Generated by tools/embed_patchdata.py. Source data and SHA-256:",
        provenance,
        "//",
        "// The kext parses these buffers directly; it must not perform VFS/file-system reads.",
        "// `kBuilds` is the selector index: iterate it and compare `build` with the exact",
        "// `kern.osversion` string, then validate the manifest bytes with the normal v1 parser.",
        "// Metadata mirrors the validated manifest header for early filtering/diagnostics and is",
        "// not authoritative: the parser must still check magic/version/sizes/checksums/sites.",
        "//",
        "// Regenerate: python3 tools/embed_patchdata.py",
        "// Verify:     python3 tools/embed_patchdata.py --check && python3 tools/test_embedded_patchdata.py",
        "",
        "#pragma once",
        "#include <stddef.h>",
        "#include <stdint.h>",
        "",
        "namespace NRedUserPatchData",
        "{",
        "    // One embedded exact-build PatchData set.",
        "    struct EmbeddedBuild",
        "    {",
        "        const char* build;          // exact NUL-terminated kern.osversion, e.g. \"24H32\"",
        "        const uint8_t* manifest;    // embedded manifest.bin bytes",
        "        const size_t manifestSize;  // manifest.bin length in bytes",
        "        const uint8_t* pages;       // embedded pages.bin bytes (4 KiB page images)",
        "        const size_t pagesSize;     // pages.bin length in bytes",
        "",
        "        // Mirrored from the manifest header; the loader re-validates the bytes.",
        "        const uint32_t pagesChecksum;     // FNV-1a-32 over pages.bin",
        "        const uint64_t manifestChecksum;  // FNV-1a-64 over manifest.bin with the field zeroed",
        "        const uint16_t darwinMajor;",
        "        const uint16_t darwinMinor;",
        "        const uint16_t darwinPatch;",
        "        const uint32_t apuMask;           // APU family mask (bits 0..5)",
        "        const uint32_t tableCount;",
        "        const uint32_t pageCount;",
        "        const uint32_t siteCount;",
        "    };",
        "",
        "    // Selector index, sorted by build string.  Exactly `kBuildCount` entries.",
        "    extern const EmbeddedBuild kBuilds[];",
        "    extern const size_t kBuildCount;",
        "",
        "}    // namespace NRedUserPatchData",
        "",
    ]
    return "\n".join(lines)


def _render_source(builds: list[BuildBlob]) -> str:
    lines = [
        "// NootedRedUserPatch embedded PatchData - GENERATED FILE, DO NOT EDIT BY HAND.",
        "// See NootedRedUserPatch/PatchDataBlob.hpp and tools/README-userpatch-data.md.",
        "",
        "#include \"PatchDataBlob.hpp\"",
        "",
        "namespace NRedUserPatchData",
        "{",
        "namespace",
        "{",
    ]
    for index, blob in enumerate(builds):
        if index:
            lines.append("")
        lines.append(_format_bytes(blob.manifest_symbol, blob.manifest,
                                   f"{blob.build} manifest.bin (sha256 {blob.manifest_sha256})"))
        lines.append("")
        lines.append(_format_bytes(blob.pages_symbol, blob.pages,
                                   f"{blob.build} pages.bin (sha256 {blob.pages_sha256})"))
    lines.extend([
        "}    // namespace",
        "",
        "extern const EmbeddedBuild kBuilds[] = {",
    ])
    for blob in builds:
        lines.extend([
            "    {",
            f"        \"{blob.build}\",",
            f"        {blob.manifest_symbol},",
            f"        sizeof({blob.manifest_symbol}),",
            f"        {blob.pages_symbol},",
            f"        sizeof({blob.pages_symbol}),",
            f"        0x{blob.pages_checksum:08X}U,",
            f"        0x{blob.manifest_checksum:016X}ULL,",
            f"        {blob.darwin[0]}, {blob.darwin[1]}, {blob.darwin[2]},",
            f"        0x{blob.apu_mask:02X}U,",
            f"        {blob.table_count}U, {blob.page_count}U, {blob.site_count}U,",
            "    },",
        ])
    lines.extend([
        "};",
        "",
        "extern const size_t kBuildCount = sizeof(kBuilds) / sizeof(kBuilds[0]);",
        "",
        "}    // namespace NRedUserPatchData",
        "",
    ])
    return "\n".join(lines)


def _provenance_lines(builds: list[BuildBlob]) -> str:
    widths = max(len(blob.build) for blob in builds)
    lines = []
    for blob in builds:
        lines.append(f"//   {blob.build.ljust(widths)}  manifest.bin {blob.manifest_sha256} "
                     f"({len(blob.manifest)} B), pages.bin {blob.pages_sha256} ({len(blob.pages)} B)")
    return "\n".join(lines)


def parse_generated_arrays(source: str) -> dict[str, bytes]:
    """Decode the byte arrays back out of generated C++ (used for the internal round-trip check)."""

    arrays: dict[str, bytes] = {}
    for match in BYTE_ARRAY_RE.finditer(source):
        name = match.group(1)
        _require(name not in arrays, f"duplicate generated array {name}")
        arrays[name] = bytes(int(value, 16) for value in HEX_BYTE_RE.findall(match.group(2)))
    return arrays


def render(patchdata_root: Path = DEFAULT_PATCHDATA) -> tuple[bytes, bytes, list[BuildBlob]]:
    builds = load_builds(patchdata_root)
    header = _render_header(builds, _provenance_lines(builds)).encode("utf-8")
    source = _render_source(builds).encode("utf-8")

    # Internal byte-for-byte round-trip: the generated arrays must decode back to the PatchData bytes.
    arrays = parse_generated_arrays(source.decode("utf-8"))
    expected_arrays = 2 * len(builds)
    _require(len(arrays) == expected_arrays,
             f"generated source exposes {len(arrays)} arrays, expected {expected_arrays}")
    for blob in builds:
        _require(arrays.get(blob.manifest_symbol) == blob.manifest,
                 f"{blob.build}: generated manifest array does not round-trip")
        _require(arrays.get(blob.pages_symbol) == blob.pages,
                 f"{blob.build}: generated pages array does not round-trip")
    return header, source, builds


def check(hpp: Path = DEFAULT_HPP, cpp: Path = DEFAULT_CPP,
          patchdata_root: Path = DEFAULT_PATCHDATA) -> list[str]:
    header, source, _ = render(patchdata_root)
    problems: list[str] = []
    for path, expected in ((hpp, header), (cpp, source)):
        if not path.is_file():
            problems.append(f"missing generated file {path}")
            continue
        actual = path.read_bytes()
        if actual != expected:
            problems.append(f"{path}: stale generated file; run python3 tools/embed_patchdata.py")
            problems.append(f"  committed sha256 {sha256_hex(actual)}, regenerated {sha256_hex(expected)}")
    return problems


def report(patchdata_root: Path = DEFAULT_PATCHDATA) -> int:
    builds = load_builds(patchdata_root)
    print(f"embedded PatchData sets: {len(builds)}")
    total = 0
    for blob in builds:
        total += len(blob.manifest) + len(blob.pages)
        print(f"  {blob.build}: Darwin {'.'.join(map(str, blob.darwin))}, "
              f"apuMask 0x{blob.apu_mask:02X}, {blob.table_count} table(s), "
              f"{blob.page_count} page(s), {blob.site_count} site(s)")
        print(f"    manifest.bin {len(blob.manifest)} B sha256 {blob.manifest_sha256}")
        print(f"    pages.bin    {len(blob.pages)} B sha256 {blob.pages_sha256}")
    print(f"embedded payload: {total} bytes before C++ encoding")
    return 0


def write(hpp: Path = DEFAULT_HPP, cpp: Path = DEFAULT_CPP,
          patchdata_root: Path = DEFAULT_PATCHDATA) -> int:
    header, source, builds = render(patchdata_root)
    hpp.parent.mkdir(parents=True, exist_ok=True)
    hpp.write_bytes(header)
    cpp.write_bytes(source)

    # Verify what was written by re-running the same checks against the committed files.
    problems = check(hpp, cpp, patchdata_root)
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1
    print(f"wrote {hpp} ({len(header)} B) and {cpp} ({len(source)} B)")
    print(f"embedded {len(builds)} build(s): {', '.join(blob.build for blob in builds)}")
    print(f"sha256 {hpp.name} {sha256_hex(header)}")
    print(f"sha256 {cpp.name} {sha256_hex(source)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Embed committed PatchData sets into NootedRedUserPatch static C++ arrays.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=("The generated files are deterministic and round-trip checked against PatchData/. "
                "The satellite kext reads only the embedded arrays (no VFS I/O).\n"),
    )
    parser.add_argument("--patchdata", type=Path, default=DEFAULT_PATCHDATA,
                        help="PatchData source root (default: repo-root PatchData/)")
    parser.add_argument("--hpp", type=Path, default=DEFAULT_HPP, help="output header path")
    parser.add_argument("--cpp", type=Path, default=DEFAULT_CPP, help="output source path")
    parser.add_argument("--check", action="store_true", help="verify committed generated files")
    parser.add_argument("--report", action="store_true", help="print builds/sizes/hashes")
    args = parser.parse_args(argv)
    try:
        if args.report:
            return report(args.patchdata)
        if args.check:
            problems = check(args.hpp, args.cpp, args.patchdata)
            if problems:
                for problem in problems:
                    print(f"error: {problem}", file=sys.stderr)
                return 1
            print(f"ok: {args.hpp} and {args.cpp} are current")
            return 0
        return write(args.hpp, args.cpp, args.patchdata)
    except EmbedError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
