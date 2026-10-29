#!/usr/bin/env python3
"""Locate the source image of runtime-delivered NRPT page hashes (evidence only).

The NootedRedUserPatch kext publishes, for every profile page record that was delivered at its exact
expected pager offset, the actual FNV-1a-64 of the delivered page:

    NRedUserPatchExpectedOffsetActualHashes = "0:0x...", "2:0x...", ...

This tool takes those actual hashes (or any hashes) and searches candidate driver/cache images for a
4 KiB-aligned page with the same FNV-1a-64, so the origin of a delivered page can be identified
offline: which file, which file offset, and which page index inside that file.  It also prints the
hash the NRPT profile expected for that record, so a "content mismatch" report can be explained: the
delivered page belongs to a different image/version, or (if no candidate matches) to content that is
not a clean on-disk page at all (e.g. already modified in memory).

This is an evidence/diagnostic script only.  It never modifies anything and it is not part of the
kext or the offline validator; the acceptance policy is unaffected.

Usage:
    # hashes as printed by the kext / ioreg
    tools/find_nrpt_page_origin.py --profile build/profile-24H232/nred-24H232.nrpt \
        --hashes "0:0x0123...,2:0x4567..."

    # read the property straight out of an ioreg dump file
    ioreg -l -n NootedRedUserPatch > /tmp/nootedred-ioreg.txt
    tools/find_nrpt_page_origin.py --ioreg-file /tmp/nootedred-ioreg.txt \
        --profile build/profile-24H232/nred-24H232.nrpt

    # NRPT v3 profile: expected hashes plus each record's mode, target image and pageVmOffset
    tools/find_nrpt_page_origin.py --ioreg-file /tmp/nootedred-ioreg.txt \
        --profile build/profile-24H232-v3/nred-24H232-v3.nrpt

    # explicit candidate images / fixture directory
    tools/find_nrpt_page_origin.py --hashes 0x... --image /path/to/binary --image-dir fixtures/15.8.2-clean

With no --image/--image-dir the script auto-discovers the AMD X5000/X6000 driver bundles and the
x86_64h dyld shared cache files on the running system (read-only).  Native scanning reuses
test/hash_scan.c (compiled on demand with clang); a pure-Python fallback handles small candidate sets.

Exit codes: 0 = scan completed (even when some hashes were not found), 1 = usage/scan error,
2 = invalid profile or hash input.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

PAGE_SIZE = 4096
NRPT_HEADER_SIZE = 64
NRPT_PAGE_RECORD_SIZE = 32
NRPT_VERSION = 3
NRPT_MAX_IMAGES = 16
NRPT_IMAGE_ENTRY_HEADER_SIZE = 16
NRPT_MAX_IMAGE_PATH_LENGTH = 200
NRPT_MODE_NAMES = {1: "PAGE", 2: "DYLD", 3: "RESOLVER"}
NATIVE_SCAN_THRESHOLD_BYTES = 64 * 1024 * 1024
HASH_SCAN_SOURCE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "test", "hash_scan.c")

DEVICE_TREE_PROPERTY = "NRedUserPatchExpectedOffsetActualHashes"
PROPERTY_RE = re.compile(re.escape(DEVICE_TREE_PROPERTY) + r'"\s*=\s*"([^"]*)"')

# Default candidate roots on a running macOS system (read-only evidence collection).
DEFAULT_IMAGE_GLOBS = (
    "/System/Library/Extensions/AMDRadeon*.bundle/Contents/MacOS/*",
    "/System/Library/Extensions/AppleGVA*.bundle/Contents/MacOS/*",
    "/System/Library/Extensions/AMDRadeonVADriver*.bundle/Contents/MacOS/*",
    "/System/Library/dyld/dyld_shared_cache_x86_64h*",
    "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64h*",
)


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


class NRPTPage:
    __slots__ = ("index", "page_file_offset", "page_hash", "mode", "image_index", "page_vm_offset")

    def __init__(self, index: int, page_file_offset: int, page_hash: int, mode: int,
                 image_index: int, page_vm_offset: int) -> None:
        self.index = index
        self.page_file_offset = page_file_offset
        self.page_hash = page_hash
        self.mode = mode
        self.image_index = image_index
        self.page_vm_offset = page_vm_offset


class NRPTImage:
    __slots__ = ("index", "kind", "path", "unslid_vmaddr", "vm_size")

    def __init__(self, index: int, kind: int, path: str, unslid_vmaddr: int, vm_size: int) -> None:
        self.index = index
        self.kind = kind
        self.path = path
        self.unslid_vmaddr = unslid_vmaddr
        self.vm_size = vm_size


def _round_up4(value: int) -> int:
    return (value + 3) & ~3


def load_nrpt_profile(path: str) -> tuple[str, int, list[NRPTPage], list[NRPTImage]]:
    """Minimal strict NRPT v3 reader (mode/image metadata used for evidence only)."""
    with open(path, "rb") as handle:
        data = handle.read()
    if len(data) < NRPT_HEADER_SIZE:
        raise ValueError(f"{path}: shorter than the 64-byte NRPT header")
    if data[0:4] != b"NRPT":
        raise ValueError(f"{path}: not an NRPT profile (bad magic)")
    version, header_size = struct.unpack_from("<HH", data, 4)
    if version != NRPT_VERSION or header_size != NRPT_HEADER_SIZE:
        raise ValueError(f"{path}: unsupported NRPT version/header ({version}/{header_size}); v3 only")
    build = data[8:24].split(b"\x00", 1)[0].decode("ascii", "replace")
    page_count, site_count = struct.unpack_from("<HH", data, 32)
    page_table_size, site_table_size, payload_checksum = struct.unpack_from("<III", data, 36)
    image_count = struct.unpack_from("<H", data, 52)[0]
    image_table_size = struct.unpack_from("<I", data, 54)[0]
    if page_table_size != page_count * NRPT_PAGE_RECORD_SIZE:
        raise ValueError(f"{path}: pageTableSize mismatch for NRPT v3")
    expected_size = NRPT_HEADER_SIZE + page_table_size + site_table_size + image_table_size
    if expected_size != len(data):
        raise ValueError(f"{path}: total size mismatch (header says {expected_size}, file is {len(data)})")
    if fnv1a32(data[NRPT_HEADER_SIZE:]) != payload_checksum:
        raise ValueError(f"{path}: payload checksum mismatch")

    images: list[NRPTImage] = []
    cursor = NRPT_HEADER_SIZE + page_table_size + site_table_size
    end = cursor + image_table_size
    if not 1 <= image_count <= NRPT_MAX_IMAGES or end > len(data):
        raise ValueError(f"{path}: invalid image table")
    for image_index in range(image_count):
        if end - cursor < NRPT_IMAGE_ENTRY_HEADER_SIZE:
            raise ValueError(f"{path}: truncated image entry")
        kind = data[cursor]
        path_length = struct.unpack_from("<H", data, cursor + 2)[0]
        unslid_vmaddr = struct.unpack_from("<Q", data, cursor + 4)[0]
        vm_size = struct.unpack_from("<I", data, cursor + 12)[0]
        if not 1 <= path_length <= NRPT_MAX_IMAGE_PATH_LENGTH:
            raise ValueError(f"{path}: invalid image path length {path_length}")
        entry_size = NRPT_IMAGE_ENTRY_HEADER_SIZE + _round_up4(path_length + 1)
        if end - cursor < entry_size:
            raise ValueError(f"{path}: image entry exceeds image table")
        base = cursor + NRPT_IMAGE_ENTRY_HEADER_SIZE
        image_path = data[base:base + path_length].decode("ascii", "replace")
        images.append(NRPTImage(image_index, kind, image_path, unslid_vmaddr, vm_size))
        cursor += entry_size
    if cursor != end:
        raise ValueError(f"{path}: imageTableSize mismatch")

    pages: list[NRPTPage] = []
    for index in range(page_count):
        offset = NRPT_HEADER_SIZE + index * NRPT_PAGE_RECORD_SIZE
        page_file_offset, page_hash = struct.unpack_from("<QQ", data, offset)
        mode = data[offset + 22]
        image_index = struct.unpack_from("<H", data, offset + 24)[0]
        page_vm_offset = struct.unpack_from("<I", data, offset + 28)[0]
        pages.append(NRPTPage(index, page_file_offset, page_hash, mode, image_index, page_vm_offset))
    return build, version, pages, images


def parse_hash_spec(spec: str) -> list[tuple[int | None, int]]:
    """Parse '0:0x...', '0x...', comma/space separated lists into (index-or-None, hash) pairs."""
    entries: list[tuple[int | None, int]] = []
    for token in re.split(r"[\s,]+", spec.strip()):
        if not token:
            continue
        index: int | None = None
        value = token
        if ":" in token:
            index_text, value = token.split(":", 1)
            index = int(index_text, 10)
        if not value.lower().startswith("0x"):
            value = "0x" + value
        entries.append((index, int(value, 16)))
    return entries


def read_hashes_from_ioreg(path: str) -> list[tuple[int | None, int]]:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    entries: list[tuple[int | None, int]] = []
    for match in PROPERTY_RE.finditer(text):
        entries.extend(parse_hash_spec(match.group(1)))
    return entries


def default_candidate_images() -> list[str]:
    images: list[str] = []
    for pattern in DEFAULT_IMAGE_GLOBS:
        for path in sorted(glob.glob(pattern)):
            if not os.path.isfile(path) or path.endswith(".map") or path.endswith(".symbols"):
                continue
            images.append(path)
    return images


def discover_images(image_args: list[str], image_dirs: list[str]) -> list[str]:
    images: list[str] = []
    for path in image_args:
        if os.path.isfile(path):
            images.append(path)
        else:
            print(f"skip (not a file): {path}", file=sys.stderr)
    for directory in image_dirs:
        for root, _dirs, files in os.walk(directory):
            for name in sorted(files):
                path = os.path.join(root, name)
                if os.path.isfile(path) and os.path.getsize(path) >= PAGE_SIZE:
                    images.append(path)
    if not images:
        images = default_candidate_images()
    # Drop unreadable / too-small files and duplicate paths.
    unique: list[str] = []
    seen: set[str] = set()
    for path in images:
        if path in seen:
            continue
        seen.add(path)
        try:
            if os.path.getsize(path) < PAGE_SIZE or not os.access(path, os.R_OK):
                continue
        except OSError:
            continue
        unique.append(path)
    return unique


def native_hash_scan_binary() -> str | None:
    if not os.path.isfile(HASH_SCAN_SOURCE):
        return None
    compiler = shutil.which("clang") or shutil.which("cc") or shutil.which("gcc")
    if compiler is None:
        return None
    with open(HASH_SCAN_SOURCE, "rb") as handle:
        import hashlib

        digest = hashlib.sha256(handle.read()).hexdigest()[:16]
    binary_path = os.path.join(tempfile.gettempdir(), f"nrpt_hash_scan_{digest}")
    if os.path.isfile(binary_path) and os.access(binary_path, os.X_OK):
        return binary_path
    try:
        completed = subprocess.run([compiler, "-O2", "-o", binary_path, HASH_SCAN_SOURCE],
                                   capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0 or not os.path.isfile(binary_path):
        return None
    return binary_path


def scan_native(images: list[str], wanted: set[int], binary_path: str) -> dict[int, list[tuple[str, int]]] | None:
    if not wanted:
        return {}
    query_handle = tempfile.NamedTemporaryFile(mode="w", prefix="nrpt-origin-queries-", suffix=".txt",
                                              delete=False)
    try:
        for digest in sorted(wanted):
            query_handle.write(f"{digest:016x}\n")
        query_handle.close()
        completed = subprocess.run([binary_path, query_handle.name] + images, capture_output=True, text=True,
                                   timeout=1800)
        if completed.returncode != 0:
            print(f"native scanner failed: {completed.stderr.strip()}", file=sys.stderr)
            return None
        results: dict[int, list[tuple[str, int]]] = {digest: [] for digest in wanted}
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
            if digest in results and 0 <= image_index < len(images):
                results[digest].append((images[image_index], offset))
        return results
    except (OSError, subprocess.SubprocessError) as error:
        print(f"native scanner failed: {error}", file=sys.stderr)
        return None
    finally:
        if not query_handle.closed:
            query_handle.close()
        try:
            os.unlink(query_handle.name)
        except OSError:
            pass


def scan_python(images: list[str], wanted: set[int]) -> dict[int, list[tuple[str, int]]]:
    results: dict[int, list[tuple[str, int]]] = {digest: [] for digest in wanted}
    for path in images:
        try:
            with open(path, "rb") as handle:
                offset = 0
                while True:
                    page = handle.read(PAGE_SIZE)
                    if len(page) != PAGE_SIZE:
                        break
                    digest = fnv1a64(page)
                    if digest in results:
                        results[digest].append((path, offset))
                    offset += PAGE_SIZE
        except OSError:
            continue
    return results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Find the source image of runtime-delivered NRPT page hashes (evidence only).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--hashes", action="append", default=[],
                        help="hash spec, e.g. '0:0x0123...' or comma-separated list (repeatable)")
    parser.add_argument("--ioreg-file", help=f"file containing an ioreg dump with {DEVICE_TREE_PROPERTY}")
    parser.add_argument("--profile", help="NRPT v3 profile to show the expected hash, mode and target-image metadata per record index")
    parser.add_argument("--image", action="append", default=[], help="explicit candidate image (repeatable)")
    parser.add_argument("--image-dir", action="append", default=[],
                        help="candidate image directory scanned recursively (repeatable)")
    parser.add_argument("--json", action="store_true", help="machine-readable JSON output")
    parser.add_argument("--no-native", action="store_true", help="force the pure-Python scanner")
    args = parser.parse_args(argv)

    requested: list[tuple[int | None, int]] = []
    for spec in args.hashes:
        requested.extend(parse_hash_spec(spec))
    if args.ioreg_file:
        requested.extend(read_hashes_from_ioreg(args.ioreg_file))
    if not requested:
        print("error: no hashes supplied (use --hashes and/or --ioreg-file)", file=sys.stderr)
        return 2

    pages_by_index: dict[int, NRPTPage] = {}
    images_by_index: dict[int, NRPTImage] = {}
    build = None
    profile_version = None
    if args.profile:
        try:
            build, profile_version, pages, profile_images = load_nrpt_profile(args.profile)
            pages_by_index = {page.index: page for page in pages}
            images_by_index = {image.index: image for image in profile_images}
        except (OSError, ValueError) as error:
            print(f"error: {error}", file=sys.stderr)
            return 2

    images = discover_images(args.image, args.image_dir)
    if not images:
        print("error: no candidate images found", file=sys.stderr)
        return 1
    total_bytes = 0
    for path in images:
        try:
            total_bytes += os.path.getsize(path)
        except OSError:
            pass

    wanted = {digest for _index, digest in requested}
    print(f"scanning {len(wanted)} hash(es) over {len(images)} candidate image(s) "
          f"({total_bytes / 1e9:.2f} GB)", file=sys.stderr)
    scan_mode = "python"
    matches: dict[int, list[tuple[str, int]]] | None = None
    if not args.no_native:
        binary = native_hash_scan_binary()
        if binary is not None:
            if total_bytes > NATIVE_SCAN_THRESHOLD_BYTES:
                matches = scan_native(images, wanted, binary)
                if matches is not None:
                    scan_mode = "native"
            else:
                matches = scan_native(images, wanted, binary)
                if matches is not None:
                    scan_mode = "native"
    if matches is None:
        if total_bytes > 256 * 1024 * 1024:
            print("error: native scanner unavailable and candidate set is too large for the Python fallback "
                  "(install clang or use --image/--image-dir with smaller inputs)", file=sys.stderr)
            return 1
        matches = scan_python(images, wanted)
    print(f"scan mode: {scan_mode}", file=sys.stderr)

    report: dict[str, object] = {
        "profile": args.profile,
        "profile_build": build,
        "profile_version": profile_version,
        "scan_mode": scan_mode,
        "candidate_images": len(images),
        "candidate_bytes": total_bytes,
        "entries": [],
    }
    found_count = 0
    for index, digest in requested:
        origins = [{"image": image, "offset": offset, "page_index": offset // PAGE_SIZE,
                    "page_offset_hex": f"0x{offset:X}"} for image, offset in matches.get(digest, [])]
        expected = None
        expected_mode = None
        expected_offset = None
        expected_image = None
        expected_page_vm_offset = None
        if index is not None and index in pages_by_index:
            page = pages_by_index[index]
            expected = page.page_hash
            expected_mode = NRPT_MODE_NAMES.get(page.mode, f"mode{page.mode}")
            expected_offset = page.page_file_offset
            image = images_by_index.get(page.image_index)
            if image is not None:
                expected_image = {
                    "index": image.index,
                    "kind": "standalone-file" if image.kind == 0 else "dyld-shared-cache",
                    "path": image.path,
                    "unslid_vmaddr": f"0x{image.unslid_vmaddr:X}",
                    "vm_size": f"0x{image.vm_size:X}",
                }
            expected_page_vm_offset = page.page_vm_offset
        entry = {
            "index": index,
            "actual_hash": f"0x{digest:016X}",
            "expected_hash": f"0x{expected:016X}" if expected is not None else None,
            "expected_page_file_offset": f"0x{expected_offset:X}" if expected_offset is not None else None,
            "expected_mode": expected_mode,
            "expected_image": expected_image,
            "expected_page_vm_offset": (f"0x{expected_page_vm_offset:X}"
                                        if expected_page_vm_offset is not None else None),
            "actual_equals_expected": expected is not None and digest == expected,
            "origins": origins,
        }
        report["entries"].append(entry)
        if origins:
            found_count += 1

        prefix = f"[{index}]" if index is not None else "[?]"
        print(f"{prefix} actual 0x{digest:016X}", end="")
        if expected is not None:
            verdict = "== expected" if digest == expected else f"!= expected 0x{expected:016X}"
            print(f" ({verdict}, profile offset 0x{expected_offset:X})", end="")
        print()
        if expected_image is not None:
            print(f"    profile target: mode={expected_mode} image[{expected_image['index']}] "
                  f"{expected_image['kind']} {expected_image['path']} "
                  f"pageVmOffset=0x{expected_page_vm_offset:X} "
                  f"(unslid 0x{int(expected_image['unslid_vmaddr'], 16):X})")
        if origins:
            for origin in origins:
                print(f"    found in {origin['image']} at 0x{origin['offset']:X} "
                      f"(page {origin['page_index']})")
        else:
            print("    no 4 KiB-aligned match in the candidate set "
                  "(possibly already patched/generated in memory, not a clean on-disk page)")

    print(f"\n{found_count}/{len(requested)} delivered hash(es) located in the candidate set")
    if args.json:
        print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
