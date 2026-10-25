# UserPatch source data

Build-time source data for the embedded tables in `NootedRedUserPatch.kext`, in the format defined by
[`docs/UserPatch-Data-Format.md`](../docs/UserPatch-Data-Format.md). Each subdirectory is one exact
macOS build; it is compiled into the kext through `tools/embed_patchdata.py` and is **not** copied to
`/Library/Application Support` at runtime.

**Do not edit these binaries by hand.** They are derived deterministically from the pinned master
snapshot (`tools/pinned/master` at commit `0efa6f4`) by
[`tools/convert_master_patchdata.py`](../tools/convert_master_patchdata.py); the readable inputs are
under [`tools/specs/`](../tools/specs/).

## Contents

| Build | Darwin | `apuMask` | Table kinds | Pages | Sites | `manifest.bin` |
| --- | --- | --- | --- | --- | --- | --- |
| `24H32` (macOS 15.8.1) | 24.6.0 | `0x3F` | 1 GL, 2 Metal, 3 VDA/VA, 4 VDA/AppleGVA | 12 | 17 | 1652 B |
| `25G241` (macOS 26.7.1) | 25.6.0 | `0x3F` | 1 GL, 2 Metal, 3 VDA/VA, 4 VDA/AppleGVA | 11 | 17 | 1636 B |
| `23J631` (macOS 14.8.9) | 23.6.0 | `0x38` | 3 VDA/VA, 4 VDA/AppleGVA | 9 | 13 | 1252 B |

Each directory contains `manifest.bin`, `pages.bin` and the human-readable `manifest.json`
(ignored by the kext). GL/Metal tables are independent of the main kext; VDA/AppleGVA tables require
the main kext's `NRedVCNBridgeReady` property and the exact 4 KiB page to match before any byte is
written.

## Embed / install

```sh
python3 tools/embed_patchdata.py --write    # regenerate PatchDataBlob.*
python3 tools/embed_patchdata.py --check    # fail if generated blob is stale
# rebuild and re-sign NootedRedUserPatch.kext, then install it through OpenCore
```

The satellite selects the exact embedded build whose `kern.osversion` matches. There is no runtime
data directory to copy or remove; a mismatched build or checksum is a fail-closed `NoOp`. Adding a
build requires regenerating the blob and rebuilding/re-signing the kext.

## Regenerate / verify

From the repository root:

```sh
python3 tools/master_source.py --verify            # pinned master snapshot hashes
python3 tools/convert_master_patchdata.py          # rewrite tools/specs + PatchData
python3 tools/convert_master_patchdata.py --check  # fail if committed data is stale
python3 tools/convert_master_patchdata.py --report # inventory and gaps
python3 tools/embed_patchdata.py --write           # regenerate embedded C++ arrays
python3 tools/embed_patchdata.py --check           # generated arrays match PatchData
python3 tools/test_userpatch_data.py               # independent format/deployment validation
python3 tools/test_embedded_patchdata.py            # embedded-array round-trip tests
```

Regeneration is deterministic: identical pinned sources produce byte-identical `manifest.bin`,
`pages.bin` and `manifest.json`. The converter refuses to guess: pages must come from master's stock
arrays and sites must resolve from the verified `find`/`replace`/`skip`/`count` fields.

## Provenance and gaps

`manifest.json` in each directory records the pinned master commit, per-source-file SHA-256, the
master patch table for every kind, and the known gaps. Current gaps:

- **`23J631` GL/Metal are not deployed.** Master has exact Sonoma GL/Metal pages for the Darwin 23.6
  range, but they are not pinned to an exact `kern.osversion`, so only VDA/VA and VDA/AppleGVA are
  generated for that build. This is listed in the spec/manifest provenance rather than papered over.
- Other macOS builds have no data. Adding one requires pinning the source and extending
  `tools/convert_master_patchdata.py`; do not hand-edit page arrays.
- VDA/AppleGVA data is hardware-validated only on Renoir `0x1638` (15.8.1). Format v1 has a single
  `apuMask` per build; other VCN 2.2 APUs rely on exact page equality and `NRedVCNBridgeReady`.
- Driver identity in format v1 is exact 4 KiB page equality; there is no driver-bundle hash field.

No Apple driver binary is included: every `pages.bin` byte is a master source byte array (the arrays
themselves were extracted from real driver builds). See each spec's `provenance` block and
`tools/fixtures/master-15.8.1/README.md` for the independent cross-checks.
