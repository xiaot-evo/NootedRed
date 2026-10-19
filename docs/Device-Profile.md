# Device Profile / Media Capability Layer

This layer is the first step toward a single source of truth for both the Chromium rendering fix and future
VCN/UVD/VDA hardware decoding. It deliberately does **not** change the current stable behaviour.

## Why

The rendering fix and hardware decoding are different layers:

- rendering: per-pipeline `CB_COLOR_CONTROL.DISABLE_DUAL_QUAD` policy for dual-source blending;
- media: VCN/UVD engines, firmware, rings, power and VideoToolbox/VDA capabilities.

Trying to solve rendering with a global hardware RB+ disable failed on Renoir (QQ Helper still reset the
GPU with user-space patches off), and a global switch would also affect video/compositing. A device
profile keeps the two concerns separate but shares the same APU/OS selection.

## Data model

`NootedRed/DeviceProfile.hpp`:

```cpp
struct GraphicsPolicy {
    bool conditionalDualQuad; // install the per-pipeline GL/Metal fix
    bool correctHwInfo;       // apply the existing CU/SE corrections
};

struct MediaPolicy {
    bool hasUVD0;              // engine enablement (still false in Phase 1)
    bool hasVCE;
    bool hasVCN0;
    VcnGeneration vcnGeneration; // kVcn1_0 (0x0100) or kVcn2_2 (0x0202)
    const char* vcnFirmware;     // embedded VCN blob: ativvaxy_rv.dat / ativvaxy_nv.dat
    uint32_t vcnRingSize;        // future VCN ring allocation, bytes
    uint32_t vcnFenceSize;       // future VCN fence allocation, bytes
    DecodeCaps decode;           // H.264/HEVC/AV1 capability flags
};

struct Profile {
    const char* name;
    uint16_t deviceID;
    ApuFamily family;
    KernelVersion minVersion, maxVersion;
    GraphicsPolicy graphics;
    MediaPolicy media;
};
```

The media data is populated for every family. The engine flags are enablement, not capability: only the
designated `0x1638` VDA target enables `hasVCN0` (and only after the `-NRedVDA` bridge has prepared both
drivers and allocated the engine); all other profiles keep the flags false until their own validation.

## Selection

`DeviceProfile::current()` selects by `NRed::getDeviceID()`:

| device ID | profile |
| --- | --- |
| 0x1636 | Renoir |
| 0x1638 | Renoir / Green Sardine |
| 0x164C | Cezanne |
| 0x15E7 | Barcelo |
| 0x15DD | Raven |
| 0x15D8 | Raven2 / Picasso |

An unknown/not-yet-populated device uses a fallback profile with the graphics policy enabled and all media
disabled.

## Media capability data

The media capability data is populated per family. The engine enablement flag is only set on the
designated VDA target (`0x1638`, hardware validation pending); everything else stays off until its own
validation.

| device ID | profile | VCN | firmware | H.264 | HEVC | AV1 | engines |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0x1636 | Renoir | 2.2 (`0x0202`) | `ativvaxy_nv.dat` | yes | yes | no | off (unvalidated) |
| 0x1638 | Renoir / Green Sardine | 2.2 (`0x0202`) | `ativvaxy_nv.dat` | yes | yes | no | VCN0 on (`-NRedVDA`) |
| 0x164C | Cezanne | 2.2 (`0x0202`) | `ativvaxy_nv.dat` | yes | yes | no | off (unvalidated) |
| 0x15E7 | Barcelo | 2.2 (`0x0202`) | `ativvaxy_nv.dat` | yes | yes | no | off (unvalidated) |
| 0x15DD | Raven | 1.0-class (`0x0100`) | `ativvaxy_rv.dat` | yes | yes | no | off |
| 0x15D8 | Raven2 / Picasso | 1.0-class (`0x0100`) | `ativvaxy_rv.dat` | yes | yes | no | off |

The VCN generation is the major/minor IP version; the values match the `ipVersion` argument that `HWLibs`
currently passes to the firmware loader (`0x0100`/`0x0202`). The generation-to-family mapping follows the
Linux AMD hardware component list (Renoir/Cezanne/Barcelo are VCN 2.2; Raven/Picasso are VCN 1.0 and
Raven2 is VCN 1.0.1, which share the `0x0100` VCN 1.0 family code in `MediaPolicy`).

## Integration points

- `UserPatches::processPatcher()` logs the profile and can disable the rendering fix through
  `graphics.conditionalDualQuad`. `UserPatches` also owns the native page-patch backend that applies the
  GL table when `-NRedGLFix` is set and the generated VA/AppleGVA tables when `-NRedVDA` is set.
- `X5000::wrapSetupAndInitializeHWCapabilities()` reads `hasUVD0/hasVCE/hasVCN0` from the profile. The
  effective values are also gated by `VDA::isRequested()` and `VCNBridge::loadReady()`, so the engine is
  only advertised when the user opted in, the 0x1638 profile enables it and both 15.8.1 drivers were
  prepared/loaded. If engine allocation fails, `X5000::allocateHWEngines()` clears the capability again.
- `VDA::init()` parses the opt-in `-NRedVDA` boot argument (default off), and
  `VDA::processPatcher()` logs the media policy. When `-NRedVDA` is set it also publishes
  `NRedVDARequested`, `NRedVDAMediaEnabled` and `NRedVCNGeneration` on the iGPU for diagnostics.
- `VCNBridge` (new module) force-loads the native `AMDRadeonX6000` VCN2 engine, verifies the generated
  per-build ABI guards, installs the generated call-site patches, allocates `AMDVCN2HWEngine` into
  X5000's engine array and bridges the video/shared/SML metaclasses. It is best-effort: any failure
  disables the bridge and leaves the normal graphics-only accelerator state.
- The rendering fix remains per-pipeline and does not need to know about decode.

## Adding a new APU

1. Add a `Profile` entry with the device ID and family.
2. Keep `conditionalDualQuad` only if the APU is in the validated family.
3. Fill its `MediaPolicy` capability data, but only flip `hasUVD0`/`hasVCE`/`hasVCN0` after the engine
   bring-up is implemented and tested on that APU.
4. Verify with the profile log and the existing rendering tests.

## Adding a new macOS version

The current profile table is device-wide; OS-specific patch data still lives in `UserPatches`/future
`PatchSet` entries. When the table becomes version-aware:

- add a profile entry with a Darwin version range;
- add the corresponding patch set/signature data;
- keep media and graphics feature flags independent.

## Hardware decoding (VDA)

The Phase 1 capability skeleton and the Phase 2/3 bridge implementation are in place:

- Phase 1: `MediaPolicy` carries the VCN generation, firmware name, ring/fence sizes and H.264/HEVC/AV1
  capabilities; the profiles are populated; `-NRedVDA` is the opt-in gate.
- Phase 2/3: `VCNBridge` force-loads the native X6000 VCN2 engine, verifies 15.8.1-generated vtable/getter
  ABI guards, applies the generated cross-driver call-site patches, allocates `AMDVCN2HWEngine` into the
  X5000 engine array and exposes `hasVCN0` only for the validated `0x1638` profile behind `-NRedVDA`.
- Phase 4: the generated 15.8.1 VA/AppleGVA page patches are applied through `UserPatches` when
  `-NRedVDA` is set.

Hardware validation (decode, 64x64 H.264, Hackintool, watchdog/GFXOFF) is still pending; see
[`VDA-Deployment.md`](VDA-Deployment.md). The Chromium fix remains independent.

## Current status

- `DeviceProfile` skeleton: implemented.
- Graphics policy: wired into `UserPatches`; current profiles keep it enabled.
- Media policy: capability data populated; only `0x1638` enables VCN0 after the bridge prepared both
  drivers. All other profiles stay disabled until hardware validation.
- `-NRedVDA`: parsed and logged, default off; with the opt-in it drives `VCNBridge` and the generated
  VA/AppleGVA user-space patches.
- Build: passes (release, debug, releasedbg; CommandLineTools toolchain while the default Xcode select is
  broken on the test machine).
- Runtime/reboot validation: **hardware decode passed** on macOS 15.8.1 / Renoir `0x1638`: ABI guards,
  native X6000 load, engine allocation, VCN initHardware and VA/AppleGVA user-space patches all succeeded;
  H.264 and HEVC decode matched software output. See
  [`analysis/vda-1581-hardware-validation.md`](../analysis/vda-1581-hardware-validation.md).
- Follow-ups: default-off boot on this build, Chromium/real-app playback, DRM/10-bit, other APUs.
