#!/usr/bin/env python3
"""Collect parser-validation fixtures on the target macOS machine.

Run this on any macOS version you want to validate. It does not install or load
anything; it only copies the files needed by the two parsers:

  * user-space parser: dyld shared cache + .map + AMD GL/Metal/VDA driver images;
  * VCN runtime resolver: SystemKernelExtensions.kc (X5000/X6000 symbols/vtables).

The output is a directory (and optionally a zip) with a manifest and SHA-256 for
every file, so it can be transferred and validated elsewhere.

Usage:
    python3 collect_validation_fixtures.py
    python3 collect_validation_fixtures.py --out ~/Desktop/nred-validation --map-only
    python3 collect_validation_fixtures.py --out /tmp/nred-validation --zip

No root is required. The dyld cache can be multi-GB; use --map-only for a
metadata-only bundle.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path


SYSTEM_VERSION = Path("/System/Library/CoreServices/SystemVersion.plist")
KERNEL_COLLECTION_ROOTS = [
    Path("/System/Library/KernelCollections"),
]
DYLD_DIRS = [
    Path("/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld"),
    Path("/System/Library/dyld"),
]
DRIVER_PATHS = [
    Path("/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle"),
    Path("/System/Library/Extensions/AMDRadeonX5000MTLDriver.bundle"),
    Path("/System/Library/Extensions/AMDRadeonX5000VADriver.bundle"),
    Path("/System/Library/Extensions/AMDRadeonX5000.kext"),
    Path("/System/Library/Extensions/AMDRadeonX6000.kext"),
    Path("/System/Library/Extensions/AMDRadeonX6000Framebuffer.kext"),
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str]) -> str:
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=20).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def system_version() -> dict:
    try:
        with SYSTEM_VERSION.open("rb") as handle:
            return plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return {}


def copy_file(source: Path, root: Path, output: Path) -> dict:
    try:
        relative = source.resolve().relative_to(root.resolve())
    except ValueError:
        relative = Path("files") / source.name
    destination = output / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    os.chmod(destination, 0o644)
    return {
        "path": str(relative),
        "size": destination.stat().st_size,
        "sha256": sha256(destination),
    }


def copy_tree(source: Path, root: Path, output: Path) -> list[dict]:
    results = []
    if source.is_file():
        return [copy_file(source, root, output)]
    for item in sorted(source.rglob("*")):
        if item.is_file() and not item.is_symlink():
            results.append(copy_file(item, root, output))
    return results


def first_existing(paths: list[Path]) -> Path | None:
    for path in paths:
        if path.exists():
            return path
    return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Collect NootedRed parser validation fixtures on this Mac")
    parser.add_argument("--out", type=Path, default=None, help="output directory")
    parser.add_argument("--map-only", action="store_true", help="copy only the dyld cache .map, not cache segments")
    parser.add_argument("--no-drivers", action="store_true", help="do not copy standalone AMD driver bundles")
    parser.add_argument("--zip", action="store_true", help="also create a zip next to the output directory")
    args = parser.parse_args(argv)

    version = system_version()
    build = version.get("ProductBuildVersion") or "unknown-build"
    product = version.get("ProductVersion") or "unknown-version"
    root = Path("/")
    output = args.out or (Path.cwd() / f"nred-validation-{build}")
    output.mkdir(parents=True, exist_ok=True)

    files: list[dict] = []
    notes: list[str] = []

    if SYSTEM_VERSION.is_file():
        files += copy_tree(SYSTEM_VERSION, root, output)

    collections: list[Path] = []
    for collection_root in KERNEL_COLLECTION_ROOTS:
        collections.extend(sorted(collection_root.glob("*.kc")))
    if not collections:
        notes.append("no kernel collection found")
    for collection in collections:
        files += copy_tree(collection, root, output)

    dyld_dir = first_existing(DYLD_DIRS)
    cache_files = []
    if dyld_dir is not None:
        cache_files = sorted(dyld_dir.glob("dyld_shared_cache_x86_64h*"))
        if args.map_only:
            cache_files = [item for item in cache_files if item.name.endswith(".map")]
            notes.append("map-only: dyld cache segments not copied")
    else:
        notes.append("dyld shared cache directory not found")
    for item in cache_files:
        if item.is_file():
            files += copy_tree(item, root, output)

    if not args.no_drivers:
        for driver in DRIVER_PATHS:
            if driver.exists():
                files += copy_tree(driver, root, output)
    else:
        notes.append("standalone AMD driver bundles not copied")

    manifest = {
        "schema": 1,
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "host": {
            "productVersion": product,
            "build": build,
            "darwin": run(["uname", "-r"]),
            "machine": run(["uname", "-m"]),
            "bootArgs": run(["sysctl", "-n", "kern.bootargs"]),
        },
        "hardware": {
            "deviceID": next(
                (line.split(":")[-1].strip() for line in run(["system_profiler", "SPDisplaysDataType"]).splitlines()
                 if "Device ID:" in line),
                "unknown",
            ),
        },
        "completeness": {
            "systemVersion": SYSTEM_VERSION.is_file(),
            "kernelCollection": bool(collections),
            "dyldCache": dyld_dir is not None and any(not item.name.endswith(".map") for item in cache_files),
            "dyldMap": any(item.name.endswith(".map") for item in cache_files),
            "drivers": not args.no_drivers,
        },
        "files": files,
        "notes": notes,
    }
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    if args.zip:
        archive = output.with_suffix(".zip")
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as handle:
            for item in output.rglob("*"):
                if item.is_file():
                    handle.write(item, item.relative_to(output))
        print(json.dumps({"output": str(output), "zip": str(archive), "build": build}, indent=2))
    else:
        print(json.dumps({"output": str(output), "build": build}, indent=2))

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
