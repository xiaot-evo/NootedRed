# Target driver data collector (archived)

> **Superseded by [`collect_compat_data.py`](README-collect-compat-data.md).** This script from the
> archived `research/patch-resolver` branch only collects the GL/MTL user-space images; the current
> collector also scans the patch sites and gathers the VDA data. Kept for reference.

`collect_target_data.py` collects the user-space AMD driver data needed to add
support for a new macOS build. It does **not** install or patch anything.

## Why

The Chromium fix is version-specific: `AMDRadeonX5000GLDriver` and the
`AMDRadeonX5000MTLDriver` shared-cache image change between macOS builds. A
`PatchSet` needs the real page images/instruction context from the target
build; guessing offsets is not acceptable.

## Requirements

- Run on the target macOS install.
- Python 3 (`/usr/bin/python3`, Xcode CLT, Homebrew, or python.org).
- Read access to `/System/Library/Extensions` and the dyld shared cache.
- No root required.

## Usage

```sh
python3 tools/collect_target_data.py --out NootedRed-target-data.zip
```

If the cache directory is not auto-detected:

```sh
python3 tools/collect_target_data.py \
  --cache-dir /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld \
  --out NootedRed-target-data.zip
```

Send the resulting zip back for analysis. It contains:

- `GLDriver.bin` and the `0xE000` / `0x8000` GL pages;
- `MTL-image.bin` (`__TEXT` of the MTL driver from the shared cache);
- MTL load commands and matching symbols;
- `system.txt` (`sw_vers`, `uname`, `kextstat`, `ioreg`);
- `hashes.txt`.

## Privacy / redistribution

The zip contains Apple driver code. Use it only for local compatibility
analysis; do not publish it. Only the resulting minimal page images/signatures
belong in the project.

## After collection

1. Identify the Darwin version (`sw_vers` / `uname -r`).
2. Locate the GL HwInfo/dual-quad sites and the MTL gate/setz sites for that
   build (disassembly + symbols from `MTL-symbols.txt`).
3. Generate `PagePatch`/`PatchSet` entries with `tools/gen_patch_data.py` or the
   resolver signature generator.
4. Build, install, reboot, and verify on the target APU.
