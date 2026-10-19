# VDA / Hardware Video Decode — Implementation Plan

This branch is the dedicated VDA/VCN workstream. It builds on the `DeviceProfile`/`MediaPolicy`
layer from `feature/device-profile`.

## Current state

Implementation is complete and **hardware-validated on 15.8.1 / Renoir `0x1638`** (2026-10-19). Evidence:
[`analysis/vda-1581-hardware-validation.md`](../analysis/vda-1581-hardware-validation.md). The final
default-off boot and the wider acceptance matrix (Chromium, DRM, 10-bit, other APUs) remain follow-ups.

- Phase 1 (capability skeleton): `DeviceProfile::MediaPolicy` carries `vcnGeneration`
  (`0x0100`/`0x0202`), `vcnFirmware` (`ativvaxy_rv.dat`/`ativvaxy_nv.dat`), ring/fence sizes and
  H.264/HEVC/AV1 flags. Only `0x1638` enables `hasVCN0`; all other profiles stay off.
- Phase 2 (firmware/PSP + 15.8.1 data): `tools/gen_vcn_kernel_data.py` derives the kernel vtable/getter
  ABI guards and 20 cross-driver call-site patches from the live 15.8.1 `SystemKernelExtensions.kc`;
  `NootedRed/VCNKernelData.hpp` is generated and self-checked. The existing `HWLibs` `ativvaxy_nv.dat`
  (`ipVersion 0x0202`) injection stays in place.
- Phase 3 (engine): `NootedRed/VCNBridge.{hpp,cpp}` force-loads `AMDRadeonX6000` from inside the X5000
  accelerator start, verifies both drivers' ABI, applies the generated call-site patches with rollback,
  allocates `AMDVCN2HWEngine` into the X5000 PM4 engine array at `kAMDHWEngineTypeVCN0`, bridges the
  video/shared/SML entry points and `safeMetaCast`, and only then leaves `hasVCN0` enabled. Every failure
  path clears readiness and keeps the normal graphics-only state; the new code has no panic path. A hang in
  Apple's engine/power path remains the hardware risk and is covered by the staged runbook.
- Phase 4 (user space): `tools/gen_vda_va_data.py` and `tools/gen_vda_gva_data.py` derive the 15.8.1
  `AMDRadeonVADriver2` and AppleGVA patches (6 + 1 patch records, 6 page images). `UserPatches` now
  supports multiple patch tables, applies the VA/GVA tables only when `-NRedVDA` is set, the target is
  0x1638 and the kernel VCN bridge has prepared/loaded both drivers, and keeps the GL table behaviour
  unchanged. A failed native engine hardware-init disables the bridge and clears `hasVCN0`.
- Default behaviour is unchanged: without `-NRedVDA` no VCN engine, capability, property or user-space
  hook is installed by the new code.
- Builds pass in release, debug and releasedbg (CommandLineTools toolchain on this machine).
- Hardware/reboot validation is pending; the deployment and rollback steps are in
  [`VDA-Deployment.md`](VDA-Deployment.md).

### Bring-up log

- First boot with `-NRedVDA` (2026-10-19): VDA policy ran (`NRedVDARequested=1`,
  `NRedVCNGeneration=0x0202`) but the kernel bridge did not prepare (`NRedVCNX5000Seen` absent,
  no `NRedVCNX5000ABIValidated`, X6000 not loaded). The policy had a fallback profile, which points to the
  X5000 kext-load callback running before `NRed::processPatcher()` finished setting the device ID: the
  bridge's X5000 branch required a supported device/profile and returned early.
- Fix: X5000 preparation now depends only on `-NRedVDA`; the device/profile/OS check is done in
  `acceleratorStart()` and the X6000 branch, after the device ID is known. Added `NRedVCNX5000Seen`,
  `NRedVCNX6000Seen`, `NRedVCNAccelStartSeen` diagnostics for the next boot.
- Second boot with the race fix: the bridge reached `NRedVCNStage=2` / `NRedVCNX5000Seen=1` but then
  returned. The guard `kextRadeonX6000.loadIndex != Unloaded` was wrong: Lilu's `loadKinfo()` assigns a
  load index when the KextInfo is registered at patcher load, even if the kext is not running. The guard was
  removed; preloaded X6000 is now handled solely by the `loadAttempted` gate in the X6000 branch.
- The loadIndex-fixed build (`457d02f6…`) was deployed to the ESP. Third boot (2026-10-19 19:38):
  `NRedVCNStage=11`, `NRedVCNX5000ABIValidated=1`, `NRedVCNX6000ABIValidated=1`,
  `NRedVCNNativeLoadReady=1`, `NRedVCNEngineAllocated=1`, `NRedVCNLastHardwareInit=1`,
  `NRedVCNUserApplied=4`; H.264 720p/64x64 and HEVC 720p/1080p decode with VideoToolbox matched the
  software YUV output byte-for-byte. Hardware decode is working on the target. Evidence and caveats:
  [`analysis/vda-1581-hardware-validation.md`](../analysis/vda-1581-hardware-validation.md). A follow-up
  found hardware encode (`h264_videotoolbox`/`hevc_videotoolbox`) failing with -12704 and added the VCN2
  feedback-stride patches; that build is deployed and awaits a reboot test (decode is unchanged).

## Prior art and chosen direction

Two previous implementations were studied in depth (static research, no code copied). Full reports:
[`analysis/vcn-legacy-nootedred.md`](../analysis/vcn-legacy-nootedred.md),
[`analysis/vcn-steve12311.md`](../analysis/vcn-steve12311.md) and the synthesis
[`analysis/vcn-approaches.md`](../analysis/vcn-approaches.md).

- **Removed legacy NootedRed VCN code** (2022–2024, deleted by `4523553` "Remove the mostly broken VCN
  code"). It was a "borrow X6000 VCN2 engine + patch Apple user space" bridge: X6000 force-loaded via an
  injected personality, `AMDVCN2HWEngine` inserted into X5000's engine array, `HasVCN0=true`
  unconditionally, and `_cs_validate_page` patches for VideoToolbox/AppleGVA/`AMDRadeonVADriver2`. It
  partially worked (HEVC on one Renoir report, H.264 not) and was always developer-gated.
- **steve12311/NootedRed fork** (2026). The same bridge concept, modernised for macOS 26: optional X6000
  load, generated six-slot vtable/getter ABI guards, generated call-site patches, GFXOFF pairing, and a
  `_shared_region_check_np` COW transaction for the user-space patches. It is credible prior art but
  single-author, Tahoe-only, and its generated data does not fit macOS 15.8.1 (kernel guard mismatch on
  the `0x2A8/0x2B0` getter, 4/20 shifted call sites, 2/18 user-space functions differ).

**Chosen direction.** Adopt the architecture *concept*, not the code or generated data:

1. Reuse Apple's native X6000 VCN2 engine inside the X5000 accelerator, with strict ABI guards and
   all-or-nothing user-space transactions; do not resurrect the legacy code or port Tahoe data.
2. Option A (native X6000 engine bridge) is the Phase 2/3 prototype. It reintroduces the X6000 dependency
   that upstream removed in 2025-11, so the project owner must explicitly accept it; otherwise Phase 3
   must switch to Option B (reimplement the engine with `RuntimeMC`) before writing code.
3. Everything stays behind `-NRedVDA`, default off. `hasVCN0` flips only after the engine/ring path is
   validated on the tested profile; any failure leaves the current graphics-only accelerator state.
4. User-space patch generation for the target OS is the long pole and a separate research track; the
   current `UserPatches` framework is the preferred delivery host, with the fork's transaction safety
   properties adopted conceptually.

## Target data path

Typical modern macOS path:

```text
Chromium / AVFoundation
  -> VideoToolbox
  -> VDA / VTDecoderXPCService
  -> AppleVADriver / AMDRadeonX5000VCE (kernel)
  -> VCN engine + firmware
```

Renoir is a VCN 2.x-class APU; Raven/Picasso are VCN 1.0-class. The exact generation belongs in
`MediaPolicy`, not in hardcoded paths.

Prior art shows that on modern macOS the VCN 2.x engine used by Renoir/Cezanne is Apple's X6000
`AMDVCN2HWEngine`, reached by bridging the active X5000 accelerator to X6000 — not the legacy X5000
VCE path in the diagram. Option A therefore targets "X5000 active + native X6000 VCN2 engine"; Option B
would replace that with a `RuntimeMC`/native reimplementation.

## Phases

### Phase 1 — media capability skeleton — implemented

- Extended `MediaPolicy` with:
  - `vcnGeneration` — major << 8 | minor, also the firmware loader `ipVersion`
    (`kVcn1_0 = 0x0100`, `kVcn2_2 = 0x0202`);
  - `vcnFirmware` — `ativvaxy_rv.dat` (VCN 1.0) or `ativvaxy_nv.dat` (VCN 2.2), matching the blobs
    embedded by `HWLibs.cpp`;
  - `vcnRingSize` / `vcnFenceSize` — future VCN ring/fence allocation sizes in bytes;
  - `decode.h264` / `decode.hevc` / `decode.av1` — hardware capability flags (AV1 is false: VCN 1.x/2.x
    have no AV1 decoder).
- Engine enablement is limited to the designated `0x1638` VDA target (`hasVCN0`), and is effective only
  when `-NRedVDA` is set and the bridge prepared/loaded both drivers with a successful engine allocation.
  All other profiles keep `hasUVD0`/`hasVCE`/`hasVCN0` false. Compile-time assertions in
  `DeviceProfile.cpp` reject enabling any other profile or a profile with missing VCN data.
- Added the `-NRedVDA` boot argument (default off, independent of `-NRedGLFix`). It is parsed in
  `VDA::init()`, and Phase 1 only uses it for diagnostics in `VDA::processPatcher()`; no MMIO, firmware or
  engine access happens. The default path only logs under `-NRedDebug`.
- `X5000` gates the profile engine flags with `-NRedVDA` + `VCNBridge::engineEnabled()` (both drivers
  ready/loaded and the native engine allocated); allocation failure clears `hasVCN0` again.
- Verification: `xmake` passes for release, debug and releasedbg; media flags cannot change at compile
  time, so the graphics path is untouched. One boot on a target machine is still required to confirm no
  runtime regression (`-NRedVDA` absent and present).

### Phase 2 — firmware / PSP bring-up and 15.8.1 data — implemented and validated

Status: `tools/gen_vcn_kernel_data.py` + `VCNKernelData.hpp` are generated from the live 15.8.1 KC and
self-checked; the X6000 optional load is wired in `VCNBridge`. Firmware read-back and the actual X6000
load can only be confirmed on the next boot.

- Confirm VCN firmware names per family (the tree already references `ativvaxy_rv.dat` for VCN 1.0 and
  `ativvaxy_nv.dat` for VCN 2.2 in HWLibs; the HWLibs comment says VCN 2.1, but it passes `0x0202` as
  the firmware `ipVersion`, and the Linux AMD hardware list classifies Renoir/Cezanne as VCN 2.2).
- Extract the 15.8.1 `AMDRadeonX5000`, `AMDRadeonX6000` and `AMDRadeonX5000HWLibs` Mach-Os from
  `SystemKernelExtensions.kc` (or a KDK); record versions, UUIDs and hashes. Do not commit extracted
  binaries.
- Generate 15.8.1-specific ABI data before any hook: both hardware vtables, the six guard slots, the
  `0x2A8/0x2B0` getter difference, and the 20 call-site patches (expect the four shifted offsets). Prefer
  an in-tree generator with an input-hash manifest over hand-edited tables.
- Prove the optional `OSKextLoadKextWithIdentifier("com.apple.kext.AMDRadeonX6000")` load on Renoir-only
  15.8.1 and that `AMDVCN2HWEngine`/`AMDAccel*` metaclasses are usable. Keep engine allocation and
  `hasVCN0` disabled in this step.
- Verify the existing firmware injection path (`ativvaxy_nv.dat`, `ipVersion 0x0202`, Navi10 device-type
  spoof) is exercised only when the engine is used; add read-back diagnostics.
- Keep media disabled if any load/ABI/firmware step fails; no user-visible decode in Phase 2.

### Phase 3 — VCN engine insertion and ring/submit validation — implemented and validated on 0x1638

Status: `VCNBridge` allocates `AMDVCN2HWEngine` into the X5000 engine array and gates `hasVCN0` on both
drivers being prepared/loaded plus a successful allocation; GFXOFF wait pairing is part of the generated
call-site data. The runtime ring/submit and watchdog behaviour is hardware-only.

- Decide and record Option A (native X6000 engine bridge) or Option B (`RuntimeMC` reimplementation)
  before writing engine code. Option A is the prototype; Option B is required if the project owner rejects
  reviving the X6000 dependency.
- Option A: allocate `AMDVCN2HWEngine`, insert it into the X5000 PM4 engine array at
  `kAMDHWEngineTypeVCN0`, and validate the native engine's ring/doorbell setup and command submission.
  NootedRed does not allocate VCN rings itself in this design; restate the old "allocate rings" goal as
  "validate the native engine's rings".
- Reproduce the fork's GFXOFF wait pairing and idleness checks; validate no Hackintool `VCN0Dec` stall,
  WindowServer watchdog or `.gpuRestart`, with a recovery plan (bootable EFI / remove arg / reboot).
- Enable `hasVCN0` only for the tested profile after ring/submit validation, behind `-NRedVDA`; any
  failure must leave the graphics-only accelerator state and fall back to software decode, never panic.
- Add diagnostics to the media log tag (`VDA`).

### Phase 4 — VideoToolbox/VDA exposure — implemented and validated on 0x1638

Status: 15.8.1 VA (6 records / 5 pages) and AppleGVA (1 record / 1 page) patches are generated and
integrated into `UserPatches`; they are only applied when `-NRedVDA` is set, the profile is `0x1638` and
the kernel VCN bridge reports ready. End-to-end VideoToolbox selection/decode needs hardware validation.

- Generate 15.8.1 user-space patches for the AppleGVA decoder-selection path and
  `AMDRadeonVADriver2` (`VAAcceleratorInfo::identify` with per-device `vaFamily=5`, `VAFactory::create*`,
  AddrLib family/swizzle fixes); re-derive the two functions that do not match the fork's Tahoe data and
  revalidate all patch sites. Use our existing `UserPatches` transaction semantics (all-or-nothing,
  restore RX, rollback); do not copy the fork's generated data.
- Decide whether to keep or suppress the existing X5000 personality's `IOGVACodec = AMDVCN2` /
  HEVC capability advertisement while testing; do not change stable graphics behaviour without
  validation.
- Ensure `VTDecoderXPCService` can open a hardware decoder.
- Validate H.264/HEVC decode surfaces and format compatibility, including the fork's known adverse cases
  (64×64 H.264, Hackintool create/destroy, ≥5 min idle then start, continuous playback, 10-bit HEVC).
- Check the Chromium hardware decode path.

### Phase 5 — multi-APU / multi-macOS

- Add MediaPolicy values per APU profile.
- Add OS/version-specific media data where required.
- Keep DeviceProfile as the only device selector.

## Required data collection

Use `tools/collect_platform_data.py` on each target machine. The zip includes:

- GPU/APU identity and `GPUConfigurationVariable`;
- X5000/X6000 kexts, PlugIns, Info.plists and firmware resources;
- GL/MTL driver images and symbols (for graphics regressions);
- ioreg media/VideoToolbox properties and `ffmpeg -hwaccels`.

For VDA work also record:

- kernel-collection/KDK extraction of `AMDRadeonX5000`, `AMDRadeonX6000` and `AMDRadeonX5000HWLibs`
  (versions, UUIDs, hashes) — the on-disk `Contents/MacOS` binaries are absent on current macOS;
- dyld shared cache UUID/base and the `AppleGVA` / `AMDRadeonVADriver2` / `libsystem_c` images and
  symbols;
- boot args, decoder `UsingHardwareAcceleratedVideoDecoder`, software-vs-hardware pixel digests, and any
  `.gpuRestart`/WindowServer reports.

Run on:

- 15.8.1 Renoir baseline;
- 26.7.1 with 5800H and 7730U;
- any Raven/Picasso/Raven2 available.

Never mix data generated on one OS/driver version into another; keep a version→data table.

## Safety rules

- `-NRedVDA` must be opt-in; default off.
- Media and graphics flags must be independent.
- The default path (no `-NRedVDA`) must stay inert: no engine access, no capability change, no user-space
  patch. All new engine/user-space work is gated by `-NRedVDA` and the `0x1638` profile.
- If firmware/ring bring-up fails, fall back to software decode; never panic.
- Do not tie VDA to the failed global RB+ experiments.
- Do not flip `hasUVD0`/`hasVCE`/`hasVCN0` or change media enablement defaults without real hardware
  validation.

## Handoff

When starting a new session:

1. Check out `feature/vda-hardware-decode`;
2. Read this document, `docs/Device-Profile.md`, and the prior-art reports
   [`analysis/vcn-legacy-nootedred.md`](../analysis/vcn-legacy-nootedred.md),
   [`analysis/vcn-steve12311.md`](../analysis/vcn-steve12311.md),
   [`analysis/vcn-approaches.md`](../analysis/vcn-approaches.md);
3. Confirm the current stable graphics build and boot args; run
   `xmake f -m release -y && xmake -y` (and debug/releasedbg before handing off);
4. The recorded decision is **Option A** (native X6000 engine bridge), implemented in `VCNBridge`; do not
   switch to Option B without a new decision;
5. Phases 1-4 are implemented and hardware-validated on macOS 15.8.1 / Renoir `0x1638`. The next steps are
   the wider acceptance matrix: boot once with `-NRedVDA` removed to confirm the default-off path on this
   build, then Chromium/real-application playback, DRM/Apple TV, 10-bit HEVC, longer playback/desktop
   responsiveness and Hackintool create/destroy. If the OS or AMD drivers change, regenerate
   `VCNKernelData.hpp`, `VDAVAData.hpp` and `VDAGVAData.hpp`; never reuse this data across builds. The
   development machine is a Renoir `0x1638` on macOS 15.8.1 (Darwin 24.6).
