# NootedRed architecture

Status: **authoritative architecture** (2026-10-20). This document supersedes the old in-memory
page-patching design documents in [`archive/`](archive/). The archived documents are kept for history and
are not implementation guidance.

## 1. Scope

NootedRed has two user-visible features that touch Apple binaries:

- **GLFIX** — the Chromium/Electron OpenGL/Metal dual-source fix for GFX9 APUs;
- **VDA/VCN** — hardware H.264/HEVC video decode/encode through the X6000 VCN2 engine.

The kernel-side VCN bridge and the NootedRed X5000/HWLibs work are sound and stay. The user-space part of
the old architecture — an in-memory `_cs_validate_page` page-cache patcher with exact-page tables,
semantic fallback and per-build resolver data — has been tested and does **not** meet the stability bar.
This document replaces it with a two-plane architecture modelled on mature Hackintosh projects.

## 2. What other projects do

### OpenCore Legacy Patcher (OCLP)

OCLP is the reference for **persistent user-space patching** on modern macOS.

- OCLP calls its user-space changes **root patches**: it mounts the APFS root volume read/write (or works
  from the installer/recovery), installs versioned patched kexts/frameworks from its
  **PatcherSupportPkg**, rebuilds the kernel collection with `kmutil`, and blesses a new APFS snapshot
  ([`sys_patch.py`](https://github.com/dortania/OpenCore-Legacy-Patcher/blob/master/opencore_legacy_patcher/sys_patch/sys_patch.py),
  [`docs/PATCHEXPLAIN.md`](https://github.com/dortania/OpenCore-Legacy-Patcher/blob/master/docs/PATCHEXPLAIN.md)).
- It explicitly documents the APFS snapshot rollback path (`bless --last-sealed-snapshot`), QDK/KDK
  merging, preboot/kernel-collection rebuilding and the fact that OS updates require re-patching.
- Patches are **hardware- and OS-build-specific payloads**, not generic runtime guesses. The installer
  verifies the model/build, installs the exact files, and records the state.
- It combines user-space payloads with a small number of kernel patches where required (for example the
  Library Validation enforcement patch used by non-Metal patches), and documents SIP/AMFI implications.
- For graphics it ships patched frameworks/kexts and per-GPU patchsets, rather than a kernel extension
  that rewrites user pages in place.

### FeatureUnlock

FeatureUnlock is the reference for **in-memory page patching done conservatively**.

- It routes `_cs_validate_page` (Big Sur+) / `_cs_validate_range` (older) and patches only after the
  original validation succeeded
  ([`kern_start.cpp`](https://github.com/acidanthera/FeatureUnlock/blob/master/FeatureUnlock/kern_start.cpp)).
- It identifies the target through `vn_getpath` and `UserPatcher::matchSharedCachePath`, or an exact
  executable path for individual bundles.
- It uses small find/replace **data** patterns (model lists, feature gates) with masks, bounded loop
  counts and a time limit, and tracks per-patch “already applied” flags.
- It does not rebuild whole pages from snapshots, does not decode instruction semantics, and does not try
  to discover ABI layouts at runtime.

### Lilu / WhateverGreen

- Lilu is the plugin/platform layer; its process/framework patcher is legacy and can be disabled with
  `-liluuseroff`/`-liluslow` ([Lilu README](https://github.com/acidanthera/Lilu)).
- WhateverGreen and NootedRed's kernel paths prove the preferred model for kernel-visible behavior:
  patch the kext/kernel interface, keep user space untouched, fail closed when the pattern/ABI does not
  match ([WhateverGreen](https://github.com/acidanthera/WhateverGreen)).

### itlwm / AirportItlwm (laobamac fork)

- [`laobamac/itlwm`](https://github.com/laobamac/itlwm) supports macOS Sequoia/Tahoe **without** SIP,
  AMFI, Library Validation or root-patch changes. It is a Wi-Fi **driver kext**, not a patcher: it
  subclasses Apple's `IO80211Controller`/Skywalk interfaces and links against `IO80211Family`.
- Multi-OS support is done with per-OS ABI headers and separate targets: `include/Airport/macOS15` and
  `include/Airport/macOS26`, with `AirportItlwm-Sequoia` and `AirportItlwm-Tahoe` build products and
  matching Info.plists. The kext is injected by OpenCore like any other third-party kext.
- Lesson: per-OS ABI adaptation is robust **when you implement the driver yourself**. It cannot be used
  to change an Apple user-space driver we do not own, which is why GLFIX/VDA still need Plane B (or a
  much larger reimplementation) once user-space code changes are required.

### Common rules

1. **Separate the planes.** Kernel patches live in the kext; code changes in Apple user-space binaries
   live in an explicit root patch, not in a hidden kext hook.
2. **No runtime guesswork.** The exact OS build and binary identity are part of the payload contract.
3. **Always have a rollback.** APFS snapshot/revert for root patches; no irreversible page-cache writes.
4. **Versioned payloads, versioned support.** A new OS build means a new payload and validation record,
   not a widened generic matcher.
5. **Bound the patcher.** Path allowlists, bounded work, explicit enable flags, no patching unrelated
   processes.

## 3. Why the previous in-memory architecture failed

The old design routed `_cs_validate_page`/`_cs_validate_range` from the kext and wrote patched bytes into
the page cache of `AMDRadeonX5000GLDriver`, the Metal driver, `AMDRadeonVADriver2` and AppleGVA. It
accumulated:

- exact 4 KiB page snapshots per build, then a masked-context resolver, then an instruction-semantic GL
  matcher, then per-build VDA tables imported from another fork;
- build-family gates that accepted untested sub-builds;
- no supported rollback: once a page was patched, every process saw it until reboot;
- no way to prove that a patch hit only the intended build/APU;
- data from 14.8.9/15.8.1 mixed into a single runtime selector without hardware validation of every
  combination;
- a per-page hook on the code-signing fast path with shared-cache/page-cache side effects that are
  difficult to reason about and difficult to debug.

The result is what was observed on hardware: context-dependent behavior, instability on some
applications, and a support matrix that cannot be honestly certified. **Fail-closed is necessary but not
sufficient** if the mechanism itself is undocumented and has no rollback.

## 4. Target architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Plane A — NootedRed.kext (Lilu plugin)                                       │
│   • kernel/kext patches only: X5000, HWLibs, AGDP, VCN bridge, DeviceProfile  │
│   • per-build generated ABI data + guards + call-site verification            │
│   • no VFS I/O in patcher-load; no user-space page-cache writes               │
│   • fail-closed; no runtime semantic/ABI guessing                             │
└──────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ provides kernel engine/ABI support
                                   ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Plane B — NootedRedRootPatch (companion tool, OCLP model)                    │
│   • versioned payloads for Apple user-space drivers/frameworks               │
│   • explicit install: verify build/hashes → mount root → install files →     │
│     rebuild kernel/dyld caches as required → snapshot/bless → reboot         │
│   • explicit revert: last sealed snapshot + state cleanup                    │
│   • state file + OS-update detection + re-apply prompt                       │
└──────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ optional, narrow, data-only
                                   ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Plane C — research-only in-memory fallback (FeatureUnlock constraints)       │
│   • only small data/feature-gate patches, never driver code/ABI              │
│   • exact binary path allowlist; bounded loops/time; applied flags           │
│   • off by default; never used by a release payload for GLFIX/VDA            │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Plane A — kernel extension

**Responsibility:** everything the kernel can affect without touching Apple user-space code.

- `VCNBridge`: X5000/X6000 ABI verification, VCN2 engine allocation, X5000 media capability bits.
- `X5000`/`HWLibs`/`AGDP`/`Backlight`/`AppleGFXHDA`/`DriverInjector` existing patches.
- `DeviceProfile`: family/media capability data and canonical logging.
- Per-build generated data (`VCNData/<build>.hpp`): one self-contained table set per supported build,
  selected by exact build string and verified against the live kext;
- no `_cs_validate_page`/`_cs_validate_range` routing for GLFIX/VDA in a release build;
- no user-space page-cache writes.

The kext must stay a **pure kernel plane**: if a feature needs a user-space change, it is disabled until the
root patch is installed, and the IORegistry/log clearly says so.

### Plane B — root patch tool

**Responsibility:** Apple user-space files that cannot be changed safely from the kernel.

- Provide a separate tool/package (working name `NootedRedRootPatch`) with the OCLP workflow:
  1. detect OS build, model/APU, SIP/AMFI/library-validation state;
  2. read the **manifest** for that exact OS build;
  3. verify target file hashes/UUIDs and APU compatibility;
  4. mount the APFS root volume read/write (or operate from the installer/recovery);
  5. install the versioned payload (patched driver bundles/frameworks/kexts) and, where needed, merge the
     KDK and rebuild kernel collections/caches;
  6. create a new APFS snapshot and bless it;
  7. record installed payload IDs + hashes for update/repair detection;
  8. reboot.
- Revert is a first-class operation: APFS last-sealed snapshot + state cleanup, then reboot.
- On macOS updates the tool detects the changed build, marks patches stale, and requires re-apply.
- Root patching is explicit and user-consented; it is never done silently by the kext.

For the two features:

| Feature | Kernel plane | User-space payload |
| --- | --- | --- |
| GLFIX | none beyond existing X5000 | patched `AMDRadeonX5000GLDriver` bundle and the MTL driver image/container as determined by the build |
| VDA/VCN | VCN bridge, engine allocation, media caps | patched `AMDRadeonVADriver2` and AppleGVA images/containers |

**Feasibility gate:** the MTL driver, `AMDRadeonVADriver2` and AppleGVA live in the dyld shared cache on
modern macOS. The root-patch tool must first prove a supported cache strategy for each target OS (for
example replacing the file plus an OS-supported cache rebuild, a cache-split/override strategy, or
narrowing the feature to file-backed bundles). This is a design spike, not something to paper over with
a runtime matcher.

### Plane C — research-only in-memory fallback

Only if a future feature can be expressed as a **small data/feature-gate patch**, a FeatureUnlock-style
hook may be used for research:

- target selection by `vn_getpath` + shared-cache/bundle allowlist;
- masked find/replace patterns, bounded loop count and total time budget;
- per-patch applied flags; no exact page snapshots/semantics/ABI discovery;
- off by default, compile-time gated, and never used by a release payload for GLFIX/VDA.

## 5. Data contracts

The only supported data unit is a **build payload**:

```json
{
  "schema": 2,
  "payload_id": "nred-glfix-15.8.1-20261019",
  "os": { "product": "15.8.1", "build": "24H32", "darwin": [24, 6] },
  "apu": { "families": ["Renoir", "Green Sardine"], "device_ids": [1638] },
  "feature": "GLFIX",
  "level": "validated",
  "source": {
    "binary": "/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver",
    "uuid": "BAD9208B-B99B-3DAA-AA51-15D199498873",
    "sha256": "…"
  },
  "files": [
    {
      "path": "/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver",
      "installed_sha256": "…",
      "mode": "replace",
      "patches": [
        { "name": "HwInfo shadow engines", "offset": "0xe081", "find": "c7477804000000", "replace": "c7477801000000" }
      ]
    }
  ],
  "requires": ["amfi-off", "library-validation-patch"],
  "revert": { "strategy": "apfs-last-sealed-snapshot" }
}
```

Rules:

- one manifest per `product/build` and feature set; immutable once validated;
- exact source hashes/UUIDs recorded; the installer re-verifies them before touching the volume;
- no cross-build reuse; a new OS build is a new payload;
- support level (`validated`, `experimental`, `unsupported`) is data, not prose;
- the generated manifest is checked by CI against stored Apple binaries; a mismatch fails the build;
- the runtime has **no** generic semantic/ABI fallback path. If the manifest does not match, the feature
  is unavailable (fail-closed and visible).

## 6. Lifecycle

```
install:
  detect OS/APU → load manifest → verify hashes → check SIP/AMFI/LV requirements
  → mount root rw → install payload files → KDK merge if needed
  → rebuild kernel collections/caches → create snapshot → bless → record state → reboot

OS update:
  build changed → patch state marked stale → tool prompts → install new build's payload
  (or revert to stock while no payload exists)

revert:
  boot snapshot/recovery → last sealed snapshot → remove state/payloads → reboot

failure:
  verification failure before mount → no change
  install failure → revert snapshot before reboot
  boot failure → last sealed snapshot from recovery
```

## 7. Security and user consent

- Root patching requires explicit user action and a deliberate security reduction: SIP lowered (OCLP uses
  `csr-active-config=0x803`), SecureBootModel Disabled, and Library Validation/AMFI adjustments as required
  by the payload. The exact matrix is in
  [ROOT-PATCH-PIPELINE §7](ROOT-PATCH-PIPELINE.md#7-security-prerequisites).
- The tool must explain the tradeoff and offer revert; it must never change SIP/Secure Boot/AMFI
  silently.
- The kext never writes to disk and never hides user-space modifications; `NRedCompat*`/IORegistry shows
  kernel-plane state, and the root patch tool has its own state file/log.
- APFS snapshots are the rollback contract. No “patch and hope” page-cache writes.
- No patching of unrelated processes/files; path allowlists and hashes are mandatory.
- The support matrix is generated from manifests; no generic “works across versions” claims.

## 8. Versioning and support policy

- Supported macOS builds are explicit: currently `15.8.1 (24H32)` is the validated baseline; other builds
  require their own payload and hardware validation.
- Supported APUs/families come from `DeviceProfile`; a payload may narrow the list further.
- `experimental` means the payload exists but has not passed the full hardware matrix; it is never
  presented as validated.
- An OS update without a payload means the feature is unavailable, not “best effort”.

## 9. Migration plan from the current tree

1. **Documentation (this change).** Archive the old in-memory architecture docs and freeze their claims.
2. **Feasibility spike.** Prove root-patch/dyld-cache strategy for GL/MTL/VA/GVA on 15.8.1 (the validated
   baseline). Decide whether cache-resident images can be replaced safely; if not, narrow the first
   production scope to file-backed bundles + kernel plane.
3. **Disable the generic in-memory release path.** Remove `Patch-Architecture`-era resolver/semantic
   routing and the multi-version VDA page tables from the release kext; keep them only behind a
   compile-time research flag if needed for investigation.
4. **Root patch tool skeleton.** Manifest parser, hash verifier, APFS mount/snapshot, KDK/kmutil/cache
   steps, state file, revert, OS-update detection; no feature-specific hacks.
5. **GLFIX payload first.** One build, one APU set, full install/revert/update test; then VDA payload.
6. **Multi-version payloads.** Only after a build passes hardware validation; add 14.8.9/26.x payloads
   when their binaries and tests exist.
7. **Packaging/CI.** Release kext + root patch tool + payload manifests; CI verifies hashes and manifests;
   hardware test matrix and rollback test are release gates.
8. **Remove archived in-memory code** after the root patch path is stable; keep only kernel-plane code.

## 10. Non-goals

- no generic cross-version binary patching;
- no in-memory instruction-semantic decoder in production;
- no silent disk/page-cache modifications;
- no support claims without a manifest and a hardware test record.

## 11. References

- [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher) —
  [`sys_patch.py`](https://github.com/dortania/OpenCore-Legacy-Patcher/blob/master/opencore_legacy_patcher/sys_patch/sys_patch.py),
  [`PATCHEXPLAIN.md`](https://github.com/dortania/OpenCore-Legacy-Patcher/blob/master/docs/PATCHEXPLAIN.md),
  [`PROCESS.md`](https://github.com/dortania/OpenCore-Legacy-Patcher/blob/master/docs/PROCESS.md).
- [FeatureUnlock](https://github.com/acidanthera/FeatureUnlock) —
  `kern_start.cpp`, `kern_dyld_patch.hpp`, `kern_usr_patch.hpp`.
- [Lilu](https://github.com/acidanthera/Lilu), [WhateverGreen](https://github.com/acidanthera/WhateverGreen).
- [NootedRed](https://github.com/ChefKissInc/NootedRed) upstream.
- Historical NootedRed analysis in the local `../analysis/` directory (not tracked) and the archived docs in
  [`archive/`](archive/).

## 12. Related documents

- [Root patch pipeline design](ROOT-PATCH-PIPELINE.md) — detailed payload/tool contract.
- [Build artifacts](Build-Artifacts.md) — kext build layout.
- [Platform data index](Platform-Data-Index.md) — collected platform data.
- [Archive](archive/) — historical in-memory design documents.
