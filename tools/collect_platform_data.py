#!/usr/bin/env python3
"""Collect platform data needed for multi-macOS / multi-APU compatibility work.

Run on the target machine (no root required).  The resulting zip contains:
  - macOS/Darwin/build, hardware and GPU capability metadata;
  - boot args, SIP, kext list;
  - the GL driver bundle binary and its 0xE000/0x8000 pages;
  - the MTL driver __TEXT image from the dyld shared cache, load commands and symbols;
  - relevant X5000/X6000 kext binaries, Info.plists and firmware resources;
  - filtered ioreg/VideoToolbox/media capability data.

Send the zip back for analysis.  It contains Apple binaries; do not publish it.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import plistlib
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
MTL_IMAGE = "AMDRadeonX5000MTLDriver"
PAGE = 0x1000
KEXT_PATTERNS = [
    "AMDRadeonX5000*.kext",
    "AMDRadeonX6000Framebuffer.kext",
    "AMDRadeonX6000*.kext",
    "AMDRadeonX5000*.bundle",
]
MEDIA_PATTERNS = ["VCN", "VCE", "UVD", "VideoToolbox", "VTDecoder", "AV1", "HEVC", "H264"]


def run(cmd: list[str], timeout: int = 30) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception as exc:
        return f"<failed: {exc}>"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class CacheReader:
    def __init__(self, cache_dir: Path):
        self.cache_dir = cache_dir
        self.maps: list[tuple[int, int, int, object]] = []
        self.handles = []
        self._load()

    def _load(self):
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
        raise ValueError(f"unmapped {address:#x} (+{size:#x})")

    def image_base(self) -> int:
        map_file = self.cache_dir / "dyld_shared_cache_x86_64h.map"
        lines = map_file.read_text(errors="replace").splitlines()
        for index, line in enumerate(lines):
            if line.strip() == MTL_IMAGE or line.strip().endswith("/" + MTL_IMAGE):
                for following in lines[index + 1:]:
                    fields = following.split()
                    if len(fields) >= 2 and fields[0] == "__TEXT":
                        return int(fields[1], 16)
        raise ValueError(f"{MTL_IMAGE} not found in cache map")

    def close(self):
        for handle in self.handles:
            handle.close()


def parse_macho(reader: CacheReader, base: int):
    header = reader.read(base, 32)
    magic, _, _, _, ncmds, sizeofcmds = struct.unpack_from("<IIIIII", header)
    if magic != 0xFEEDFACF:
        raise ValueError(f"not Mach-O64 at {base:#x}")
    commands = reader.read(base + 32, sizeofcmds)
    segments, symbols = [], None
    offset = 0
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", commands, offset)
        if cmd == 0x19:
            name, vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<16sQQQQ", commands, offset + 8)
            segments.append((name.rstrip(b"\0").decode(), vmaddr, vmsize, fileoff, filesize))
        elif cmd == 2:
            symbols = struct.unpack_from("<IIII", commands, offset + 8)
        offset += size
    result = []
    if symbols is not None:
        symoff, nsyms, stroff, strsize = symbols
        linkedit = next((segment for segment in segments if segment[0] == "__LINKEDIT"), None)
        if linkedit is not None:
            symdata = reader.read(linkedit[1] + symoff - linkedit[3], nsyms * 16)
            strdata = reader.read(linkedit[1] + stroff - linkedit[3], strsize)
            for index in range(nsyms):
                strx, kind, _, _, value = struct.unpack_from("<IBBHQ", symdata, index * 16)
                end = strdata.find(b"\0", strx)
                result.append((value, kind, strdata[strx:end].decode(errors="replace")))
            result.sort()
    return segments, result


def add_text(root: Path, name: str, text: str):
    (root / name).write_text(text, errors="replace")


def _copy_bundle(root: Path, bundle: Path, kept: list[dict], seen: set[Path]):
    resolved = bundle.resolve()
    if resolved in seen:
        return
    seen.add(resolved)
    info = bundle / "Contents" / "Info.plist"
    binary_dir = bundle / "Contents" / "MacOS"
    resources = bundle / "Contents" / "Resources"
    if not info.exists() and not binary_dir.exists():
        return
    dest = root / "kexts" / bundle.name
    dest.mkdir(parents=True, exist_ok=True)
    if info.exists():
        (dest / "Info.plist").write_bytes(info.read_bytes())
    binaries = []
    if binary_dir.is_dir():
        binaries = sorted(path for path in binary_dir.iterdir() if path.is_file())
        for binary in binaries:
            (dest / binary.name).write_bytes(binary.read_bytes())
    if resources.is_dir():
        resource_dest = dest / "Resources"
        resource_dest.mkdir(exist_ok=True)
        for resource in sorted(resources.iterdir()):
            if resource.is_file() and resource.stat().st_size < 32 * 1024 * 1024:
                (resource_dest / resource.name).write_bytes(resource.read_bytes())
    if binaries:
        kept.append({"name": bundle.name, "binary": binaries[0].name, "path": str(bundle)})
    plugins = bundle / "Contents" / "PlugIns"
    if plugins.is_dir():
        for plugin in sorted(plugins.glob("*.kext")):
            _copy_bundle(root, plugin, kept, seen)


def collect_kexts(root: Path) -> list[dict]:
    kept: list[dict] = []
    seen: set[Path] = set()
    extension_root = Path("/System/Library/Extensions")
    for pattern in KEXT_PATTERNS:
        for bundle in sorted(extension_root.glob(pattern)):
            _copy_bundle(root, bundle, kept, seen)
    return kept


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="NootedRed-platform-data.zip")
    parser.add_argument("--cache-dir", type=Path)
    args = parser.parse_args()

    cache_dir = args.cache_dir
    if cache_dir is None:
        cache_dir = next((path for path in CACHE_CANDIDATES
                          if (path / "dyld_shared_cache_x86_64h.map").exists()), None)
    if cache_dir is None:
        raise SystemExit("dyld cache not found; pass --cache-dir")
    if not GL_DRIVER.exists():
        raise SystemExit(f"GL driver missing: {GL_DRIVER}")

    out = Path(args.out)
    root = out.parent / (out.stem + ".tmp")
    root.mkdir(parents=True, exist_ok=True)

    # OS / hardware / boot environment
    add_text(root, "sw_vers.txt", run(["sw_vers"]))
    add_text(root, "uname.txt", run(["uname", "-a"]))
    add_text(root, "hardware.json", run(["system_profiler", "SPHardwareDataType", "-json"]))
    add_text(root, "displays.json", run(["system_profiler", "SPDisplaysDataType", "-json"]))
    add_text(root, "kextstat.txt", run(["kextstat"]))
    add_text(root, "kmutil.txt", run(["kmutil", "showloaded"]))
    add_text(root, "csrutil.txt", run(["csrutil", "status"]))
    add_text(root, "nvram.txt", run(["nvram", "-p"]))
    ioreg = run(["ioreg", "-lw0"])
    add_text(root, "ioreg-gpu.txt", "\n".join(
        line for line in ioreg.splitlines()
        if "IOKitDiagnostics" not in line and len(line) < 4000
        and any(key.lower() in line.lower() for key in ("AMDRadeonX5000", "AMDRadeonX6000", "GPUConfigurationVariable"))
    ))
    add_text(root, "ioreg-media.txt", "\n".join(
        line for line in ioreg.splitlines()
        if "IOKitDiagnostics" not in line and len(line) < 4000
        and any(key.lower() in line.lower() for key in MEDIA_PATTERNS)
    ))
    for class_name in ("AMDRadeonX5000_AMDGFX9Hardware", "AMDRadeonX5000_AMDHWInfo",
                       "AMDRadeonX5000_AMDHWRegisters"):
        add_text(root, f"ioreg-{class_name}.txt", run(["ioreg", "-lw0", "-c", class_name]))
    add_text(root, "coremedia-defaults.txt", run(["defaults", "read", "com.apple.coremedia"]))
    add_text(root, "videotoolbox-ffmpeg.txt", run(["ffmpeg", "-hide_banner", "-hwaccels"]))

    # GL driver bundle
    gl = GL_DRIVER.read_bytes()
    (root / "GLDriver.bin").write_bytes(gl)
    for page_offset in (0xE000, 0x8000):
        (root / f"GL-page-{page_offset:06X}.bin").write_bytes(gl[page_offset:page_offset + PAGE])
    add_text(root, "GL-nm.txt", run(["nm", "-m", str(GL_DRIVER)]))

    # MTL driver from shared cache
    reader = CacheReader(cache_dir)
    try:
        base = reader.image_base()
        segments, symbols = parse_macho(reader, base)
        text = next((segment for segment in segments if segment[0] == "__TEXT"), None)
        if text is None:
            raise SystemExit("MTL __TEXT not found")
        image = reader.read(text[1], text[2])
    finally:
        reader.close()

    (root / "MTL-image.bin").write_bytes(image)
    add_text(root, "MTL-load-commands.json", json.dumps({
        "image_base": hex(base),
        "segments": [{"name": name, "vmaddr": hex(addr), "vmsize": hex(size),
                      "fileoff": hex(fileoff), "filesize": hex(filesize)}
                     for name, addr, size, fileoff, filesize in segments],
    }, indent=2))
    add_text(root, "MTL-symbols-all.txt",
             "\n".join(f"{value:#x} {kind} {name}" for value, kind, name in symbols))

    # Relevant kexts and firmware
    add_text(root, "kexts.json", json.dumps(collect_kexts(root), indent=2))

    # Hashes of every payload
    hashes = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name != "hashes.txt":
            hashes.append(f"{sha256(path.read_bytes())}  {path.relative_to(root)}")
    (root / "hashes.txt").write_text("\n".join(hashes) + "\n")

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(root.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(root))
    print(f"wrote {out} ({out.stat().st_size} bytes)")
    print(f"MTL image base {base:#x}, __TEXT {len(image)} bytes, {len(symbols)} symbols")


if __name__ == "__main__":
    main()
