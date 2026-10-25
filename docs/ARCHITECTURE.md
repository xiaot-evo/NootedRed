# NootedRed architecture

Status: **current architecture** (2026-10-23). This document describes the satellite split that the
branch actually implements. The old in-memory root-patch plans are archived:
[`archive/Root-Patch-Architecture.md`](archive/Root-Patch-Architecture.md) (superseded two-plane
root-patch design), [`ROOT-PATCH-PIPELINE.md`](ROOT-PATCH-PIPELINE.md) (historical pipeline notes,
superseded — see the banner in that file) and the other files in [`archive/`](archive/README.md). They are kept for history and are **not**
implementation guidance.

Related current documents:

- [Modules and support](MODULES-AND-SUPPORT.md) — module responsibilities and full APU/build matrix;
- [Satellite UserPatch plan](Satellite-UserPatch-Plan.md) — decisions, phases, validation matrix;
- [UserPatch data format](UserPatch-Data-Format.md) — source-data contract and embedded generation;
- [`PatchData/README.md`](../PatchData/README.md) — source data sets and gaps;
- [Compatibility matrix](COMPATIBILITY.md) — per-build/APU status.

## 1. Components

```
Lilu
 ├── NootedRed.kext             kernel plane: X5000/HWLibs/AGDP/Backlight/AppleGFXHDA,
 │                              Framebuffer/DC/PM/SMU, VCN kernel bridge, VCNData tables.
 │                              Publishes NRedVCNBridgeReady on the AMD iGPU IOPCIDevice.
 └── NootedRedUserPatch.kext   satellite: exact-page user-space patches for GL/Metal/VDA/AppleGVA.
        └── PatchDataBlob.*    embedded build-time data (generated from PatchData/)
              manifest/pages const arrays, selected by exact kern.osversion
```

Adding/changing a build means regenerating `PatchDataBlob.*` and rebuilding/re-signing the satellite;
there is no runtime data directory. The satellite auto-loads when `NootedRed.kext` is present
(OpenCore `OSBundleLibraries` dependency); `-NRedUserPatchOff` disables it for debugging.

## 2. What runs where

**`NootedRed.kext` (kernel plane)** — kernel/kext patches only. It contains no
`_cs_validate_page`/`_cs_validate_range` routing, no GL/Metal/VDA user-space tables and no VFS I/O in
patcher-load. It publishes the single main↔satellite coordination fact:

- `NRedVCNBridgeReady` — 32-bit IOPCIDevice property, value `1` while
  `VCNBridge::loadReady()` (`requested && x5000Prepared && x6000Prepared && loadCompleted`) is true,
  `0` after readiness is withdrawn (accelerator stop, engine-allocation failure, `initHardware`
  failure). Absent means "not ready".

The main kext must build and run with the satellite absent; that is the primary rollback path.

**`NootedRedUserPatch.kext` (satellite)** — a Lilu plugin that installs
`_cs_validate_page`/`_cs_validate_range` hooks and, for every validated page, compares the complete
4 KiB page image against the embedded page bytes before writing any site bytes. It:

- selects the exact embedded build whose `kern.osversion` matches, then validates magic/version/header,
  `manifestSize`, FNV-1a checksums, canonical table layout, limits, page/site bounds and site `find`
  bytes at their recorded offsets;
- applies tables of kind 1 GL and 2 Metal independently of the main kext; kinds 3 VDA/VA and
  4 VDA/AppleGVA only while the cached `NRedVCNBridgeReady` value is true;
- requires an exact full-page match and the site's `find` bytes at the declared offset; there is no
  semantic scan, no page search and no nearest-build fallback;
- fails closed (`NoOp`) on a missing/mismatched embedded build, build/Darwin/APU mismatch or page
  mismatch, while the plugin stays loaded and the routes stay inert;
- retries transient identity/readiness failures from the Lilu patcher-load callback,
  `IOService::start` and a bounded `thread_call` timer; it performs no file I/O in any of them.

The parser/loader contract is defined in [UserPatch-Data-Format.md](UserPatch-Data-Format.md).

## 3. Data plane

`PatchData/` is generated deterministically from the pinned master-branch exact-page tables
(`tools/pinned/master`, master commit `0efa6f4`) by `tools/convert_master_patchdata.py`; readable
inputs live under `tools/specs/`. `tools/embed_patchdata.py` then emits
`NootedRedUserPatch/PatchDataBlob.*`, which is compiled into the kext. Host validation is
`tools/test_userpatch_data.py` plus `tools/convert_master_patchdata.py --check` and
`tools/test_embedded_patchdata.py`. Committed sets:

| Build | Darwin | Kinds | Notes |
| --- | --- | --- | --- |
| `24H32` | 24.6.0 | 1 GL, 2 Metal, 3 VDA/VA, 4 VDA/AppleGVA | full 15.8.1 set |
| `25G241` | 25.6.0 | 1, 2, 3, 4 | full 26.7.1 set, hardware pending |
| `23J631` | 23.6.0 | 3, 4 | VDA-only; 14.8.9 GL/Metal is a documented gap |

The running kext has no data directory and performs no VFS/read of these files; `PatchData/` is
build-time input only. See [`PatchData/README.md`](../PatchData/README.md) for regeneration/embedding
commands and gaps.

## 4. Selection, patching and rollback

1. Select and validate the embedded build (exact `kern.osversion`, Darwin, APU mask intersection,
   checksums, canonical layout).
2. For a page validation event, compare the live 4 KiB page with the embedded image for the selected
   table; on exact equality verify every site's `find` at its offset.
3. Write all site `replace` bytes under kernel write protection, and remember the page as patched.
4. VDA kinds require the cached `NRedVCNBridgeReady` value; GL/Metal do not.
5. A mismatch or any validation failure is a normal no-op, never a fallback.
6. Rollback: remove `NootedRedUserPatch.kext` from OpenCore (main kext unaffected) or boot
   `-NRedUserPatchOff`.

## 5. Non-goals

- No semantic instruction scanning as a release path; exact 4 KiB page images only.
- No broad cross-build page reuse: a manifest is selected by exact build identity and every page must
  match byte-for-byte.
- No user-space patching inside `NootedRed.kext`.
- No APFS root patching, dyld-cache rewriting or kext replacement in this design (those were the
  archived root-patch plan, not the approved satellite split).
