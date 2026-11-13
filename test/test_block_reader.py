#!/usr/bin/env python3
"""Build and run the host BlockReader tests (no fixtures needed)."""
from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        binary = pathlib.Path(tmp) / "test_block_reader"
        command = [
            "clang++",
            "-std=c++23",
            "-Wall",
            "-Wextra",
            "-Werror",
            f"-I{ROOT / 'NootedRedUserPatch'}",
            str(ROOT / "test" / "test_block_reader.cpp"),
            "-o",
            str(binary),
        ]
        compiled = subprocess.run(command, cwd=ROOT)
        if compiled.returncode != 0:
            print("error: BlockReader test build failed", file=sys.stderr)
            return compiled.returncode
        return subprocess.run([str(binary)], cwd=ROOT).returncode


if __name__ == "__main__":
    sys.exit(main())
