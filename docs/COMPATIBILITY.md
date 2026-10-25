# NootedRed compatibility matrix

Status date: 2026-10-23. This table describes what the current tree actually enables, not what the
hardware could theoretically do. A feature is only `validated` when it has passed a real boot and the
corresponding feature test on that exact build **and** APU.

> **Satellite split (2026-10-23):** user-space GL/Metal/VDA patching lives in the separate
> `NootedRedUserPatch.kext` satellite. Its exact-page data is **embedded at build time** from the
> repo-root `PatchData/` sources via `tools/embed_patchdata.py`; the kext performs no runtime file I/O.
> The main `NootedRed.kext` only performs kernel-side enablement and publishes the
> `NRedVCNBridgeReady` iGPU property; it builds and runs with the satellite absent. See the
> [Satellite UserPatch plan](Satellite-UserPatch-Plan.md),
> [UserPatch data format](UserPatch-Data-Format.md) and [`PatchData/README.md`](../PatchData/README.md).
>
> Embedded data committed today:
> - `24H32` — kinds 1 GL, 2 Metal, 3 VDA/VA, 4 VDA/AppleGVA;
> - `25G241` — kinds 1, 2, 3, 4;
> - `23J631` — kinds 3, 4 only (14.8.9 GL/Metal is a documented data gap).
>
> The old mainline `-NRedGLFix`/`-NRedGLFixOff` user-space toggles and the semantic GL fallback no
> longer exist. The satellite auto-loads when NootedRed is present; the only new debug override is
> `-NRedUserPatchOff`.
>
> `-NRedVDA` / `-NRedAVC` still exist, but only as **kernel VCN-bridge** opt-ins in the main kext.
> They must be present for the satellite's VDA/AppleGVA data to be usable: without the bridge,
> `NRedVCNBridgeReady` is never published and the satellite leaves kinds 3/4 unapplied. GL/Metal
> satellite data is independent of those flags.

## Status vocabulary

| Status | Meaning |
| --- | --- |
| **validated** | Real hardware boot + feature test passed for this exact build/APU. |
| **experimental** | Implementation/data exists and is build- or offline-validated, but no hardware test has passed. |
| **supported** | The kext-level path exists for this build, but this is not a claim about the feature-specific data below. |
| **unsupported** | No data or no code path for this build; the feature is a no-op or refuses to run. |
| **no-op** | The code is present, but the exact build/driver pages do not match, so nothing is written. |

## macOS build matrix

| macOS build | Darwin | Kernel / graphics | GL/Metal (satellite data) | VDA/VCN kernel bridge | VDA user-space VA + AppleGVA (satellite data) | HEVC encode |
| --- | --- | --- | --- | --- | --- | --- |
| **15.8.1 (24H32)** | 24.6.0 | supported | **validated** (`0x1638`) | **validated** (`24H32` data) | **validated** (`0x1638`; kinds 3/4) | **validated** (`0x1638`) |
| **14.8.9 (23J631)** | 23.6.0 | supported | **unsupported** (no 23J631 GL/Metal data) | experimental (imported `23J631` data, byte-gated) | experimental (kinds 3/4 data, offline) | experimental (imported data) |
| **26.7.1 (25G241)** | 25.6.0 | supported | experimental (kinds 1/2 data, offline) | experimental (`25G241` data, hardware pending) | experimental (kinds 3/4 data, hardware pending) | experimental (25G241 data, hardware pending) |
| other 15.x (`24H*`) | 24.x | supported | no-op (no exact 24H32 data) | experimental (`24H` family fallback, byte-gated) | **unsupported** (no exact `24H32` directory) | **unsupported** |
| other 14.x (`23H*`/`23G*`/`23J*`) | 23.x | supported | **unsupported** (no exact 14.x GL/Metal data) | experimental (`23J`/`23H`/`23G` family fallback, byte-gated) | **unsupported** (only exact `23J631` data) | **unsupported** |
| other 26.x | 25.x | supported | no-op (no exact 25G241 data) | experimental (`25G` family fallback, byte-gated) | **unsupported** (only exact `25G241` data) | **unsupported** |
| Catalina 10.15 – Ventura 13 | 18–22 | supported | unsupported/no-op | **unsupported** | **unsupported** | **unsupported** |

Notes:

- "Kernel / graphics" means the NootedRed kext itself loads and the existing X5000/HWLibs/display
  patches run. It does not imply GL/Metal or VDA user-space patching.
- GL/Metal and VDA user-space patches are applied by the satellite only when the exact 4 KiB driver
  page matches the committed `pages.bin`; any build/APU/page mismatch is a fail-closed no-op. There is
  no semantic scanner and no nearest-build fallback.
- VDA/AppleGVA tables (kinds 3/4) are additionally gated on the main kext's `NRedVCNBridgeReady`
  property. The property is 1 while `VCNBridge::loadReady()` is true and is republished as 0 on
  accelerator stop, engine-allocation failure and `initHardware` failure, so the satellite cannot apply
  VDA pages while no accelerator exists.
- The satellite runtime has been boot-tested on 15.8.1 / `0x1638`: it loaded the embedded `24H32`
  data, installed both hooks and applied a page. The `validated` entries still describe the
  exact-page data validated previously in the mainline kext; GL/Metal/VDA feature-level tests and
  other builds/APUs remain on the hardware checklist.
- `PatchData/23J631` deliberately does not contain GL/Metal tables: master's Sonoma GL/Metal pages are
  a Darwin 23.6-range table, not pinned to an exact `kern.osversion`. This is a listed data gap, not a
  silent regression.
- VCN family-prefix adapters reuse the nearest validated kernel table (`23J631`, `24H32`, `25G241`) for
  nearby patch releases. Every guard/getter and original call-site byte is still checked; a changed
  kernel is a no-op. These adapters are not a substitute for a build-specific VDA page table.

## APU matrix

| APU / device ID | VCN generation | GL/Metal (15.8.1) | VDA/VA + AppleGVA (15.8.1) | VDA/VA + AppleGVA (23J631) | VDA/VA + AppleGVA (25G241) |
| --- | --- | --- | --- | --- | --- |
| Renoir / Green Sardine `0x1638` | VCN 2.2 | **validated** | **validated** | experimental (data present, hardware pending) | experimental (data present, hardware pending) |
| Renoir `0x1636` | VCN 2.2 | experimental (same 15.8.1 pages) | experimental (same 15.8.1 data) | experimental | experimental |
| Cezanne `0x164C` | VCN 2.2 | experimental | experimental | experimental | experimental |
| Barcelo `0x15E7` | VCN 2.2 | experimental | experimental | experimental | experimental |
| Raven `0x15DD` | VCN 1.x | experimental | **unsupported** (no VCN 2.2 bridge readiness) | **unsupported** | **unsupported** |
| Raven2 / Picasso `0x15D8` | VCN 1.x | experimental | **unsupported** (no VCN 2.2 bridge readiness) | **unsupported** | **unsupported** |

The GL/Metal page data is shared across gfx9 APUs for the listed builds, but only `0x1638` on 15.8.1
has a recorded hardware validation. VDA readiness is never published for VCN 1.x profiles, so VDA
tables stay no-op there even though a 24H32/25G241 manifest's APU mask covers those families for
GL/Metal.

## Feature/control matrix

| Feature | Control | 15.8.1 | 14.8.9 | 26.7.1 |
| --- | --- | --- | --- | --- |
| GL dual-source fix | satellite, `PatchData` kind 1 | validated | no data (no-op) | experimental (exact 25G241 pages) |
| Metal dual-quad fix | satellite, `PatchData` kind 2 | validated | no data (no-op) | experimental (gate/allow, hardware pending) |
| VDA/AppleGVA user-space | satellite, kinds 3/4 + `NRedVCNBridgeReady` | validated | experimental (offline data) | experimental (offline data) |
| VCN2 hardware decode / encode | main kext VCN bridge + satellite VDA | validated | experimental (byte-gated) | experimental (25G241, hardware pending) |
| Disable user-space patches | `-NRedUserPatchOff` debug boot arg | available | available | available |
| Main kext without satellite | remove satellite kext | supported | supported | supported |

## What "macOS 26 support" means here

- The kext range already includes macOS 26 (Darwin 25), with `25G241` VCN kernel data and committed
  satellite GL/Metal/VDA data.
- **VDA/VCN on macOS 26** is still experimental until a real 26.7.1 boot/decode/encode test passes.
  Other 26.x builds remain unsupported for user-space VDA because the data is exact-build and
  byte-gated.
- For another 26.x build, collect its `SystemKernelExtensions.kc`/`AMDRadeonVADriver2`/AppleGVA pages
  and platform metadata, derive a new `PatchData` directory from pinned source (see
  [`tools/README-userpatch-data.md`](../tools/README-userpatch-data.md)), run
  `tools/embed_patchdata.py --write`, rebuild/re-sign the satellite, then hardware-validate it.
  15.8.1 or 26.7.1 data must not be relabelled for another build.

## Evidence

- [Architecture](ARCHITECTURE.md) — current kernel + satellite planes, data flow and rollback.
- [Satellite UserPatch plan](Satellite-UserPatch-Plan.md) — main/satellite split, phase status and
  `NRedVCNBridgeReady` readiness contract.
- [UserPatch data format](UserPatch-Data-Format.md) — authoritative source-data contract and embedded
  generation model.
- [`PatchData/README.md`](../PatchData/README.md) — source data sets, regeneration/embed commands and
  known gaps.
- [Modules and support](MODULES-AND-SUPPORT.md) — current module architecture and full APU/build matrix.
- [Platform data index](Platform-Data-Index.md) — collected datasets, including the 26.7.1 GL/MTL data.
- [Archived 26.7.1 support note](archive/Tahoe-26.7.1-Support.md) — historical data derivation and the
  open runtime-validation task.
- `NootedRed/VCNData/24H32.hpp` / `23J631.hpp` / `25G241.hpp` — the three VCN kernel builds present.
