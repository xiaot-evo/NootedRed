#!/usr/bin/env python3
"""Host-side check of the version/family patch-set selection rules.

This mirrors the small pure selection loop in UserPatches::selectPatchSet().
It does not load the kext; it catches table/ordering regressions before a reboot.
"""

from dataclasses import dataclass

RENOIR = 1 << 3
RENOIR_E = 1 << 4
GREEN_SARDINE = 1 << 5
RAVEN = 1 << 0
RAVEN2 = 1 << 1
PICASSO = 1 << 2
ALL = 0x3F


@dataclass(frozen=True)
class PatchSet:
    name: str
    major: int
    minor: int
    apus: int


SETS = [
    PatchSet("15.8.1 / Renoir-family", 24, 6, RENOIR | RENOIR_E | GREEN_SARDINE),
    PatchSet("15.8.1 / Raven-family", 24, 6, RAVEN | RAVEN2 | PICASSO),
    PatchSet("15.8.1 / gfx9 APU fallback", 24, 6, ALL),
    PatchSet("26.7.1 / gfx9 APU", 25, 6, ALL),
]


def select(major: int, minor: int, apus: int) -> str | None:
    for patch_set in SETS:
        if (major, minor) < (patch_set.major, patch_set.minor):
            continue
        if (major, minor) > (patch_set.major, patch_set.minor):
            continue
        if apus == 0:
            if patch_set.apus != ALL:
                continue
        elif patch_set.apus & apus == 0:
            continue
        return patch_set.name
    return None


def main() -> None:
    cases = [
        (24, 6, RENOIR | GREEN_SARDINE, "15.8.1 / Renoir-family"),
        (24, 6, RENOIR_E, "15.8.1 / Renoir-family"),
        (24, 6, RAVEN, "15.8.1 / Raven-family"),
        (24, 6, RAVEN2, "15.8.1 / Raven-family"),
        (24, 6, PICASSO, "15.8.1 / Raven-family"),
        (24, 6, 0, "15.8.1 / gfx9 APU fallback"),
        (24, 5, RENOIR, None),
        (24, 7, RENOIR, None),
        (25, 6, RENOIR, "26.7.1 / gfx9 APU"),
        (25, 5, RENOIR, None),
        (23, 6, RENOIR, None),
    ]
    for major, minor, apus, expected in cases:
        got = select(major, minor, apus)
        status = "ok" if got == expected else "FAIL"
        print(f"{status}: macOS/Darwin {major}.{minor} apus=0x{apus:02X} -> {got}")
        if got != expected:
            raise SystemExit(1)
    print("all patch-set selection cases passed")


if __name__ == "__main__":
    main()
