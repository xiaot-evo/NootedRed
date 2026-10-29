#!/usr/bin/env python3
# Inject / check / extract the NRPT v3 `NRedProfiles` bundle in the NootedRedUserPatch
# personality of a kext Info.plist.
#
# The v3 engine reads one personality property at IOService::start:
#   NRedProfiles  (Array) - array of dictionaries, each with exactly:
#       Build    (String)  - exact running kern.osversion (e.g. "24H232")
#       APUMask  (Integer) - APU family mask (subset of 0x3F, non-zero)
#       DeviceID (Integer) - PCI device ID (0 = no device gate, else 0...0xFFFF)
#       Profile  (Data)    - one complete NRPT v3 profile
#
# The array is validated as a whole and exactly one entry is selected for the running
# build/APU/device (docs/PatchProfile-Spec.md section 8); the legacy single-profile
# properties (NRedOffsetProfile / NRedSystemBuild) are removed by this tool.
#
# Examples:
#   # inject one profile (repeat --profile/--build/--apumask/--deviceid per entry)
#   test/inject_profile.py --info-plist NootedRedUserPatch.kext/Contents/Info.plist \
#       --profile nred-24H232-v3.nrpt --build 24H232 --apumask 0x28 --deviceid 0x1638 \
#       --output /tmp/out/Info.plist
#   # verify an existing bundle
#   test/inject_profile.py --info-plist Info.plist --check
#   # extract all profiles and a manifest
#   test/inject_profile.py --info-plist Info.plist --extract /tmp/profiles
#   # entries from a JSON manifest instead of repeated flags
#   test/inject_profile.py --info-plist Info.plist --manifest entries.json --output Info.plist
#
# `--manifest` accepts {"schema": 1, "entries": [{"profile": ..., "build": ...,
# "apuMask": ..., "deviceID": ...}, ...]} (apuMask/deviceID optional: decoded from the profile).
#
# Exit codes: 0 = success/OK, 1 = verification failure, 2 = usage/IO error.

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import plistlib
import sys
from dataclasses import dataclass
from typing import Optional, Sequence

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

try:  # the validator is the single source of truth for the v3 wire format.
    import nrpt_validator as NRPT
except Exception:  # pragma: no cover - only when the tool is copied away from test/
    NRPT = None

PERSONALITY_KEY = "org.ChefKiss.NootedRedUserPatch"
BUNDLE_KEY = "NRedProfiles"
LEGACY_KEYS = ("NRedOffsetProfile", "NRedSystemBuild")
ENTRY_KEYS = ("Build", "APUMask", "DeviceID", "Profile")
MAX_BUNDLE_ENTRIES = 16


@dataclass
class EntrySpec:
    profile_path: str
    build: Optional[str] = None
    apu_mask: Optional[int] = None
    device_id: Optional[int] = None


def _parse_u32(value: str) -> int:
    return int(value, 0)


def load_entries_from_args(args: argparse.Namespace) -> list[EntrySpec]:
    if args.manifest:
        if args.profile or args.build or args.apumask or args.deviceid:
            raise SystemExit("error: --manifest cannot be combined with --profile/--build/--apumask/--deviceid")
        with open(args.manifest, "r", encoding="utf-8") as handle:
            manifest = json.load(handle)
        raw_entries = manifest.get("entries")
        if not isinstance(raw_entries, list) or not raw_entries:
            raise SystemExit("error: manifest needs a non-empty 'entries' array")
        specs: list[EntrySpec] = []
        for index, raw in enumerate(raw_entries):
            if not isinstance(raw, dict) or not isinstance(raw.get("profile"), str):
                raise SystemExit(f"error: manifest entry {index} needs a string 'profile' path")
            apu = raw.get("apuMask")
            device = raw.get("deviceID")
            specs.append(
                EntrySpec(
                    profile_path=raw["profile"],
                    build=raw.get("build"),
                    apu_mask=_coerce_u32(apu, index, "apuMask"),
                    device_id=_coerce_u32(device, index, "deviceID"),
                )
            )
        return specs

    profiles = args.profile or []
    builds = args.build or []
    apu_masks = args.apumask or []
    devices = args.deviceid or []
    counts = {len(profiles), len(builds), len(apu_masks), len(devices)}
    if len(profiles) != len(builds) or len(apu_masks) not in (0, len(profiles)) or len(devices) not in (0, len(profiles)):
        raise SystemExit(
            "error: --profile/--build must be given once per entry; "
            "--apumask/--deviceid are optional per entry (or repeat for all)"
        )
    if counts == {0}:
        raise SystemExit("error: at least one --profile entry (or --manifest) is required")
    specs = []
    for index, profile_path in enumerate(profiles):
        specs.append(
            EntrySpec(
                profile_path=profile_path,
                build=builds[index],
                apu_mask=apu_masks[index] if apu_masks else None,
                device_id=devices[index] if devices else None,
            )
        )
    return specs


def _coerce_u32(value, index: int, name: str) -> Optional[int]:
    if value is None:
        return None
    if isinstance(value, bool) or isinstance(value, str):
        if isinstance(value, str) and value.lower().startswith("0x"):
            try:
                return int(value, 0)
            except ValueError as error:
                raise SystemExit(f"error: manifest entry {index} {name}: {error}") from error
        if isinstance(value, str):
            try:
                return int(value, 0)
            except ValueError:
                return None
        raise SystemExit(f"error: manifest entry {index} {name} must be an integer")
    if isinstance(value, int) and 0 <= value <= 0xFFFFFFFF:
        return value
    raise SystemExit(f"error: manifest entry {index} {name} out of range")


def build_entries(specs: Sequence[EntrySpec]) -> list[dict]:
    entries: list[dict] = []
    for index, spec in enumerate(specs):
        try:
            with open(spec.profile_path, "rb") as handle:
                data = handle.read()
        except OSError as error:
            raise SystemExit(f"error: cannot read profile {spec.profile_path}: {error}")
        if NRPT is not None:
            try:
                profile = NRPT.decode(data)
            except NRPT.NRPTCodecError as error:
                raise SystemExit(f"error: {spec.profile_path}: {error}")
            header = profile.header
        else:  # pragma: no cover - minimal header read if the validator module is absent
            if len(data) < 32 or data[:4] != b"NRPT" or int.from_bytes(data[4:6], "little") != 3:
                raise SystemExit(f"error: {spec.profile_path}: not an NRPT v3 profile")
            raw_build = data[8:24].split(b"\x00", 1)[0].decode("ascii", "replace")
            header = type(
                "Header",
                (),
                {
                    "build": raw_build,
                    "apu_mask": int.from_bytes(data[24:28], "little"),
                    "device_id": int.from_bytes(data[28:32], "little"),
                },
            )()
        build = spec.build or header.build
        apu_mask = spec.apu_mask if spec.apu_mask is not None else header.apu_mask
        device_id = spec.device_id if spec.device_id is not None else header.device_id
        if build != header.build:
            raise SystemExit(
                f"error: {spec.profile_path}: requested Build {build!r} != profile build {header.build!r}"
            )
        if apu_mask != header.apu_mask:
            raise SystemExit(
                f"error: {spec.profile_path}: APUMask 0x{apu_mask:08X} != profile 0x{header.apu_mask:08X}"
            )
        if device_id != header.device_id:
            raise SystemExit(
                f"error: {spec.profile_path}: DeviceID 0x{device_id:04X} != profile 0x{header.device_id:04X}"
            )
        entries.append({"Build": build, "APUMask": apu_mask, "DeviceID": device_id, "Profile": data})
    if not 1 <= len(entries) <= MAX_BUNDLE_ENTRIES:
        raise SystemExit(f"error: bundle needs 1..{MAX_BUNDLE_ENTRIES} entries, got {len(entries)}")
    return entries


def load_plist(path: str) -> tuple[dict, bool]:
    with open(path, "rb") as handle:
        raw = handle.read()
    binary = raw.startswith(b"bplist00")
    try:
        return plistlib.loads(raw), binary
    except Exception as error:  # plistlib exposes several parse errors
        raise SystemExit(f"error: cannot parse {path}: {error}")


def find_personality(plist: dict) -> dict:
    personalities = plist.get("IOKitPersonalities")
    if not isinstance(personalities, dict):
        raise SystemExit("error: Info.plist has no IOKitPersonalities dictionary")
    personality = personalities.get(PERSONALITY_KEY)
    if not isinstance(personality, dict):
        raise SystemExit(f"error: Info.plist has no {PERSONALITY_KEY} personality")
    return personality


def inject(specs: Sequence[EntrySpec], info_plist: str, output: str) -> int:
    entries = build_entries(specs)
    plist, binary = load_plist(info_plist)
    personality = find_personality(plist)
    personality[BUNDLE_KEY] = entries
    removed = []
    for legacy in LEGACY_KEYS:
        if legacy in personality:
            del personality[legacy]
            removed.append(legacy)
    os.makedirs(os.path.dirname(os.path.abspath(output)) or ".", exist_ok=True)
    format = plistlib.FMT_BINARY if binary else plistlib.FMT_XML
    with open(output, "wb") as handle:
        plistlib.dump(plist, handle, fmt=format, sort_keys=False)
    print(
        f"injected {BUNDLE_KEY} with {len(entries)} profile(s) into {info_plist} -> {output}"
        + (f" (removed legacy keys: {', '.join(removed)})" if removed else "")
    )
    for index, entry in enumerate(entries):
        print(
            f"  [{index}] build={entry['Build']} apuMask=0x{entry['APUMask']:08X} "
            f"deviceID=0x{entry['DeviceID']:04X} profile={len(entry['Profile'])} bytes "
            f"sha256={hashlib.sha256(entry['Profile']).hexdigest()}"
        )
    return 0


def verify_bundle(personality: dict, quiet: bool = False) -> list[dict]:
    if BUNDLE_KEY not in personality:
        raise ValueError(f"personality has no {BUNDLE_KEY} array")
    raw_entries = personality[BUNDLE_KEY]
    if not isinstance(raw_entries, list):
        raise ValueError(f"{BUNDLE_KEY} is not an array")
    if not 1 <= len(raw_entries) <= MAX_BUNDLE_ENTRIES:
        raise ValueError(f"{BUNDLE_KEY} has {len(raw_entries)} entries; allowed 1..{MAX_BUNDLE_ENTRIES}")
    entries: list[dict] = []
    seen_builds: set[str] = set()
    for index, raw in enumerate(raw_entries):
        if not isinstance(raw, dict):
            raise ValueError(f"bundle[{index}] is not a dictionary")
        if tuple(raw.keys()) != ENTRY_KEYS and set(raw.keys()) != set(ENTRY_KEYS):
            raise ValueError(f"bundle[{index}] keys must be exactly {list(ENTRY_KEYS)}")
        build = raw["Build"]
        apu_mask = raw["APUMask"]
        device_id = raw["DeviceID"]
        profile_data = raw["Profile"]
        if not isinstance(build, str) or not build:
            raise ValueError(f"bundle[{index}].Build must be a non-empty string")
        if isinstance(apu_mask, bool) or not isinstance(apu_mask, int):
            raise ValueError(f"bundle[{index}].APUMask must be an integer")
        if isinstance(device_id, bool) or not isinstance(device_id, int):
            raise ValueError(f"bundle[{index}].DeviceID must be an integer")
        if not isinstance(profile_data, (bytes, bytearray)) or not profile_data:
            raise ValueError(f"bundle[{index}].Profile must be a non-empty data value")
        if build in seen_builds:
            raise ValueError(f"bundle[{index}]: duplicate Build {build!r}")
        seen_builds.add(build)
        if NRPT is not None:
            try:
                profile = NRPT.decode(bytes(profile_data))
            except NRPT.NRPTCodecError as error:
                raise ValueError(f"bundle[{index}].Profile: {error}")
            if (profile.header.build, profile.header.apu_mask, profile.header.device_id) != (
                build,
                apu_mask,
                device_id,
            ):
                raise ValueError(
                    f"bundle[{index}] metadata ({build}, 0x{apu_mask:08X}, 0x{device_id:04X}) "
                    f"differs from profile header ({profile.header.build}, "
                    f"0x{profile.header.apu_mask:08X}, 0x{profile.header.device_id:04X})"
                )
        entries.append(
            {
                "index": index,
                "build": build,
                "apuMask": apu_mask,
                "deviceID": device_id,
                "profile": bytes(profile_data),
            }
        )
        if not quiet:
            print(
                f"  [{index}] build={build} apuMask=0x{apu_mask:08X} deviceID=0x{device_id:04X} "
                f"profile={len(profile_data)} bytes sha256={hashlib.sha256(profile_data).hexdigest()}"
            )
    for legacy in LEGACY_KEYS:
        if legacy in personality:
            raise ValueError(f"legacy single-profile property {legacy} is still present")
    return entries


def check(info_plist: str, quiet: bool = False) -> int:
    plist, _binary = load_plist(info_plist)
    personality = find_personality(plist)
    try:
        entries = verify_bundle(personality, quiet=quiet)
    except ValueError as error:
        print(f"CHECK FAILED: {error}", file=sys.stderr)
        return 1
    if not quiet:
        print(f"CHECK OK: {len(entries)} profile(s) in {PERSONALITY_KEY}.{BUNDLE_KEY}")
    return 0


def extract(info_plist: str, output_dir: str, quiet: bool = False) -> int:
    plist, _binary = load_plist(info_plist)
    personality = find_personality(plist)
    try:
        entries = verify_bundle(personality, quiet=quiet)
    except ValueError as error:
        print(f"EXTRACT FAILED: {error}", file=sys.stderr)
        return 1
    os.makedirs(output_dir, exist_ok=True)
    manifest_entries = []
    for entry in entries:
        filename = f"{entry['index']:02d}-{entry['build']}.nrpt"
        path = os.path.join(output_dir, filename)
        with open(path, "wb") as handle:
            handle.write(entry["profile"])
        manifest_entries.append(
            {
                "file": filename,
                "index": entry["index"],
                "build": entry["build"],
                "apuMask": f"0x{entry['apuMask']:08X}",
                "deviceID": f"0x{entry['deviceID']:04X}",
                "size": len(entry["profile"]),
                "sha256": hashlib.sha256(entry["profile"]).hexdigest(),
            }
        )
        if not quiet:
            print(f"extracted {entry['build']} ({len(entry['profile'])} bytes) -> {path}")
    manifest = {
        "schema": 1,
        "kind": "NRedProfiles-extract",
        "personality": PERSONALITY_KEY,
        "profileCount": len(entries),
        "entries": manifest_entries,
    }
    manifest_path = os.path.join(output_dir, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    if not quiet:
        print(f"manifest: {manifest_path}")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Inject/check/extract the NRPT v3 NRedProfiles bundle in a kext Info.plist."
    )
    parser.add_argument("--info-plist", required=True, help="kext Info.plist to modify/verify")
    parser.add_argument("--output", help="output Info.plist (default: overwrite --info-plist)")
    parser.add_argument("--profile", action="append", help="NRPT v3 profile path (repeatable, one per entry)")
    parser.add_argument("--build", action="append", help="matching Build string per --profile entry")
    parser.add_argument("--apumask", action="append", type=_parse_u32, help="optional APUMask per entry")
    parser.add_argument("--deviceid", action="append", type=_parse_u32, help="optional DeviceID per entry")
    parser.add_argument("--manifest", help="JSON entries manifest (alternative to repeated flags)")
    parser.add_argument("--check", action="store_true", help="verify an existing NRedProfiles bundle")
    parser.add_argument("--extract", metavar="DIR", help="extract all bundle profiles and a manifest")
    parser.add_argument("--quiet", action="store_true", help="suppress informational output")
    args = parser.parse_args(argv)

    if args.check or args.extract:
        if args.profile or args.manifest:
            print("error: --check/--extract do not take profile entries", file=sys.stderr)
            return 2
        if args.check and args.extract:
            print("error: choose one of --check/--extract", file=sys.stderr)
            return 2
        if args.extract:
            return extract(args.info_plist, args.extract, quiet=args.quiet)
        return check(args.info_plist, quiet=args.quiet)

    if not args.profile and not args.manifest:
        print("error: inject needs --profile entries (or --manifest) plus --check/--extract for verification",
              file=sys.stderr)
        return 2
    specs = load_entries_from_args(args)
    output = args.output or args.info_plist
    return inject(specs, args.info_plist, output)


if __name__ == "__main__":
    sys.exit(main())
