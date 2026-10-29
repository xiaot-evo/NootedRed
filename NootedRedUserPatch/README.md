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
- Retries the running-build discovery on a bounded cadence: `kern.osversion` is only published when
  launchd (PID 1) writes it during user-space bring-up, which is after the plugin's kernel-phase entry
  points. Discovery retries once a second for up to 40 attempts and then fails closed (see
  [Build identity timing](#build-identity-timing-kernosversion-is-set-by-launchd)).
- May start matching **provisionally** during that discovery window: the injected `NRedSystemBuild`
  hint is accepted only when it is a valid build string and exactly equals the parsed profile build;
  the plugin then publishes `NRedUserPatchIdentityProvisional=1` and keeps retrying. Once the actual
  build is readable it is authoritative: exact equality confirms the state, a disagreement is a hard
  error that revokes the profile and stops any further writes. Invalid or mismatched hints are never
  used.
- Publishes per-page applied diagnostics (`NRedUserPatchAppliedPageMask` hex, plus applied/unapplied
  page index lists) so a record that never got applied can be identified from `ioreg` alone.
- NRPT **v2** profiles additionally carry target-image metadata (image path/kind, unslid VM address and
  size, plus per-page image index and page VmOffset).  The matching engine is **hook-only**: every
  delivered page goes through the same `_cs_validate_page`/`_cs_validate_range` route as before, but a
  v2 page is located by the **real vnode name** of the delivered data (standalone driver basename, or
  `dyld`/`dyld_shared_cache` for cache images) plus its **complete 4 KiB FNV-1a-64 content hash**, not
  by the recorded pager offset.  Pages that already carry all replace bytes (shared page cache, earlier
  validation) are recognised and marked applied without any write.  A page whose content or vnode does
  not match is never written; v1 profiles keep the legacy pager-offset gate.  There is no worker, no
  task tracking, no cross-process map access, and no direct write path.
- Publishes state and counters as IORegistry properties on its own service (see Diagnostics).

Validation hooks never allocate, touch IOKit/VFS or sleep, and their logging is bounded by a shared
budget. Hardware identity (iGPU device ID) is detected once in the sleepable patcher-load callback.

## Profile injection (no runtime file I/O)

The host generator injects one binary profile as the `NRedOffsetProfile` property of the
`org.ChefKiss.NootedRedUserPatch` personality in the kext `Info.plist`, together with the matching
`NRedSystemBuild` string. The committed `Info.plist` intentionally carries **no** profile: without an
injected one the plugin reports `NoOp`/`ProfileAbsent` and writes nothing.  NRPT v1 and v2 profiles
both drive the same validation-hook path; v2's target-image metadata supplies the vnode-name gate and
per-page image association (the records remain part of the frozen profile format for the generator and
offline tooling).

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
| `Loaded` | profile parsed, build/APU/device gates passed, tables published; hooks may now write matching pages. If the build gate is only provisional the diagnostics carry `NRedUserPatchIdentityProvisional=1` until `kern.osversion` confirms it. |
| `NoOp` | fail-closed terminal state (`ProfileAbsent`, `ProfileInvalid`, `BuildUnavailable`, `BuildMismatch`, `ApuUnavailable`, `ApuMismatch`, `DeviceMismatch`). Nothing is written. A `NoOp`/`BuildMismatch` reached after a provisional activation is a **revocation**: the hooks stop writing immediately, but pages already written earlier in the boot cannot be rolled back and stay reported. |

Entry points:

| Entry point | What it does |
| --- | --- |
| plugin kmod start (`init`) | allocates the state lock and registers the Lilu patcher-load callback. No IOKit/VFS work. |
| Lilu patcher load (`onPatcherLoad`) | if the IOKit service instance is already visible: copies/validates the injected profile **before** routing the validators, detects the running iGPU identity from Lilu's cached `DeviceInfo`, resolves the running build / provisional hint, and may activate matching before any page can be validated. Then installs both routes unconditionally (deferred otherwise). |
| `IOService::start` | fallback profile load point (used when the service instance was not visible at patcher load): copies/validates the injected profile, resolves the running build, completes the transition if hardware identity is already known, publishes diagnostics. |
| identity `thread_call` | bounded 1 s running-build discovery retry (launchd publishes `kern.osversion` after the kernel-phase entry points); stops on resolution, on a NoOp verdict, or after 40 attempts when it fails closed. |
| diagnostics `thread_call` | bounded refresh schedule (applied counters only). |

Both entry points may run in either order; the profile transition happens exactly once, when the
profile and all identity gates are known. If both entry points ran and the authoritative running build
is still unreadable, the plugin reports `NoOp`/`BuildUnavailable` instead of guessing.

## Build identity timing (`kern.osversion` is set by launchd)

In XNU the kernel build string is **not** present during kernel initialization:

- `libkern/version.c`'s `osversion` buffer is zero-initialized and is written by user space; `kern.osversion`
  is a writable `SYSCTL_PROC` (`bsd/kern/kern_sysctl.c`) whose write handler also calls
  `IORegistrySetOSBuildVersion()` to publish the IODeviceTree root `OS Build Version` property.
- launchd (PID 1) performs that single write once during early user-space bring-up, after all kext
  personality starts and patcher-load callbacks (which run during kernel initialization) have returned.

Because a page faulted while the profile is inert has its validation result cached by the kernel and
is never presented to the hooks again, the injected profile is copied/validated at the earliest point
where the IOKit service instance is visible (normally the Lilu patcher-load callback, *before* the
code-signing routes are installed); `IOService::start` remains the fallback.  The load stage is
published as `NRedUserPatchProfileLoadStage`.  The engine treats the actual build as a discovery that
may complete late: the entry points attempt it once, and if no source is readable yet a bounded
`thread_call` chain retries once per second (up to 40 attempts). While the build is unresolved the profile is parsed but not
active, so no page is written. `NRedSystemBuild` is never used to fill this gap; it can only reject on
mismatch. After the retry budget is exhausted the plugin fails closed with
`NoOp`/`BuildUnavailable` and records the last observed values of all three sources in the diagnostics
properties (`NRedUserPatchDeviceTreeBuild`, `NRedUserPatchSysctlBuild`, `NRedUserPatchXnuBuild`,
`NRedUserPatchBuildSource`, `NRedUserPatchIdentityAttempts`).

Pages that user space faulted before the identity resolved are not patched again. To close that
window the plugin accepts the injected `NRedSystemBuild` as **provisional** identity while the actual
build is still unreadable, but only when the hint is valid, non-empty and exactly equal to the parsed
profile build; that state is published as `NRedUserPatchIdentityProvisional=1`. The discovery retries
continue in the background:

- actual build readable and equal to the profile build: the provisional state is promoted to confirmed
  (`IdentityProvisional=0`), nothing is re-applied;
- actual build readable and different: hard error, the profile is revoked (`NoOp`/`BuildMismatch`),
  all future hook writes stop; pages already written during the provisional window are reported and
  cannot be rolled back because the original bytes were replaced in the pager;
- actual build never becomes readable inside the 40-attempt budget: fail closed
  (`NoOp`/`BuildUnavailable`), same revocation rules.

An invalid or mismatched hint is never stored or used; a mismatched hint can only produce a hard error
once the actual build is readable. The actual `kern.osversion` build is always authoritative for the
final state.

## Per-page runtime diagnostics (no acceptance effect)

The validation hooks additionally record, for every profile page record, whether its full-page content
hash was ever observed and at which pager offset.  This does not change matching or writing: acceptance
still requires the offset gate (when configured) + full-page hash + every site find, and a rejected
delivery stays a silent no-op.  The purpose is to decide from a single `ioreg` dump why a record never
applied:

| Observation | Meaning |
| --- | --- |
| applied bit set | record applied normally |
| `offsetMismatch` bit set | hash matched, but the record's required `pageFileOffset` differs from the pager offset the kernel reported — the `ObservedPageOffsets` entry shows the offset that was actually delivered (offset-namespace mismatch, not content) |
| hash observed, no offset mismatch, not applied | hash and offset matched but a site find or the write failed (`FindMismatches`/`WriteFailures` tell which) |
| `offsetSeen` bit set, hash never observed | the exact expected pager offset was delivered but the 4 KiB content differs (content/build mismatch) |
| neither bit | no chunk with the expected pager offset and no matching content was ever delivered — the page was not presented to the validator (still requires offset gating; offset-free records report `unobserved`) |

When a chunk arrives at a record's **exact required pager offset**, the engine additionally records the
actual delivered FNV-1a-64 and how many of that record's generated site `find` bytes matched, even when
the full-page hash differs (bounded: up to four distinct hashes per record, independent of the
content-observation budget above):

| Expected-offset evidence | Meaning |
| --- | --- |
| all site finds matched for a recorded actual hash | the delivered page is almost certainly the target page with other bytes changed (partial content drift / another build's page), not an unrelated file |
| no site finds matched | an unrelated page happens to live at the same pager offset (offset collision), so the "content mismatch" classification is a collision artifact, not a target-page problem |
| `NRedUserPatchExpectedOffsetActualHashes` (`index:0xHASH`) | the actual delivered page hashes; search them with `tools/find_nrpt_page_origin.py` to identify the source image/file offset/page |

`NRedUserPatchUnappliedPageDiagnostics` collapses the mask observations into `index:reason` pairs
(`offsetMismatch`, `siteOrWriteMismatch`, `contentMismatch`, `neverPresented`, `unobserved`).
Content-observation hashing for diagnostics is **bounded**: it runs only while not every record has
been observed and stops after `kDiagnosticsChunkBudget` (65536) delivered chunks, so a record that
never appears cannot impose unbounded per-page hashing cost.  Acceptance hashing is not affected by
this budget.  Formatting happens only in the IORegistry publication context; the hooks only update
atomics and masks.

### Identifying delivered page origins offline

`tools/find_nrpt_page_origin.py` searches candidate driver/dyld-cache images (or an explicit fixture
directory) for 4 KiB-aligned pages whose FNV-1a-64 equals the values in
`NRedUserPatchExpectedOffsetActualHashes`, and prints file/offset/page index plus the profile's
expected hash for that record.  It is read-only evidence collection and does not affect the kext:

```sh
ioreg -l -n NootedRedUserPatch > /tmp/nootedred-ioreg.txt
tools/find_nrpt_page_origin.py --ioreg-file /tmp/nootedred-ioreg.txt \
    --profile build/profile-24H232/nred-24H232.nrpt
# or explicit candidates:
tools/find_nrpt_page_origin.py --hashes "0:0x..." --image /path/to/binary --image-dir fixtures/15.8.2-clean
```

With no explicit candidates it auto-discovers the installed AMD driver bundles and x86_64h dyld shared
cache files (read-only).  A hash that is not a clean on-disk page (e.g. already patched or generated in
memory) is reported as "not found".

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
| `NRedUserPatchBuildSource` | first running-build source that resolved (`deviceTree`, `sysctl`, `xnu`) |
| `NRedUserPatchDeviceTreeBuild` / `NRedUserPatchSysctlBuild` / `NRedUserPatchXnuBuild` | last observed value of each source (`none` when unreadable/invalid) |
| `NRedUserPatchIdentityResolved` / `NRedUserPatchIdentityAttempts` | running-build discovery state and attempt count |
| `NRedUserPatchDataSource` | `personality:NRedOffsetProfile` after a successful parse, else `none` |
| `NRedUserPatchErrorCode` / `NRedUserPatchErrorContext` | stable `E0xx` code and short field context (`none` when not applicable) |
| `NRedUserPatchApuMask` / `NRedUserPatchDeviceID` | identity fields from the profile |
| `NRedUserPatchPages` / `NRedUserPatchSites` | validated page/site counts |
| `NRedUserPatchHooks` | `1` when the `_cs_validate_page` route is installed |
| `NRedUserPatchRangeHook` | `1` when the `_cs_validate_range` route is installed |
| `NRedUserPatchLoaded` | `1` once the profile is active and hooks may write |
| `NRedUserPatchAppliedPages` | pages patched exactly once (expected to reach `Pages` after all target pages fault) |
| `NRedUserPatchAppliedPageMask` | 64-bit hex bitmap of applied profile page records (bit *i* = record *i*); four words are emitted for the 256-record v1 limit |
| `NRedUserPatchAppliedPageList` / `NRedUserPatchUnappliedPageList` | comma-separated applied/non-applied record indices (`none` when empty) — identifies records that never faulted/applied |
| `NRedUserPatchIdentityProvisional` | `1` while matching is allowed only by the validated `NRedSystemBuild` hint, before `kern.osversion` confirms it |
| `NRedUserPatchProfileLoadStage` | where the injected profile was copied/validated: `patcherLoad` (before validators were routed), `serviceStart` (fallback), `absent`, or `none` |
| `NRedUserPatchObservedHashPageMask` / `NRedUserPatchObservedHashPages` | records whose full-page hash matched at some delivered chunk, at any pager offset |
| `NRedUserPatchOffsetMismatchPageMask` / `NRedUserPatchOffsetMismatchPages` | records whose hash matched but whose `REQUIRE_OFFSET` gate rejected the delivery (offset namespace mismatch) |
| `NRedUserPatchOffsetSeenPageMask` / `NRedUserPatchOffsetSeenPages` | records for which a chunk with exactly the required `pageFileOffset` was delivered |
| `NRedUserPatchObservedPageOffsets` | first pager offset at which each record's content was observed (`index:0xOFFSET` or `index:none`) |
| `NRedUserPatchUnappliedPageDiagnostics` | decisive classification of every unapplied record (see below) |
| `NRedUserPatchOffsetMismatchEvents` / `NRedUserPatchPendingObservations` | offset-gate rejections observed and records still never observed |
| `NRedUserPatchExpectedOffsetSeenPageMask` | records for which at least one chunk was delivered at exactly the required `pageFileOffset` |
| `NRedUserPatchExpectedOffsetActualHashes` | actual delivered FNV-1a-64 per exact-offset delivery (`index:0xHASH`, up to four distinct hashes per record) |
| `NRedUserPatchExpectedOffsetSiteFindCounts` | generated site finds that matched in that delivered chunk (`index:matched/total`) |
| `NRedUserPatchSiteFindAtExpectedOffsetPages` / `NRedUserPatchSiteFindAtExpectedOffsetCount` | records where an exact-offset delivery still matched every site find (content drift rather than offset collision) |
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
| `BuildUnavailable` | authoritative running build still unreadable after the bounded discovery retries, or the sources conflict; the per-source `NRedUserPatch*Build` diagnostics show what was last observed |
| `BuildMismatch` | profile build != running `kern.osversion`, or the injected `NRedSystemBuild` hint disagrees with it. When this happens after a provisional activation the profile is revoked: writes stop, early writes stay reported (never rolled back) |
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
- First hardware boot of the profile-driven package (2026-10-29, 15.8.2 / 24H232 / Renoir 0x1638)
  reached the engine with the injected profile parsed (13 pages / 18 sites), APU/device identity
  detected, both routes installed, and correctly failed closed at the running-build gate
  (`NoOp`/`BuildUnavailable`). Root cause was the missing identity retry: at the plugin's kernel-phase
  entry points `kern.osversion` had not been written yet by launchd. The fix adds the bounded 1 s
  discovery retry and the per-source diagnostics above; it still never accepts `NRedSystemBuild` in
  place of the actual build. Re-validation on hardware is pending (Lead-owned).
- Second hardware boot (2026-10-29, 15.8.2 / 24H232 / Renoir 0x1638) after the identity retry:
  **PASS** — `State=Loaded`, `IdentityResolved=1`, `BuildSource=sysctl`, `IdentityAttempts=3`,
  13 pages / 18 sites parsed, 9 pages applied after Metal+GL+QQ probes, `FindMismatches=0`,
  `WriteFailures=0`, `RangeHook=1`; H.264 and HEVC VideoToolbox encode passed and QQ stayed stable.
  The 4 unapplied records were faulted during the ~3 s pre-identity window and were permanently
  skipped (page results are cached by the kernel). The provisional mode above closes that window on a
  normal boot; the new applied-mask/list properties identify any record that still never applies.
- Third hardware boot with the provisional-identity package: `Loaded`, `IdentityProvisional=0`,
  applied records `1,3,4,5,6,7,8,12` (8/13), unapplied `0,2,9,10,11`, `FindMismatches=0`; GL probe,
  H.264/HEVC encode, AVFoundation decode and QQ/Metal did not cover the remaining records.  The
  per-page runtime diagnostics above were added to classify those records from the next boot instead of
  guessing (never presented vs offset mismatch vs content mismatch).
- Fourth hardware boot with the per-page diagnostics: pages `0,2,9,10,11` were delivered at their
  expected pager offsets but their full-page hash did not match the profile (contentMismatch);
  `OffsetMismatch` was empty and `PendingObservations=5`.  The expected-offset content evidence above
  (actual delivered hashes + site-find match counts) and the
  `tools/find_nrpt_page_origin.py` scanner were added so those 5 pages can be classified and traced to
  their source image offline without another purpose-built kext.
- Host-side offline tests for the expected-offset evidence (7 scenarios: evidence on content
  mismatch, partial/all site-find matches, duplicate-hash dedupe and four-slot cap, required-offset
  gating, evidence still recorded after the content-observation budget is exhausted, acceptance
  regression) pass against the real `PatchProfile.cpp`.
- Host-side offline tests for the per-page runtime diagnostics (8 scenarios: observation at the wrong
  offset with retained first offset, content mismatch at the expected offset, never-presented,
  applied-is-observed, offset-free records, bounded diagnostics chunk budget, provisional revocation,
  find-mismatch atomicity) pass against the real `PatchProfile.cpp`.
- Host-side offline tests for the provisional identity transition (14 scenarios: provisional
  accept/confirm/revoke, invalid and mismatched hints, revocation stops future writes but keeps early
  writes, hint disagreement, applied-mask words, hash/find mismatch no-write) pass against the real
  `PatchProfile.cpp` with stub Lilu headers.
- Root-cause refinement under test: pages that were never delivered to the validators were probably
  faulted before the profile became active at `IOService::start`, so their cached validation result
  prevented any later matching.  The profile is now copied/validated in the patcher-load callback
  (before routing) and `NRedUserPatchProfileLoadStage` reports where it happened
  (`patcherLoad`/`serviceStart`/`absent`).  A boot with `ProfileLoadStage=patcherLoad` and
  `IdentityProvisional=1` from the start is expected to capture the previously missing records.
- Host-side NRPT v2 parser tests pass against the real `PatchProfile.cpp`: v1 profile still accepted
  (hook-only, no direct metadata), a generated 13-page/18-site/4-image v2 profile accepted with
  `directTargetsAvailable()`, and crafted mutations rejected with the expected `E034`/`E036`/`E037`/
  `E038`/`E039`/`E040` codes.  The official generator-emitted v2 profile for 24H232 (2776 bytes,
  13 pages / 18 sites / 4 images, deterministic, with per-page target-image evidence) is validated
  against this parser: its page identity fields and site table are byte-identical to the canonical v1
  profile and every `(imageIndex, pageVmOffset)` re-resolves inside the declared image extent.  The
  direct-patch package injects that official profile.
- The direct-map backend (workers, cross-process `vm_map_*`, watchdog respawn) was removed after the
  panic-risk audit (`analysis/directpatch-panic-audit.md`): shared verify/write buffers across respawned
  workers, unbounded blocking cross-task kernel calls, no shutdown quiescence and a task/map teardown
  race are all gone from this directory.  Hook-only matching was aligned with the native backend design
  (`analysis/upstream-native-backend-comparison.md`): vnode-name gate from the real hook argument,
  complete 4 KiB content identity, no pager-offset requirement, already-patched detection.  The GL
  pages that failed before were delivered at a different pager offset and/or already patched in the
  shared page cache; both cases are handled without any direct memory write.
- This revision has **not** been boot-tested after the hook-only matching changes.  Expected boot:
  `NRedUserPatchVnodeGate=active`, `AppliedPages=13`, `FindMismatches=0`, `WriteFailures=0`, with
  `NRedUserPatchHashOnlyAppliedPages` / `NRedUserPatchAlreadyPatchedPages` explaining the pages the old
  pager-offset gate rejected.  The hook path remains the only write path; no EFI/deployment is done by
  this directory.

## Source layout

| File | Purpose |
| --- | --- |
| `Plugin.cpp` | `PluginConfiguration`, own `IOService`, locked runtime orchestration, bounded running-build discovery retry with per-source diagnostics, bounded counter refresh, IORegistry properties |
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
  boot; pages faulted before the profile activates are not retried. With provisional identity the
  activation window is normally the first plugin entry point, but pages faulted even earlier (before
  the plugin's kernel-phase start) still cannot be re-patched.
- The provisional mode means early pages can be written before the actual build is confirmed. The hint
  must equal the profile build and any later disagreement revokes matching, but bytes already written
  in that window are not rolled back (impossible without the original page bytes). The applied-page
  diagnostics record exactly what was written.
- `NRedUserPatchAppliedPageMask` is emitted as up to four 64-bit hex words (256 records); per-index
  lists are bounded and truncate for pathological profiles.
- Per-page content observations are stopped after `kDiagnosticsChunkBudget` delivered chunks (and once
  every record has been observed).  A page faulted after that window is still applied normally if it
  matches; it just is not added to the observation diagnostics.
