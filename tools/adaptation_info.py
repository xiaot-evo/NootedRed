#!/usr/bin/env python3
"""Report production adaptation and support information for NootedRed.

This is the current production-facing replacement for the archived target-driver
collector: it does not collect Apple binaries and does not patch anything. It
answers, for the running machine and this checkout:

  * which macOS/Darwin build and APU are present;
  * which embedded satellite PatchData set is applicable;
  * which feature tables (GL/Metal/VDA/AppleGVA) that set contains;
  * whether the main kext and satellite loaded, what the satellite selected,
    and whether the VCN bridge/readiness flags are present;
  * which current boot arguments are meaningful.

Run it from the repository root on the target machine (no root required).
Use --json for machine-readable output and --out for a file.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATCHDATA = ROOT / "PatchData"
SYSTEM_VERSION = Path("/System/Library/CoreServices/SystemVersion.plist")

KINDS = {1: "GL", 2: "Metal", 3: "VDA/VA", 4: "VDA/AppleGVA"}
APU_NAMES = {
    "0x15DD": "Raven",
    "0x15D8": "Raven2/Picasso",
    "0x1636": "Renoir",
    "0x164C": "Cezanne",
    "0x15E7": "Barcelo",
    "0x1638": "Renoir/Green Sardine",
}
APU_MASKS = {
    "0x15DD": 1 << 0,
    "0x15D8": (1 << 1) | (1 << 2),
    "0x1636": (1 << 3) | (1 << 4),
    "0x164C": (1 << 3) | (1 << 4),
    "0x15E7": (1 << 3) | (1 << 5),
    "0x1638": (1 << 3) | (1 << 5),
}
VCN_CAPABLE = {"0x1636", "0x1638", "0x164C", "0x15E7"}
BOOT_ARGS = [
    ("-NRedVDA", "main kext: enable the VCN/VDA kernel bridge; required for satellite VDA pages"),
    ("-NRedAVC", "main kext: alternate VDA/VCN opt-in"),
    ("-NRedVCNNoGfxOff", "main kext: diagnostic GFXOFF hold for VCN"),
    ("-NRedUserPatchOff", "satellite: disable all user-space page patching"),
    ("-NRedUserPatchDebug", "satellite: verbose Lilu logging"),
    ("-NRedUserPatchBeta", "satellite: allow non-release kernels"),
    ("-NRedOff", "main kext: disable NootedRed"),
    ("-NRedDebug", "main kext: verbose logging"),
    ("-NRedBeta", "main kext: allow non-release kernels"),
    ("-NRedNoAccel", "main kext: FB-only debug mode"),
]


def run(cmd: list[str]) -> str:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        return result.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def read_system_version() -> dict:
    try:
        with SYSTEM_VERSION.open("rb") as handle:
            return plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return {}


def read_ioreg() -> dict[str, str]:
    text = run(["ioreg", "-n", "IGPU", "-r", "-l", "-w0"])
    properties: dict[str, str] = {}
    for line in text.splitlines():
        match = re.search(r'"([^"]+)"\s*=\s*(.+?)\s*$', line)
        if match is None:
            continue
        key, value = match.group(1), match.group(2).strip()
        properties[key] = value.strip('"')
    return properties


def read_satellite() -> dict[str, str]:
    text = run(["ioreg", "-c", "NootedRedUserPatch", "-r", "-l", "-w0"])
    properties: dict[str, str] = {}
    for line in text.splitlines():
        match = re.search(r'"([^"]+)"\s*=\s*(.+?)\s*$', line)
        if match is None:
            continue
        key, value = match.group(1), match.group(2).strip()
        properties[key] = value.strip('"')
    return properties


def read_loaded_kexts() -> list[str]:
    text = run(["kmutil", "showloaded", "--list-only"])
    if not text:
        text = run(["kextstat"])
    loaded = []
    for line in text.splitlines():
        if "NootedRed" in line or "NootedRedUserPatch" in line:
            match = re.search(r"(org\.ChefKiss\.(?:NootedRedUserPatch|NootedRed))", line)
            if match is not None:
                loaded.append(match.group(1))
    return sorted(set(loaded))


def load_patchdata() -> dict[str, dict]:
    builds: dict[str, dict] = {}
    if not PATCHDATA.is_dir():
        return builds
    for directory in sorted(PATCHDATA.iterdir()):
        manifest = directory / "manifest.json"
        if not directory.is_dir() or not manifest.is_file():
            continue
        try:
            data = json.loads(manifest.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        tables = data.get("tables", [])
        data["tableKinds"] = sorted({kind for table in tables if (kind := table.get("kind")) in KINDS})
        builds[data.get("build", directory.name)] = data
    return builds


def boot_args() -> list[str]:
    return run(["sysctl", "-n", "kern.bootargs"]).strip().split()


def supported_args(args: list[str]) -> list[dict[str, str]]:
    return [
        {"argument": argument, "meaning": meaning, "present": argument in args}
        for argument, meaning in BOOT_ARGS
    ]


def make_report() -> dict:
    system_version = read_system_version()
    build = system_version.get("ProductBuildVersion", "")
    product = system_version.get("ProductVersion", "")
    uname = run(["uname", "-a"]).strip()
    release = run(["sysctl", "-n", "kern.osrelease"]).strip()
    ioreg = read_ioreg()
    satellite = read_satellite()
    device = None
    for key in ("NRedCompatDeviceID", "device-id"):
        value = ioreg.get(key)
        if value is None:
            continue
        match = re.search(r"(0x[0-9A-Fa-f]+|\d+)", value)
        if match is not None:
            device = f"0x{int(match.group(1), 0):04X}"
            break
    expected_mask = APU_MASKS.get(device or "", 0)
    patchdata = load_patchdata()
    exact = patchdata.get(build)
    args = boot_args()
    return {
        "machine": {
            "model": run(["sysctl", "-n", "hw.model"]).strip(),
            "productVersion": product,
            "build": build,
            "darwin": release,
            "uname": uname,
        },
        "apu": {
            "deviceID": device,
            "name": APU_NAMES.get(device or "", "unknown"),
            "expectedMask": expected_mask,
            "vcn2MediaCapable": device in VCN_CAPABLE,
        },
        "loadedKexts": read_loaded_kexts(),
        "patchData": {
            "availableBuilds": sorted(patchdata),
            "exactBuildPresent": exact is not None,
            "exactBuild": None if exact is None else {
                "build": exact.get("build"),
                "darwin": exact.get("darwin"),
                "apuMask": exact.get("apuMask"),
                "counts": exact.get("counts"),
                "tableKinds": [KINDS[kind] for kind in exact.get("tableKinds", [])],
            },
            "apuMaskMatches": None if exact is None else bool(exact.get("apuMask", 0) & expected_mask),
        },
        "main": {
            "properties": {
                key: value for key, value in ioreg.items()
                if key.startswith("NRedVCN") or key.startswith("NRedCompat")
            },
            "vcnBridgeReady": ioreg.get("NRedVCNBridgeReady") == "1",
        },
        "satellite": {
            "loaded": "NootedRedUserPatch" in " ".join(read_loaded_kexts()),
            "properties": satellite,
        },
        "bootArgs": {
            "current": args,
            "supported": supported_args(args),
        },
    }


def print_human(report: dict) -> None:
    machine, apu, patch = report["machine"], report["apu"], report["patchData"]
    satellite, main, boot = report["satellite"], report["main"], report["bootArgs"]
    print("NootedRed production adaptation info")
    print(f"  macOS: {machine['productVersion']} ({machine['build']}), Darwin {machine['darwin']}")
    print(f"  model: {machine['model']}")
    print(f"  APU:   {apu['name']} {apu['deviceID'] or 'unknown'}  expected mask={apu['expectedMask']:#x}")
    print(f"  VCN2 media path: {'yes' if apu['vcn2MediaCapable'] else 'no'}")
    print(f"  loaded kexts: {', '.join(report['loadedKexts']) or 'none'}")
    print(f"  available PatchData builds: {', '.join(patch['availableBuilds']) or 'none'}")
    if patch["exactBuildPresent"]:
        exact = patch["exactBuild"]
        print(f"  exact build data: {exact['build']}  kinds={','.join(exact['tableKinds'])}")
        print(f"  pages/sites: {exact['counts']}  APU mask match={patch['apuMaskMatches']}")
    else:
        print("  exact build data: none (satellite would stay NoOp)")
    print(f"  main NRedVCNBridgeReady: {main['vcnBridgeReady']}")
    print(f"  satellite loaded: {satellite['loaded']}")
    if satellite["loaded"]:
        for key in ("NRedUserPatchState", "NRedUserPatchReason", "NRedUserPatchBuild",
                    "NRedUserPatchDataSource", "NRedUserPatchApuMask",
                    "NRedUserPatchPages", "NRedUserPatchSites", "NRedUserPatchVdaReady"):
            if key in satellite["properties"]:
                print(f"    {key}: {satellite['properties'][key]}")
    print("  boot arguments:")
    for entry in boot["supported"]:
        print(f"    {'*' if entry['present'] else ' '} {entry['argument']}: {entry['meaning']}")
    print("  current boot-args:", " ".join(boot["current"]))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="print JSON instead of the summary")
    parser.add_argument("--out", type=Path, help="write JSON to this path")
    args = parser.parse_args()
    report = make_report()
    if args.out is not None:
        args.out.write_text(json.dumps(report, indent=2) + "\n")
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_human(report)
        if args.out is not None:
            print(f"JSON written to {args.out}")


if __name__ == "__main__":
    main()
