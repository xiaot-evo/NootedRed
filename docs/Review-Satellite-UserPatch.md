# Code review and boot-flow validation — NootedRedUserPatch satellite

> Historical review: this report describes the external-PatchData generation reviewed at commit
> `ab2afc9`. The external runtime loader was later replaced by embedded static data after a proven
> early-boot VFS hang; see the fix-verification addendum and the current
> [modules/support document](MODULES-AND-SUPPORT.md). Keep this as review history, not as current
> deployment instructions.

Review date: 2026-10-23. Reviewer: verifier (independent review, task-4).

Branch: `research/satellite-userpatch`, 7 commits on top of `master` `0efa6f4`. Reviewed tree:
`HEAD` `ab2afc9` ("NootedRed: remove user-space patching and publish VCN readiness"), clean working tree.
Related contract documents reviewed: `docs/Satellite-UserPatch-Plan.md`,
`docs/UserPatch-Data-Format.md`.

Scope: review only. No mainline/satellite/tool source was modified by this task; this report is the only
file written. No kext was installed, no boot argument was changed and the machine was not rebooted.

**Bottom line:** the split is structurally correct. The main kext is clean, the satellite's exact-page
backend is conservative and fail-closed, the data-format implementation matches its contract, and all
xmake modes build. It is **not** end-to-end validated: nothing that requires `_cs_validate_page` to
actually run in a fresh boot has been observed, no deployable patch data (in particular **no VDA /
AppleGVA data at all**) is shipped, and two boot-timing/threading risks need a real reboot to resolve.
No claim of hardware stability is made.

---

## 1. Verdict per invariant

| # | Invariant | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | Main `NootedRed` has no user-space `_cs_validate*` hooks, no GL/Metal/VDA page tables, no research-branch policy/APU-DB/semantic code | **PASS** | `git diff master..HEAD -- NootedRed/` is 12 deletions + `NRed.cpp`/`VCNBridge.cpp` edits only; no file added under `NootedRed/` except the readiness publication. `strings` of the built `release` kext: **0** matches for `cs_validate|UserPatch|GLFix|VDAVAData|TahoePatchData|NRPD`. `grep -rn "_cs_validate\|UserPatches\|GLFixSemantic\|VDA*Data" NootedRed/` returns nothing. No research APU database/policy import added. |
| 2 | Satellite auto-loads only when `NootedRed` is present; `-NRedUserPatchOff` disables it | **PASS** (static) | `NootedRedUserPatch/Info.plist:43-63` declares `org.ChefKiss.NootedRed = 0.9.0` in `OSBundleLibraries` (same version as the built main kext; both 0.9.0). `-NRedUserPatchOff` is both the Lilu disable arg (`Plugin.cpp:219-232`) and checked defensively (`Plugin.cpp:116-122`); when Lilu rejects the plugin its `pluginStart` never runs, so no data is read and no route is installed. Not observed on hardware. |
| 3 | External data selection is fail-closed (exact build/Darwin/APU, checksums, canonical layout, site offsets; no boot-arg path; missing/malformed = no hooks/no patches) | **PASS** with minor deviations (D11) | `PatchData.cpp:107-316` selects `<fixed root>/<kern.osversion>/`, requires exact `build`, Darwin major/minor/patch, APU-mask intersection, both FNV checksums, v1 record layout/limits and canonical contiguous table ranges (`parseManifest`, `318-461`); any failure → `setNoOp` (frees buffers, state `NoOp`) and `ensure()` only installs hooks when `loaded()` (`Plugin.cpp:145-161`, `UserPatchBackend.cpp:42-48`). Path is a compile-time constant (`PatchData.cpp:47`); the only boot args are Off/Debug/Beta. Parser↔doc cross-check found no fail-open divergence; deviations are cosmetic/documented (see D11). |
| 4 | Exact-page backend compares complete 4 KiB images, verifies find bytes at declared offsets before any write, restores kernel write protection, no semantic scanner, no retained/deferred shared-cache pointer | **PASS** | `UserPatchBackend.cpp:97` full-page `memcmp`; `131-162` verify every site's `find` at its authoritative `offset` *before* toggling WP, then write all sites under `MachInfo::setKernelWriting(true/false, KernelPatcher::kernelWriteLock)`; no page/vnode/pager pointer is stored; no search/scan; `isPatchedPage` (`164-191`) only re-identifies an already-patched page. No deferred `thread_call`/write exists anywhere in `NootedRedUserPatch/`. Caveat: the backend is entered from more than one context and its bookkeeping fields are not atomic (D4, D5), but that does not weaken the byte-level write gate. |
| 5 | VDA/AppleGVA pages gate on `NRedVCNBridgeReady`; GL/Metal independent. Publication and lookup agree on name/location/value/timing | **PASS** (contract) / timing open | Main publishes `NRedVCNBridgeReady` = 32-bit 1/0 on the AMD iGPU `IOPCIDevice` via `NRed::setProp32` (`VCNBridge.cpp:118-133,264,310,328,472`); satellite scans `IOPCIDevice` (vendor 0x1002, running device-id) and accepts OSNumber/OSData (`PatchData.cpp:50,706-746`); GL/Metal bypass the gate (`UserPatchBackend.cpp:98-110`). Names/locations/values agree. Timing caveat: the gate is read lazily at patch time only; a VDA page validated before readiness is skipped and is not retried for that mapping (acceptable for decoder-process pages, not proven on hardware); the documented `NootedRed` `IOService` fallback can never be true (D11); `acceleratorStop` does not withdraw readiness (D10). |
| 6 | Boot/kext flow: OpenCore load order → Lilu plugin init → data read timing/retries → build/APU detection → hook routing → page patch → VDA readiness → decode | **NOT PROVEN** (static trace passes with risks) | Full trace in §3. Two medium risks are only resolvable on hardware: late kernel-text routing from `IOService::start` (D2) and the two-entry-point retry model if `/Library` is not readable at either early point (D3). No boot log from a branch boot exists. |
| 7 | Build all xmake modes; run all still-valid host tests; classify obsolete tooling vs regressions | **PASS** | All three modes build (§2.1). `test_userpatch_data.py`: 91 tests OK, 1 skipped. Legacy tests classified in §5; the one in-branch regression is the fixture extractor/provenance test (D7). |
| 8 | Claim only what can be proven without a reboot; explicit hardware checklist | **PASS** | §6 lists reboot-only items; §7 separates proven from unproven. |

---

## 2. Commands and results

### 2.1 Builds (all modes)

```sh
export AppleForgePath=/Volumes/WorkSpace/Projects/Hackintosh/AppleForge
for m in release releasedbg debug; do
  xmake f --project=. -m $m -y && xmake --project=. -y
done
```

Result: `build ok` in all three modes, no warnings/errors. Artifacts (per branch/platform/arch/mode):

```
build/branches/shared/macosx/x86_64/<mode>/NootedRed.kext
build/branches/shared/macosx/x86_64/<mode>/NootedRed-0.9.0-<MODE>.zip
build/branches/shared/macosx/x86_64/<mode>/userpatch/NootedRedUserPatch.kext
build/branches/shared/macosx/x86_64/<mode>/userpatch/NootedRedUserPatch-0.9.0-<MODE>.zip
```

Verbose release compile command confirms the satellite is built as intended:

```
clang++ -c ... -DLILU_CUSTOM_IOKIT_INIT -DMAC_OS_X_VERSION_MIN_REQUIRED=101500 \
  -DMODULE_VERSION=0.9.0 -DPRODUCT_NAME=NootedRedUserPatch ... --target=x86_64-apple-macos10.15 \
  -fapple-kext ... NootedRedUserPatch/Plugin.cpp
```

and links against Lilu/kmod with `-Wl,-kext` (`LILU_CUSTOM_IOKIT_INIT` is in effect because
`NootedRedUserPatch` class symbols are defined only by `Plugin.cpp`: `_ZN18NootedRedUserPatch*`,
`ADDPR(selfInstance)`; no duplicate `PRODUCT_NAME` definitions).

Build-nesting check: `xmake.lua` is nested below the main checkout. A scratch reproduction
(`/tmp/xmakenest/xmake.lua` + `/tmp/xmakenest/sub/xmake.lua`, run from `sub/`) showed plain `xmake`
selecting the **outer** project and warning to force the current directory. `--project=.` is therefore
required and was used for every reported build; the worktree-local `.xmake/` was updated, the parent
checkout's `.xmake/` was not touched.

### 2.2 Host data tests

```sh
python3 tools/test_userpatch_data.py
# Ran 91 tests in 0.283s — OK (skipped=1); exit 0
# The one skip is FixtureProvenanceTest because NootedRed/UserPatches.cpp is deleted at HEAD (D7).

python3 tools/userpatch_data.py --spec tools/fixtures/minimal-24H32/spec.json --out /tmp/updata
# manifest.bin 188 B  sha256 bedb1d897c8415643280cebab58dd7c72a5bd2775eefc4376c57c9be90ab5bf3
# pages.bin    4096 B sha256 e8a5f32bb90c9e5bd130d6bc490410f16b76183ea02e87c3eb77b002bc7da932
# -> both hashes match tools/fixtures/minimal-24H32/README.md exactly

python3 tools/userpatch_data.py --spec tools/fixtures/master-15.8.1/spec.json --out /tmp/updata_full
# manifest.bin 472 B (2 tables, 3 pages, 4 sites); pages.bin 12288 B; manifest.json emitted
# re-running into /tmp/updata_full2 and `diff -r` -> byte-identical (deterministic output confirmed)

python3 tools/extract_userpatch_fixture.py --check
# exit 1: "missing source file .../NootedRed/UserPatches.cpp"  (D7)
```

Fixture provenance was nevertheless verified **against master's source**, independently of the broken
CLI, by extracting the historical file and calling the extractor API:

```sh
git show master:NootedRed/UserPatches.cpp > /tmp/UserPatches_master.cpp
python3 - <<'PY'
# imports tools/extract_userpatch_fixture.py and calls extract(Path('/tmp/UserPatches_master.cpp'))
PY
# 3/3 pages MATCH the checked-in fixture byte-for-byte;
# spec (excluding provenance hash) is equal; source sha256 ee53a8ac... matches spec.json provenance.
```

All three fixture pages are therefore real, source-derived 15.8.1 data, as documented.

### 2.3 Empirical environment checks (no reboot)

Host machine: macOS 15.8.1 `24H32`, Darwin 24.6.0, AMD `0x1638` (Renoir / Green Sardine), Lilu 1.7.2
loaded, installed `org.ChefKiss.NootedRed 0.9.0` (`REL-090-2026-10-19`) loaded. Boot args:
`keepsyms=1 -v debug=0x144 itlwm_he=1 -NRedGLFix -NRedVDA -NRedVCNNoGfxOff`.

- `ioreg -n IGPU -r -l`: `NRedVCNNativeLoadReady = 1`, `NRedVCNAcceleratorStarted = 1`,
  `NRedVCNEngineAllocated = 1`; **`NRedVCNBridgeReady` is absent** (installed kext predates task-3).
  `NRedCompatDeviceID = 5688` (0x1638).
- `NRedProfile` on the iGPU: `glfix state=applied variant=semantic`, `vda state=applied`,
  `counters.vda-user-patches=1`, `gva-page-patch=0`. The installed mainline build is therefore currently
  providing user-space GL and VDA patches on this exact machine — the behavior the branch would hand to
  the satellite.
- `ioreg -c NootedRed`: a `NootedRed` IOService object **exists** (class `NootedRed`, IOResources).
  This disproves `docs/Satellite-UserPatch-Plan.md:201-202` ("mainline has no such service").
- `diskutil apfs list`: the System volume/snapshot is **Sealed: Yes**; the on-disk GL driver cannot have
  been altered. Nonetheless reading
  `/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver`
  (file pages 0xE000 and 0x8000) while the installed kext is active shows **exactly one differing byte
  per page vs the checked-in fixture, at a patch site**:
  - 0xE000 page: 4095/4096 bytes identical, offset 0x84 `04 -> 01` (HwInfo fix replacement);
  - 0x8000 page: 4095/4096 bytes identical, offset 0x158 `E1 -> C9` (a dual-quad-form replacement).
  The page cache is patched in memory by the running kext (the sealed disk is unchanged). Consequences:
  (a) the fixture page images are confirmed to be this machine's pristine 15.8.1 driver pages;
  (b) live driver bytes in the current boot must not be used as a pristine baseline for hardware testing;
  (c) a branch boot is required to give the satellite a pristine page cache.

---

## 3. Boot-flow trace (static, with risks)

1. **OpenCore/kernel-collection load.** Lilu loads first; `NootedRed.kext` and
   `NootedRedUserPatch.kext` are resolved. The satellite is a Lilu plugin and depends on
   `org.ChefKiss.NootedRed` (`Info.plist:43-63`), so the loader will not load it if NootedRed is absent.
2. **Plugin kmod start / registration.** Each plugin's `PluginConfiguration.pluginStart` runs:
   - main: `NRed::init()` registers kext-load and patcher-load callbacks (`NRed.cpp:62-105`);
   - satellite: `UserPatchRuntime::init()` checks `-NRedUserPatchOff`, logs the fixed data root, and
     registers `onPatcherLoadForce` (`Plugin.cpp:116-129`). No IOKit/VFS work is done in this context.
3. **Lilu patcher-load dispatch.** Lilu defers plugin init via `_PE_initialize_console`/`kPEEnableScreen`
   to a `thread_call` that calls `processPatcherLoadCallbacks` (AppleForge Lilu
   `Sources/kern_start.cpp:92-119`). At this point:
   - main `NRed::processPatcher` sets `iGPU`, device id/revision and the compatibility line
     (`NRed.cpp:157-222`), then installs its kernel/kext routes;
   - satellite `onPatcherLoad` (`Plugin.cpp:131-137`) → `ensure()` (`145-161`):
     `UserPatchData::load()` reads `kern.osversion`/`kern.osrelease` (`PatchData.cpp:585-625`), detects
     the AMD iGPU/device id for the APU candidate mask (`646-683`), reads and validates
     `<root>/<build>/manifest.bin` and `pages.bin` (`117-316`), builds the runtime page/site tables
     (`463-539`), and only then installs `_cs_validate_page` / `_cs_validate_range` routes through Lilu's
     shared `KernelPatcher` (`UserPatchBackend.cpp:42-77`). On any selection/validation failure the kext
     stays loaded with state `NoOp` and **no hooks**.
4. **Satellite IOService start (second entry point).** The plugin's `IOResources` personality starts
   (`Plugin.cpp:68-76,189-211`) → `serviceStart()` (`139-143`) retries the same idempotent
   `ensure()` and publishes diagnostic properties (`163-183`). Either order relative to step 3 is legal;
   this is also the *late hook installation* path (risk D2).
5. **Kernel-side VCN bring-up (main kext, unchanged).** On X5000 start the bridge requests/loads
   `com.apple.kext.AMDRadeonX6000`; when `loadCompleted` becomes true it publishes
   `NRedVCNBridgeReady = 1` immediately, and again publishes the final state after the original
   accelerator start, including `0` on rollback (`VCNBridge.cpp:301-328`). Readiness is also withdrawn
   on engine-allocation failure (`264`) and on `initHardware` failure (`464-472`). `loadReady()` is
   `requested && x5000Prepared && x6000Prepared && loadCompleted` (`236-239`); without `-NRedVDA`/
   `-NRedAVC` the property is never written (absent = not ready).
6. **User-space page validation.** When a decoder/graphics process maps a signed image, the kernel calls
   the routed validators (`UserPatchBackend.cpp:193-221`). The original validator runs first; the
   satellite only acts on pages the original validator accepted (`201`). For each 4 KiB page:
   full-image compare (`97`); VDA readiness check for kinds 3/4 only (`98-110`); all site `find` bytes
   verified at their recorded offsets, then writes under the kernel write lock (`131-162`); already-patched
   pages are recognised and not rewritten (`125-128,164-191`).
7. **Decode use.** Only after VDA/AppleGVA user-space pages are patched and the VCN2 engine is up does
   hardware decode/encode run. GL/Metal patches are applied independently of VDA readiness.
8. **Rollback.** Remove the satellite from OpenCore, or boot `-NRedUserPatchOff`: main kext is untouched
   and fully functional (mainline has no user-space code). This is the primary rollback path.

Risks in this flow: the two entry points can race (D4); installing kernel routes after boot has
progressed is riskier than at `onPatcherLoad` (D2); the retry model has no delayed attempt if neither
early point can read `/Library` (D3); the VDA readiness lookup runs IOKit matching inside the
code-signing callback (D5).

---

## 4. Defects (file:line, severity)

Severity: **High** = breaks a stated deliverable/known-good behavior; **Medium** = real risk that must be
resolved or hardware-tested before shipping; **Low** = correctness/hygiene of docs/tooling/CI;
**Info** = cosmetic or dead code.

### D1 — High — no deployable patch data, and no VDA/AppleGVA data pipeline at all
`docs/Satellite-UserPatch-Plan.md:3` claims "phases 1–3 implemented". Phase 3 includes "port VDA/AppleGVA
tables and generation tools" (`Plan:264-271`), but:
- the only checked-in data is a **test fixture** (`tools/fixtures/master-15.8.1`, 3 GL/Metal pages, 4
  sites) and a minimal 24H32 vector; no `<PatchData>/<build>/manifest.bin` exists in the tree
  (`find . -name manifest.bin` → nothing outside temp output);
- **no VDA/AppleGVA (table kinds 3/4) data or spec exists anywhere**;
- the old VDA generators (`tools/gen_vda_va_data.py`, `tools/gen_vda_gva_data.py`) still emit C++ headers
  for the deleted `VDAVAData*.hpp`/`VDAGVAData*.hpp`, so they cannot produce the new format;
- `tools/userpatch_data.py` is a generic generator, but no tool converts `platform-data` VDA page images
  into a spec/manifest for kinds 3/4.

Impact: on a branch boot the satellite's VDA path can only ever no-op. On this machine the *installed*
mainline currently applies user-space VDA patches (`NRedProfile counters.vda-user-patches=1`), so the
branch as committed would regress the validated 15.8.1 hardware-decode behavior until data is generated
and deployed by hand. GL/Metal likewise only have fixture data (fixture is real, but not a deployment).
Recommendation: add a data-generation path for VDA/AppleGVA (and 15.8.1 GL/Metal) and ship (or document a
one-command deployment of) a real `PatchData/24H32` set; correct the plan status line.

### D2 — Medium — late kernel-text routing from `IOService::start`
Hooks are installed **only after** data has loaded (`Plugin.cpp:145-161` → `UserPatchBackend.cpp:42-48,
50-77`). Normally that happens at `onPatcherLoad` (early). If data is not readable then, installation is
deferred to `IOService::start` (`Plugin.cpp:131-143,197-211`), which patches `_cs_validate_page`'s kernel
text after boot has advanced, while other CPUs may execute that path. Kernel text patching at that point
is materially riskier than at the patcher-load callback used by every other Lilu kext.
Recommendation: install the routes unconditionally at `onPatcherLoad`; let the loaded data gate only page
writes (the hook already no-ops when `!loaded()`). This also removes the install/load ordering coupling.

### D3 — Medium — retry state machine has no delayed attempt
`load()` retries only when the last failure was transient (`PatchData.cpp:107-115`), and it is called from
exactly two early-boot points (`Plugin.cpp:131-161`; also `serviceStart`). `BuildUnavailable`,
`ApuUnknown` and `DataMissing` are transient, but if neither point can see the build string, IOKit or
`/Library` (the plan explicitly anticipated an unreadable data volume, `Plan:169-172`) the satellite stays
inert for the whole boot with only a log line; there is no `thread_call`/delayed retry. Recommendation:
schedule a bounded delayed retry (or an extra later service/kext-load hook) before declaring no-op.
Also note the doc claim "retried from a kernel thread" (`NootedRedUserPatch/README.md:243`) is stronger
than the implementation.

### D4 — Medium — two entry points, unsynchronised shared state
`ensure()` can run concurrently from the Lilu patcher-load thread and the IOService-start thread:
- `UserPatchData::load()`/`loadLocked()` are not locked and `resetAttempt()`/`setNoOp()` free the
  manifest/pages buffers (`PatchData.cpp:541-583`); concurrent calls can double-free or use-after-free;
- `UserPatchBackend::installIfReady()` checks `installed_`/`installFailed_` without a lock
  (`UserPatchBackend.cpp:42-48`) and `install()` routes on the shared KernelPatcher
  (`50-77`); a race can install twice;
- `appliedPages_`/`appliedPageCount_`/`vdaGateLogged_` are plain fields (`UserPatchBackend.hpp:76-80`,
  updated at `UserPatchBackend.cpp:104-121`); races here only affect diagnostics (page writes stay
  idempotent and WP-protected), but they are still data races.
`PatchData.hpp:134-136` and `UserPatchBackend.hpp:40-41` claim multi-entry-point safety; that claim needs
a lock or a single-threaded design. Recommendation: one `IOLock` around `ensure()` (or make the
IOService start path read-only when patcher-load already ran) and atomics for the counters.

### D5 — Medium — IOKit matching inside the code-signing callback
`vcnBridgeReady()` (`PatchData.cpp:706-746`) calls `IOService::serviceMatching`/`getMatchingServices`
(allocates and walks the registry) and is invoked from `processPage` inside the routed
`_cs_validate_page`/`_cs_validate_range` callback (`UserPatchBackend.cpp:100`). This is a sensitive
context; registry locking/re-entrancy is unproven, and the lookup repeats for every matched VDA page.
Recommendation: cache the readiness decision (e.g. retain the iGPU `IORegistryEntry`/`OSNumber` at a safe
point, or cache the boolean and refresh it from a kernel thread) so the hook performs only a pointer/flag
read. (The old mainline called `VCNBridge::singleton().loadReady()` directly, i.e. a plain memory read.)

### D6 — Low — documentation is stale/inconsistent after the split
- `NootedRedUserPatch/README.md:203-204` still says "The main kext currently does not publish this
  property; task-3 adds it" — task-3 is merged and `VCNBridge.cpp:118-133` publishes it.
- `NootedRedUserPatch/README.md:7` still says "Status: Phase 2 scaffold"; `:198` claims a `NootedRed`
  IOService fallback that mainline never writes (see D11); `:223` says `NRedUserPatchHooks` = 1 when
  **both** hooks are installed, but `installed_` is set even when `_cs_validate_range` routing fails
  (`UserPatchBackend.cpp:63-75`); `:232` lists a `BootArgDisabled` reason the code never sets.
- `docs/Satellite-UserPatch-Plan.md`: §3.3 (`:104-147`) still describes per-table blobs
  (`gl-4k.bin`, `vda-va-4k.bin`…), a driver-identity hash, `build_prefix_ok` prefix selection and a
  generator named `tools/gen_userpatch_data.py` — all superseded by the single `pages.bin` v1 format and
  `tools/userpatch_data.py`; `:86,223` list `MTLHwInfoData.hpp`, which never existed in master;
  `:201-202` claims mainline has no `NootedRed` service, which `ioreg -c NootedRed` disproves;
  `:3` overclaims phase 3 (D1).
- `docs/COMPATIBILITY.md:29-34,41,50,71-76` still claims 15.8.1 GLFIX/VDA "validated", refers to removed
  headers/data (`VDAVAData`, `VDAGVAData`, `TahoePatchData`), and documents opt-in flags
  (`-NRedGLFix`/`-NRedGLFixOff`, semantic fallback) that no longer exist in mainline and have no satellite
  equivalent. Status date (2026-10-20) predates the split.
- `docs/ARCHITECTURE.md:3,111,145-146,292` is still "authoritative" and explicitly requires "no
  `_cs_validate_page` routing for GLFIX/VDA in a release build; no user-space page-cache writes" and a
  `NootedRedRootPatch` root-patch plane — the exact opposite of the approved satellite design. The tree
  now has two contradictory architecture documents.

### D7 — Low — in-branch regression: fixture provenance tooling is broken at HEAD
`tools/extract_userpatch_fixture.py` was added by this branch but depends on
`NootedRed/UserPatches.cpp`, which the same branch deletes:
- `python3 tools/extract_userpatch_fixture.py --check` exits 1 ("missing source file");
- the `--source` option is parsed (`:285`) but ignored: `main` always calls
  `write_fixture(args.fixture)`/`check_fixture(args.fixture)` (`:288-296`), which use the module-level
  `SOURCE` (`:33,126,246,262`);
- the test suite therefore silently skips its only fixture-provenance test
  (`tools/test_userpatch_data.py:671-686`, skip at `:674`) — 1 skipped in the otherwise-passing suite;
- `tools/README-userpatch-data.md:30` and `tools/fixtures/master-15.8.1/README.md:75` document commands
  that cannot succeed at HEAD.
The fixture itself is genuine (verified against `git show master:...UserPatches.cpp`, §2.2), but the
branch cannot re-verify it in-tree. Recommendation: make `--source` honoured, or check in a pinned copy of
master's table source (or convert the fixture to a pure data fixture with frozen hashes), and un-skip the
test.

### D8 — Low — obsolete tools/tests left in the tree, one false-green
Expected obsolescence (they reference removed mainline code) but not retired or marked:
`tools/test_gl_semantic_data.py` (fails: missing `GLFixSemanticData.hpp`),
`tools/test_patch_data.py` (fails: missing `UserPatches.cpp`), `tools/test_vcn_multibuild.py` (fails:
missing `VDAVAData.hpp`; also still covers the still-valid `VCNData/*.hpp` kernel tables, so trimming it
would lose coverage), `tools/gen_patch_data.py`, `tools/gen_vda_va_data.py`, `tools/gen_vda_gva_data.py`,
`tools/collect_compat_data.py` (reconstructs vanilla pages from `UserPatches.cpp`),
`tools/README-patchgen.md`, `tools/README-collect-compat-data.md`.
`tools/test_patchset_selection.py` **passes** but only because it re-implements the now-deleted
`UserPatches::selectPatchSet()` logic in the test itself — a false-green test of code that no longer
exists. No CI runs host tests (`/.github/workflows/main.yml` only builds), so this rot is invisible.
Expected obsolescence ≠ regression; D7 is the regression.

### D9 — Low — CI/artifact globs don't include the satellite zip
`/.github/workflows/main.yml:69` uploads `build/branches/*/*/*/*/*.zip` (branch/platform/arch/mode/zip),
but the satellite zip lives one level deeper at `.../<mode>/userpatch/NootedRedUserPatch-*.zip`, so it is
**never uploaded**. `tools/build-branch.sh:36` has the same shape (`*/*/*/NootedRed-*.zip`) for timestamp
renaming, so the satellite zip is also never renamed. Build/artifact placement itself is correct and the
two `after_build` zip steps are isolated by the separate `userpatch/` target dir.

### D10 — Low — readiness is not withdrawn on `acceleratorStop`
`VCNBridge::acceleratorStop` (`VCNBridge.cpp:333-346`) clears engine state only; `loadCompleted` (and
therefore `loadReady()`) stays true, so `NRedVCNBridgeReady` remains `1` after the accelerator stops until
a later start/failure publishes again. The documented contract says value `1` while ready and `0` after
readiness is withdrawn (`Plan:192-217`). Add `publishBridgeReady()` to `acceleratorStop` (or document the
exception) so the satellite cannot apply VDA pages while no accelerator exists.

### D11 — Info — minor parser/robustness deviations (all fail-closed) and dead code
- Empty `<root>/<build>/manifest.bin` is classified as transient `DataMissing` rather than
  `ManifestInvalid` (`PatchData.cpp:763-768` → `:150-152`); harmless but retried and mislabelled.
- `readKernelIdentity` `strlcpy`s the sysctl build string into a 16-byte buffer before validating it
  (`PatchData.cpp:596-603`); a hypothetical >15-char build string would be truncated and could select a
  truncated directory. Kernel build strings are short, but the order should be length-check-then-copy.
- The doc's "Darwin major >= 1" rule (`UserPatch-Data-Format.md:310`) is not checked explicitly; a
  manifest with 0 is still rejected via identity mismatch. The doc's "canonical sequential page layout" is
  explicitly host-only (`UserPatch-Data-Format.md:115-117`) and the runtime intentionally accepts any
  aligned page — no divergence beyond the documented one.
- Dead code: `Reason::kBootArgDisabled` is never set (Lilu blocks the plugin before `init`); the
  `NootedRed`-service fallback for the readiness property can never be true (main publishes on the iGPU
  only); `NRed::processPatcher(KernelPatcher&)` now ignores its parameter (`NRed.cpp:157`).
- Behaviour difference vs master: master checked `isGLDriverVnode()` before applying GL pages; the
  satellite applies to any vnode whose 4 KiB page is byte-identical. This is the approved "driver identity
  = exact page equality" model (`Plan:253-256`) and is safe in practice, but is worth recording.
- Satellite GL/Metal patches are applied automatically when data is present, whereas master's GL fix was
  opt-in (`-NRedGLFix`). This is the approved auto-enable decision, but the removed flags remain in
  `COMPATIBILITY.md` (D6).

---

## 5. Obsolete tooling classification (invariant 7)

| Item | Status | Notes |
| --- | --- | --- |
| `tools/userpatch_data.py`, `tools/test_userpatch_data.py`, fixtures, `tools/README-userpatch-data.md` | **current** | 91 tests pass (1 skipped by D7); deterministic output verified. |
| `tools/extract_userpatch_fixture.py` | **in-branch regression** (D7) | `--check` fails at HEAD; `--source` ignored. |
| `tools/test_gl_semantic_data.py`, `tools/test_patch_data.py` | expected obsolete | Parse deleted semantic/`UserPatches` data; fail at HEAD. |
| `tools/test_vcn_multibuild.py` | partially obsolete | Fails on deleted VDA headers, but part of its kernel `VCNData` coverage is still valid; trim rather than delete. |
| `tools/test_patchset_selection.py` | false-green | Passes by re-implementing deleted `selectPatchSet()`; should be retired or moved to satellite selection tests. |
| `tools/gen_patch_data.py`, `gen_vda_va_data.py`, `gen_vda_gva_data.py` | expected obsolete, but see D1 | Emit C++ for removed headers; **no replacement generator exists for VDA/AppleGVA data**. |
| `tools/collect_compat_data.py`, `README-collect-compat-data.md` | partially obsolete | Data-collection intent still valid; the "reconstruct vanilla pages from `UserPatches.cpp`" path is dead. |
| `tools/README-patchgen.md` | obsolete | Documents the removed mainline generator workflow. |
| `docs/COMPATIBILITY.md`, `docs/ARCHITECTURE.md` | stale (D6) | Contradict the split; need a superseding note/update. |
| `docs/archive/CONTRIBUTING-USERPATCHES.md` | correctly archived | Already marked historical. |
| CI host tests | missing (pre-existing) | `.github/workflows/main.yml` builds only; no guard against tool/test rot. |

---

## 6. Hardware validation checklist (all require a reboot; NOT executed here)

Precondition P0: this machine's booted page cache is currently patched by the installed mainline kext
(§2.3), so no live-driver comparison is meaningful until a clean boot. Note also that no deployable
`PatchData` exists yet (D1) — generate and install one first, from a pristine boot (`-NRedOff` or after
removing the old mainline user-space backend) so the page images are not post-patch bytes.

1. **Data generation.** Produce `PatchData/24H32` (GL, Metal, VDA/VA, VDA/AppleGVA) from collected
   platform data; run `python3 tools/test_userpatch_data.py` and a per-page `find` audit. Verify page
   images against a pristine driver/shared-cache extraction.
2. **Install and load.** OpenCore: Lilu → NootedRed → NootedRedUserPatch + data directory; reboot.
   Confirm the satellite loads only with NootedRed present (`kmutil showloaded | grep NootedRed`).
3. **State properties.** `ioreg -l -n NootedRedUserPatch | grep NRedUserPatch`: `State=Loaded`,
   `Reason=None`, `Hooks=1`, `Pages`/`Sites` matching the data, `Build=24H32`, `ApuMask=0x28`
   (Renoir|GreenSardine on this 0x1638 machine), `AppliedPages>0`.
4. **Readiness contract.** With `-NRedVDA`: `ioreg -n IGPU -r -l` must show `NRedVCNBridgeReady=1` after
   VCN bring-up; with `-NRedVDA` removed the property must be absent and VDA pages must stay unpatched
   while GL/Metal still apply. Open a decoder process and confirm VDA pages are applied only after the
   property is 1 (compare `NRedUserPatchAppliedPages` before/after).
5. **GL dual-source / Chrome / Zen.** Run the project's GL probe plus Chrome and Zen WebGL; verify the
   dual-source pixels and no canvas corruption (the issue this feature exists for).
6. **Metal / QQ.** Open an image in QQ (Metal path) and confirm correct rendering, no corruption.
7. **Hardware decode.** `-NRedVDA` + `vda_hwtest.sh`/VideoProc/QuickTime H.264 and HEVC decode (and HEVC
   encode if claimed) must use the VCN2 engine, not software.
8. **`-NRedUserPatchOff`.** Boot with the override: no data read, no hooks, satellite state absent/inert;
   main kext and decode behave as stock; no panics.
9. **Satellite absent / rollback.** Remove `NootedRedUserPatch.kext` from OpenCore and boot: main kext
   must remain fully functional (the plan's primary rollback).
10. **Unsupported build / missing data.** Boot with the build directory renamed or with data for another
    build: `State=NoOp`, `Reason=DataMissing`/`BuildMismatch`, `Hooks=0`, nothing patched, no panic.
11. **Malformed data.** Corrupt `pagesChecksum`/`manifestChecksum` and boot: `NoOp
    ManifestChecksumMismatch`/`PagesChecksumMismatch`, no hooks, no writes.
12. **Late-install path.** Verify from logs whether hooks installed at patcher load or at
    `IOService::start`; ideally exercise the late path deliberately and check `NRedVCNBridgeReady` gating
    and no instability.
13. **Stability.** After each boot: inspect unified log for `NootedRed`/`UserPatch` panic, watchdog,
    GPU reset or WindowServer restart; check `/Library/Logs/DiagnosticReports` for panics; keep Chrome/
    Electron open for a while.
14. **Thread-safety soak.** Repeated app launch/close, sleep/wake (readiness withdrawal), and decoder
    start/stop; watch for page-cache double-patch logs, hangs, or panics.

---

## 7. What is proven now, and what is not

Proven without a reboot: tree cleanliness/main-kext invariants (§1.1), build success in all modes and
artifact layout (§2.1), host data-format implementation and test suite, deterministic generator output and
fixture hashes (§2.2), fixture provenance against master's deleted source, Info.plist dependency/version
match, exact-page backend code path (compare→verify→write) by inspection, publication/lookup property
name/location/value agreement, and the data-selection fail-closed behaviour by inspection.

**Not proven (requires a real boot):** that hooks are actually installed and route correctly on 15.8.1;
the ordering of patcher-load vs IOService-start and data-volume readability; that
`NRedVCNBridgeReady` is visible to the satellite in time for decode; that VDA/AppleGVA pages are applied
and used by hardware decode; that GL/Metal fixes reproduce the previous validated behavior; absence of
panics/GPU resets/watchdog; the late-routing and retry risks (D2/D3) and the concurrency model (D4/D5).
No hardware-stability claim is made.

---

## 8. Recommendations (no code changed by this task)

Must-fix before hardware sign-off: D1 (ship/generate real data, especially VDA/AppleGVA), D2 (install
hooks at patcher load, data only gates writes), D3 (delayed retry or a single late hook), D4 (serialize
the two entry points), D5 (cache readiness outside the hook), D10 (withdraw readiness on stop), plus D6/D7
doc/tooling corrections. Then execute §6.

Nice-to-have: retire/mark obsolete tools and add host CI for `tools/test_userpatch_data.py`; add a
host-testable unit harness for the loader's selection/state machine (the current tests cannot execute the
kernel parser); update `NootedRedUserPatch/README.md` status and the plan's implementation status; resolve
the `ARCHITECTURE.md` vs satellite-plan contradiction with an explicit superseding note.

---

## Addendum — fix verification for D1–D11 (task-9, 2026-10-23)

Reviewed tree: `HEAD` `2c0b60e` ("docs/ci: retire obsolete mainline tooling after the satellite split"),
five fix commits on top of the originally reviewed `ab2afc9`. Scope: read-only verification plus this
addendum; no kext/data/code was modified, nothing was installed and the machine was not rebooted.

**Bottom line:** D1–D5, D7, D9, D10 and the substantive parts of D6/D8/D11 are fixed and re-verified
statically and by build/test. Remaining defects are one documentation accuracy issue (boot args) plus
hardware-only timing risks (bounded readiness-cache window vs. accelerator stop/restart; bounded retry
windows) and missing CI coverage for the host tests. None of the fixes can be called end-to-end proven
without a reboot.

### A.1 Verdict per review defect

| Defect | Verdict | Evidence at `2c0b60e` |
| --- | --- | --- |
| D1 High — no deployable data / no VDA pipeline | **FIXED** | Committed `PatchData/24H32` (kinds 1–4, 12 pages, 17 sites), `PatchData/25G241` (kinds 1–4, 11/17) and `PatchData/23J631` (kinds 3/4 only, 9/13, GL/Metal gap documented). Derived from pinned master `0efa6f4` by `tools/convert_master_patchdata.py`; verified by `DeployablePatchDataTest` (`tools/test_userpatch_data.py:772-890`), which compares every VDA/AppleGVA page to the pinned `VDAVAData*`/`VDAGVAData*` arrays, the 15.8.1 GL/Metal pages to the fixture and the 25G241 pages to `TahoePatchData.hpp`. `--check`/`--report` pass; no fabricated builds. Plan status and `PatchData/README.md` gaps now match the data. |
| D2 Medium — late kernel-text routing from `IOService::start` | **FIXED** | Routes are installed exactly once, from the patcher-load callback, before any data attempt: `Plugin.cpp:194-226` → `UserPatchBackend::install` (only call site, `Plugin.cpp:206`; install code `UserPatchBackend.cpp:34-72`). `serviceStart` (`Plugin.cpp:228-256`) only retries load/readiness and publishes diagnostics; it has no routing call. Data gates page **writes** only (`UserPatchBackend.cpp:91-93`). |
| D3 Medium — no delayed retry | **FIXED** | Bounded kernel `thread_call`: load 15 attempts × 2 s, readiness 12 × 5 s (`Plugin.cpp:51-57,319-380`); the callback touches only load/readiness state, never page pointers (`Plugin.cpp:344-380`). Terminal failures stop retries (`Plugin.cpp:258-273`). Bounds are documented (`NootedRedUserPatch/README.md:257-261`). |
| D4 Medium — unsynchronised two-entry-point state | **FIXED** (static) | One `IOLock` serialises `ensure/install/snapshot/retry-flag` (`Plugin.cpp:180-185,203-222,234-252,314-317,352-374`). Published data uses a release store/acquire load (`PatchData.cpp:315,824`) with buffers frozen after publication (`PatchData.cpp:550-556` comment + code path), so the former double-free/UAF window is closed. Hook counters/readiness/flags are atomics (`UserPatchBackend.cpp:76,87,99,110,130,132,256`), the write toggle is under a per-backend spinlock (`UserPatchBackend.cpp:42,118-120`), and a second route install is impossible (`UserPatchBackend.cpp:36-37` `installAttempted_`). Kernel-context races remain unproven without hardware (see A.4). |
| D5 Medium — IOKit matching inside the code-signing callback | **FIXED** | `vcnBridgeReady()` was removed from the loader; `queryVcnReady()` (`PatchData.cpp:725-746`) is called only from the runtime lock (`Plugin.cpp:285`) and the hook reads a cached atomic (`UserPatchBackend.cpp:99`); `UserPatchBackend.*` includes no IOKit headers and performs no registry/IOKit work in `processPage`. Correctness of the cache’s refresh window is the remaining risk (R3). |
| D6 Low — stale/inconsistent docs | **PARTIAL** | Satellite README status/claims corrected (readiness now published, no `NootedRed`-service fallback, `Hooks`/`RangeHook` semantics split, no `BootArgDisabled`, retry table, install/artifact paths); plan §3.3/§3.4.1/status rewritten to v1 data model; `COMPATIBILITY.md` and `ARCHITECTURE.md` now describe the satellite split, old architecture archived. One wrong statement remains: R1. |
| D7 Low — fixture extractor broken at HEAD | **FIXED** | `tools/extract_userpatch_fixture.py --check` exits 0 and honours `--source`; pinned snapshot replaces the deleted live source (`tools/pinned/master`), suite is **101 tests OK, 0 skipped** (provenance test un-skipped), `tools/master_source.py --verify` confirms 11 pinned files at `0efa6f4`. |
| D8 Low — obsolete/false-green tooling | **FIXED** | Retired files deleted and catalogued with replacements in `tools/RETIRED.md`; `test_vcn_multibuild.py` keeps the valid VCN kernel-table coverage; false-green `test_patchset_selection.py` replaced by `test_patchdata_selection.py`, which exercises the real committed `PatchData/` and documented selection contract. CI still does not run host tests (R4). |
| D9 Low — CI/artifact globs miss the satellite zip | **FIXED** | Workflow uploads both globs (`.github/workflows/main.yml:68-79`) and `tools/build-branch.sh:37-38` renames both zips; guarded by `tools/test_build_artifacts.py` (4/4) and matched against the real tree. **Correction to the original report:** the original §D9 claim that the two `after_build` zip steps were already isolated at `ab2afc9` was wrong — the satellite targetdir was nested under the main mode directory, so the NootedRed zip recursively swallowed `userpatch/` and raced the satellite after-build (this reproduced as an intermittent `releasedbg` archive failure during the first review round). The fix makes the satellite targetdir a sibling (`xmake.lua:70`); rebuild verification now shows clean, non-overlapping zips (A.2). |
| D10 Low — readiness not withdrawn on `acceleratorStop` | **FIXED** (main-kext contract; e2e unproven) | `acceleratorStop` clears `loadCompleted` when it was set, records the stop-induced withdrawal and republishes `0` (`NootedRed/VCNBridge.cpp:352-368`); the next start restores readiness for the still-loaded X6000 driver and re-publishes `1` (`VCNBridge.cpp:318-326`). Other transitions (load success, start rollback, allocation failure, `initHardware` failure) still publish (`VCNBridge.cpp:270,316,342,496`), and an `initHardware` failure cannot be undone by the stop-restore flag. Satellite-side observation of a late stop is limited by R3. |
| D11 Info — parser/robustness nits and dead code | **FIXED** | Empty `manifest.bin` is terminal `ManifestInvalid` (size checked before dereference, `PatchData.cpp:151-160`); build string is read into a 64-byte buffer, validated, then copied (`PatchData.cpp:600-620`); dead `NootedRed`-service fallback and `Reason::kBootArgDisabled` removed; `manifest.json`/parser deviations that remain are the documented host-only canonical-layout rule. `NRed::processPatcher(KernelPatcher&)` still ignores its parameter (Info, mainline, unrelated to the split). |

Main-kext invariant re-checked on the new release binary: 0 string matches for
`_cs_validate|UserPatches|GLFix|VDAVAData|TahoePatchData|NRPD|NRedUserPatch`; `NRedVCNBridgeReady`
present; no `_cs_validate`/`UserPatches`/`VDA*Data` references remain under `NootedRed/`.

### A.2 Commands and results (no reboot)

Builds (all modes, pinned to the nested worktree):

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export AppleForgePath=/Volumes/WorkSpace/Projects/Hackintosh/AppleForge
export NRED_BUILD_BRANCH=verify9
for m in release releasedbg debug; do
  xmake f --project=. -m $m -y && xmake --project=. -y
done
# plus a second `xmake --project=. -y -r` round per mode
```

Result: `build ok`, exit 0, in **all three modes and both rounds**. Artifacts use the fixed layout `build/branches/verify9/macosx/x86_64/<mode>/{NootedRed.kext,*.zip}` and
`build/branches/verify9/macosx/x86_64/userpatch/<mode>/{NootedRedUserPatch.kext,*.zip}`. Zip listing
confirms isolation: main zips contain only `NootedRed.kext`/dSYM, satellite zips only
`NootedRedUserPatch.kext`/dSYM. Compiler warnings are pre-existing mainline only
(`X5000.cpp` frame size, `BiosParser.hpp` anonymous unions); the satellite sources compile warning-free.
The built `Info.plist` keeps `org.ChefKiss.NootedRed = 0.9.0` in `OSBundleLibraries`; debug symbols show
the expected `_IOLockAlloc`, `_IOSimpleLockAlloc`, `_thread_call_*` and `wrapCsValidate*` symbols.

Host tests / tooling:

```text
python3 tools/test_userpatch_data.py          # Ran 101 tests — OK (0 skipped)
python3 tools/test_patchdata_selection.py     # Ran 4 tests — OK
python3 tools/test_build_artifacts.py         # Ran 4 tests — OK
python3 tools/test_vcn_multibuild.py          # all multi-version VCN kernel-table checks passed
python3 tools/convert_master_patchdata.py --check   # ok: specs + PatchData match pinned master
python3 tools/convert_master_patchdata.py --report  # 3 builds, kinds/gaps as documented
python3 tools/master_source.py --verify             # ok: 11 pinned files, 0efa6f4
python3 tools/extract_userpatch_fixture.py --check  # ok (also with --source tools/pinned/master/...)
```

Valid-test inventory is now `test_userpatch_data.py`, `test_patchdata_selection.py`,
`test_build_artifacts.py`, `test_vcn_multibuild.py`; the retired generators/tests listed in
`tools/RETIRED.md` are absent from the tree (confirmed) and are expected obsolescence, not regressions.
The original report’s §2.2 D7 failure and skip are resolved; §2.1’s artifact paths are superseded by
`userpatch/<mode>/` (A.2 above).

### A.3 Remaining defects / residuals (reported, not fixed here)

1. **R1 Low (docs accuracy; can mislead hardware testers):** `docs/COMPATIBILITY.md:19-21` says the old
   `-NRedGLFix`/`-NRedVDA`/`-NRedAVC` flags “no longer exist”. `-NRedVDA`/`-NRedAVC` are still parsed
   (`NootedRed/VCNBridge.cpp:49-50,208`) and are required for the VCN bridge to become ready, so with the
   satellite installed the VDA/AppleGVA data (kinds 3/4) stays no-op unless one of them is passed.
   `NootedRedUserPatch/README.md:53-72` and `PatchData/README.md:20-24` do not say this either.
   Recommend: correct the sentence and add one operator line (“VDA user-space data additionally needs the
   mainline VDA/AVC opt-in; GL/Metal do not”).
2. **R2 Low (format-doc consistency):** `docs/UserPatch-Data-Format.md:42-46` still lists the
   `Contents/Resources/PatchData/` bootstrap fallback as part of the layout without the explicit
   “not implemented in this phase” note that `Satellite-UserPatch-Plan.md:150-153` and
   `NootedRedUserPatch/README.md:329` carry. The format doc is labelled the implementation contract; add
   the clause (or mark the section “planned”).
3. **R3 Medium, hardware-only, documented:** VDA readiness is cached, and the cache is refreshed only
   inside a bounded window (12 × 5 s after data load). If the bridge becomes ready later, VDA pages stay
   stock for the boot; if the accelerator stops/restarts after the window, the satellite can keep a stale
   cached `true` even though the main kext correctly published `0` (D10). This is acknowledged in
   `NootedRedUserPatch/README.md:334-337`; it cannot be resolved without a real boot (or a notification
   mechanism that is out of scope here).
4. **R4 Low:** `.github/workflows/main.yml:61-64` still only builds; the host tests
   (`test_userpatch_data.py`, `test_patchdata_selection.py`, `test_build_artifacts.py`,
   `test_vcn_multibuild.py`) are not run in CI, so tool/data rot can recur silently. This was a
   nice-to-have in the original review and remains open.
5. **R5 Info, pre-existing:** `NootedRed/VCNBridge.cpp:54-55` says “There is no family-prefix fallback”
   while `NootedRed/VCNData/families.hpp:23-118` implements family-prefix adapters and
   `docs/COMPATIBILITY.md` documents them. Predates the split (present at `master`), not caused by these
   fixes; worth a wording cleanup.

### A.4 Hardware validation checklist still required

Precondition: deploy `PatchData/24H32` (copy to `/Library/Application Support/NootedRedUserPatch/PatchData/`)
from a pristine/clean boot; the currently booted machine’s page cache is already patched by the installed
mainline kext, so it must not be used as a pristine baseline (original §2.3).

1. **Load/install order:** satellite loads only with NootedRed present; log shows `installed exact-page
   routes (page=yes range=… )` during the patcher-load phase (`NRedUserPatchHooks=1`,
   `NRedUserPatchRangeHook` as applicable), not from `IOService::start`; data `NoOp` still shows
   `Hooks=1` with no writes.
2. **State properties:** `ioreg -l -n NootedRedUserPatch | grep NRedUserPatch` → `State=Loaded`,
   `Reason=None`, `Build=24H32`, `Pages=12`, `Sites=17`, `LoadAttempts≥1`, `RetryPending=0`.
3. **Readiness ordering (with `-NRedVDA`):** `NRedVCNBridgeReady=1` on the IGPU and
   `NRedUserPatchVdaReady=1` before a decoder process maps its pages; without `-NRedVDA`/`-NRedAVC`:
   property absent, `VdaReady=0`, VDA pages untouched while GL/Metal still apply.
4. **D10 stop/restart:** accelerator stop/sleep-wake must publish `NRedVCNBridgeReady=0` and no VDA page
   may be written while stopped; after restart it must return to `1` and patches resume. Exercise the R3
   late-stop window explicitly.
5. **Retry windows:** boot with the data directory missing → `NoOp DataMissing`, bounded retries; confirm
   it stays inert after exhaustion (documented) and does not panic; repeat with malformed
   checksum/manifest and an unsupported build (`NoOp`, `Hooks` still installed, no writes).
6. **GL/Metal:** GL dual-source probe pixels, Chrome WebGL, Zen WebGL, QQ image/Metal rendering — no
   corruption (the regression the feature exists for).
7. **VDA:** `-NRedVDA`/`-NRedAVC` + `vda_hwtest.sh`/VideoProc/QuickTime H.264 and HEVC decode (and HEVC
   encode if claimed) must use the VCN engine, not software.
8. **Rollback / isolation:** `-NRedUserPatchOff` boots with no routes/reads/properties; removing the
   satellite kext leaves the main kext fully functional with hardware decode behaving stock.
9. **Stability/soak:** repeated app launch/close, sleep/wake, decoder start/stop, WindowServer; inspect
   unified log and `DiagnosticReports` for panic, watchdog, GPU reset, double-patch or double-route logs.

**Cannot be proven without a reboot:** that the routes actually install and run on `_cs_validate_page/
_range`; that live-code page images match and site writes land in the real page cache; hook-context
safety of `setKernelWriting`/spinlock and the atomic/hot-path design under real concurrency; the
IOLock/`thread_call` state machine under real boot timing; readiness visibility/withdrawal ordering and
the R3 cache window; that the deployed 24H32 pages match pristine 15.8.1 driver/AppleGVA bytes on a clean
boot; GL/Metal/VDA functional results; and the absence of panics, GPU resets or WindowServer restarts.
No hardware-stability claim is made by this addendum.
