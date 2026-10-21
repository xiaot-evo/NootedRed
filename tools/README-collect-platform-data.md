# Platform data collector (legacy)

> Superseded by [`collect_compat_data.py`](README-collect-compat-data.md) for current Chromium-fix and
> VDA work.  This script is kept for the historical `platform-data/` datasets.

`collect_platform_data.py` collects everything needed to add a new macOS build / APU family to the
DeviceProfile and PatchSet tables. It does **not** install or patch anything.

## Requirements

- Run on the target macOS install.
- Python 3 (`/usr/bin/python3`, Xcode CLT, Homebrew, or python.org).
- No root required.
- Enough free space for a ~5 MB zip (default optimized profile).

## Usage

```sh
python3 tools/collect_platform_data.py --out NootedRed-platform-data.zip
```

The default profile keeps the analysis-critical data and skips huge Metal resources (MPS/Tensile/
`.builtin` runtime blobs). Use `--full` only when those resources are specifically needed; the zip can
grow to ~40 MB.

If the dyld cache is not auto-detected:

```sh
python3 tools/collect_platform_data.py \
  --cache-dir /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld \
  --out NootedRed-platform-data.zip
```

Run it on **each** target machine/APU when validating a new device; the zip records the device ID and
hardware profile.

## Contents

- macOS build, Darwin version, CPU/model, hardware and display info;
- boot-args, SIP, kext list and loaded kext metadata;
- `GLDriver.bin`, its `0xE000`/`0x8000` pages and `nm` symbols;
- `AMDRadeonX5000MTLDriver` `__TEXT`, load commands and the full symbol table from the dyld cache;
- relevant X5000/X6000 kexts, plug-ins, Info.plists and firmware resources;
- filtered ioreg GPU/media data, VideoToolbox/CoreMedia defaults and `ffmpeg -hwaccels` (if installed);
- `manifest.json` and SHA-256 hashes for every payload, including skipped large resources.

## Privacy

The zip contains Apple driver code, `nvram` output and hardware identifiers. Use it only for local
compatibility analysis; do not publish it. Only minimal page images/patches/signatures belong in the
project.

## After collection

1. Note `sw_vers`/`uname` and the GPU device ID.
2. Add a DeviceProfile entry if the APU is new.
3. Locate the GL/MTL patch sites for that build; generate a PatchSet/signatures.
4. Build, install, reboot, and verify on that machine.

## Importing a dataset

Use the importer to verify the archive and normalize its metadata into the local dataset archive:

```sh
python3 tools/import_platform_data.py NootedRed-platform-data.zip
```

It writes `platform-data/<date>_<os>_<build>_<cpu>_<device>/` with the archive, `SHA256`,
`dataset.json`, extracted metadata and driver images. `platform-data/` is gitignored because it
contains Apple binaries and hardware identifiers.
