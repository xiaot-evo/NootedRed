# Device Profile / Media Capability Layer

This layer is the hardware half of the compatibility model described in
[Compatibility Architecture](Compatibility-Architecture.md): it is a single source of truth for per-device
graphics and media capabilities. It deliberately does **not** contain patch bytes or per-macOS-build data;
binary-target data is the other half of the model and is selected by the identity of the binary being
patched.

## Why

The rendering fix and hardware decoding are different layers:

- rendering: per-pipeline `CB_COLOR_CONTROL.DISABLE_DUAL_QUAD` policy for dual-source blending;
- media: VCN/UVD engines, firmware, rings, power and VideoToolbox/VDA capabilities.

Trying to solve rendering with a global hardware RB+ disable failed on Renoir (QQ Helper still reset the GPU
with user-space patches off), and a global switch would also affect video/compositing. A device profile keeps
the two concerns separate but shares the same APU selection.

The profile is keyed by device ID only and is deliberately small: adding an APU must never duplicate patch
data, and adding a macOS build must never duplicate hardware facts. The two axes are orthogonal; see the
architecture document for the target-identity half.

## Data model

`NootedRed/DeviceProfile.hpp`:

```cpp
struct GraphicsPolicy {
    bool  conditionalDualQuad; // install the per-pipeline GL/Metal fix
    bool  correctHwInfo;       // apply the existing CU/SE corrections
    bool  rbPlusAllowed;       // APU-level RB+ capability (logged; becomes a site precondition)
    UInt8 numShaderEngines;    // value written by the GL HwInfo correction (APU fact, not a patch byte)
};

enum VcnGeneration : UInt32 { kVcnNone, kVcn1_0 = 0x0100, kVcn2_2 = 0x0202 };
struct DecodeCaps { bool h264, hevc, av1; };

struct MediaPolicy {
    bool hasUVD0;              // engine enablement, not capability
    bool hasVCE;
    bool hasVCN0;
    VcnGeneration vcnGeneration; // major << 8 | minor, doubles as the firmware ipVersion
    const char* vcnFirmware;     // embedded blob: ativvaxy_rv.dat / ativvaxy_nv.dat
    UInt32 vcnRingSize;          // future VCN ring allocation, bytes
    UInt32 vcnFenceSize;         // future VCN fence allocation, bytes
    DecodeCaps decode;           // H.264/HEVC/AV1 capability flags
};

struct Profile {
    const char* name;
    UInt16 deviceID;
    ApuFamily family;          // Raven, Raven2, Picasso, Renoir, RenoirE, GreenSardine, Cezanne, Barcelo
    SupportLevel level;        // unavailable / experimental / validated (coarse roll-up)
    KernelVersion minVersion, maxVersion;
    GraphicsPolicy graphics;
    MediaPolicy media;
};
```

The media capability data is populated for every family. The engine flags are enablement, not capability:
the VCN 2.x profiles (Renoir, Renoir/Green Sardine, Cezanne and Barcelo) set `hasVCN0` so the same VDA
implementation can be tried on every VCN 2.x APU. `0x1638` is the hardware-validated target; the other
VCN 2.x APUs are experimental. Raven/Raven2/Picasso are VCN 1.x and keep media disabled because the X6000
VCN2 bridge cannot serve them. The engine is only enabled after the `-NRedVDA`/`-NRedAVC` bridge has
prepared both drivers and allocated the engine. The bridge and user-space data currently cover macOS
15.8.1 (24H32) and macOS 14.8.9 (23J631); other builds are rejected or no-op.

`level` is a coarse, per-profile roll-up for logging, and it stays `experimental` while media is disabled on
most profiles. The authoritative per-feature level is generated from the compatibility manifest (see the
architecture document). The only hardware-validated combination today is the conditional GL/Metal fix on
macOS 15.8.1 / Renoir `0x1638`; that is a per-build fact, so it is recorded in the support matrix rather than
in this version-wide table.

## Selection

`DeviceProfile::current()` selects by `NRed::getDeviceID()` and `currentKernelVersion()`:

| device ID | profile | level |
| --- | --- | --- |
| 0x1638 | Renoir / Green Sardine | experimental (GL/Metal fix validated on 15.8.1; VDA validated on 15.8.1) |
| 0x1636 | Renoir | experimental |
| 0x164C | Cezanne | experimental |
| 0x15E7 | Barcelo | experimental |
| 0x15DD | Raven | experimental |
| 0x15D8 | Raven2 / Picasso | experimental |

`forDevice(deviceID, version)` returns `nullptr` when the device is unknown or the kernel version falls
outside the profile's `[minVersion, maxVersion]` window. `current()` falls back to the generic profile, which
keeps the graphics policy enabled and all media disabled, so an unknown combination never enables media.
The version window is metadata for now: per-build data is keyed by binary identity, not by this range.

Note: `NRed::processPatcher()` still panics on an unknown device ID, so the fallback is effectively
unreachable for devices not in the table. The unknown-device no-op policy is Milestone 2 of the
architecture document.

## Media capability data

| device ID | profile | VCN | firmware | H.264 | HEVC | AV1 | engines |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0x1636 | Renoir | 2.2 (`0x0202`) | `ativvaxy_nv.dat` | yes | yes | no | on (`-NRedVDA`, experimental) |
| 0x1638 | Renoir / Green Sardine | 2.2 (`0x0202`) | `ativvaxy_nv.dat` | yes | yes | no | VCN0 on (`-NRedVDA`, bridge ready) |
| 0x164C | Cezanne | 2.2 (`0x0202`) | `ativvaxy_nv.dat` | yes | yes | no | on (`-NRedVDA`, experimental) |
| 0x15E7 | Barcelo | 2.2 (`0x0202`) | `ativvaxy_nv.dat` | yes | yes | no | on (`-NRedVDA`, experimental) |
| 0x15DD | Raven | 1.0-class (`0x0100`) | `ativvaxy_rv.dat` | yes | yes | no | off |
| 0x15D8 | Raven2 / Picasso | 1.0-class (`0x0100`) | `ativvaxy_rv.dat` | yes | yes | no | off |

The VCN generation is the major/minor IP version; the values match the `ipVersion` argument that `HWLibs`
currently passes to the firmware loader (`0x0100`/`0x0202`). The generation-to-family mapping follows the
Linux AMD hardware component list (Renoir/Cezanne/Barcelo are VCN 2.2; Raven/Picasso are VCN 1.0 and
Raven2 is VCN 1.0.1, which share the `0x0100` VCN 1.0 family code in `MediaPolicy`).

## Integration points

- `UserPatches::processPatcher()` logs the profile, applies the graphics gate from
  `graphics.conditionalDualQuad`, selects the version/family-aware GL patch set, and owns the native
  page-patch backend that applies the GL table when `-NRedGLFix` is set and the generated VA/AppleGVA
  tables when `-NRedVDA` is set.
- `X5000::wrapSetupAndInitializeHWCapabilities()` reads `hasUVD0/hasVCE/hasVCN0` from the profile. The
  effective values are also gated by `VDA::isRequested()` and `VCNBridge::loadReady()`, so the engine is
  only advertised when the user opted in, the profile enables it and both 15.8.1 drivers were
  prepared/loaded. If engine allocation fails, `X5000::allocateHWEngines()` clears the capability again.
  The VDA/user-space gates are capability-based (`media.hasVCN0` + `vcnGeneration == kVcn2_2`), not
  hardcoded to a device ID, so enabling VCN0 on another profile is a data change.
- `VDA::init()` parses the opt-in `-NRedVDA` boot argument (default off), and
  `VDA::processPatcher()` logs the media policy. When `-NRedVDA` is set it also publishes
  `NRedVDARequested`, `NRedVDAMediaEnabled` and `NRedVCNGeneration` on the iGPU for diagnostics.
- `VCNBridge` (new module) force-loads the native `AMDRadeonX6000` VCN2 engine, verifies the generated
  per-build ABI guards, installs the generated call-site patches, allocates `AMDVCN2HWEngine` into
  X5000's engine array and bridges the video/shared/SML metaclasses. It is best-effort: any failure
  disables the bridge and leaves the normal graphics-only accelerator state.
- `DeviceProfile::logCurrent()` emits one canonical line per boot and publishes the same facts as IORegistry
  properties (`NRedCompatDeviceID`, `NRedCompatFamily`, `NRedCompatLevel`,
  `NRedCompatNumShaderEngines`, `NRedCompatVCNGeneration`).
- The rendering fix remains per-pipeline and does not need to know about decode.

Example log line:

```text
Compat: profile="Renoir/Green Sardine" family="Green Sardine" level=experimental device=0x1638 rev=0xC5
darwin=24.6 graphics{dualQuad=1 hwInfo=1 rbPlus=1 numSE=1}
media{gate=0 vcn=0x0202 fw=ativvaxy_nv.dat ring=0x10000 fence=0x1000 h264=1 hevc=1 av1=0}
```

## Adding a new APU

1. Add a `Profile` entry with the device ID and an explicit family (do not alias Cezanne/Barcelo to an
   existing family).
2. Set `level` to `experimental` until the combination is actually validated on hardware.
3. Keep `conditionalDualQuad` enabled only if the APU belongs to the validated family.
4. Fill `rbPlusAllowed` and `numShaderEngines` from a real capability source (register/IP probe preferred);
   do not guess from the device ID alone.
5. Fill the `MediaPolicy` capability data, but only flip `hasUVD0`/`hasVCE`/`hasVCN0` after the engine
   bring-up is implemented and tested on that APU.
6. Verify with the canonical profile log and the existing rendering tests. Never treat a code-level entry as
   a hardware validation claim.

## Adding a new macOS version

The current profile table is device-wide; OS-specific patch data lives in the patch-set/target tables, not
in this file. When adding a macOS build:

- collect the target binaries with the [compatibility data collector](../tools/README-collect-compat-data.md)
  and add the target-identity data (see [Compatibility Architecture](Compatibility-Architecture.md));
- add the generated patch data and its validation status;
- keep media and graphics feature flags independent.

Do not widen `minVersion`/`maxVersion` as a substitute for target data: the version window only decides which
profile is selected, not whether a patch matches.

## Hardware decoding (VDA)

The Phase 1 capability skeleton and the Phase 2/3 bridge implementation are in place:

- Phase 1: `MediaPolicy` carries the VCN generation, firmware name, ring/fence sizes and H.264/HEVC/AV1
  capabilities; the profiles are populated; `-NRedVDA` is the opt-in gate.
- Phase 2/3: `VCNBridge` force-loads the native X6000 VCN2 engine, verifies 15.8.1-generated vtable/getter
  ABI guards, applies the generated cross-driver call-site patches, allocates `AMDVCN2HWEngine` into the
  X5000 engine array and exposes `hasVCN0` only for the validated `0x1638` profile behind `-NRedVDA`.
- Phase 4: the generated 15.8.1 VA/AppleGVA page patches are applied through `UserPatches` when
  `-NRedVDA` is set.

The Chromium fix remains independent. The VDA user-space half is a separate target-identity set; see
[`VDA-Deployment.md`](VDA-Deployment.md) and `analysis/vda-1581-hardware-validation.md`.

## Current status

- `DeviceProfile` v2 (Milestone 1 of the compatibility architecture): implemented — capability fields,
  explicit Cezanne/Barcelo families, version-aware lookup, compile-time table invariants, canonical log.
- Graphics policy: wired into `UserPatches`; current profiles keep it enabled.
- Media policy: capability data populated; the VCN 2.x profiles enable VCN0 (`0x1638` validated, the
  other VCN 2.x APUs experimental). VCN 1.x profiles stay disabled until a VCN 1.x path exists.
- `-NRedVDA`/`-NRedAVC`: parsed and logged, default off; with the opt-in they drive `VCNBridge` and the
  per-build generated VA/AppleGVA user-space patches. `-NRedAVC` keeps AVC/H.264 on hardware and leaves
  HEVC to software.
- Build: passes (release; debug/releasedbg were validated on the VDA branch before the merge).
- Runtime validation: the rendering fix was validated on macOS 15.8.1 / Renoir `0x1638`; VDA hardware
  decode and encode were validated on the same machine (H.264/HEVC decode matched software output,
  `h264_videotoolbox`/`hevc_videotoolbox` produced decodable files). The merged master still needs a
  default-off boot check of the combined log lines before release.
