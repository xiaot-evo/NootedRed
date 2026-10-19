#!/usr/bin/env python3
"""Import a collected platform-data zip into the local dataset archive.

The archive is kept outside git (platform-data/ is ignored), while this script
normalizes the machine metadata, hashes and extracted analysis files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path("platform-data")
TEXT_FILES = [
    "sw_vers.txt", "uname.txt", "hardware.json", "displays.json", "kexts.json",
    "manifest.json", "hashes.txt", "csrutil.txt", "nvram.txt",
    "ioreg-gpu.txt", "ioreg-media.txt", "GL-nm.txt", "MTL-symbols-all.txt",
    "MTL-load-commands.json",
]
BINARY_FILES = [
    "GLDriver.bin", "GL-page-008000.bin", "GL-page-E000.bin",
    "GL-page-00E000.bin", "MTL-image.bin",
]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-") or "unknown"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("zip")
    parser.add_argument("--label", help="override the directory label")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    source = Path(args.zip)
    archive_sha = sha256(source)
    with zipfile.ZipFile(source) as archive:
        names = set(archive.namelist())
        manifest = json.loads(archive.read("manifest.json")) if "manifest.json" in names else {}
        sw_vers = archive.read("sw_vers.txt").decode(errors="replace") if "sw_vers.txt" in names else ""
        uname = archive.read("uname.txt").decode(errors="replace") if "uname.txt" in names else ""
        hardware = json.loads(archive.read("hardware.json")) if "hardware.json" in names else {}
        displays = json.loads(archive.read("displays.json")) if "displays.json" in names else {}

    def field(text: str, key: str) -> str:
        match = re.search(rf"^{re.escape(key)}:\s*(.+)$", text, re.MULTILINE)
        return match.group(1).strip() if match else "unknown"

    version = field(sw_vers, "ProductVersion")
    build = field(sw_vers, "BuildVersion")
    darwin = field(uname, "Darwin") if False else ""
    darwin_match = re.search(r"Darwin Kernel Version (\d+\.\d+\.\d+)", uname)
    darwin = f"{darwin_match.group(1)}" if darwin_match else "unknown"
    cpu = "unknown"
    try:
        cpu = hardware["SPHardwareDataType"][0].get("cpu_type", "unknown")
    except (KeyError, IndexError, TypeError):
        pass
    gpu = "unknown"
    device_id = None
    revision = None
    try:
        display = displays["SPDisplaysDataType"][0]
        gpu = display.get("_name", "unknown")
        device_id = display.get("spdisplays_device-id")
        revision = display.get("spdisplays_revision-id")
    except (KeyError, IndexError, TypeError):
        pass

    date = (manifest.get("generated") or datetime.now(timezone.utc).isoformat())[:10]
    label = args.label or f"{date}_macos-{safe_name(version)}_{safe_name(build)}_{safe_name(cpu)}_{safe_name(device_id or 'gpu')}"
    target = args.root / label
    if target.exists() and not args.force:
        raise SystemExit(f"{target} exists; pass --force or choose --label")
    target.mkdir(parents=True, exist_ok=True)
    (target / "metadata").mkdir(exist_ok=True)
    (target / "drivers").mkdir(exist_ok=True)

    archive_dest = target / source.name
    if not archive_dest.exists() or archive_dest.read_bytes() != source.read_bytes():
        shutil.copy2(source, archive_dest)
        archive_dest.chmod(0o600)

    with zipfile.ZipFile(source) as zip_file:
        for name in TEXT_FILES:
            if name in zip_file.namelist():
                (target / "metadata" / name).write_bytes(zip_file.read(name))
        for name in BINARY_FILES:
            if name in zip_file.namelist():
                (target / "drivers" / name).write_bytes(zip_file.read(name))

    dataset = {
        "label": label,
        "source": source.name,
        "archive_sha256": archive_sha,
        "collected_at": manifest.get("generated"),
        "full_resources": manifest.get("full_resources"),
        "macos": version,
        "build": build,
        "darwin": darwin,
        "cpu": cpu,
        "gpu": gpu,
        "device_id": device_id,
        "revision": revision,
        "archive_bytes": source.stat().st_size,
    }
    (target / "dataset.json").write_text(json.dumps(dataset, indent=2) + "\n")
    (target / "SHA256").write_text(f"{archive_sha}  {source.name}\n")

    print(json.dumps(dataset, indent=2))
    print(f"saved to {target}")


if __name__ == "__main__":
    main()
