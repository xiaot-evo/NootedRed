#!/usr/bin/env python3
"""Validate the semantic GL/Metal patch data against driver images and page fixtures.

The semantic backend (`NootedRed/UserPatches.cpp` + `NootedRed/GLFixSemanticData.hpp`) locates the
Chromium/GL/Metal fix sites by masked instruction context instead of full 4 KiB page images.  This test
verifies, offline:

  * every table entry is structurally valid (context/mask/find/replace sizes, site inside the context);
  * the GL entries match exactly one site in the tested AMDRadeonX5000GLDriver builds;
  * the Metal variant groups match their page fixtures exactly once, and do not match unrelated builds;
  * a replacement is only emitted when the `find` bytes are present at the matched site.

Inputs:
  * the live 15.8.1 GL driver (stock bytes are reconstructed from the committed exact pages, because the
    running kernel may already have patched the file-backed page cache);
  * the 26.7.1 `GLDriver.bin` / `MTL-image.bin` from `platform-data/` when available;
  * optionally `--reference-repo /tmp/weachy-nootedred` for the Sonoma/Tahoe page fixtures;
  * optionally `--collector-dir` for a 15.8.1 `chromium/MTL-image.bin`.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GL_DRIVER = pathlib.Path(
    "/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver")
GL_DATA = ROOT / "NootedRed" / "GLFixSemanticData.hpp"
USER_PATCHES = ROOT / "NootedRed" / "UserPatches.cpp"
PAGE = 0x1000


class Failure(RuntimeError):
    pass


def load_arrays(path: pathlib.Path) -> dict[str, bytes]:
    text = path.read_text(errors="replace")
    arrays = {}
    for match in re.finditer(r"static const UInt8\s+(\w+)\s*\[\]\s*=\s*\{(.*?)\};", text, re.S):
        values = re.findall(r"0x([0-9A-Fa-f]{2})", match.group(2))
        arrays[match.group(1)] = bytes(int(value, 16) for value in values)
    return arrays


def parse_table(text: str, arrays: dict[str, bytes]) -> list[dict]:
    entries = []
    pattern = re.compile(
        r'\{\s*"([^"]+)"\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*sizeof\((\w+)\)\s*,\s*(\d+)\s*,'
        r'\s*(\w+)\s*,\s*sizeof\((\w+)\)\s*,\s*(\w+)\s*,\s*sizeof\((\w+)\)\s*,\s*(\d+)\s*,'
        r'\s*(true|false)\s*,\s*UserPatches::(\w+)\s*,?\s*\}'
    )
    for match in pattern.finditer(text):
        (name, context_name, mask_name, context_size_name, site_offset,
         find_name, find_size_name, replace_name, replace_size_name,
         group, cache_page, kind) = match.groups()
        if context_name not in arrays or mask_name not in arrays:
            raise Failure(f"{name}: missing context/mask array")
        if find_name not in arrays or replace_name not in arrays:
            raise Failure(f"{name}: missing find/replace array")
        if context_size_name != context_name or find_size_name != find_name or replace_size_name != replace_name:
            raise Failure(f"{name}: sizeof() does not reference the right array")
        entries.append({
            "name": name,
            "context": arrays[context_name],
            "mask": arrays[mask_name],
            "site": int(site_offset),
            "find": arrays[find_name],
            "replace": arrays[replace_name],
            "group": int(group),
            "cache": cache_page == "true",
            "kind": kind,
        })
    if not entries:
        raise Failure("could not parse any semantic patch entries")
    return entries


def masked_matches(data: bytes, context: bytes, mask: bytes, limit: int = 8) -> list[int]:
    hits = []
    for offset in range(0, len(data) - len(context) + 1):
        if all((data[offset + index] & mask[index]) == (context[index] & mask[index])
               for index in range(len(context))):
            hits.append(offset)
            if len(hits) >= limit:
                break
    return hits


def patchable(data: bytes, entry: dict, offset: int) -> bool:
    site = offset + entry["site"]
    return data[site:site + len(entry["find"])] == entry["find"]


def validate_structure(entries: list[dict]) -> None:
    for entry in entries:
        if len(entry["context"]) != len(entry["mask"]):
            raise Failure(f"{entry['name']}: context/mask length differs")
        if not entry["find"] or len(entry["find"]) != len(entry["replace"]):
            raise Failure(f"{entry['name']}: find/replace length differs")
        if entry["site"] + len(entry["find"]) > len(entry["context"]):
            raise Failure(f"{entry['name']}: site is outside the context")
        if entry["cache"] and entry["kind"].startswith("kSemanticGL"):
            raise Failure(f"{entry['name']}: GL entry cannot be marked as a cache page")
        if not entry["cache"] and entry["kind"].startswith("kSemanticMTL"):
            raise Failure(f"{entry['name']}: Metal entry must be marked as a cache page")

    groups = {}
    for entry in entries:
        if entry["group"] == 0:
            continue
        groups.setdefault(entry["group"], []).append(entry)
    for group, members in groups.items():
        if len(members) not in (1, 2):
            raise Failure(f"group {group} must contain one or two sites")
        if any(member["cache"] != members[0]["cache"] for member in members):
            raise Failure(f"group {group} mixes cache and file-backed entries")


def stock_live_gl() -> bytes | None:
    if not GL_DRIVER.is_file():
        return None
    live = GL_DRIVER.read_bytes()
    arrays = load_arrays(USER_PATCHES)
    pages = {
        0xE000: ("kGLDriverHwInfoPage", bytes.fromhex("c7477801000000")),
        0x8000: ("kGLDriverDualQuadPage", bytes.fromhex("83c801")),
    }
    stock = bytearray(live)
    for page_offset, (name, _replace) in pages.items():
        committed = arrays.get(name)
        if committed is None or len(committed) != PAGE:
            return None
        # The committed arrays are the stock page images; the live file's page cache may already contain
        # our replacement bytes, so validate against the committed pages unconditionally.
        stock[page_offset:page_offset + PAGE] = committed
    return bytes(stock)


def find_gl26() -> pathlib.Path | None:
    for candidate in sorted((ROOT / "platform-data").glob("*/drivers/GLDriver.bin")):
        if "26.7.1" in str(candidate):
            return candidate
    return None


def find_mtl26() -> pathlib.Path | None:
    for candidate in sorted((ROOT / "platform-data").glob("*/drivers/MTL-image.bin")):
        if "26.7.1" in str(candidate):
            return candidate
    return None


def validate_gl(entries: list[dict], driver: bytes, label: str) -> None:
    for entry in entries:
        if entry["cache"]:
            continue
        for page in range(0, len(driver), PAGE):
            page_data = driver[page:page + PAGE]
            if len(page_data) != PAGE:
                break
            hits = masked_matches(page_data, entry["context"], entry["mask"])
            if len(hits) > 1:
                raise Failure(f"{label}: {entry['name']} matches {len(hits)} times in page {page:#x}")
            if not hits:
                continue
            offset = page + hits[0]
            if not patchable(driver, entry, offset):
                raise Failure(f"{label}: {entry['name']} site is not the expected find bytes")
            print(f"  GL   {label:<10} {entry['name']:<24} offset {offset:#08x}")
            break
        else:
            raise Failure(f"{label}: {entry['name']} not found")
    else:
        return


def validate_groups(entries: list[dict], image: bytes, label: str, expected_groups: set[int]) -> set[int]:
    matched: set[int] = set()
    for page in range(0, len(image), PAGE):
        page_data = image[page:page + PAGE]
        if len(page_data) != PAGE:
            break
        for group in sorted({entry["group"] for entry in entries if entry["group"] != 0}):
            members = [entry for entry in entries if entry["group"] == group]
            sites = []
            for member in members:
                hits = masked_matches(page_data, member["context"], member["mask"])
                if len(hits) != 1 or not patchable(page_data, member, hits[0]):
                    break
                sites.append(hits[0])
            else:
                if group not in expected_groups:
                    raise Failure(f"{label}: unexpected Metal group {group} matched at page {page:#x}")
                matched.add(group)
                print(f"  MTL  {label:<10} group {group} at page {page:#08x} ({len(sites)} site(s))")
    if matched != expected_groups:
        raise Failure(f"{label}: expected Metal groups {sorted(expected_groups)}, matched {sorted(matched)}")
    return matched


def validate_reference_gl(entries: list[dict], repo: pathlib.Path) -> None:
    fixtures = {
        "Sonoma": ("UserPatchesSonoma.inc", "kGLDriverHwInfoPage_Sonoma", "kGLDriverDualQuadPage_Sonoma"),
        "Sequoia": ("UserPatchesSequoia.inc", "kGLDriverHwInfoPage_Sequoia", "kGLDriverDualQuadPage_Sequoia"),
        "Tahoe": ("UserPatchesTahoe.inc", "kGLDriverHwInfoPage_Tahoe", "kGLDriverDualQuadPage_Tahoe"),
    }
    gl_entries = {
        "kSemanticGLHwInfo": next(entry for entry in entries if entry["kind"] == "kSemanticGLHwInfo"),
        "kSemanticGLDualQuad": next(entry for entry in entries if entry["kind"] == "kSemanticGLDualQuad"),
    }
    for label, (filename, hwinfo_array, dualquad_array) in fixtures.items():
        path = repo / "NootedRed" / filename
        if not path.is_file():
            print(f"  skip reference {label}: {path} missing")
            continue
        arrays = load_arrays(path)
        for array_name, kind in ((hwinfo_array, "kSemanticGLHwInfo"), (dualquad_array, "kSemanticGLDualQuad")):
            page = arrays.get(array_name)
            if page is None or len(page) != PAGE:
                raise Failure(f"reference {label}: {array_name} is not a 4 KiB page")
            entry = gl_entries[kind]
            hits = masked_matches(page, entry["context"], entry["mask"])
            if len(hits) != 1 or not patchable(page, entry, hits[0]):
                raise Failure(f"reference {label}: {entry['name']} did not match {array_name}")
            print(f"  GL   {label:<10} {entry['name']:<24} page offset {hits[0]:#05x}")


def validate_reference_pages(entries: list[dict], repo: pathlib.Path) -> None:
    fixtures = {
        1: ("UserPatchesSonoma.inc", "kMTLControlPage_Sonoma", "Sonoma"),
        2: ("UserPatchesSequoia.inc", "kMTLControlPage_Sequoia", "Sequoia"),
        3: ("UserPatchesTahoe.inc", "kMTLControlPage_Tahoe", "Tahoe"),
    }
    for group, (filename, array_name, label) in fixtures.items():
        path = repo / "NootedRed" / filename
        if not path.is_file():
            print(f"  skip reference {label}: {path} missing")
            continue
        arrays = load_arrays(path)
        page = arrays.get(array_name)
        if page is None or len(page) != PAGE:
            raise Failure(f"reference {label}: {array_name} is not a 4 KiB page")
        members = [entry for entry in entries if entry["group"] == group]
        sites = []
        for member in members:
            hits = masked_matches(page, member["context"], member["mask"])
            if len(hits) != 1 or not patchable(page, member, hits[0]):
                raise Failure(f"reference {label}: {member['name']} did not match the page fixture")
            sites.append(hits[0])
        print(f"  MTL  {label:<10} group {group} reference page fixture ok ({len(sites)} site(s))")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--reference-repo", type=pathlib.Path, help="weachy/NootedRed checkout for older page fixtures"
    )
    parser.add_argument(
        "--collector-dir", type=pathlib.Path, help="collect_compat_data output with chromium/MTL-image.bin"
    )
    args = parser.parse_args()

    data_text = GL_DATA.read_text()
    arrays = load_arrays(GL_DATA)
    entries = parse_table(data_text, arrays)
    validate_structure(entries)
    print(f"parsed {len(entries)} semantic patch(es)")

    stock = stock_live_gl()
    if stock is None:
        print("skip 15.8.1 GL: live driver unavailable")
    else:
        validate_gl(entries, stock, "15.8.1")

    gl26 = find_gl26()
    if gl26 is None:
        print("skip 26.7.1 GL: platform-data driver unavailable")
    else:
        validate_gl(entries, gl26.read_bytes(), "26.7.1")

    mtl26 = find_mtl26()
    if mtl26 is None:
        print("skip 26.7.1 Metal: platform-data image unavailable")
    else:
        validate_groups(entries, mtl26.read_bytes(), "26.7.1", {3, 4})

    if args.collector_dir is not None:
        mtl15 = args.collector_dir / "chromium" / "MTL-image.bin"
        if mtl15.is_file():
            validate_groups(entries, mtl15.read_bytes(), "15.8.1", {2})
        else:
            print(f"skip 15.8.1 Metal: {mtl15} missing")

    if args.reference_repo is not None:
        validate_reference_gl(entries, args.reference_repo)
        validate_reference_pages(entries, args.reference_repo)

    print("all semantic patch data checks passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
