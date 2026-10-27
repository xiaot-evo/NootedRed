# NootedRed current modules and support matrix

Status date: 2026-10-23. This document describes the tree as it actually builds and boots after the
satellite split and the embedded-PatchData change.

## 1. Module architecture

```
Lilu
 ├── NootedRed.kext
 │     kernel-side AMD iGPU enablement only
 │     - X5000/X6000/HWLibs/AGDP/Backlight/AppleGFXHDA kernel patches
 │     - framebuffer, DC, power management, SMU/PSP
 │     - VCN kernel bridge/firmware
 │     - publishes NRedVCNBridgeReady on the AMD iGPU IOPCIDevice
 │     - no user-space GL/Metal/VDA page tables or _cs_validate_* hooks
 │
 └── NootedRedUserPatch.kext
       satellite Lilu plugin, auto-loaded only when NootedRed is present
       - exact 4 KiB page backend for _cs_validate_page/_cs_validate_range
       - embedded PatchData arrays (no runtime VFS)
       - exact build + APU-mask selection
       - VDA/AppleGVA gated on NRedVCNBridgeReady
       - no semantic scanner, no deferred page pointers
```

### Data flow

```
PatchData/<build>/manifest.bin + pages.bin        (build-time source, checked in)
        │ tools/embed_patchdata.py
        ▼
NootedRedUserPatch/PatchDataBlob.cpp/.hpp           (generated static const arrays)
        │ linked into kext
        ▼
NootedRedUserPatch.kext
        │ load embedded set -> exact 4 KiB page match
        ▼
_cs_validate_page/_cs_validate_range
        │ complete 4 KiB compare -> verify site find -> write replace
        ▼
user-space GL/Metal/VDA pages patched
```

`PatchData/` is no longer copied to `/Library/Application Support`. It is build-time input only.

## 2. Boot flow

1. OpenCore loads Lilu, then `NootedRed.kext` and `NootedRedUserPatch.kext`. The satellite's
   `OSBundleLibraries` declares `org.ChefKiss.NootedRed`, so it only loads when the main kext exists.
2. Satellite `pluginStart` registers `onPatcherLoadForce`; it does no filesystem work.
3. At Lilu patcher load, the satellite installs `_cs_validate_page`/`_cs_validate_range`
   unconditionally, then loads the embedded data set for exact `kern.osversion`.
4. No match/validation failure = `NoOp`; no page is written.
5. Main kext brings up the VCN bridge; after `VCNBridge::loadReady()` it publishes
   `NRedVCNBridgeReady=1` on the iGPU as a status/diagnostic signal. `acceleratorStop`/failure
   publishes `0`; the next successful start republishes `1`.
6. VDA/AppleGVA pages are applied only when the user passed `-NRedVDA`; the satellite no longer reads
   the readiness property for page gating. GL/Metal pages do not depend on the flag.
7. The hooks compare complete pages; on exact match they verify `find` at the recorded offset and write
   `replace` under the kernel write lock. A mismatched page is left untouched.

## 3. Module responsibilities

| Module | Responsibility | Must not do |
| --- | --- | --- |
| `NootedRed.kext` | kernel patching, FB/DC/PM/SMU, VCN bridge, readiness publication | user-space page patching, VFS reads at boot |
| `NootedRedUserPatch.kext` | user-space exact-page GL/Metal/VDA patches, embedded data | kernel kext patching, runtime VFS/plist reads, semantic scans |
| `PatchData/` + `tools/embed_patchdata.py` | source data and deterministic embedding | runtime loading |
| `tools/convert_master_patchdata.py` | derive PatchData from pinned master exact tables | hand-editing page bytes |
| `VCNData/` | exact 24H32 kernel VCN call-site/guard data | user-space page data |

## 4. macOS support

`NootedRed.kext` declares Catalina through Tahoe. Actual kernel data is build-specific; the tables
below describe what is present, not a promise that every combination is hardware validated.

| macOS | Darwin | Main kernel/VCN | Satellite embedded data |
| --- | --- | --- | --- |
| 15.8.1 (`24H32`) | 24.6 | VCN 2.x bridge, validated target | GL + Metal + VDA/VA + AppleGVA |
| other builds | other | kernel patches only; no VCN data | no embedded data (fail-closed no-op) |

The satellite has **no semantic or nearest-build fallback**. A build without an embedded directory is
a terminal `BuildUnsupported` NoOp.

## 5. APU support

### Device profiles in the main kext

| Device ID | Family | Graphics kernel path | VCN generation | Kernel media |
| --- | --- | --- | --- | --- |
| `0x1636` | Renoir | supported (experimental) | VCN 2.2 | enabled |
| `0x1638` | Renoir / Green Sardine | supported (experimental) | VCN 2.2 | enabled (hardware-validated target) |
| `0x164C` | Cezanne | supported (experimental) | VCN 2.2 | enabled |
| `0x15E7` | Barcelo | supported (experimental) | VCN 2.2 | enabled |
| `0x15DD` | Raven | supported (experimental) | VCN 1.0 | disabled (no VCN1 path) |
| `0x15D8` | Raven2 / Picasso | supported (experimental) | VCN 1.0 | disabled (no VCN1 path) |

### Satellite data coverage

| APU | Data APU mask bits | 24H32 GL/Metal | 24H32 VDA |
| --- | --- | --- | --- |
| Raven `0x15DD` | bit 0 | data selectable, not hardware-validated | gated off (main media disabled) |
| Raven2/Picasso `0x15D8` | bits 1/2 | data selectable, not hardware-validated | gated off (main media disabled) |
| Renoir `0x1636` / Cezanne `0x164C` | bits 3/4 | data selectable; not hardware-validated | ready-gated; not hardware-validated |
| Green Sardine `0x1638` | bits 3/5 | applied on current machine (24H32) | ready-gated; VCN ready observed |
| Barcelo `0x15E7` | bits 3/5 | data selectable; not hardware-validated | ready-gated; not hardware-validated |

Important distinctions:

- "data selectable" means the exact embedded build contains a table whose mask intersects the APU;
  it does not mean the feature was tested on that APU.
- `0x15DD`/`0x15D8` have no VCN 2.x media path; the satellite may select GL/Metal data but VDA pages
  remain unapplied because `NRedVCNBridgeReady` is never published.
- Current hardware validation is `0x1638` / macOS 15.8.1. The satellite loads and applies the embedded
  24H32 page set; feature-level Chrome/Zen/QQ/VDA tests remain a separate checklist.

## 6. Feature status summary

| Feature | Main kext | Satellite | Status |
| --- | --- | --- | --- |
| AMD iGPU framebuffer/DC/PM/SMU | yes | no | experimental |
| VCN 2.2 kernel bridge | yes | no | experimental; 0x1638 validated target |
| GL dual-quad / HwInfo exact pages | no | yes (24H32) | runtime loaded/applied on 0x1638/24H32; feature tests pending |
| Metal gate/allow/HwInfo exact pages | no | yes (24H32) | 0x1638/24H32: gate/allow + supplementary HwInfo A1 applied; wallpaper/sips compute no longer resets |
| VDA/VA + AppleGVA user pages | no | yes (24H32) | data present; VDA decode needs hardware checklist |
| VCN 1.x media | no path | no | unsupported |
| X5000 compute-submit GFXOFF hook | yes | no | vtable fix hardware-observed on 0x1638/24H32; GFXOFF reset alone is not sufficient for the wallpaper compute reset |

`24H32` now carries 13 pages / 18 sites: the master GL/Metal/VDA pages plus the supplementary Metal
HwInfo A1 page (`numShaderEngines 4 -> 1`, pinned in `tools/sources/24H32/metal-hwinfo-page.bin`).
On 15.8.1 / `0x1638` the satellite applied all five expected pages (aggregate
`NRedUserPatchAppliedPages=5`); two controlled `sips` HEIC conversions completed without new GPU
restarts.

The X5000 compute-submit hook resets the GFXOFF idle timer before PM4 compute submissions so idle
power gating cannot stall a compute queue. The upstream implementation applied the version-specific
`ObjectField` offset to the `__ZTV` symbol instead of the vtable address point, which targeted the
wrong virtual-function slot; the restored implementation adds the two Itanium C++ ABI header slots,
verifies the slot still equals the resolved `AMDPM4HWChannel::submitCommandBuffer`, and skips
installation instead of corrupting the vtable when the layout does not match.

## 7. Boot arguments and rollback

| Argument | Effect |
| --- | --- |
| `-NRedVDA` | enable the kernel VCN bridge; required for satellite VDA data to become applicable |
| `-NRedUserPatchOff` | disable the satellite plugin |

Rollback:

- remove `NootedRedUserPatch.kext` from OpenCore and reboot: main kext remains functional;
- the main kext has no user-space hooks and builds/runs with the satellite absent;
- `PatchData/` is only build input; there is no runtime directory to remove.
