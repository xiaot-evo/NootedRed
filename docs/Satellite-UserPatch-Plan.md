# Satellite UserPatch kext — implementation plan

Status: **implemented and boot-validated on 15.8.1 / 0x1638 with embedded static PatchData** (24H32
kinds 1–4; 25G241 kinds 1–4; 23J631 VDA/AppleGVA only). The external runtime-data model was retired
after it was proven to hang early boot; external data is now build-time input only. Broader hardware
and feature validation is still pending.

Branch: `research/satellite-userpatch` (based on `master`, commit `0efa6f4`)

Date: 2026-10-23

## 1. Decision summary

Return the tree to the `master` model: **per-macOS-build, exact 4 KiB page patches**. Do not use a
shared-cache semantic scanner as the default user-space backend.

Split the user-space patching out of the main `NootedRed` kext:

```
Lilu
 ├── NootedRed.kext              stable kernel-side AMD iGPU support
 └── NootedRedUserPatch.kext     satellite kext: user-space GL/Metal/VDA patches
       └── patch data            independent, version-selected 4 KiB tables
```

The main kext keeps doing only what it does well today: kernel kext patching, Framebuffer/DC/PM/SMU/VCN
bring-up, and hardware enablement. The satellite owns:

- `_cs_validate_page` / `_cs_validate_range` hooks;
- GL driver dual-quad / HwInfo fixes;
- Metal HwInfo / gate / allow fixes;
- VDA (VA + AppleGVA) user-space tables, and the readiness coordination with the main kext.

The satellite always uses **exact 4 KiB page images** selected by OS build and APU. A non-matching
build is a no-op, never a broad semantic fallback.

Approved decisions (2026-10-23):

1. **Data format A, embedded at build time**: generated binary blobs plus a JSON manifest; generated
   `const` arrays are compiled into the satellite. There is no runtime data directory. Adding or
   changing a build requires regenerating the blob and rebuilding/re-signing the kext. The external
   runtime-file variant was retired because a kernel VFS read during early boot hung the machine.
2. **Auto-load when NootedRed is present**: no mandatory new boot argument. An override
   (`-NRedUserPatchOff`) remains for debugging.
3. **All VDA/AppleGVA user-space patches move to the satellite**, not just GL/Metal.
4. **Main kext stays on original NootedRed logic.** The experiment branch's user-space findings
   (conditional dual-quad, Metal A1, exact-page values) belong to the satellite data; they do not
   change mainline kernel behaviour.
5. After implementation: code review, then validate the complete boot flow from OpenCore kext load
   through `_cs_validate_page`/`_cs_validate_range`, user-space patch application, VDA, and rollback.

## 2. Why this change

The current research branch tried:

1. Plan B (global GL HwInfo capability bit);
2. semantic-only GL/Metal matching;
3. deferred shared-cache semantic scanning.

Results on the real machine:

- Plan B caused Zen browser corruption because it also enabled the global RB+ export/blend paths.
- semantic-only shared-cache scanning caused WindowServer watchdog panics.
- A deferred `thread_call` queue stored a validation page pointer past its mapping; the later write
  faulted inside `org.ChefKiss.NootedRed`, causing kernel page-fault panics.

Conclusions:

- exact page tables are the reliable model for a released system;
- user-space patching must not be able to destabilise the main NootedRed kext;
- patch data changes far more often than kernel code and must be independently selectable;
- version selection must be explicit (Darwin/build/APU/driver identity), not a heuristic scan.

## 3. Target architecture

### 3.1 Main kext: `NootedRed.kext`

Owns only kernel-side work:

- X5000 / X6000 / HWLibs / AGDP / Backlight / AppleGFXHDA kernel patches;
- Framebuffer, DC, power management, SMU, PSP;
- VCN kernel bridge and firmware setup;
- published readiness state for the satellite (see 3.4).

Must not contain:

- `_cs_validate_page` / `_cs_validate_range` hooks;
- GL/Metal page tables;
- VDA/AppleGVA user-space tables;
- `UserPatches.cpp`, `GLFixSemanticData.hpp`, `TahoePatchData.hpp`, `UserPatchesSonoma.inc`,
  `VDA*Data*.hpp` user-space tables.

### 3.2 Satellite kext: `NootedRedUserPatch.kext`

A Lilu plugin, loaded independently of NootedRed:

- `OSBundleLibraries`: `as.vit9696.Lilu`; dependency on the main kext identifier so OpenCore loads it
  only when NootedRed is also installed;
- own `PluginConfiguration`, minimum macOS = Catalina, maximum = Tahoe;
- **auto-enabled when NootedRed is present**; `-NRedUserPatchOff` disables it for debugging;
- only installs user-space code-signing hooks; never patches kernel kexts;
- if no matching data directory exists for the running build, or the exact page image does not match,
  it stays loaded but no-ops (feature state `NoOp`), so the rest of the system is unaffected.

The satellite may optionally be built as a separate repository/package later. It must be installable
and removable without touching the main kext or OpenCore kernel patches.

### 3.3 Patch data

Patch data is independent from the satellite's code. The authoritative on-disk contract is
[`docs/UserPatch-Data-Format.md`](UserPatch-Data-Format.md); this section only records the decisions.

- One directory per **exact** macOS build, named by `kern.osversion` (for example `24H32`):

```
PatchData/
  24H32/
    manifest.bin
    pages.bin
    manifest.json      # human-readable copy, not read by the kext
  23J631/             # kinds 3/4 only; 14.8.9 GL/Metal is a documented data gap
  25G241/
```

- `manifest.bin` is the packed little-endian v1 format: magic `"NRPD"`, `version`/`headerSize`,
  `kern.osversion` + Darwin version, APU family mask, FNV-1a-32 pages checksum, FNV-1a-64 manifest
  checksum, then canonical table records (kinds 1 GL, 2 Metal, 3 VDA/VA, 4 VDA/AppleGVA), 4 KiB
  page records and explicit-offset site records (`find`/`replace`/size). Page SHA-256 values and the
  provenance/evidence reference live in the human-readable `manifest.json`, which the kext ignores.
- Driver identity in v1 is **exact 4 KiB page equality**; there is no driver-bundle hash field and no
  `build_prefix_ok` prefix selection. The page image is the final gate.
- The generator is [`tools/userpatch_data.py`](../tools/userpatch_data.py); the deployment sets are
  derived from the pinned master tables by
  [`tools/convert_master_patchdata.py`](../tools/convert_master_patchdata.py) (readable inputs in
  `tools/specs/`). Hand-edited page arrays are forbidden.
- Selection rules (implemented in the satellite):
  1. exact `kern.osversion` directory name + exact Darwin version + `apuMask & candidateMask != 0`
     (intersection, see the format doc §3.1);
  2. otherwise `NoOp`. There is no prefix/nearest-build fallback and no semantic scan.
- VDA/AppleGVA tables (kinds 3/4) are additionally gated on `NRedVCNBridgeReady`; GL/Metal are
  independent.

Committed deployment data today: `PatchData/24H32` (kinds 1–4), `PatchData/25G241` (kinds 1–4) and
`PatchData/23J631` (kinds 3/4 only). Gaps are listed in [`PatchData/README.md`](../PatchData/README.md)
and in each `manifest.json` provenance block.

Final loading model: **embedded static data**. `tools/embed_patchdata.py` turns the committed
`PatchData/<build>/{manifest.bin,pages.bin}` sources into generated `const` arrays in
`NootedRedUserPatch/PatchDataBlob.*`; the kext links them and performs **no runtime file I/O**.

Adding a build means regenerating the blob and rebuilding/re-signing the kext; there is no runtime
directory, no resource fallback and no boot-argument path. Routes are installed unconditionally at
Lilu patcher load; the embedded data only gates page writes. A missing/mismatched embedded build is a
fail-closed `NoOp`. The satellite may retry identity/readiness from a bounded kernel timer, but it
never touches the filesystem in that path.

### 3.4 Main ↔ satellite coordination

The main kext is the single source of truth for hardware state. For VDA user-space patching the
satellite needs to know whether the VCN bridge is ready (`VCNBridge::loadReady()` today).

Preferred coordination:

- main kext publishes `NRedVCNBridgeReady` as a 32-bit non-zero property on the AMD iGPU
  `IOPCIDevice` after `VCNBridge::loadReady()` becomes true (`requested && x5000Prepared &&
  x6000Prepared && loadCompleted`);
- satellite reads the same property from the AMD iGPU `IOPCIDevice` only (there is no `NootedRed`
  IOService), caching the boolean from safe contexts before applying VDA/AppleGVA pages;
- if the property is absent or zero, VDA tables are a no-op; GL/Metal tables are independent and may
  still apply.

Do not link the satellite directly against C++ NootedRed symbols in phase 1. A small, versioned
C export can be added later only if IORegistry coordination proves insufficient.

#### 3.4.1 Implemented contract (main kext side, 2026-10-23)

The main kext publishes the contract above; there is no C++ ABI between the two kexts.

- **Property name:** `NRedVCNBridgeReady`
- **Type:** IOKit 32-bit number, written with `IOPCIDevice::setProperty(key, value, 32)`; the satellite
  additionally accepts an `OSData` of at least 4 bytes.
- **Location:** the AMD iGPU `IOPCIDevice` (renamed `IGPU` by NRed), the same IORegistry entry that
  carries `vendor-id`/`device-id`. The satellite matches it by `vendor-id == 0x1002` and the running
  device ID. The iGPU property is the only publication point; the mainline kext has no `NootedRed`
  IOService property that the satellite could fall back to.
- **Value:** `1` while ready, `0` after readiness is withdrawn. An absent property means "not ready".
- **Readiness predicate:** `VCNBridge::loadReady()` = `requested && x5000Prepared && x6000Prepared &&
  loadCompleted` (`NootedRed/VCNBridge.cpp`).
- **Publication points**, all in `NootedRed/VCNBridge.cpp`:
  1. immediately after `loadCompleted` becomes true when the X6000 kext load succeeds inside the X5000
     accelerator start — the actual readiness transition, not deferred to engine allocation;
  2. at the end of the accelerator start, including the rollback to `0` when the original start fails;
  3. when `AMDVCN2HWEngine` allocation fails and clears `loadCompleted`;
  4. when `initHardware` fails and disables the bridge;
  5. in `VCNBridge::acceleratorStop`, which clears `loadCompleted` and republishes `0` so the
     satellite cannot apply VDA pages while no accelerator exists (restored by the next start).

VDA/AppleGVA user-space pages are only applied while the property is non-zero; GL/Metal pages are
independent and may still apply. The main kext never reads the property and works fully without the
satellite installed. The property is the only main/satellite coordination point: after this change
`NootedRed.kext` no longer contains any `_cs_validate_page`/`_cs_validate_range` hook or GL / Metal /
VDA user-space table.

## 4. Main kext cleanup

On the new branch, from `master`:

1. Remove `NootedRed/UserPatches.cpp/.hpp`, `GLFixSemanticData.hpp`, `TahoePatchData.hpp`,
   `UserPatchesSonoma.inc` and the VDA user-space data headers from the main kext build.
2. Remove the `UserPatches` include, registration calls, `init()` and `processPatcher()` calls from
   `NRed.cpp`.
3. Keep `VCNBridge` and VDA kernel-side setup in the main kext; expose readiness as an IORegistry
   property for the satellite.
4. **Do not import the experiment branch's APU capability database or any other research behaviour
   into the main kext.** Mainline remains original NootedRed logic; only the satellite and its data
   carry the user-space findings.
5. No user-space patch data or code-signing hooks remain in the main kext binary.

The main kext must build and run without the satellite installed. This is the primary rollback path.

## 5. Satellite implementation phases

Status (2026-10-23): implemented and boot-validated on 15.8.1 / 0x1638. `PatchData/` is build-time
source; `tools/embed_patchdata.py` embeds it in the satellite; the mainline user-space code is removed.
The external-data runtime loader was retired after it hung early boot; hardware validation on other
builds/APUs and feature matrix items remain pending. Phase 5 is optional.

### Phase 0 — baseline and plan (this document)

- new branch from `master`;
- no code changes;
- record known-good exact-page behaviour and current boot args.

### Phase 1 — data pipeline and runtime loader

- write generator/validator for `manifest.bin` + `pages.bin` (implemented: `tools/userpatch_data.py`,
  `tools/test_userpatch_data.py`);
- derive GL/Metal/VDA/AppleGVA exact tables from pinned master sources and `platform-data`
  (implemented: `tools/convert_master_patchdata.py` → `tools/specs/`, `PatchData/`);
- v1 manifest schema with page SHA-256 provenance, FNV checksums and APU masks (implemented);
- implement the satellite's external-directory reader and binary manifest parser;
- host tests: explicit site offsets/find bytes, no conflicting site writes, page SHA-256/checksum
  validation, canonical layout, malformed-data rejection, pinned-source provenance, per-kind deployed
  data and selection matrix (implemented);
- data-only test: drop a new build directory into the data path, reboot, verify it is selected without
  rebuilding the kext.

### Phase 2 — satellite scaffold

- add second xmake target `NootedRedUserPatch`;
- own `Info.plist`, `PluginConfiguration`, auto-load dependency on NootedRed;
- own `_cs_validate_page`/`_cs_validate_range` hook installer with exact page matching only;
- no-op path when data directory, build, APU, checksum or page image does not match;
- boot test on 15.8.1 with no patch data: feature must report no-op, no panic, no main-kext change.

### Phase 3 — all user-space patches move

- port `master` 15.8.1 and 26.7.1 GL/Metal exact tables into generated data (done: `PatchData/24H32`,
  `PatchData/25G241`); 14.8.x GL/Metal remains a listed gap because master's Sonoma pages are not
  pinned to an exact `kern.osversion`;
- port VDA/AppleGVA tables (done: `PatchData/24H32`, `23J631`, `25G241` kinds 3/4);
- implement main-kext readiness property; satellite waits for it before VDA pages (done, including
  withdrawal on `acceleratorStop`);
- select by exact build + Darwin + APU mask intersection + exact page equality (done);
- remove GL/Metal/VDA user-space code and tables from the main kext (done);
- validate dual-source, Chrome, Zen, QQ image open, WindowServer stability, hardware decode
  (**pending hardware**).

### Phase 4 — code review and boot-flow validation

- review the satellite from the OpenCore kext-load order through installed hooks, data selection,
  page validation, patch write, VDA readiness and rollback;
- verify main kext builds and boots with the satellite absent;
- verify `-NRedUserPatchOff` leaves the system untouched;
- capture a real boot log and a panic/GPU-reset check before marking the phase complete.

### Phase 5 — optional follow-ups

- add more build directories to the external data path without code changes;
- evaluate a Rust host-side generator/validator (see §7);
- only revisit additional mainline changes as a separate, independently approved project.

## 6. What moves where

| Item | Main kext | Satellite | Patch data |
| --- | --- | --- | --- |
| Kernel kext patches | yes | no | no |
| VCN kernel bridge / firmware | yes | no | no |
| VCN readiness flag | yes (publish) | read | no |
| GL dual-quad exact pages | no | hook + selector | per-build pages |
| Metal gate/allow/HwInfo exact pages | no | hook + selector | per-build pages |
| VDA/AppleGVA user pages | no | hook + selector | per-build pages |
| APU capability/policy facts | no (original logic only) | read-only if needed | per-build APU mask |
| OpenCore boot args | existing | auto; optional `-NRedUserPatchOff` | no |

## 7. Rust evaluation for the satellite

Question: can the satellite (and other kexts) be written in Rust to reduce AI-generated memory
errors?

Local facts:

- no `rustc`/`cargo` is installed in the build environment;
- the project uses AppleForge's `LiluPlugIn` xmake rule, which is a C++/kernel build path;
- Apple does not provide an official Rust macOS kernel/kext target;
- Lilu's plugin ABI (`LiluAPI`, `KernelPatcher`, `OSObject` subclasses, C++ name mangling) is C++;
- a Rust kext would need `no_std`, a custom target JSON with kernel codegen flags, `panic=abort`, no
  unwinding, a C++/C shim for Lilu and IOKit, and custom symbol/initialiser handling;
- the patch logic itself is mostly raw memory access, so Rust safety would be limited to the wrapper
  layer and would still require `unsafe` for every hook.

Assessment:

- **Pure-Rust satellite kext: not easy and not recommended for phase 1.** It adds a second toolchain,
  a custom target and a C++ FFI layer before the first patch is even tested.
- **C++ satellite with generated data and host-side validation is the lower-risk path.**
- **Rust is a good fit for host-side tools**: manifest parser, page/site generator, hash/consistency
  checks and a golden-data test runner. These run on macOS in user space and do not need the kernel
  ABI. If the Rust toolchain is installed, the generator/validator can be written in Rust while the
  kext remains C++.
- Revisit Rust for a kext only if:
  - a minimal no_std Rust object can be linked into a Lilu plugin and loaded on the target macOS;
  - C++ shim boundary is small and stable;
  - Rust code has no allocator, panics, unwinding or floating-point assumptions;
  - it passes the same boot/patch/panic tests as the C++ version.

Decision for this plan: **do not make the satellite Rust**. Use C++ for kernel code; optionally use
Rust for the data generator/validator, subject to a separate toolchain decision.

## 8. Validation matrix

Host-side (implemented; run `python3 tools/test_userpatch_data.py` and
`python3 tools/test_patchdata_selection.py`):

- generator rejects page hash mismatch, ambiguous finds without `findOccurrence`, non-4 KiB pages and
  bad replace lengths;
- independent v1 manifest parser validates magic/version/header size/sizes/FNV checksums/canonical
  ranges/site bytes and rejects malformed data;
- deployed `PatchData/` is regenerated byte-for-byte from the pinned master snapshot
  (`tools/convert_master_patchdata.py --check`), including per-kind VDA/AppleGVA page identity;
- data-level selection matrix per device ID/build/readiness (`tools/test_patchdata_selection.py`);
- cross-check against `master` exact tables for 15.8.1 and the 26.7.1 platform-data pages.

Hardware:

| Test | 15.8.1 Renoir | 14.8.x | 26.7.1 |
| --- | --- | --- | --- |
| satellite loads, no main-kext change | required | required | required |
| unsupported build → no-op | required | required | required |
| GL dual-source pixels | required | if data exists | if data exists |
| Chrome WebGL | required | if data exists | if data exists |
| Zen WebGL | required | if data exists | if data exists |
| QQ image open / Metal | required | if data exists | if data exists |
| VDA hardware decode | required | if data exists | if data exists |
| no NootedRed panic / GPU reset / watchdog | required | required | required |

Rollback:

- remove satellite kext from OpenCore and reboot: main kext must remain fully functional;
- disable satellite with `-NRedUserPatchOff`: no user-space hooks installed.

## 9. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Satellite load order vs main kext VCN readiness | IORegistry property + no-op until ready |
| Wrong build data applied | exact build string + Darwin + APU mask intersection + exact 4 KiB page equality, fail closed |
| Main kext unstable due user-space hooks | hooks live only in satellite; main kext testable without it |
| External data file cannot be read at early boot | install hooks only after data open; retry from service start; no-op fallback |
| Two kexts complicate OpenCore install | separate install section/scripts; satellite optional |
| Rust toolchain complexity | keep kexts C++; Rust only for host tools if approved |
| AI-generated patch data errors | generated from extracted binaries, hashes/site tests, no hand editing |

## 10. Decisions and remaining details

Resolved by user:

1. Data: format A (binary blobs + binary manifest), **embedded at build time**; adding/changing a
   build requires regenerating the blob and rebuilding/re-signing the satellite.
2. Enablement: satellite auto-loads when NootedRed is present; `-NRedUserPatchOff` is a debug override.
3. VDA: all VDA/AppleGVA user-space patches move to the satellite in this project, not deferred.
4. Main kext: original NootedRed logic only; no research-branch policy/database changes in mainline.
5. After the move: code review, then a boot-flow validation from kext load through patch/VDA/rollback.

Resolved during Phase 1:

- no runtime data path: `PatchData/` is source input, `tools/embed_patchdata.py` generates
  `NootedRedUserPatch/PatchDataBlob.*`, and the kext performs no VFS/plist reads;
- binary format: v1, packed little-endian, single `manifest.bin` + `pages.bin`, canonical layout,
  FNV-1a checksums and documented limits — see [`UserPatch-Data-Format.md`](UserPatch-Data-Format.md);
- auto-load: OpenCore `OSBundleLibraries` dependency on `org.ChefKiss.NootedRed`, no boot argument
  required (`-NRedUserPatchOff` only for debugging);
- no `NootedRedUserPatchCtl` helper in this phase: host validation is
  `tools/test_userpatch_data.py` + `tools/convert_master_patchdata.py --check`;
- host tooling stays Python (`tools/`); the Rust generator option is deferred. Kexts remain C++.
