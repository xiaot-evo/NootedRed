#!/usr/bin/env python3
"""Generate NootedRed UserPatches page images from a target macOS install.

The output is a C++ snippet containing the 4 KiB page images, the per-page patch
sites, and a PatchSet entry for UserPatches::registerPatchSets().

This deliberately does not guess offsets: the JSON spec supplies the page
offsets/VA, find/replace bytes, and skip/count.  Every find is validated in the
extracted page before anything is emitted.
"""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

PAGE_SIZE = 0x1000


def parse_hex(value: str) -> int:
    return int(value, 16)


def read_page(path: Path, offset: int) -> bytes:
    with path.open("rb") as handle:
        handle.seek(offset)
        page = handle.read(PAGE_SIZE)
    if len(page) != PAGE_SIZE:
        raise SystemExit(f"{path}: short page at {offset:#x} ({len(page)} bytes)")
    return page


def find_sites(page: bytes, find: bytes, skip: int, count: int) -> list[int]:
    offsets: list[int] = []
    start = 0
    while True:
        index = page.find(find, start)
        if index < 0:
            break
        offsets.append(index)
        start = index + 1
    if skip >= len(offsets):
        raise SystemExit(f"skip={skip} but only {len(offsets)} occurrence(s) of {find.hex()}")
    selected = offsets[skip:skip + count]
    if len(selected) != count:
        raise SystemExit(f"expected {count} site(s) after skip={skip}, found {len(selected)}")
    return selected


def c_array(name: str, data: bytes) -> str:
    lines = [f"static const UInt8 {name}[] = {{"]
    for i in range(0, len(data), 16):
        chunk = ", ".join(f"0x{b:02X}" for b in data[i:i + 16])
        lines.append(f"    {chunk},")
    lines.append("};")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("spec", help="JSON spec describing pages and patches")
    parser.add_argument("--out", help="write the C++ snippet here instead of stdout")
    args = parser.parse_args()

    spec = json.loads(Path(args.spec).read_text())
    gl_driver = Path(spec["gl_driver"])
    cache_prefix = spec.get("cache_prefix", "kMTL")
    out: list[str] = []

    page_vars: dict[str, bytes] = {}
    patches: list[dict] = []

    for item in spec.get("gl_pages", []):
        page = read_page(gl_driver, parse_hex(item["file_offset"]))
        find = bytes.fromhex(item["find"])
        replace = bytes.fromhex(item["replace"])
        if len(find) != len(replace):
            raise SystemExit(f"{item['name']}: find/replace lengths differ")
        offsets = find_sites(page, find, int(item.get("skip", 0)), int(item.get("count", 1)))
        var = "k" + item["name"]
        page_vars.setdefault(var, page)
        for offset in offsets:
            patches.append({"page": var, "offset": offset, "find": item["find"], "replace": item["replace"]})
        print(f"{item['name']}: page {item['file_offset']} sites {[hex(x) for x in offsets]}", flush=True)

    cache_base = spec.get("cache_base")
    for item in spec.get("cache_pages", []):
        cache = Path(item["cache_file"])
        page_va = parse_hex(item["va"])
        base = parse_hex(item["cache_base"] if cache_base is None else cache_base)
        page = read_page(cache, page_va - base)
        find = bytes.fromhex(item["find"])
        replace = bytes.fromhex(item["replace"])
        if len(find) != len(replace):
            raise SystemExit(f"{item['name']}: find/replace lengths differ")
        offsets = find_sites(page, find, int(item.get("skip", 0)), int(item.get("count", 1)))
        var = "k" + item["name"]
        page_vars.setdefault(var, page)
        for offset in offsets:
            patches.append({"page": var, "offset": offset, "find": item["find"], "replace": item["replace"]})
        print(f"{item['name']}: va {item['va']} sites {[hex(x) for x in offsets]}", flush=True)

    if not patches:
        raise SystemExit("spec contains no patches")

    for var, page in page_vars.items():
        out.append(c_array(var, page))
        out.append("")

    # Emit one PagePatch per site.  The same page may appear multiple times; the
    # native backend groups by page pointer.  Find/replace arrays must be declared
    # before the table that references them.
    for patch in patches:
        find_name = "kFind" + patch["page"][1:] + f"_{patch['offset']:X}"
        replace_name = "kReplace" + patch["page"][1:] + f"_{patch['offset']:X}"
        out.append(f"static const UInt8 {find_name}[] = {{"
                   f"{', '.join('0x%02X' % b for b in bytes.fromhex(patch['find']))}}};")
        out.append(f"static const UInt8 {replace_name}[] = {{"
                   f"{', '.join('0x%02X' % b for b in bytes.fromhex(patch['replace']))}}};")
        patch["find_name"] = find_name
        patch["replace_name"] = replace_name
    out.append("")
    out.append("static const UserPatches::PagePatch kGeneratedPatches[] = {")
    for patch in patches:
        out.append(f"    // {patch['find_name']} at {patch['page']}+{patch['offset']:#x}")
        out.append(f"    {{UserPatcher::FileSegment::SegmentTextText, {patch['page']}, {patch['find_name']}, "
                   f"{patch['replace_name']},")
        out.append(f"     sizeof({patch['find_name']}), 0, 1}},")
    out.append("};")
    out.append("")

    out.append("static const UserPatches::PatchSet kGeneratedPatchSet[] = {")
    darwin = spec.get("darwin")
    if darwin is None:
        raise SystemExit("spec needs darwin = [major, minor]")
    out.append(f'    {{"{spec.get("name", "generated")}", PenguinWizardry::KernelVersion({darwin[0]}, {darwin[1]}),')
    out.append(f'     PenguinWizardry::KernelVersion({darwin[0]}, {darwin[1]}), UserPatches::kApuAll,')
    out.append('     kGeneratedPatches, sizeof(kGeneratedPatches) / sizeof(kGeneratedPatches[0])},')
    out.append("};")

    text = "\n".join(out) + "\n"
    if args.out:
        Path(args.out).write_text(text)
        print(f"wrote {args.out}", flush=True)
    else:
        print(text)


if __name__ == "__main__":
    main()
