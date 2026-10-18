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
    bool hasUVD0;
    bool hasVCE;
    bool hasVCN0;
    uint8_t vcnGeneration;
    const char* vcnFirmware;
    uint32_t vcnRingSize;
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

Current media fields are all `false`: this is intentional. They are placeholders for the VDA work, not a
claim that decoding works.

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

## Integration points

- `UserPatches::processPatcher()` logs the profile and can disable the rendering fix through
  `graphics.conditionalDualQuad`.
- `X5000::wrapSetupAndInitializeHWCapabilities()` now reads `hasUVD0/hasVCE/hasVCN0` from the profile
  instead of hardcoding `false`. Since all profiles keep them false, current behaviour is unchanged.
- VDA work will add `MediaPolicy` values and the corresponding engine bring-up; the rendering fix remains
  per-pipeline and does not need to know about decode.

## Adding a new APU

1. Add a `Profile` entry with the device ID and family.
2. Keep `conditionalDualQuad` only if the APU is in the validated family.
3. Add the media capabilities only after the engine bring-up is implemented and tested.
4. Verify with the profile log and the existing rendering tests.

## Adding a new macOS version

The current profile table is device-wide; OS-specific patch data still lives in `UserPatches`/future
`PatchSet` entries. When the table becomes version-aware:

- add a profile entry with a Darwin version range;
- add the corresponding patch set/signature data;
- keep media and graphics feature flags independent.

## Hardware decoding (future VDA)

The future VCN path needs, at minimum:

- correct VCN generation and firmware (for example `ativvaxy_nv.dat` for VCN 2.1);
- PSP/RLC firmware, rings and power;
- `hasVCN0 = true` in the profile;
- VideoToolbox/VDA capability exposure and surface/format handling.

Those will be implemented as media work behind `MediaPolicy`, so the Chromium fix can remain enabled or
disabled independently.

## Current status

- `DeviceProfile` skeleton: implemented.
- Graphics policy: wired into `UserPatches`; current profiles keep it enabled.
- Media policy: wired into `X5000`; all values false, so no behaviour change.
- Build: passes.
- Runtime/reboot validation: pending.
