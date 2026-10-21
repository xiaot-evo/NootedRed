# Compatibility data collector

`collect_compat_data.py` gathers the machine data needed to extend NootedRed's two hardware fixes to
another macOS build or AMD APU:

- the Chromium/Electron GL/Metal dual-source fix — user-space driver images and candidate patch sites;
- the VCN/VDA hardware codec support — kernel ABI data, user-space VA/AppleGVA patch data and media
  capabilities.

It is read-only, does not install anything and does not need root. It replaces the older
`collect_platform_data.py` for current work (that script is kept for the historical datasets).

## Requirements

- Run on the target macOS install, normally the machine being diagnosed.
- **Prefer a pristine boot** for data that will be used to generate new patch sets: boot with `-NRedOff`
  (or without NootedRed) so the kext has not patched the file-backed page cache. The collector detects
  the patched state and, for the already-committed 15.8.1 pages, reconstructs the vanilla pages from
  `NootedRed/UserPatches.cpp`; for any other build you need the pristine boot.
- `python3`, `nm`, `ioreg`, `system_profiler`, `kmutil`/`ffmpeg` are used when present; missing tools only
  produce warnings.

## Usage

```sh
python3 tools/collect_compat_data.py --out /tmp/nred-<os>-<apu>
python3 tools/collect_compat_data.py --out /tmp/nred-<os>-<apu> --zip
```

Options:

| Option | Meaning |
| --- | --- |
| `--out DIR` | output directory (must not exist) |
| `--zip` | also create `DIR.zip` for uploading |
| `--cache-dir DIR` | override the dyld shared cache directory |
| `--include-kc` | copy `SystemKernelExtensions.kc` (hundreds of MB); needed to re-derive VDA data for a new macOS build |
| `--no-generators` | skip running the VCN/VA/GVA generators (faster, metadata/Chromium data only) |

## Output layout

```
manifest.json                 schema/tool version, OS/GPU identity, generator results, warnings, file hashes
SHA256SUMS
metadata/
  sw_vers.txt uname.txt boot-args.txt csrutil.txt nvram-filtered.txt
  hardware.json displays.json gpu-identity.json      (serial/UUID fields redacted)
  kexts-kmutil.txt kexts-kextstat.txt
  ioreg-gpu.txt ioreg-media.txt
  videotoolbox-ffmpeg.txt coremedia-defaults.txt
chromium/
  GLDriver.bin / GLDriver.stock.bin                  (stock copy exists when the live page cache was patched)
  GLDriver-nm.txt
  MTL-image.bin / MTL-image.stock.bin
  MTL-info.json MTL-symbols-all.txt
  sites.json                                          every hit of the known patch patterns, with page hashes
  pages/<sha>.bin                                     unique 4 KiB pages containing the hits
  spec-hints.json                                     how to turn the hits into a gen_patch_data.py spec
vda/
  kernel-info.json                                    KC + X5000/X6000 UUIDs, versions and segment hashes
  kernel-abi.json                                     guards / call-site tables (when derivable)
  generated/                                          VCNData/24H32.hpp, VDAVAData.hpp, VDAGVAData.hpp
  generator-results.json                              exit codes, stdout/stderr; --check fallback verdicts
  firmware/                                           on-disk AMD firmware blobs, when available
```

`chromium/sites.json` is the important file for a new macOS build: it lists every hit of the validated
patterns (`c7477804000000`, `83e0fe`, `750b`, `0f94c0`) with the file/VA offset, page offset, 32-byte
context and a reference to the unique 4 KiB page image. Pick the correct sites in a disassembler, then
write a spec for `tools/gen_patch_data.py` (format in `tools/README-patchgen.md`).

## VDA data

`vda/generated/` contains the three headers as generated on the target build, or the committed headers
when the generators can verify them against the live system (`--check` fallback) but cannot regenerate
because the page cache is patched. `vda/generator-results.json` records both outcomes. If generation
fails entirely, the kernel/user-space build is not 15.8.1-compatible: keep the dataset, add
`--include-kc`, and re-derive the tables for that build.

`vda/kernel-info.json` is still collected on unknown builds: it contains the kernel collection UUID and
the X5000/X6000 kext UUIDs, versions and segment hashes. The VDA path is currently gated to the exact
15.8.1 build, so this is the identity evidence needed to widen that gate later.

## Privacy and redistribution

The archive contains Apple binaries and hardware details, not system files beyond what is needed. The
hardware JSON has serial numbers and hardware UUIDs redacted, and only the relevant `nvram` keys are
kept. **Do not publish the archive**; share it privately with the maintainer.

## Adding a dataset to the repository

1. Collect the archive and keep it outside git (`.gitignore` covers `platform-data/` archives).
2. Record it under `platform-data/<date>_<os>_<cpu>_<device-id>/` if it should be indexed.
3. Add an entry to `docs/Platform-Data-Index.md` with the OS build, Darwin version, APU/device ID and
   archive hash.
4. From the collected files, add the data to `NootedRed/UserPatches.cpp` / `DeviceProfile` using the
   generators, and record the hardware validation status honestly.
