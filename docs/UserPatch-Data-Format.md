# NootedRedUserPatch source data format

Status: implementation contract for format version 1 (2026-10-23). This is build-time source data:
`tools/embed_patchdata.py` compiles it into `NootedRedUserPatch.kext` as generated `const` arrays, and
the kext performs no runtime file reads. `PatchData/` is never copied to a system directory.

The host tools that produce and validate this format are:

- `tools/userpatch_data.py` — generator (JSON spec + exact 4 KiB pages → `manifest.bin`, `pages.bin`,
  `manifest.json`);
- `tools/convert_master_patchdata.py` — derives the deployment specs (`tools/specs/`) and
  `PatchData/` from the pinned master exact-page tables; `--check` verifies the committed output;
- `tools/master_source.py` — verifies the pinned `tools/pinned/master` snapshot of master's tables;
- `tools/test_userpatch_data.py` — independent parser/validator, deployment checks and
  malformed-data tests;
- `tools/fixtures/master-15.8.1/` — checked-in real 15.8.1 sample derived from master's exact-page
  tables (see its `README.md` for provenance);
- `tools/fixtures/minimal-24H32/` — 1-table/1-page/1-site subset of the same data with `apuMask`
  bit 5, for loader/selection test vectors.

## 1. Directory layout

Source tree in the repository:

```
PatchData/<build>/
    manifest.bin
    pages.bin
    manifest.json      # human-readable provenance, not parsed by the kext
```

`<build>` is the exact `kern.osversion` string, for example `24H32`. `tools/embed_patchdata.py`
compiles each build into `NootedRedUserPatch/PatchDataBlob.*`; the kext selects the embedded entry whose
build string exactly matches the running build. There is no runtime directory, no resource-bundle
fallback and no path from a boot argument. A build without an embedded entry is a fail-closed
`BuildUnsupported` NoOp.

## 2. manifest.bin

Little-endian, packed, fixed-width. All multi-byte integers are little-endian. There is no implicit
padding anywhere. The parser rejects unknown versions, unknown/duplicate table kinds, overflowed
lengths, out-of-range offsets and a manifest whose checksums do not match.

### 2.1 Header

The header is exactly **72 bytes** for format version 1. `headerSize` is the total header size in
bytes, including `manifestChecksum`; a v1 parser requires `headerSize == 72`.

| Offset | Size | Field | Value / meaning |
| --- | --- | --- | --- |
| 0 | 4 | `magic` | ASCII `"NRPD"` |
| 4 | 2 | `version` | `1` |
| 6 | 2 | `headerSize` | `72` |
| 8 | 16 | `build` | `kern.osversion` (e.g. `"24H32"`), NUL padded |
| 24 | 2 | `darwinMajor` | e.g. `24` |
| 26 | 2 | `darwinMinor` | e.g. `6` |
| 28 | 2 | `darwinPatch` | e.g. `0` |
| 30 | 2 | `reserved` | `0` |
| 32 | 4 | `apuMask` | bit 0 Raven, 1 Raven2, 2 Picasso, 3 Renoir, 4 RenoirE, 5 GreenSardine |
| 36 | 4 | `tableCount` | number of table records |
| 40 | 4 | `pageCount` | number of page records |
| 44 | 4 | `siteCount` | number of site records |
| 48 | 4 | `manifestSize` | total size of `manifest.bin` in bytes |
| 52 | 4 | `pagesSize` | length of `pages.bin` in bytes |
| 56 | 4 | `pagesChecksum` | FNV-1a 32 over `pages.bin` (see 2.6) |
| 60 | 4 | `reserved2` | `0` |
| 64 | 8 | `manifestChecksum` | FNV-1a 64 over the manifest with this field zeroed (see 2.6) |

`build` rules: 1–15 bytes, characters `[0-9A-Za-z._-]`, followed by at least one NUL byte, with all
remaining bytes zero. The field is not a C string by accident: it is fixed-width and NUL padded.

`manifestSize` is the **complete file length**, not just the record area:

```
manifestSize = 72 + tableCount * 24 + pageCount * 16 + siteCount * 76
```

`apuMask` must be non-zero and must not contain bits outside 0–5 in v1.

### 2.2 Table records

Immediately after the header, `tableCount` records of 24 bytes:

```c
struct TableRecord {
    UInt32 kind;             // 1 GL, 2 Metal, 3 VDA/VA, 4 VDA/AppleGVA
    UInt32 pageIndex;        // first page in this table
    UInt32 pageCount;
    UInt32 siteIndex;        // first site in this table
    UInt32 siteCount;
    UInt32 reserved;         // 0
};
```

### 2.3 Page records

Immediately after the table records, `pageCount` records of 16 bytes:

```c
struct PageRecord {
    UInt32 dataOffset;       // offset in pages.bin, must be 4 KiB aligned
    UInt32 dataSize;         // exactly 4096
    UInt32 reserved[2];      // 0
};
```

The canonical v1 generator emits page `i` at `dataOffset == i * 4096`, in table order and then spec
order. A parser must only require 4 KiB alignment, `dataSize == 4096` and that
`dataOffset + 4096 <= pagesSize`; host validation additionally checks the canonical sequential layout.

### 2.4 Site records

Immediately after the page records, `siteCount` records of 76 bytes:

```c
struct SiteRecord {
    UInt32 pageIndex;        // index into the PageRecord array
    UInt32 offset;           // offset inside the 4 KiB page; authoritative
    UInt8  find[32];         // bytes expected at `offset`, zero padded after `size`
    UInt8  replace[32];      // bytes written, zero padded after `size`
    UInt8  size;             // 1..32; applies to both find and replace
    UInt8  reserved[3];      // 0
};
```

Site rules:

- `offset + size <= 4096`; `pageIndex < pageCount`; `1 <= size <= 32`.
- `find` is the expected content at the declared `offset`; the runtime verifies exactly those bytes
  and writes `replace` there. `offset` is authoritative.
- **In-page find uniqueness is not required.** Real 15.8.1 data contains repeated find sequences on
  the same page (for example the dual-quad find `83 E0 FE` occurs at page offsets `0x68` and `0x160`).
  The runtime must patch only the recorded offset and must not search for a unique occurrence.
- `replace` must differ from `find`; a no-op site is malformed.
- Unused `find`/`replace` bytes after `size`, and `reserved[3]`, must be zero.
- Two sites on the same page must not have overlapping write ranges.

The binary record has no "occurrence index" field: the generator input pins an ambiguous find with an
explicit `findOccurrence` acknowledgement and only the resolved offset is stored. `manifest.json` keeps
the occurrence index for humans and for host-side re-validation.

### 2.5 Record order and canonical v1 layout

The three record arrays are stored back to back in this order: tables, pages, sites.

v1 data is canonical:

1. table kinds are unique and strictly ascending (1 < 2 < 3 < 4);
2. each table has `pageCount >= 1` and `siteCount >= 1`;
3. table page ranges are contiguous and cover all page records exactly:
   table `i` has `pageIndex == sum(pageCount of previous tables)`, and the last table ends at
   `pageCount`;
4. table site ranges are contiguous and cover all site records exactly, in the same way;
5. pages and sites appear in table order, then in the generator spec's order within each table.

A v1 parser must reject a manifest that violates 1–4. This makes the whole file self-describing:
`tableCount`/`pageCount`/`siteCount` plus the ranges account for every record exactly once.

### 2.6 Checksums

Both checksums are standard FNV-1a:

| Checksum | Width | Offset basis | Prime | Input |
| --- | --- | --- | --- | --- |
| `pagesChecksum` | 32 bit | `0x811C9DC5` | `0x01000193` | every byte of `pages.bin` in order |
| `manifestChecksum` | 64 bit | `0xCBF29CE484222325` | `0x100000001B3` | every byte of `manifest.bin`, with bytes 64–71 (`manifestChecksum`) treated as zero |

For each byte: `hash ^= byte; hash = (hash * prime) mod 2^width`. The manifest checksum therefore
covers the header (including `manifestSize`), table records, page records and site records. The
`pagesChecksum` field inside the header is covered by the manifest checksum like any other byte.

### 2.7 Limits and parser rejection rules

Format v1 limits (a parser must reject larger values; a generator must refuse to produce them):

| Item | Limit |
| --- | --- |
| `tableCount` | <= 16 (kinds are unique in v1, so at most 4 are meaningful; the larger bound is forward-compatible) |
| `pageCount` | <= 64 |
| `siteCount` | <= 1024 |
| `manifestSize` | <= 131072 bytes (128 KiB; defensive ceiling) |
| `pagesSize` | <= `pageCount * 4096` and <= 262144 bytes (256 KiB) |

The parser must validate:

- file length is within the limits and at least the 72-byte header;
- `magic == "NRPD"`, `version == 1`, `headerSize == 72`;
- header `reserved`/`reserved2` are zero, page/table/site reserved fields are zero, unused
  `find`/`replace` padding is zero;
- `build` and Darwin/Patch fields are well-formed as described in 2.1;
- `manifestSize` equals both the computed record-layout size and the real file length;
- `pagesSize` equals the real `pages.bin` length;
- both checksums match exactly;
- all table/page/site ranges are inside their arrays and the canonical layout in 2.5 holds;
- every `PageRecord` is exactly one 4 KiB aligned page, inside `pages.bin`;
- every `SiteRecord` is inside its page, has a valid size, does not overlap another site on the same
  page, and its `find` bytes equal the referenced page bytes at `offset`;
- VDA tables (kind 3, 4) are only used after the main kext's `NRedVCNBridgeReady` property is visible
  (parser-independent runtime rule, see 4 and 5).

On any failure: reject the whole directory, log a specific reason and stay `NoOp`. Never fall back to
another build, another page, or a heuristic byte scan.

## 3. Data selection

1. Open `<root>/<kern.osversion>/manifest.bin` and `pages.bin`.
2. Validate magic/version/headerSize/checksums/record ranges/build/Darwin/APU as described above.
3. If any step fails: log a specific reason, do not install hooks, feature state `NoOp`/`Unsupported`.
4. Never fall back to another build, another page, or a heuristic byte scan.

### 3.1 APU mask matching

`apuMask` is the only APU gate in format v1: there is no per-device-ID allow-list field. The satellite
derives a *candidate* family bit set for the running iGPU and accepts the manifest when the two sets
intersect:

```
accept = (manifest.apuMask & candidateFamilyMask) != 0
```

An unknown device ID (or a candidate set of zero) never matches: log `NoOp`, do not install hooks.
Intersection matches mainline NootedRed's `selectPatchSet()` rule `(set.apus & running) == 0 -> skip`.
Exact 4 KiB page equality is still the final gate, so a conservative (wider) candidate set cannot cause
writes to a mismatched driver page.

Mainline family bits (from `NRed::processPatcher/hwLateInit` and `UserPatches::currentApuMask`):

| PCI device ID | Mainline family bits | Notes |
| --- | --- | --- |
| `0x15DD` Raven | bit 0 | attributes stay empty; mainline special-cases the device ID |
| `0x15D8` Raven2/Picasso | bit 2, plus bit 1 if `devRevision >= 8` | `devRevision` is STRAP0; without a STRAP0 read use candidate `{bit1, bit2}` |
| `0x1636`, `0x164C` Renoir/Cezanne | bit 3, plus bit 4 if `devRevision == 0` and PCI revision `0x80..0x84` | without a STRAP0 read use candidate `{bit3, bit4}` |
| `0x15E7`, `0x1638` Barcelo/Green Sardine | bits 3 and 5 | mainline sets Renoir and GreenSardine together |
| anything else | none | fail closed (`NoOp`) |

A spec/manifest author declares the families for which the page/site data is validated. Because a data
directory is keyed only by the exact build, a single manifest must use the union of the families it
serves when the pages are shared (the checked-in 15.8.1 fixture uses `0x3F`, matching master's generic
gfx9 fallback). If future page data diverges per family, that needs a new format/deployment scheme
(for example a v2 field or per-family data roots); v1 cannot express per-family data for one build.

If the family properties are not available yet, retry from the service-start path; do not guess a
family.

Driver identity in format v1 is **exact 4 KiB page equality**: a site is written only if the live page
matches the stored page image byte for byte. There is no separate driver-bundle hash field yet; a
future manifest version may add one. Host-side, the generator can optionally pin a full driver image
(SHA-256) and verify that each page is the 4 KiB slice at a declared file offset.

### 3.2 Deployed data sets

The repository ships build-time source data under `PatchData/`, derived deterministically from the
pinned master snapshot (`tools/pinned/master`, master commit `0efa6f4`) by
`tools/convert_master_patchdata.py`. The readable inputs (exact page images plus table/site specs) are
checked in under `tools/specs/<build>/`; every byte has a provenance chain back to master's stock page
arrays. `tools/embed_patchdata.py` compiles this tree into the satellite's `PatchDataBlob.*`.

| Build | Darwin | `apuMask` | Table kinds | Pages | Sites | `manifest.bin` | `pages.bin` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `24H32` (15.8.1) | 24.6.0 | `0x3F` | 1 GL, 2 Metal, 3 VDA/VA, 4 VDA/AppleGVA | 13 | 18 | 1744 B | 53248 B |

Kinds 1/2 are exact `AMDRadeonX5000GLDriver`/`AMDRadeonX5000MTLDriver` pages; kinds 3/4 are
`AMDRadeonVADriver2`/`AppleGVA` pages from master's generated headers. GL/Metal are independent of the
VCN bridge; VDA kinds require `NRedVCNBridgeReady` and remain page-gated.

Deployment is build-time embedding; there is no runtime directory copy:

```sh
python3 tools/embed_patchdata.py --write    # regenerate NootedRedUserPatch/PatchDataBlob.*
python3 tools/embed_patchdata.py --check    # fail if generated arrays are stale
# rebuild and re-sign NootedRedUserPatch.kext
```

`manifest.json` is provenance/reporting only and is not parsed by the kext. Regenerate and verify:

```sh
python3 tools/master_source.py --verify            # pinned master snapshot hashes
python3 tools/convert_master_patchdata.py          # rewrite tools/specs + PatchData
python3 tools/convert_master_patchdata.py --check  # fail if committed output is stale
python3 tools/test_userpatch_data.py               # independent format/deployment tests
python3 tools/test_embedded_patchdata.py           # embedded-array round-trip tests
```

Known gaps (data is not fabricated for them):

- Only `24H32` is deployed. Other builds are intentionally unsupported until a complete exact page
  set exists; the removed `23J631`/`25G241` sets and family-prefix fallbacks are not coming back
  through guessing. Add a pinned source and a `BuildSpec` entry in
  `tools/convert_master_patchdata.py`; do not guess pages.
- VDA/AppleGVA data is hardware-validated only on Renoir `0x1638` (15.8.1). Format v1 has one
  `apuMask` per build, so other VCN 2.2 APUs rely on exact page equality plus the
  `NRedVCNBridgeReady` gate.
- Driver identity in format v1 is exact 4 KiB page equality; there is no driver-bundle hash field.

`tools/specs/*/spec.json` records the pinned master commit, per-source SHA-256, the
`UserPatches::registerVDAFix` mapping verified from master's `NRed.cpp`, and the gaps above in its
`provenance` block; `PatchData/*/manifest.json` carries the same provenance to the deployed copy.

## 4. Applying a page

For a validated file-backed page or a 4 KiB shared-cache page:

1. For each `PageRecord` in the selected GL/Metal table, compare the live `data` against the page
   image at `pages.bin + dataOffset`.
2. On exact equality, verify every site's `find` bytes at `offset` in the live page. The site's
   `offset` is used as-is; no searching or uniqueness check is performed.
3. Write `replace` bytes for every site under `MachInfo::setKernelWriting`.
4. Record the page as patched so a later validation does not rewrite it.
5. A page mismatch is a normal no-op.

VDA tables additionally require the main kext's `NRedVCNBridgeReady` property before they are used.

## 5. Generator contract

`tools/userpatch_data.py` receives:

- a JSON spec with the exact build identity (`build`, `darwin`, `apuMask`);
- table entries (kind + pages) and, per page, the exact 4 KiB page image (relative path + SHA-256);
- per site: explicit page offset, `find`/`replace` hex (equal length, 1–32 bytes), optional
  `findOccurrence`, `name`, `note`;
- optional full driver images with SHA-256 so page→driver slice identity can be checked.

It emits `manifest.bin`, `pages.bin` and `manifest.json` under `<out>/<build>/`. Adding a new build
means adding a new spec and page images; no tool source edits and no kext rebuild.

It fails on:

- a page not exactly 4096 bytes, or whose SHA-256 does not match the spec;
- a site whose `find` bytes are not present at its declared offset;
- an ambiguous `find` without a matching explicit `findOccurrence`;
- `find`/`replace` length mismatch, a no-op site, overlapping site writes, or a site past the page;
- a driver image hash mismatch, or a page that does not match the declared driver file offset;
- unknown table kinds, duplicate kinds, empty tables/pages/sites, unknown spec fields;
- build/Darwin/APU values or table/page/site counts outside the format limits.

Output is deterministic: no timestamps, absolute paths or machine-specific data; identical inputs
produce byte-identical `manifest.bin`, `pages.bin` and `manifest.json`.

Host validation must independently re-open the output and verify every record and checksum before a
commit is accepted (`tools/test_userpatch_data.py`).

## 6. What the satellite parser must enforce (checklist)

- Little-endian packed reads; never use a C struct with implicit padding.
- `magic == "NRPD"`, `version == 1`, `headerSize == 72`.
- Total file length <= 128 KiB; `manifestSize == 72 + 24*T + 16*P + 76*S == len(file)`.
- `pagesSize == len(pages.bin)` and `pagesSize <= P * 4096`.
- `pagesChecksum` = FNV-1a-32 over `pages.bin`; `manifestChecksum` = FNV-1a-64 over the manifest with
  bytes 64–71 zeroed.
- Header/table/page/site reserved fields and unused `find`/`replace` padding are zero.
- `build` is 1–15 valid characters, NUL padded, zero after the terminator; Darwin major >= 1; APU mask
  non-zero and within bits 0–5; the APU mask contains the running APU family.
- `tableCount <= 16`, `pageCount <= 64`, `siteCount <= 1024`.
- Known kinds only (1–4), unique and strictly ascending; canonical contiguous table ranges (2.5).
- Every page: `dataSize == 4096`, `dataOffset` 4 KiB aligned, `dataOffset + 4096 <= pagesSize`.
- Every site: `pageIndex < pageCount`, `offset + size <= 4096`, `1 <= size <= 32`, no overlapping
  writes on the same page, `find` matches the page image at `offset`.
- Fail closed to `NoOp` on any violation; never reuse a partially parsed directory.
- Verify the `find` bytes at the stored offset at patch time. Do **not** require in-page uniqueness.

## 7. Versioning

`version` is bumped for any layout change; a parser must reject versions it does not know. `headerSize`
exists so a future version can grow the header, but v1 parsers require exactly 72. Adding new fields
inside `reserved`, adding a new table kind, changing the checksum algorithm or changing the canonical
layout requires a version bump and a matching doc/tool/test update.
