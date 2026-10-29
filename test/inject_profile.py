#!/usr/bin/env python3
# Inject / check an NRPT v1 profile in the NootedRedUserPatch personality of a kext Info.plist.
#
# The generic engine reads two personality properties at IOService::start:
#   NRedOffsetProfile  (Data)   - the complete NRPT v1 profile bytes
#   NRedSystemBuild    (String) - the exact expected build string (kernel build hint)
# and removes both properties after copying the profile into bounded static storage.
#
# This small stdlib-only helper exists so the release package can be built deterministically even if
# the NootedRedTool binary does not expose an injection command. It never invents a profile: the
# caller supplies a validated NRPT file, and --check can prove the embedded bytes are identical.
#
# No Apple binaries are embedded; this tool only edits a text/binary plist property.
#
# Usage:
#   test/inject_profile.py --profile nred-24H232.nrpt --info-plist path/to/Info.plist
#   test/inject_profile.py --profile ... --info-plist ... --output out.plist
#   test/inject_profile.py --check --profile ... --info-plist ...           # verify embedded bytes
#   test/inject_profile.py --extract --info-plist ... --output extracted.nrpt
#
# Exit code: 0 = success/verified, 1 = check mismatch or invalid input, 2 = usage/IO error.

from __future__ import annotations

import argparse
import os
import plistlib
import sys
import tempfile

PERSONALITY_KEY = "org.ChefKiss.NootedRedUserPatch"
PROFILE_KEY = "NRedOffsetProfile"
BUILD_KEY = "NRedSystemBuild"
BUILD_ALPHABET = frozenset(
    b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-"
)


def load_plist(path: str) -> dict:
    with open(path, "rb") as handle:
        plist = plistlib.load(handle)
    if not isinstance(plist, dict):
        raise ValueError(f"{path}: top-level plist is not a dictionary")
    return plist


def find_personality(plist: dict) -> dict:
    personalities = plist.get("IOKitPersonalities")
    if not isinstance(personalities, dict) or not personalities:
        raise ValueError("Info.plist has no IOKitPersonalities dictionary")
    personality = personalities.get(PERSONALITY_KEY)
    if not isinstance(personality, dict):
        # Fall back to the only personality when the bundle identifier differs.
        if len(personalities) == 1:
            personality = next(iter(personalities.values()))
        else:
            raise ValueError(f"Info.plist has no {PERSONALITY_KEY} personality")
    if not isinstance(personality, dict):
        raise ValueError("personality value is not a dictionary")
    return personality


def validate_build(build: str) -> bytes:
    raw = build.encode("utf-8")
    if not 1 <= len(raw) <= 15 or any(byte not in BUILD_ALPHABET for byte in raw):
        raise ValueError(f"invalid build string: {build!r}")
    return raw


def write_plist(plist: dict, path: str) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="wb", dir=directory, prefix=".nred-plist-", suffix=".tmp", delete=False
    ) as handle:
        temporary = handle.name
        plistlib.dump(plist, handle, fmt=plistlib.FMT_XML, sort_keys=False)
    try:
        os.replace(temporary, path)
    except OSError:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def inject(profile_path: str, info_plist: str, output: str, build: str) -> None:
    with open(profile_path, "rb") as handle:
        profile_bytes = handle.read()
    if len(profile_bytes) < 64:
        raise ValueError(f"profile file is too short to be NRPT: {len(profile_bytes)} bytes")
    if profile_bytes[:4] != b"NRPT":
        raise ValueError("profile file does not start with NRPT magic")
    validate_build(build)

    plist = load_plist(info_plist)
    personality = find_personality(plist)
    personality[PROFILE_KEY] = profile_bytes
    personality[BUILD_KEY] = build
    write_plist(plist, output)

    # Immediate read-back proof.
    result = check(profile_path, output, build, quiet=True)
    if not result:
        raise RuntimeError("injected Info.plist failed read-back verification")
    print(
        f"injected {len(profile_bytes)} profile bytes, build {build}, "
        f"personality {PERSONALITY_KEY} -> {output}"
    )


def extract(info_plist: str, output: str) -> None:
    plist = load_plist(info_plist)
    personality = find_personality(plist)
    profile_bytes = personality.get(PROFILE_KEY)
    if not isinstance(profile_bytes, (bytes, bytearray)):
        raise ValueError(f"personality has no {PROFILE_KEY} data property")
    with open(output, "wb") as handle:
        handle.write(bytes(profile_bytes))
    print(f"extracted {len(profile_bytes)} profile bytes -> {output}")


def check(profile_path: str, info_plist: str, build: str, quiet: bool = False) -> bool:
    with open(profile_path, "rb") as handle:
        expected = handle.read()
    plist = load_plist(info_plist)
    personality = find_personality(plist)
    embedded = personality.get(PROFILE_KEY)
    embedded_build = personality.get(BUILD_KEY)
    failures = []
    if not isinstance(embedded, (bytes, bytearray)):
        failures.append(f"missing {PROFILE_KEY} data")
    elif bytes(embedded) != expected:
        failures.append(
            f"{PROFILE_KEY} differs (embedded {len(embedded)} bytes, expected {len(expected)} bytes)"
        )
    if embedded_build != build:
        failures.append(f"{BUILD_KEY} is {embedded_build!r}, expected {build!r}")
    if failures:
        if not quiet:
            for failure in failures:
                print(f"CHECK FAILED: {failure}", file=sys.stderr)
            print(f"check {info_plist}: FAIL", file=sys.stderr)
        return False
    if not quiet:
        print(
            f"check {info_plist}: OK ({len(expected)} profile bytes, build {build}, "
            f"personality {PERSONALITY_KEY})"
        )
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Inject or check the NRPT profile/Build properties in a NootedRedUserPatch Info.plist"
    )
    parser.add_argument("--profile", help="NRPT profile file")
    parser.add_argument("--info-plist", required=True, help="target kext Info.plist")
    parser.add_argument("--output", help="output path (default: modify --info-plist in place)")
    parser.add_argument("--build", default="24H232", help="build string for NRedSystemBuild")
    parser.add_argument("--check", action="store_true", help="verify the embedded profile instead of writing")
    parser.add_argument("--extract", action="store_true", help="extract the embedded profile instead of writing")
    args = parser.parse_args(argv)

    if not os.path.isfile(args.info_plist):
        print(f"error: Info.plist not found: {args.info_plist}", file=sys.stderr)
        return 2

    try:
        if args.check:
            if not args.profile:
                print("error: --check requires --profile", file=sys.stderr)
                return 2
            return 0 if check(args.profile, args.info_plist, args.build) else 1
        if args.extract:
            if not args.output:
                print("error: --extract requires --output", file=sys.stderr)
                return 2
            extract(args.info_plist, args.output)
            return 0
        if not args.profile:
            print("error: --profile is required when injecting", file=sys.stderr)
            return 2
        output = args.output or args.info_plist
        inject(args.profile, args.info_plist, output, args.build)
        return 0
    except (OSError, ValueError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
