#!/usr/bin/env python3
"""Build and run the host analyzer tests against a clean fixture tree.

Usage:
    python3 test/test_analyzer.py [--fixtures version-fixtures/15.8.2]

The analyzer core is freestanding C++ (no Lilu/kernel headers), so the same sources compile here and
into the satellite.  Fixtures are local and untracked; set NRED_FIXTURES or pass --fixtures to point
at a different clean image tree.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
INCLUDE_DIRS = [ROOT / "NootedRedUserPatch", ROOT / "test" / "support"]
TEST_SOURCE = ROOT / "test" / "test_analyzer.cpp"
# Analyzer core sources are appended here as the tasks add them.
ANALYZER_SOURCES: list[pathlib.Path] = [
    ROOT / "NootedRedUserPatch" / "Analyzer" / "MachO.cpp",
    ROOT / "NootedRedUserPatch" / "Analyzer" / "CacheLocator.cpp",
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--fixtures",
        default=os.environ.get("NRED_FIXTURES", str(ROOT / "version-fixtures")),
        help="fixture root containing 15.8.2/ and 26.7.2/",
    )
    args = parser.parse_args()

    fixtures = pathlib.Path(args.fixtures)
    if not (fixtures / "15.8.2").is_dir() or not (fixtures / "26.7.2").is_dir():
        print(f"error: fixture root must contain 15.8.2/ and 26.7.2/: {fixtures}", file=sys.stderr)
        print("hint: the tree is untracked; link or point at a clean image root with --fixtures", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory() as tmp:
        binary = pathlib.Path(tmp) / "test_analyzer"
        command = [
            "clang++",
            "-std=c++23",
            "-Wall",
            "-Wextra",
            "-Werror",
            *[f"-I{path}" for path in INCLUDE_DIRS],
            str(TEST_SOURCE),
            *[str(path) for path in ANALYZER_SOURCES],
            "-o",
            str(binary),
        ]
        compiled = subprocess.run(command, cwd=ROOT)
        if compiled.returncode != 0:
            print("error: analyzer test build failed", file=sys.stderr)
            return compiled.returncode
        return subprocess.run([str(binary), str(fixtures)], cwd=ROOT).returncode


if __name__ == "__main__":
    sys.exit(main())
