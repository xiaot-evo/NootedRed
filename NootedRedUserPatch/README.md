# NootedRedUserPatch

Satellite Lilu plugin for NootedRed. It owns the **user-space** AMD graphics/media patch backend:
the `_cs_validate_page` / `_cs_validate_range` hooks and the per-page patch matcher.

Status: **generic profile-driven engine (NRPT v1), built in release and debug**. The kext contains
**no patch data**: page offsets, page hashes, site offsets and find/replace bytes all come from an
injected profile. Nothing in this directory has been boot-tested on real hardware yet; a successful
build and the offline engine tests below are not evidence of a working hardware patch set.

Contracts:

- profile format: [`docs/PatchProfile-Spec.md`](../docs/PatchProfile-Spec.md) (NRPT v1, frozen);
- page-validation ABI and `page_offset` semantics: [`analysis/xnu-lilu-page-validation.md`](../analysis/xnu-lilu-page-validation.md);
- target architecture/rationale: [`analysis/lilu-dyld-shared-cache-profile-engine.md`](../analysis/lilu-dyld-shared-cache-profile-engine.md).

## What it does

- Installs both code-signing routes at Lilu patcher load, before any page validation can run:
  `_cs_validate_page` (7-argument `void` with `int *validated`, `*tainted`, `*nx` on macOS 15) and
  `_cs_validate_range` (6-argument `boolean_t`). Each route is installed independently; a missing
  symbol disables that path only and is reported in the diagnostics.
- Copies and fully validates the `NRedOffsetProfile` `OSData` property in `IOService::start`: NRPT
  header/build/APU/device/counts/table sizes/payload FNV-1a-32 checksum, canonical page/site ranges,
  bounds, padding and identity uniqueness. The parsed page/site records are copied into bounded static
  arrays; the `OSData` bytes are removed and never referenced again.
- Applies a page only when the original validator accepted it and every enabled identity gate of an
  authoritative record passed: exact chunk offset (when required), FNV-1a-64 over the complete 4 KiB
  chunk, and every site `find` byte at its recorded `siteInPage`. All writes of one page happen
  together under `MachInfo::setKernelWriting` and only after all gates passed.
- Applies each page record at most once per boot (atomic applied bitmap), so shared page caches and
  page/range double delivery cannot write twice.
- Fails closed: a missing, malformed, wrong-build or wrong-APU profile leaves the plugin loaded and
  the hooks inert. There is no fallback profile, no family/prefix build match, no byte scan and no
  guessed offset. The running `kern.osversion` build is authoritative; `NRedSystemBuild` is only an
  extra sanity check and can never replace that comparison.
- Publishes state and counters as IORegistry properties on its own service (see Diagnostics).

Validation hooks never allocate, touch IOKit/VFS or sleep, and their logging is bounded by a shared
budget. Hardware identity (iGPU device ID) is detected once in the sleepable patcher-load callback.

## Profile injection (no runtime file I/O)

The host generator injects one binary profile as the `NRedOffsetProfile` property of the
`org.ChefKiss.NootedRedUserPatch` personality in the kext `Info.plist`, together with the matching
`NRedSystemBuild` string. The committed `Info.plist` intentionally carries **no** profile: without an
injected one the plugin reports `NoOp`/`ProfileAbsent` and writes nothing.

- The profile is generated and offline-validated by the NootedRedTool pipeline; see
  `docs/PatchProfile-Spec.md` §12/§13 and the `NootedRedTool` profile generator/validator.
- The kext never reads a file, a directory, the boot arguments or the IORegistry for patch data.
- A new macOS build needs a new generated profile, **not** a new kext binary. The kext must be
  re-signed only when its own code changes.

## Build

Requirements: macOS, Xcode Command Line Tools, `xmake`, and a sibling AppleForge checkout with its
`Lilu` and `MacKernelSDK` submodules initialised. `xmake.lua` includes AppleForge from the
`AppleForgePath` environment variable, or `../AppleForge` when unset.

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export AppleForgePath=/path/to/AppleForge
export XMAKE_STATS=false

xmake f --project=. -m release -y && xmake --project=. -y NootedRedUserPatch
xmake f --project=. -m debug   -y && xmake --project=. -y NootedRedUserPatch
```

Artifacts:

```
build/branches/<branch>/macosx/x86_64/userpatch/release/NootedRedUserPatch.kext
build/branches/<branch>/macosx/x86_64/userpatch/release/NootedRedUserPatch-<version>-RELEASE.zip
build/branches/<branch>/macosx/x86_64/userpatch/debug/NootedRedUserPatch.kext
build/branches/<branch>/macosx/x86_64/userpatch/debug/NootedRedUserPatch-<version>-DEBUG.zip
```

**Git-worktree note.** xmake 3 resolves the *outermost* ancestor `xmake.lua` as the project. If this
tree is a git worktree nested inside another xmake checkout, pin the project explicitly with
`--project=.` as shown above.

`NootedRedUserPatch.kext` is built with AppleForge (`LiluPlugIn`) and a Catalina deployment target
(`10.15`); `PluginConfiguration` restricts loading to `KernelVersion::Catalina .. KernelVersion::Tahoe`.
`NootedRedUserPatch/**.cpp` is globbed by the target, so adding/removing a source file needs no
`xmake.lua` change.

## Installing

This directory does **not** install kexts or reboot anything. Manual install outline (OpenCore):

1. Keep the main kext installed. `Lilu.kext` and `NootedRed.kext` are required; the satellite declares
   `NootedRed` as a library dependency and will not load without it.
2. Generate a profile for the exact running macOS build and inject it as `NRedOffsetProfile` (plus
   `NRedSystemBuild`) into the satellite's `Info.plist` personality, then copy `Lilu.kext`,
   `NootedRed.kext` and `NootedRedUserPatch.kext` into `EFI/OC/Kexts/`.
3. Add `NootedRedUserPatch.kext` to `Kernel -> Add` in `config.plist` (`Enabled = true`,
   `BundlePath = NootedRedUserPatch.kext`). Lilu must load first; the kernel resolves the NootedRed
   dependency regardless of entry order.
4. Reboot and verify: `ioreg -l -n NootedRedUserPatch | grep NRedUserPatch`.
5. Rollback: remove the `NootedRedUserPatch.kext` entry from `config.plist` and the file from
   `EFI/OC/Kexts/`, or boot once with `-NRedUserPatchOff`. The main kext must remain fully functional
   with the satellite absent; that is the primary rollback path.

## Runtime states

Serialised by one `IOLock`; validation hooks never take it (they only acquire-load the immutable
published flag and update atomics).

| State | Meaning |
| --- | --- |
| `Idle` | kmod/plugin started; profile or runtime identity not complete yet, or hooks not yet reached. |
| `Loaded` | profile parsed, build/APU/device gates passed, tables published; hooks may now write matching pages. |
| `NoOp` | fail-closed terminal state (`ProfileAbsent`, `ProfileInvalid`, `BuildUnavailable`, `BuildMismatch`, `ApuUnavailable`, `ApuMismatch`, `DeviceMismatch`). Nothing is written. |

Entry points:

| Entry point | What it does |
| --- | --- |
| plugin kmod start (`init`) | allocates the state lock and registers the Lilu patcher-load callback. No IOKit/VFS work. |
| Lilu patcher load (`onPatcherLoad`) | installs both routes unconditionally, detects the running iGPU identity from Lilu's cached `DeviceInfo`, resolves the running build, and completes the profile transition if the profile is already loaded. |
| `IOService::start` | copies/validates the injected profile, resolves the running build, completes the transition if hardware identity is already known, publishes diagnostics. |
| delayed `thread_call` | bounded diagnostics refresh schedule (applied counters only). |

Both entry points may run in either order; the profile transition happens exactly once, when the
profile and all identity gates are known. If both entry points ran and the authoritative running build
is still unreadable, the plugin reports `NoOp`/`BuildUnavailable` instead of guessing.

## Diagnostics

Log tags: `init` (plugin lifecycle/identity), `PatchEngine` (profile parse/identity decisions),
`UserPatch` (routes and page application). Fail-closed decisions log one specific line, including the
stable `E0xx` profile error code from `docs/PatchProfile-Spec.md` §11.

IORegistry properties on the `NootedRedUserPatch` service:

| Property | Meaning |
| --- | --- |
| `NRedUserPatchState` | `Idle` / `Loaded` / `NoOp` |
| `NRedUserPatchReason` | last fail-closed reason (see Runtime states) |
| `NRedUserPatchBuild` | active/expected profile build string |
| `NRedUserPatchDataSource` | `personality:NRedOffsetProfile` after a successful parse, else `none` |
| `NRedUserPatchErrorCode` / `NRedUserPatchErrorContext` | stable `E0xx` code and short field context (`none` when not applicable) |
| `NRedUserPatchApuMask` / `NRedUserPatchDeviceID` | identity fields from the profile |
| `NRedUserPatchPages` / `NRedUserPatchSites` | validated page/site counts |
| `NRedUserPatchHooks` | `1` when the `_cs_validate_page` route is installed |
| `NRedUserPatchRangeHook` | `1` when the `_cs_validate_range` route is installed |
| `NRedUserPatchLoaded` | `1` once the profile is active and hooks may write |
| `NRedUserPatchAppliedPages` | pages patched exactly once (expected to reach `Pages` after all target pages fault) |
| `NRedUserPatchFindMismatches` | identity matched but a site `find` did not (`0` in a healthy boot) |
| `NRedUserPatchMatchedPages` | page identity matches observed in the validation hooks |
| `NRedUserPatchChunkCalls` | 4 KiB chunks examined by the matcher |
| `NRedUserPatchWriteFailures` | `setKernelWriting` enable/restore failures (`0` in a healthy boot) |

## Failure paths

Every one of these is an expected, safe state: the plugin stays loaded, the routes stay installed and
no page is written.

| Reason | Cause |
| --- | --- |
| `ProfileAbsent` | no `NRedOffsetProfile` property injected (there is no fallback) |
| `ProfileInvalid` | full profile rejection: see `NRedUserPatchErrorCode` (`E001`-`E032`); no partial state survives |
| `BuildUnavailable` | authoritative running build unreadable/conflicting from the device-tree `OS Build Version`, `kern.osversion` sysctl and XNU `osversion` sources |
| `BuildMismatch` | profile build != running `kern.osversion`, or the injected `NRedSystemBuild` hint disagrees with it |
| `ApuUnavailable` | iGPU missing or unknown device ID — running APU family cannot be determined |
| `ApuMismatch` | `profile.apuMask` does not intersect the detected APU family |
| `DeviceMismatch` | profile header bit 0 requires an exact iGPU PCI device ID and it differs from the running one |

`-NRedUserPatchOff` is not a runtime reason: Lilu rejects the plugin before it starts.

## Verification performed for this revision

- `xmake` release and debug builds of `NootedRedUserPatch` are green with no warnings; artifact
  SHA-256 values are reported with the task hand-off (see `build/` for the exact kext/zip files).
- The binary audit is clean: no page offsets, page hashes, find/replace constants, `NRPD`/`PatchData`
  strings or per-build tables are compiled into the kext; only generic parser/matcher/identity code.
- The engine was exercised offline with a temporary host harness (56 scenarios) covering: a golden
  NRPT profile generated by an independent encoder (and confirmed byte-identical by the reference
  `ProfileCodec.swift`), every `E001`-`E032` rejection path, identity gate order (build/APU/device),
  offset-gated and offset-free matching, full-page hash mismatch, atomic no-partial-page find mismatch,
  applied-once behaviour, range chunking and trailing-partial-chunk handling.
- This revision has **not** been boot-tested. The next step is the offline-validator/package task and
  then a hardware boot with `NRedUserPatchState`/`NRedUserPatchAppliedPages` verification.

## Source layout

| File | Purpose |
| --- | --- |
| `Plugin.cpp` | `PluginConfiguration`, own `IOService`, locked runtime orchestration, build identity resolution, bounded diagnostics refresh, IORegistry properties |
| `PatchProfile.hpp/.cpp` | generic NRPT parser/validator, identity gates, bounded page/site tables, chunk matcher, atomics, bounded hook logging |
| `UserPatchBackend.hpp/.cpp` | `_cs_validate_page` / `_cs_validate_range` routing, 7-argument page wrapper, 6-argument range wrapper, one-shot iGPU identity detection |
| `Info.plist` | bundle identifier, Lilu + NootedRed dependencies, IOKit personality (profile injected at deploy time) |

## Known limitations

- Not boot-tested yet; offline engine tests and a green build only.
- A missing/invalid profile is a fail-closed `NoOp`: the satellite does nothing until the NootedRedTool
  pipeline injects a profile for the exact running build.
- APU/device identity is validated, but the actual patch safety identity is the full-page hash plus the
  site finds; the profile is generated per APU family union (v1 has no per-APU page subsets).
- The applied-page bitmap is one bit per profile page record, so a page record patches at most once per
  boot; pages faulted before the profile activates are not retried.
