# Patch architecture: GLFIX and VDA/VCN

This document describes the two NootedRed features that patch Apple's user-space and kernel drivers:

1. **GLFIX** — the Chromium/Electron OpenGL/Metal dual-source fix.
2. **VDA/VCN** — hardware video decode/encode on VCN 2.x APUs by bridging Apple's X6000 VCN2 engine
   into the X5000 accelerator.

It covers the runtime flow, the exact system-level modifications, and the safety gates around them.
The data tables and their evidence are documented separately in
[`analysis/gl-hwinfo.md`](../analysis/gl-hwinfo.md),
[`analysis/gl-semantic-patches.md`](../analysis/gl-semantic-patches.md),
[`analysis/vda-1581-va-data.md`](../analysis/vda-1581-va-data.md),
[`analysis/vda-1581-gva-data.md`](../analysis/vda-1581-gva-data.md) and
[`analysis/vcn-1581-kernel-data.md`](../analysis/vcn-1581-kernel-data.md).

## 1. Why these patches exist

### 1.1 GLFIX

Apple's `AMDRadeonX5000GLDriver` hard-codes dGPU Vega presets in `_gfx9_HwInfoInitData`. On a Renoir
iGPU the driver takes the Vega10 dGPU branch and writes `numShaderEngines = 4`; the driver then derives
the CU count from

```
rec+0x64 = rec+0x60 * rec+0x78 * rec+0x80
```

which yields 32 CUs instead of the iGPU's 8. The same wrong model feeds the dual-quad / RB+ decisions in
`_glrAMD_GFX9_UpdateHwCbDualQuadMode` and the Metal pipeline path. Chromium (and other
dual-source users) consequently hits GPU resets / corrupted blending.

The fix is two site families:

- **GL driver**: correct the HwInfo record and the dual-quad update instruction.
- **Metal driver** (in the dyld shared cache): patch the allowRBPlus gate/setcc pair (or, on 26.x, the
  direct-field boolean write).

### 1.2 VDA/VCN

Apple's `AMDRadeonX5000` accelerator has no VCN engine for APUs in its advertised media capability;
`AMDRadeonX6000` contains the VCN2 engine implementation used by Navi dGPUs. Renoir/Cezanne/Barcelo
have VCN 2.2 hardware which is close enough that the X6000 VCN2 engine code can drive it.

NootedRed therefore keeps the X5000 accelerator as the display/3D driver, force-loads the X6000 kext as
a symbol/engine donor, and makes the X5000 PM4 engine array expose an X6000 `AMDVCN2HWEngine` as VCN0.
VideoToolbox then talks to the stock `AMDRadeonVADriver2` / `AppleGVA` stack, which is patched to treat
the iGPU as a VA family-5 (Navi10-class) device.

## 2. GLFIX architecture

### 2.1 Layers

```
Plugin.cpp (Lilu plugin)
  └─ NRed::init()
       ├─ register VDA generated tables (VDAVAData/VDAGVAData)
       ├─ UserPatches::init()          parse boot args, select tables
       ├─ VDA::init() / VCNBridge::init()
       └─ onPatcherLoad → NRed::processPatcher()
            └─ UserPatches::processPatcher(patcher)
                 ├─ selectPatchSet()   Darwin version + APU mask
                 └─ installNativePagePatcher()
                      routes _cs_validate_page / _cs_validate_range

User process page-in
  └─ kernel code-signing validation
       └─ NootedRed hook (after validation succeeded)
            ├─ exact 4 KiB page table        (L0, validated fast path)
            ├─ semantic instruction context  (L1 fallback, no page snapshot)
            └─ masked signature resolver     (opt-in QA fallback)
                 └─ memcpy replacement into the page cache
```

### 2.2 Data model

`NootedRed/UserPatches.hpp`:

| Type | Purpose |
| --- | --- |
| `PatchSet` | One version range + APU mask; points to page patches, optional resolver signatures |
| `PagePatch` | Exact 4 KiB page image + `find`/`replace` + `skip`/`count` |
| `SignaturePatch` | Masked context (32 B), relative patch offset, replacement; optional page offset |
| `SemanticPatch` | Instruction-context window, mask, site offset, `find`/`replace`, kind, group; used by the semantic backend |

Data files:

- `NootedRed/UserPatches.cpp` — 15.8.1 exact page arrays + `PatchSet` table;
- `NootedRed/TahoePatchData.hpp` — 26.7.1 exact page arrays;
- `NootedRed/GLFixSemanticData.hpp` — instruction contexts for GL A1/A2 and the Metal variant groups.

Selection is:

```cpp
for (set in patchSets)
    if (version in [minVersion, maxVersion] && (set.apus & currentApuMask()))
        use set;
```

`currentApuMask()` comes from `NRed`'s `Attributes` (Raven/Raven2/Picasso/Renoir/RenoirE/GreenSardine).
No match means the exact-page path installs nothing; the semantic fallback may still match the
instruction context.

### 2.3 Exact-page backend (L0)

`UserPatches::buildNativePatches()` converts the selected `PagePatch` table into `NativePage` records:
the complete page image, a cheap first-word head, and the per-site `find`/`replace` entries. Installation
routes two kernel functions:

| Kernel function | Why |
| --- | --- |
| `_cs_validate_page` | File-backed images, e.g. `AMDRadeonX5000GLDriver` bundle |
| `_cs_validate_range` | Dyld shared cache ranges, e.g. `AMDRadeonX5000MTLDriver` |

For every page that passed validation, `patchNativePage()`:

1. compares the page head, then the complete 4 KiB image;
2. optionally checks the page's VDA flag and that `VCNBridge::loadReady()` is true;
3. verifies every `find` site still exists;
4. disables kernel write protection (`MachInfo::setKernelWriting`), writes the replacements, restores it;
5. records diagnostics (`NRedVCNUserApplied`, IORegistry properties).

The write goes to the **file-backed page cache**, not to disk. It affects every process that maps that
page until reboot. `isPatchedPage()` prevents double-patching when the same page is validated again.

### 2.4 Semantic backend (L1)

`UserPatches::patchSemanticPage()` handles builds without an exact page table (or whose page image
changed). It works on the same validation buffer:

1. match a masked instruction-context window (`context`/`mask`, 40–64 B);
2. require exactly one match on the page (ambiguity → no-op);
3. verify the `find` bytes at `siteOffset`;
4. verify the instruction form for the semantic kind (store imm32, `and`/`or` pair, etc.);
5. write the same-length replacement under the same write-protection window.

GL entries are only applied to a **file-backed vnode whose name contains
`AMDRadeonX5000GLDriver`**. The name lookup (`vnode_getname`/`vnode_putname`) happens only after a
context candidate was found, so it is not on the hot path for every validated page. A candidate that is
not the GL driver is dropped.

Metal entries are applied to shared-cache pages and are organised as variant groups (Sonoma gate/allow,
Sequoia gate/allow, Tahoe gate/allow, Tahoe direct-field). A group only applies when **all** of its sites
match the same page, and only one group applies per page. Metal scanning is forced with
`-NRedGLFixSemanticMTL`, and automatically enabled when no exact patch set matches the build; it can be
disabled with `-NRedGLFixSemanticOff`.

### 2.5 Resolver fallback (opt-in)

`-NRedGLFixResolve` enables `SignaturePatch` entries: a pre-build masked context with a relative offset
and replacement. `-NRedGLFixResolveOnly` bypasses the exact page path for QA. The resolver is
independent of the semantic backend and is not enabled by default.

### 2.6 Patch semantics

On the validated 15.8.1 driver:

| Site | Instruction | Meaning |
| --- | --- | --- |
| A1 | `C7 47 78 04 00 00 00` → `... 01 ...` | `GFX9_HwInfoRec+0x78` shader engines 4 → 1 |
| A2 | `83 E0 FE` (skip 1 in page 0x8000) → `83 C8 01` | `and eax,~1` → `or eax,1`, forcing the dual-quad-disable bit |
| MTL gate | `75 0B` → `EB 0B` | take the allowRBPlus path unconditionally |
| MTL allow | `0F 94 C0` → `31 C0 90` | clear the RB+ result register |

26.7.1 uses different page layouts and, for Metal, the direct-field form
`83 E2 FE 09 CA 41 89 94 24 E4 00 00 00` → `83 CA 01 ...` (Tahoe direct variant).

### 2.7 GLFIX system-level modifications

| Level | Modification |
| --- | --- |
| Kernel text | Routes `_cs_validate_page` and `_cs_validate_range` (KernelPatcher long route); saves and calls the originals |
| Kernel memory | Writes replacement bytes into the validated page buffer with kernel write protection temporarily disabled |
| Kernel KPI | `vnode_getname`/`vnode_putname` for the semantic GL-driver identity check |
| User-space memory | Patches the GL bundle's file-backed pages and MTL shared-cache pages in the page cache |
| IORegistry | `NRedGLFixSemantic`, `NRedGLFixSemanticMetal` when the semantic backend applies; `NRedCompat*` diagnostics |
| Boot args | `-NRedGLFix`, `-NRedGLFixOff`, `-NRedGLFixResolve`, `-NRedGLFixResolveOnly`, `-NRedGLFixSemanticMTL`, `-NRedGLFixSemanticOff` |
| Disk / SIP | No disk writes, no SIP changes, no additional kext injection for GLFIX |

Failure behaviour: a mismatched page/context is a no-op. A rejected code-signing page is never patched.
The patch is only written after the original validation succeeds.

## 3. VDA/VCN architecture

### 3.1 Components

```
DeviceProfile (media policy)
  └─ vcnGeneration, firmware, ring/fence sizes, decode caps, hasVCN0

VDA module
  └─ -NRedVDA parsing, profile logging, feature gating

VCNBridge
  ├─ version/device gates
  ├─ X5000 entry-point routing
  ├─ X6000 force load + ABI verification + call-site patches
  ├─ AMDVCN2HWEngine allocation into X5000's VCN0 slot
  └─ X5000/X6000 metaclass + video/shared/SML bridging

Generated data
  ├─ VCNKernelData.hpp    (15.8.1 + 14.8.9 call-site tables + getCallPatches selector)
  ├─ VDAVAData.hpp        (15.8.1 AMDRadeonVADriver2 pages)
  ├─ VDAVADataSonoma.hpp  (14.8.9 AMDRadeonVADriver2 pages)
  ├─ VDAGVAData.hpp       (15.8.1 AppleGVA page)
  └─ VDAGVADataSonoma.hpp (14.8.9 AppleGVA page)
```

### 3.2 Kernel flow

1. **`-NRedVDA` / `-NRedAVC` parsing**
   - `VDA::init()` records the request and the AVC-only mode; `VCNBridge::init()` rejects non-23.6/24.6
     builds, registers the X6000 kext-load hook, and waits for device/driver load. `-NRedAVC` strips the
     HEVC capabilities from the injected X5000 personality so VideoToolbox keeps HEVC on software.
2. **X5000 load (`VCNBridge::processKext`)**
   - verifies the generated X5000 ABI guards (vtable slots, getter bytes);
   - resolves and routes:
     - `AMDGraphicsAccelerator::start/stop`
     - `newShared` / `newSharedUserClient`
     - `AMDGFX9GraphicsAccelerator::newVideoContext`
     - `IAMDSMLInterface::createSMLInterface`
     - `AMDAccelSharedUserClient::start/stop`, `AMDAccelShared::SurfaceCopy`
     - `AMDFX9Hardware::notifyGfxAccess`
   - routes the kernel-wide `OSMetaClassBase::safeMetaCast` for metaclass bridging.
3. **X5000 accelerator start**
   - `VCNBridge::acceleratorStart` checks the PCI provider matches NRed's iGPU and the device/profile is
     a VCN 2.x APU;
   - force-loads `com.apple.kext.AMDRadeonX6000` with `OSKextLoadKextWithIdentifier`;
   - `X5000::allocateHWEngines` hook allocates an `AMDVCN2HWEngine` and places it in the PM4 engine array
     at `kAMDHWEngineTypeVCN0`;
   - `wrapSetupAndInitializeHWCapabilities` exposes `hasUVD0`/`hasVCE`/`hasVCN0` only when
     `VDA::isRequested()` and `VCNBridge::engineEnabled()`.
4. **X6000 load**
   - verifies the X6000 ABI guards/getters;
   - resolves VCN2 engine, shared/client metaclasses, `newVideoContext`, `createSMLInterface`;
   - verifies and applies **20 X6000 call-site patches** (all-or-nothing): vtable-slot calls are redirected
     to the X5000 slots; GFXOFF pairing calls are redirected to
     `AMDRadeonX6000_AMDHardware::signalGPUWorkSubmitted`;
   - on success marks the bridge ready; any mismatch reverts and disables the feature.
5. **Bridged entry points**
   - `newVideo` → X6000 video context;
   - `createSML` → X6000 SML;
   - `newShared`/`newClient` → X6000 metaclasses;
   - `clientStart/Stop`, `surfaceCopy`, `signalWork`, `initHardware` use the appropriately bridged/original
     implementations;
   - `safeMetaCast` tries the X5000 class, then the X6000 equivalent, so cross-driver object casts work.

### 3.3 User-space VDA flow

Once the kernel bridge is ready, `UserPatches` applies the generated VDA page tables through the same
code-signing hooks:

- `VDAVAData.hpp` / `VDAVADataSonoma.hpp` (8 page images, 9 records, 12 sites each):
  - target `AMDRadeonVADriver2` for the selected build;
  - forces the stock VA driver to identify the GFX9/VCN 2.x iGPU as **VA family 5** (Navi10/VCN2 class),
    while keeping GFX9 engines, GFX9 video processors and the Gfx9 address library.
- `VDAGVAData.hpp` / `VDAGVADataSonoma.hpp`:
  - target `AppleGVA`'s decoder-selection function `AVDGetGPUAccelerators` for the selected build;
  - when no Intel accelerator exists, inserts the AMD accelerator collected from the -0x130 array instead
    of returning an empty list; without this VideoToolbox disables hardware decode.
- These pages are only patched when:
  - `-NRedVDA` or `-NRedAVC` is set;
  - the profile has `hasVCN0` and VCN 2.2;
  - no external GPU is present;
  - `VCNBridge::loadReady()` is true (checked in the page hook).

After that, VideoToolbox → `VTDecoderXPCService` → `AMDRadeonVADriver2` → X5000 accelerator → X6000
VCN2 engine.

### 3.4 Generated data and provenance

| File | Generator / source |
| --- | --- |
| `VCNKernelData.hpp` | `tools/gen_vcn_kernel_data.py` for 15.8.1; 14.8.9 call sites imported from `weachy/NootedRed` |
| `VDAVAData.hpp` | `tools/gen_vda_va_data.py`, `AMDRadeonVADriver2`, 15.8.1 |
| `VDAVADataSonoma.hpp` | same generator, 14.8.9; imported from `weachy/NootedRed` |
| `VDAGVAData.hpp` | `tools/gen_vda_gva_data.py`, `AppleGVA`, 15.8.1 |
| `VDAGVADataSonoma.hpp` | same generator, 14.8.9; imported from `weachy/NootedRed` |

The build selector lives in `NRed::init()` (Darwin major 23 vs 24), `VCNKernelData::getCallPatches()`
(Sonoma vs Sequoia call sites) and `VCNBridge::isSupportedBuild()` (23J/24H build families). Every
`original` call-site byte and vtable guard is verified before patching, so a materially different build is
rejected instead of patched; 26.x has no data and is rejected.

Every header carries source UUIDs, segment/text hashes and version strings. The generators support
`--check` to re-read the live system and fail loudly on any mismatch. `VCNBridge` additionally verifies
the vtable guards and getter bytes at runtime before patching.

### 3.5 VDA/VCN system-level modifications

| Level | Modification |
| --- | --- |
| Kernel text (X5000) | Routes accelerator start/stop, shared/client creation, video context, SML interface, surface copy, GFX access notification |
| Kernel text (X6000) | Verifies and rewrites 20 generated call sites in the VCN2 engine/channel/video-context functions |
| Kernel text (kernel) | Routes `OSMetaClassBase::safeMetaCast` for X5000↔X6000 metaclass bridging |
| Kext loading | `OSKextLoadKextWithIdentifier("com.apple.kext.AMDRadeonX6000")` from X5000 accelerator start only |
| X5000 object fields | `hasVCN0`/`hasUVD0`/`hasVCE` capability bits, PM4 engine array `[kAMDHWEngineTypeVCN0]`, display count, paging queue/get-all-clock-limits flags |
| Kernel objects | Allocates `AMDRadeonX6000_AMDVCN2HWEngine`, `AMDAccelShared`, `AMDAccelSharedUserClient` instances and places/serves them through the X5000 accelerator |
| Firmware | Uses the existing HWLibs firmware path and packaged `ativvaxy_nv.dat` / `ativvaxy_rv.dat`; no extra firmware loading from the bridge |
| User-space memory | Patches `AMDRadeonVADriver2` and `AppleGVA` shared-cache pages after validation |
| IORegistry | `NRedVDARequested`, `NRedVDAAVCOnly`, `NRedVCNDataVariant`, `NRedVDAMediaEnabled`, `NRedVCNStage`, `NRedVCNX5000Seen`, `NRedVCNX5000ABIValidated`, `NRedVCNX6000Seen`, `NRedVCNX6000ABIValidated`, `NRedVCNEngineAllocated`, `NRedVCNNativeLoadStatus`, `NRedVCNNativeLoadReady`, `NRedVCNUserApplied`, `NRedVCNGeneration` |
| Boot args | `-NRedVDA` (full AVC+HEVC) or `-NRedAVC` (AVC only, HEVC software); default off |
| Disk / SIP | No disk writes, no SIP changes, no permanent kext installation; X6000 is force-loaded at runtime |

Failure behaviour: every gate (build identity, ABI, device profile, external GPU, engine allocation,
accelerator start) is fail-closed. On failure the bridge clears `NRedVCNEngineAllocated`/
`NRedVDAMediaEnabled`, the user-space VDA tables are not applied, and VideoToolbox falls back to
software decode. The graphics path is unaffected.

## 4. Boot-time ordering

```
Lilu loads NootedRed
  Plugin.cpp: request start, declare support range
  NRed::init: register VDA tables, UserPatches::init, VDA::init, VCNBridge::init,
              register X6000/HWLibs/X5000/AGDP/AppleGFXHDA load hooks,
              register patcher-load callback

patcher-load callback (after device detection)
  NRed::processPatcher:
      identify iGPU, rename to IGPU, set built-in/hda-gfx, build Attributes/DeviceProfile
      VDA::processPatcher (publish request/profile)
      UserPatches::processPatcher
          select GL PatchSet (version + APU)
          build native page list (GL exact + semantic + VDA if allowed)
          route _cs_validate_page/_cs_validate_range
      DriverInjector / RuntimeMCManager

later kext loads
  X5000 load  → VCNBridge routes X5000 entry points
  X6000 load  → VCNBridge verifies ABI and patches 20 call sites
  X5000 accelerator start → force-load X6000, allocate VCN0 engine, advertise media caps

user process page-in
  code-signing validation → UserPatches hook → page cache patched → patched code executes
```

## 5. Safety and observability

- **No filesystem writes.** Both features only write to the in-memory page cache or to kernel text under a
  temporary write-protection window. A reboot removes everything.
- **No early-boot VFS I/O.** The patcher-load phase only selects tables and routes functions; it does not
  read driver files. (An earlier identity-capture implementation that did VFS I/O here stalled boot and
  was removed.)
- **Fail-closed gates.** GLFIX: exact page / semantic context / resolver signature must match precisely;
  otherwise no write. VDA: exact kernel build, ABI guards, getter bytes, device profile, external-GPU
  check, engine allocation and accelerator start must all succeed.
- **No panic on feature failure.** User-space patch failures are logged and skipped; VDA failures clear
  the capability and leave software decode in place.
- **Diagnostics.** DeviceProfile publishes `NRedCompat*`; VDA/VCN stage markers show exactly where the
  bridge stopped; the semantic backend publishes `NRedGLFixSemantic*`; boot args control opt-in.
- **Version/identity gates.** VDA is hard-gated to 15.8.1 / 24H32 today; GLFIX exact tables are keyed by
  Darwin major.minor and APU mask, with semantic fallback for other builds whose instruction contexts
  still match.

## 6. Code map

| Path | Role |
| --- | --- |
| `NootedRed/Plugin.cpp` | Lilu entry point, supported OS range, boot args |
| `NootedRed/NRed.cpp/.hpp` | iGPU detection, attributes, module wiring, patcher-load callback |
| `NootedRed/UserPatches.cpp/.hpp` | GL/MTL/VDA user-space patch engine (exact, semantic, resolver) |
| `NootedRed/GLFixSemanticData.hpp` | Instruction-context data for the cross-build GL/Metal fallback |
| `NootedRed/TahoePatchData.hpp` | 26.7.1 exact page data |
| `NootedRed/VDA.cpp/.hpp` | `-NRedVDA` request/profile publication |
| `NootedRed/VCNBridge.cpp/.hpp` | X5000/X6000 bridging, engine allocation, call-site patches |
| `NootedRed/VCNKernelData.hpp` | Generated kernel ABI/guard/call-site data |
| `NootedRed/VDAVAData.hpp` | Generated AMDRadeonVADriver2 page patches |
| `NootedRed/VDAGVAData.hpp` | Generated AppleGVA page patches |
| `NootedRed/X5000.cpp/.hpp` | Accelerator HW capabilities, engine allocation, media capability fields |
| `NootedRed/DeviceProfile.cpp/.hpp` | Family/capability/media policy data |
| `tools/gen_*_data.py` | Deterministic data generators with `--check` |
| `tools/test_patch_data.py`, `tools/test_gl_semantic_data.py` | Offline data validation |

## 7. Current verification state

As of the 15.8.1 / Renoir `0x1638` boot with `-NRedGLFix -NRedGLFixSemanticMTL -NRedVDA`:

- exact GLFIX page patches were observed in the page cache: A1 `C7 47 78 01...`, Metal gate `EB 0B`,
  Metal allow `31 C0 90`; the VDA/VCN multi-build tables pass `tools/test_vcn_multibuild.py`;
- the GL dual-quad page (0x8000) is patched lazily when its page is first executed/validated;
- VDA markers show the bridge prepared and engine allocated (`NRedVDAMediaEnabled=1`,
  `NRedVCNEngineAllocated=1`, `NRedVCNNativeLoadReady=1`); a full decode run is done with
  `tools/vda_hwtest.sh` after boot.
