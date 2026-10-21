#!/usr/bin/env python3
"""Collect user-space AMD driver data from a target macOS install.

The output is a zip containing:
  - the AMDRadeonX5000GLDriver binary and its 0xE000/0x8000 pages;
  - the AMDRadeonX5000MTLDriver image extracted from the dyld shared cache;
  - Mach-O load commands / matching symbols;
  - sw_vers, uname, kextstat, ioreg GPU info.

Run on the target machine (no root required) and send the zip back for analysis.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import zipfile
from pathlib import Path

GL_DRIVER = Path("/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver")
CACHE_CANDIDATES = [
    Path("/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld"),
    Path("/System/Cryptexes/OS/System/Library/dyld"),
    Path("/System/Library/dyld"),
]
IMAGE_NAME = "AMDRadeonX5000MTLDriver"
PAGE = 0x1000


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout
    except Exception as exc:  # pragma: no cover - target-machine diagnostics
        return f"<failed: {exc}>"


class CacheReader:
    def __init__(self, cache_dir: Path):
        self.cache_dir = cache_dir
        self.maps = []  # (va_start, va_end, file_offset, handle)
        self.handles = []
        self._load_maps()
        self.map_text = (cache_dir / "dyld_shared_cache_x86_64h.map").read_text(errors="replace")

    def _load_maps(self):
        for path in sorted(self.cache_dir.glob("dyld_shared_cache_x86_64h*")):
            if path.suffix in (".map", ".atlas"):
                continue
            handle = path.open("rb")
            header = handle.read(0x68)
            if not header.startswith(b"dyld_v1"):
                handle.close()
                continue
            mapping_offset, mapping_count = struct.unpack_from("<II", header, 16)
            handle.seek(mapping_offset)
            raw = handle.read(mapping_count * 32)
            if len(raw) != mapping_count * 32:
                handle.close()
                continue
            self.handles.append(handle)
            for index in range(mapping_count):
                va, size, file_offset, _, _ = struct.unpack_from("<QQQII", raw, index * 32)
                self.maps.append((va, va + size, file_offset, handle))

    def read(self, address: int, size: int) -> bytes:
        for start, end, file_offset, handle in self.maps:
            if start <= address and address + size <= end:
                handle.seek(file_offset + address - start)
                data = handle.read(size)
                if len(data) == size:
                    return data
        raise ValueError(f"unmapped address {address:#x} (+{size:#x})")

    def image_base(self) -> int:
        lines = self.map_text.splitlines()
        for index, line in enumerate(lines):
            if line.strip() == IMAGE_NAME or line.strip().endswith("/" + IMAGE_NAME):
                for following in lines[index + 1:]:
                    fields = following.split()
                    if len(fields) >= 2 and fields[0] == "__TEXT":
                        return int(fields[1], 16)
                break
        raise ValueError(f"{IMAGE_NAME} not found in map")

    def close(self):
        for handle in self.handles:
            handle.close()


def parse_macho(reader: CacheReader, base: int):
    header = reader.read(base, 32)
    magic, _, _, _, ncmds, sizeofcmds = struct.unpack_from("<IIIIII", header)
    if magic != 0xFEEDFACF:
        raise ValueError(f"not a Mach-O64 at {base:#x}: {magic:#x}")
    commands = reader.read(base + 32, sizeofcmds)
    segments = []
    symbols = None
    offset = 0
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", commands, offset)
        if cmd == 0x19:  # LC_SEGMENT_64
            name, vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<16sQQQQ", commands, offset + 8)
            segments.append((name.rstrip(b"\0").decode(), vmaddr, vmsize, fileoff, filesize))
        elif cmd == 2:  # LC_SYMTAB
            symbols = struct.unpack_from("<IIII", commands, offset + 8)
        offset += size
    if symbols is None:
        return segments, []
    symoff, nsyms, stroff, strsize = symbols
    linkedit = next((s for s in segments if s[0] == "__LINKEDIT"), None)
    if linkedit is None:
        return segments, []
    symdata = reader.read(linkedit[1] + symoff - linkedit[3], nsyms * 16)
    strdata = reader.read(linkedit[1] + stroff - linkedit[3], strsize)
    result = []
    for index in range(nsyms):
        strx, kind, _, _, value = struct.unpack_from("<IBBHQ", symdata, index * 16)
        end = strdata.find(b"\0", strx)
        name = strdata[strx:end].decode(errors="replace")
        result.append((value, kind, name))
    result.sort()
    return segments, result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="NootedRed-target-data.zip")
    parser.add_argument("--cache-dir", type=Path, default=None)
    args = parser.parse_args()

    cache_dir = args.cache_dir
    if cache_dir is None:
        cache_dir = next((p for p in CACHE_CANDIDATES if (p / "dyld_shared_cache_x86_64h.map").exists()), None)
    if cache_dir is None:
        raise SystemExit("dyld shared cache not found; pass --cache-dir")

    if not GL_DRIVER.exists():
        raise SystemExit(f"GL driver not found: {GL_DRIVER}")

    out = Path(args.out)
    tmp = out.parent / (out.stem + ".tmp")
    tmp.mkdir(parents=True, exist_ok=True)

    gl = GL_DRIVER.read_bytes()
    (tmp / "GLDriver.bin").write_bytes(gl)
    for page_offset in (0xE000, 0x8000):
        page = gl[page_offset:page_offset + PAGE]
        (tmp / f"GL-page-{page_offset:06X}.bin").write_bytes(page)

    reader = CacheReader(cache_dir)
    try:
        base = reader.image_base()
        segments, symbols = parse_macho(reader, base)
        text = next((s for s in segments if s[0] == "__TEXT"), None)
        if text is None:
            raise ValueError("__TEXT segment not found")
        image = reader.read(text[1], text[2])
    finally:
        reader.close()

    (tmp / "MTL-image.bin").write_bytes(image)
    (tmp / "MTL-load-commands.json").write_text(json.dumps({
        "image_base": hex(base),
        "segments": [{"name": n, "vmaddr": hex(a), "vmsize": hex(s), "fileoff": hex(f), "filesize": hex(fs)}
                     for n, a, s, f, fs in segments],
    }, indent=2))
    keys = ("HwInfo", "HwInfoInit", "InitDeviceSettings", "RenderPipeline", "PipelineState", "UBM", "AddrLib", "GFX9")
    with (tmp / "MTL-symbols.txt").open("w") as handle:
        for value, _kind, name in symbols:
            if any(key.lower() in name.lower() for key in keys):
                handle.write(f"{value:#x} {name}\n")

    (tmp / "system.txt").write_text("\n".join([
        "## sw_vers", run(["sw_vers"]),
        "## uname", run(["uname", "-a"]),
        "## kextstat", run(["kextstat"]),
        "## ioreg GPU", run(["ioreg", "-l"]),
    ]))
    (tmp / "hashes.txt").write_text("\n".join(f"{sha256(p.read_bytes())}  {p.name}" for p in sorted(tmp.iterdir())) + "\n")

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(tmp.iterdir()):
            archive.write(path, path.name)
    print(f"wrote {out} ({out.stat().st_size} bytes)")
    print(f"GL pages: 0xE000/0x8000, MTL image at {base:#x}, {len(image)} bytes")


if __name__ == "__main__":
    main()
