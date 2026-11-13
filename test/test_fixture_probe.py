#!/usr/bin/env python3
"""Probe the runtime analyzer against the available clean fixture trees.

Version slots 13.* and 14.* are reserved now; adding version-fixtures/13.x or
version-fixtures/14.x makes them run automatically.  Existing 15.* and 26.*
fixtures are exercised immediately.
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
INCLUDE_DIRS = [ROOT / "NootedRedUserPatch", ROOT / "test" / "support"]
ANALYZER_SOURCES = [
    ROOT / "NootedRedUserPatch" / "Analyzer" / "MachO.cpp",
    ROOT / "NootedRedUserPatch" / "Analyzer" / "CacheLocator.cpp",
    ROOT / "NootedRedUserPatch" / "Analyzer" / "RuleTable.cpp",
    ROOT / "NootedRedUserPatch" / "Analyzer" / "RuleResolver.cpp",
]
DEFAULT_SLOTS = ("13.*", "14.*", "15.*", "26.*")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(ROOT / "version-fixtures"))
    parser.add_argument("--versions", default=",".join(DEFAULT_SLOTS))
    args = parser.parse_args()

    root = pathlib.Path(args.root)
    slots = [slot for slot in args.versions.split(",") if slot]

    with tempfile.TemporaryDirectory() as tmp:
        binary = pathlib.Path(tmp) / "test_fixture_probe"
        command = [
            "clang++",
            "-std=c++23",
            "-Wall",
            "-Wextra",
            "-Werror",
            *[f"-I{path}" for path in INCLUDE_DIRS],
            str(ROOT / "test" / "test_fixture_probe.cpp"),
            *[str(path) for path in ANALYZER_SOURCES],
            "-o",
            str(binary),
        ]
        compiled = subprocess.run(command, cwd=ROOT)
        if compiled.returncode != 0:
            print("error: fixture probe build failed", file=sys.stderr)
            return compiled.returncode

        failures = 0
        exercised = 0
        for slot in slots:
            fixtures = sorted(path for path in root.glob(slot) if path.is_dir())
            if not fixtures:
                print(f"RESERVED {slot}: no fixture under {root}")
                continue
            for fixture in fixtures:
                exercised += 1
                print(f"== {fixture.name} ==", flush=True)
                result = subprocess.run([str(binary), str(fixture)], cwd=ROOT)
                if result.returncode != 0:
                    failures += 1

        if exercised == 0:
            print(f"FAIL: no fixtures found under {root}")
            return 1
        if failures != 0:
            print(f"FAIL: {failures} fixture(s) unresolved")
            return 1
        print("PASS: all available fixtures resolved")
        return 0


if __name__ == "__main__":
    sys.exit(main())
