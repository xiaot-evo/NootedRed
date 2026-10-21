# iGPU HwInfo / UBM Model Research Plan

> Status: research record, merged from the archived `research/igpu-hwinfo-logic` branch. The conclusion
> was that `_amdUbm_HWL_Init` already consumes the iGPU hardware-info blob, so the GL fix does not need a
> separate UBM model; the open item is the per-build/per-APU site data described in Phase 5.

## Starting point

NootedRed maintainer's issue #158 comment points at Apple's user-space driver having **no iGPU logic** and
falling back to Vega dGPU values in functions like:

- `gfx9_HwInfoInitData`
- `_amdUbm_HWL_Init` / AddrLib initialization

Current production workaround only patches the downstream dual-quad decision. This branch researches a
more root-level fix: give the driver a coherent Renoir iGPU HwInfo/UBM model.

## Feasibility assessment

Supported by current conditions:

- 15.8.1 GL/MTL driver binaries and symbols are available.
- Ghidra and the page-patch/native resolver framework are available.
- DeviceProfile and the platform-data collector are in place.
- The existing conditional dual-quad fix is a known-good baseline for A/B.

Not yet available:

- macOS 26.7.1 driver dumps (collector must run on those machines).
- A complete, validated Renoir UBM/AddrLib model.
- Confirmed behavior of every RB+/tiling field.

Conclusion: **feasible as a research prototype on 15.8.1, not yet a production fix.** The stable build must
stay unchanged until the prototype passes GL/Metal dual-source tests without artifacts.

## Required functions

1. `gfx9_HwInfoInitData` (GL and MTL drivers)
   - family/flags
   - `numShaderEngines`, `numShaderArrays`, CU count
   - TCC/RB counts
   - `GB_ADDR_CONFIG` / tile fields
2. `_amdUbm_HWL_Init` (and related `InitDeviceSettings`, `InitUBMHwRegFields`,
   `InitAddrLibHwRegFields`)
   - tiling/DCC/surface parameters must match the HwInfo topology.
3. Pipeline setup
   - dual-source / RB+ decision must be consistent with the iGPU capability.

## Initial inventory (2026-10-19)

15.8.1 `AMDRadeonX5000GLDriver` symbols:

```text
_gfx9_HwInfoInitData   0xdf40
_amdUbm_HWL_Init       0x5ee3a
```

Initial findings:

- `_amdUbm_HWL_Init` has **no family branch**; it initializes a `0x204`-byte UBM input, writes a fixed
  `0x121011A` / `0x1C`, then copies fields from the HwInfo record (for example HwInfo `+0xf0` to UBM
  `+0x1d8`, HwInfo `+0x108` to UBM `+0x1dc`, HwInfo `+0x18/+0x1c` to UBM `+0x24`, HwInfo `+0x28/+0x38`
  to UBM `+0x30`).
- This supports the theory that UBM is largely a consumer of HwInfo: a coherent iGPU HwInfo may be
  enough, but the exact HwInfo fields consumed by UBM must be mapped before changing anything.
- `gfx9_HwInfoInitData` still takes the Vega10 branch for Renoir (`numShaderEngines=4`, TCC `0x10`,
  flags `0x4d`).

Critical repository note: the local 15.8.1 `AMDRadeonX5000GLDriver` file has A1/A2 bytes already patched
in its first branch (`0xE081 = 1`, dual-quad `0x8160` patched). For model analysis use a reconstructed
vanilla copy made by restoring the two 4 KiB pages from `UserPatches.cpp` (written as
`/tmp/GLDriver-vanilla` during this round), not the on-disk file.

### Round 2 findings (Ghidra)

`_amdUbm_HWL_Init` does **not** consume the `GFX9_HwInfoRec` directly. It:

1. zeroes a 0x204-byte stack input;
2. writes fixed `0x121011A` and `0x1C` to the UBM create input;
3. calls `IOAccelDeviceGetConnect(...)` + `IOConnectCallMethod(..., selector 0x100, ...)` to fetch a
   0x204-byte **kernel hardware-info blob**;
4. copies fields from that blob into the UBM object (`+0x1d8`, `+0x1dc`, `+0x1c`, `+0x24`, `+0x2c`,
   `+0x30`), plus fixed family `0x8d`.

So UBM initialization is mostly a **kernel HW-info consumer**, not an HwInfo-record consumer. A real iGPU
model needs the kernel HW-info blob and/or the fixed UBM values to be checked, not only
`gfx9_HwInfoInitData`.

Vanilla `gfx9_HwInfoInitData` (reconstructed from page images) first-branch constants:

```text
+0x78 numShaderEngines = 4
+0x80..+0x8c = {1, 32, 127, 0x1000}
+0x90 = 0x10
+0xa0 flags = 0x4d
+0xac chipFlags = 0xc1
```

The local on-disk driver has these branches already patched at the A1/A2 sites (0xE081 = 1 and
0x8160 = patched); use `/tmp/GLDriver-vanilla` for analysis.

Next research step: map HwInfo fields `+0xf0`, `+0x108`, `+0x28`, `+0x38` and the UBM fields they feed,
then derive Renoir values from Linux/Mesa and the collected platform data.

## Round 3 conclusion: the kernel blob is already iGPU-correct

A direct `IOAccelerator` user client (`IOServiceOpen(..., type 5)` + `IOConnectCallMethod(selector 0x100)`)
returned the same 0x204-byte blob on Renoir. Key values:

```text
+0x08 = 1        chip revision / branch selector
+0x20 = 8        active CUs
+0x88 = 1        seCount (NootedRed)
+0x90 = 1        shCount (NootedRed)
+0xa0 = 0x24000042  GB_ADDR_CONFIG
```

`_amdUbm_HWL_Init` copies exactly these fields into the UBM object. So UBM is already consuming iGPU
values from the kernel; it is not the source of the Vega dGPU model.

The user-space `gfx9_HwInfoInitData` field map (analysis/gl-hwinfo.md) shows only two fields that matter
for the observed bug:

- `rec+0x78` numShaderEngines: 4 -> 1 (A1);
- `rec+0xa0` feature flags: bit1 enables the RB+ / dual-quad paths (A2 correlates this with the
  downstream `UpdateHwCbDualQuadMode` decision).

`rec+0x90` is an unknown count/cap, not TCC; changing it to the kernel blob value is not justified.
`UpdateHwCbDualQuadMode` has no dual-source condition, so even a perfect HwInfo branch cannot make GL
disable dual-quad by itself; the A2 consumer patch is the practical iGPU logic fix.

Therefore the "full iGPU HwInfo/UBM model" does **not** appear to replace the current A1/A2 workaround
on 15.8.1. The remaining cross-version problem is driver-page data (for example 26.7.1), not a missing
UBM model.

## Phases

### Phase 1 — map the current logic

- Inventory symbols and callers in the 15.8.1 GL/MTL drivers.
- Dump the current values produced by `gfx9_HwInfoInitData` and consumed by UBM/AddrLib.
- Identify exactly which fields are Vega dGPU values.

### Phase 2 — derive the Renoir model

- Use Linux `amdgpu`/Mesa for Renoir topology and tiling constraints.
- Confirm `GB_ADDR_CONFIG = 0x24000042` and related fields.
- Decide the RB+ policy: full RB+ only if the entire model is coherent; otherwise model iGPU as
  RB+ unsupported first.

### Phase 3 — experimental patch

- Add an iGPU branch to `gfx9_HwInfoInitData`.
- Synchronize `_amdUbm_HWL_Init`/AddrLib inputs.
- Gate the experiment behind a separate boot argument, leaving stable `-NRedGLFix` untouched.

### Phase 4 — validation

- GL dual-source probe: `dual=64,0,64,255`, no corruption.
- Metal normal/dual-source pipeline controls and render comparison.
- No `Kernel_*.gpuRestart`.
- Compare with the current conditional workaround.

### Phase 5 — generalization

- Run the collector on 26.7.1 / 5800H / 7730U and other APUs.
- Add per-APU/per-OS data to DeviceProfile/PatchSet.
- Decide whether to replace the downstream workaround or keep it as fallback.

## Safety

- Do not touch `master` or the stable build.
- The `research/igpu-hwinfo-logic` branch has been archived after this record was merged into `master`.
- Experiment must be opt-in.
- No GPU test on an unstable boot.
