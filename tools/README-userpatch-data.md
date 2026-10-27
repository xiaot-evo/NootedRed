# UserPatch external data tooling

Host-side generator and independent validator for the satellite kext's external patch data. The
on-disk contract is [`docs/UserPatch-Data-Format.md`](../docs/UserPatch-Data-Format.md); this file
covers the tools only. Nothing here touches a kext, installs data, or reboots a machine.
Tooling retired with the mainline split (old C++ page-header generators/tests) is listed in
[`RETIRED.md`](RETIRED.md).

## Files

| File | Purpose |
| --- | --- |
| `userpatch_data.py` | generate `<out>/<build>/{manifest.bin,pages.bin,manifest.json}` from a JSON spec + exact 4 KiB page images |
| `convert_master_patchdata.py` | derive `tools/specs/` + generated `PatchData/` from the pinned master tables (`--check`/`--report`) |
| `master_source.py` | verify/refresh the pinned `tools/pinned/master` snapshot (D7 provenance fix) |
| `master_tables.py` | read-only parsers for master's C++ page arrays and `PagePatch` tables |
| `test_userpatch_data.py` | independent parser/validator, pinned-source/deployment checks and malformed-data tests |
| `embed_patchdata.py` | embed committed `PatchData/` into `NootedRedUserPatch/PatchDataBlob.{hpp,cpp}` (deterministic, round-trip checked) |
| `test_embedded_patchdata.py` | host validation of the embedded arrays (bytes, index metadata, no-VFS contract, C++ compile/run) |
| `NootedRedUserPatch/PatchDataBlob.*` | **generated** embedded data; do not edit by hand |
| `extract_userpatch_fixture.py` | derive the checked-in fixture from master's exact-page tables (`--check` verifies it is current) |
| `pinned/master/` | byte-for-byte master snapshot of the table sources, with commit/SHA-256 manifest |
| `specs/` | readable deployment inputs for `convert_master_patchdata.py` (spec + exact page images) |
| `fixtures/master-15.8.1/` | real 15.8.1 sample data (3 pages, 4 sites) with provenance in its `README.md` |
| `fixtures/minimal-24H32/` | 1-table/1-page/1-site subset of the above (`apuMask` bit 5) for loader/selection test vectors |

## Commands

```sh
# Generate a PatchData build directory from a spec (generator input; embed + rebuild afterwards)
python3 tools/userpatch_data.py \
    --spec tools/fixtures/master-15.8.1/spec.json \
    --out build/PatchData
# -> build/PatchData/24H32/{manifest.bin,pages.bin,manifest.json}

# Validate the generated output and run the full test suite
python3 tools/test_userpatch_data.py

# Verify the checked-in fixture against the pinned master snapshot (or a live/--source tree)
python3 tools/extract_userpatch_fixture.py --check
```

The generator is deterministic: no timestamps or absolute paths, and identical inputs produce
byte-identical outputs. `--build` overrides the build string/directory only (format-plumbing tests).

## PatchData build sets (generator input)

`PatchData/` at the repository root contains the generated per-build data sets. Since the satellite
embeds them at build time (see the next section), this directory is **generator input and host
validation data**, not a runtime deployment directory:

| Build | Darwin | Kinds | Pages | Sites |
| --- | --- | --- | --- | --- |
| `24H32` | 24.6.0 | 1 GL, 2 Metal, 3 VDA/VA, 4 VDA/AppleGVA | 13 | 18 |

```sh
# Verify the pinned master snapshot (works at HEAD; master's user-space source is deleted here)
python3 tools/master_source.py --verify

# Regenerate readable specs + PatchData deterministically
python3 tools/convert_master_patchdata.py
python3 tools/convert_master_patchdata.py --check   # fail if committed output is stale
python3 tools/convert_master_patchdata.py --report  # inventory + gaps

# Then embed the updated data into the kext-generated blob (required before a rebuild)
python3 tools/embed_patchdata.py
python3 tools/test_embedded_patchdata.py
```

All pages are master's stock byte arrays and all sites are derived from its verified
`find`/`replace`/`skip`/`count` fields; nothing is hand-edited or invented. `--source-root` and
`--source-git` accept an alternative master tree for verification.

Known gaps (listed, not fabricated): only `24H32` is deployed; other builds are intentionally
unsupported and there is no family-prefix fallback. VDA/AppleGVA is hardware-validated only on Renoir
`0x1638` (15.8.1) and stays behind `NRedVCNBridgeReady` plus exact page equality; v1 has no
driver-bundle hash field.

## Embedded static PatchData (satellite)

The satellite kext does **not** read files at runtime. A diagnostic boot proved that forcing the
external loader to open `PatchData/<build>/manifest.bin` + `pages.bin` from the kernel during early boot
hangs the machine, so the approved design embeds the committed data in the kext:

```
tools/embed_patchdata.py  ->  NootedRedUserPatch/PatchDataBlob.hpp
                              NootedRedUserPatch/PatchDataBlob.cpp   (generated, compiled into kext)
```

`PatchData/` remains the source of truth for generation and host validation, but it is no longer copied
to `/Library/Application Support/...`: there is no runtime data directory, no VFS read, no plist/build
fallback, and no data-volume timing/retry. The kext parses the embedded buffers with the same v1 parser
and applies the same exact-page/readiness rules.

### Generated interface

```cpp
namespace NRedUserPatchData
{
    struct EmbeddedBuild
    {
        const char* build;          // exact kern.osversion, e.g. "24H32"
        const uint8_t* manifest;    // embedded manifest.bin bytes
        const size_t manifestSize;
        const uint8_t* pages;       // embedded pages.bin bytes
        const size_t pagesSize;
        // Mirrored manifest metadata for early filtering/diagnostics (non-authoritative):
        const uint32_t pagesChecksum;     // FNV-1a-32
        const uint64_t manifestChecksum;  // FNV-1a-64 with the checksum field zeroed
        const uint16_t darwinMajor, darwinMinor, darwinPatch;
        const uint32_t apuMask, tableCount, pageCount, siteCount;
    };

    extern const EmbeddedBuild kBuilds[];  // sorted selector index
    extern const size_t kBuildCount;
}
```

The loader iterates `kBuilds`, matches `build` exactly, then validates/parses `manifest`/`pages`
exactly as before (magic/version/header/sizes/FNV checksums/canonical layout/site checks). The mirrored
metadata must not replace that validation.

### Commands

```sh
# Regenerate the embedded files after PatchData changes
python3 tools/embed_patchdata.py

# Staleness / CI check (byte-for-byte against a fresh render and round-trip against PatchData/)
python3 tools/embed_patchdata.py --check
python3 tools/embed_patchdata.py --report

# Host validation: array round-trip, index metadata vs parsed manifests, no-VFS tokens,
# standalone C++ compile+run with checksum recomputation
python3 tools/test_embedded_patchdata.py
```

Embedded today: `24H32` only (the generated `.cpp` is ~340 KB of
hex before compilation). The generated files are deterministic (sorted builds, no timestamps or
absolute paths, content SHA-256 values only) and are round-trip decoded by the generator itself before
being written/accepted.

### Workflow and trade-offs

Adding or changing a build:

1. update `PatchData/<build>/` with `tools/convert_master_patchdata.py` (as before);
2. run `python3 tools/embed_patchdata.py` and commit the regenerated `PatchDataBlob.{hpp,cpp}`;
3. run `python3 tools/embed_patchdata.py --check` + `python3 tools/test_embedded_patchdata.py`;
4. rebuild and re-sign the satellite kext. There is nothing to copy to the target machine's data path
   (the external directory is generator input only).

- **Pro:** no kernel VFS/file-system access in early boot (the measured hang), no dependency on the data
  volume or on `/Library` being readable, no data-file corruption/mismatch at runtime, and patch data is
  versioned and signed together with the kext.
- **Con:** a new/updated build now requires regenerating the blob and rebuilding/re-signing the kext (no
  drop-in directory update), the kext binary grows by the embedded payload (~136 KB), and the satellite
  cannot distinguish data issues from code issues via external files. This rebuild cost is the approved
  stability trade-off.
- **Rollback:** remove/disable the satellite kext and reboot; the main kext is unaffected.

## Spec format

```json
{
  "schema": 1,
  "build": "24H32",
  "darwin": [24, 6, 0],
  "apuMask": 63,
  "drivers": {
    "gl-driver": {"path": "driver/GLDriver.bin", "sha256": "<64 hex>", "size": 1809872}
  },
  "tables": [
    {
      "kind": 1,
      "note": "GL",
      "pages": [
        {
          "source": "pages/gl-driver-hwinfo-0xE000.bin",
          "sha256": "<64 hex>",
          "fileOffset": 57344,
          "driver": "gl-driver",
          "note": "file offset 0xE000",
          "sites": [
            {
              "offset": 129,
              "find": "c7477804000000",
              "replace": "c7477801000000",
              "findOccurrence": 0,
              "name": "gfx9 HwInfo shader-engine count"
            }
          ]
        }
      ]
    }
  ]
}
```

- `kind`: 1 GL, 2 Metal, 3 VDA/VA, 4 VDA/AppleGVA; one table per kind, emitted in ascending kind
  order.
- `pages[*].source`: path relative to the spec directory. Exactly 4096 bytes and pinned by `sha256`.
- `pages[*].driver` + `fileOffset` (optional): additionally verify the page is the 4 KiB slice at that
  offset of the full driver image declared under `drivers` (which is pinned by SHA-256/size).
- `sites[*]`: `offset` is authoritative and must already contain `find`. If `find` occurs more than
  once on the page, `findOccurrence` is required and must be the 0-based index of that match position
  (overlapping matches count). This mirrors master's `skip`/`count` semantics; the runtime does not
  search and never requires find uniqueness.
- `find`/`replace`: hex strings with optional whitespace, 1–32 bytes, equal length; `replace` must
  differ from `find`. Unknown keys are rejected so typos cannot silently drop data.

Output layout is canonical: table kinds ascending, table page/site ranges contiguous and covering the
page/site arrays exactly, pages in table order, sites in page order. Limits: <= 16 tables, <= 64 pages,
<= 1024 sites; manifest <= 128 KiB, pages.bin <= 256 KiB. See the format doc for the byte layout,
FNV-1a checksums and the full parser checklist.

## Adding a build

1. Make the exact 4 KiB page images and exact build identity available; for master-derived data, pin
   the source files (`python3 tools/master_source.py --refresh`) and add a `BuildSpec` entry in
   `tools/convert_master_patchdata.py`.
2. Run `python3 tools/convert_master_patchdata.py` to write `tools/specs/<build>/` and
   `PatchData/<build>/`; add `--report` gaps only for data that is genuinely missing.
3. Run `python3 tools/embed_patchdata.py` to embed the new data into the satellite blob, then
   `python3 tools/test_embedded_patchdata.py`.
4. Run `python3 tools/test_userpatch_data.py`; committed specs/PatchData are checked byte-for-byte
   against a fresh derivation.
5. Rebuild and re-sign the satellite kext (embedded data is part of the signed binary; there is no
   external data-directory deployment step).

## Fixture

`fixtures/master-15.8.1/` is real 15.8.1 data: the three pages and four sites are decoded from
master's `kGLDriverHwInfoPage`, `kGLDriverDualQuadPage`, `kMTLControlPage` and `kGLDriverPatches[]`
table. No Apple driver binary is copied into the repository, and no bytes are invented. The fixture
intentionally contains repeated find sequences (HwInfo 3x, dual-quad 2x, Metal allow 2x), so tests
fail if the validator or generator regresses to requiring find uniqueness. Its `README.md` records
source hashes, page hashes and per-site offsets.
