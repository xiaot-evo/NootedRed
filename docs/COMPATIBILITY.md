# NootedRed compatibility matrix

Status date: 2026-10-25. This table describes what the current tree actually enables, not what the
hardware could theoretically do. A feature is only `validated` when it has passed a real boot and the
corresponding feature test on that exact build **and** APU.

> **Satellite split:** user-space GL/Metal/VDA patching lives in the separate
> `NootedRedUserPatch.kext` satellite. Its exact-page data is **embedded at build time** from the
> repo-root `PatchData/` sources via `tools/embed_patchdata.py`; the kext performs no runtime file I/O.
> The main `NootedRed.kext` only performs kernel-side enablement and publishes the
> `NRedVCNBridgeReady` iGPU property; it builds and runs with the satellite absent. See the
> [Satellite UserPatch plan](Satellite-UserPatch-Plan.md),
> [UserPatch data format](UserPatch-Data-Format.md) and [`PatchData/README.md`](../PatchData/README.md).
>
> **Only the complete 15.8.1 / `24H32` set is deployed.** Incomplete or unvalidated build sets
> (`23J631`, `25G241`) and the family-prefix VCN fallbacks were removed. A build without an exact
> committed data set is a fail-closed no-op; there is no nearest-build fallback.
>
> `-NRedVDA` is the only VDA/VCN opt-in. It must be present for the satellite's VDA/AppleGVA data to
> be usable: without the bridge, `NRedVCNBridgeReady` is never published and the satellite leaves
> kinds 3/4 unapplied. GL/Metal satellite data is independent of that flag.

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
| other 15.x (`24H*`) | 24.x | supported | **unsupported** (no exact `24H32` data) | **unsupported** (no VCN data) | **unsupported** | **unsupported** |
| other macOS builds | 18–25 | supported (kernel patches only) | **unsupported** | **unsupported** | **unsupported** | **unsupported** |

Notes:

- "Kernel / graphics" means the NootedRed kext itself loads and the existing X5000/HWLibs/display
  patches run. It does not imply GL/Metal or VDA user-space patching.
- GL/Metal and VDA user-space patches are applied by the satellite only when the exact 4 KiB driver
  page matches the committed `pages.bin`; any build/APU/page mismatch is a fail-closed no-op. There is
  no semantic scanner and no nearest-build fallback.
- VDA/AppleGVA tables (kinds 3/4) are gated on the exact page/build/APU data. With `-NRedVDA` they are
  early-eligible because AppleGVA/VADriver pages are validated before the bridge readiness property is
  observable; on a non-`-NRedVDA` boot they remain gated on `NRedVCNBridgeReady`.
- `NootedRed/VCNData/` contains only the exact `24H32` kernel call-site/guard table. Every guard and
  original call-site byte is verified against the live X5000/X6000 drivers before any write.

## APU matrix

| APU / device ID | VCN generation | GL/Metal (15.8.1) | VDA/VA + AppleGVA (15.8.1) |
| --- | --- | --- | --- |
| Renoir / Green Sardine `0x1638` | VCN 2.2 | **validated** | **validated** |
| Renoir `0x1636` | VCN 2.2 | experimental (same pages) | experimental (same data) |
| Cezanne `0x164C` | VCN 2.2 | experimental | experimental |
| Barcelo `0x15E7` | VCN 2.2 | experimental | experimental |
| Raven `0x15DD` | VCN 1.x | experimental | **unsupported** (no VCN 2.2 bridge readiness) |
| Raven2 / Picasso `0x15D8` | VCN 1.x | experimental | **unsupported** (no VCN 2.2 bridge readiness) |

The GL/Metal page data is shared across gfx9 APUs, but only `0x1638` on 15.8.1 has a recorded hardware
validation. VDA readiness is never published for VCN 1.x profiles, so VDA tables stay no-op there.

## Feature/control matrix

| Feature | Control | 15.8.1 |
| --- | --- | --- |
| GL dual-source fix | satellite, `PatchData` kind 1 | validated |
| Metal dual-quad fix | satellite, `PatchData` kind 2 | validated |
| Metal HwInfo A1 (`numShaderEngines 4 -> 1`) | satellite, supplementary `PatchData` kind 2 page | validated (`0x1638`; sips/wallpaper compute) |
| VDA/AppleGVA user-space | satellite, kinds 3/4; `-NRedVDA` makes pages early-eligible | validated |
| VCN2 hardware decode / encode | main kext VCN bridge + satellite VDA | validated |
| Disable user-space patches | `-NRedUserPatchOff` debug boot arg | available |
| Main kext without satellite | remove satellite kext | supported |

## Adding another build

There is no generic fallback. To add a build:

1. collect its `SystemKernelExtensions.kc` and the matching VADriver/AppleGVA images;
2. generate `NootedRed/VCNData/<build>.hpp` with `tools/gen_vcn_kernel_data.py` and register the
   variant in `VCNData.cpp`;
3. derive a complete `PatchData/<build>` set from pinned exact pages, regenerate
   `PatchDataBlob.*`, and rebuild/re-sign the satellite;
4. hardware-validate decode/encode and the GL/Metal paths before marking it supported.

## Evidence

- [Architecture](ARCHITECTURE.md) — current kernel + satellite planes, data flow and rollback.
- [Satellite UserPatch plan](Satellite-UserPatch-Plan.md) — main/satellite split and readiness contract.
- [UserPatch data format](UserPatch-Data-Format.md) — authoritative source-data contract.
- [`PatchData/README.md`](../PatchData/README.md) — source data set, regeneration and embedding.
- [Modules and support](MODULES-AND-SUPPORT.md) — module architecture and APU/build support.
