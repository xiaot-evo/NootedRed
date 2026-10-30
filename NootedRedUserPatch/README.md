# NootedRedUserPatch

A Lilu-based satellite kext that applies user-space AMD driver patches at the macOS code-signing
validation hooks (`_cs_validate_page` / `_cs_validate_range`).  It contains no Apple code and no
hardcoded patch bytes, addresses or offsets: everything comes from an NRPT v3 profile bundle injected
into the kext personality at deploy time.

## How it works (hook-only, NRPT v3)

1. The injected `NRedProfiles` personality property is an `OSArray` of dictionaries
   `{Build, APUMask, DeviceID, Profile}`; each `Profile` is a complete binary NRPT v3 profile.
2. The plugin copies and validates the bundle, selects **exactly one** profile by exact running
   `kern.osversion`, APU family mask intersection and the device-ID gate (`0` = no gate, otherwise
   exact), then removes the property.  There is no fallback, no heuristic and no cross-build/device
   entry.  While `kern.osversion` is still being published by launchd, matching may start
   provisionally from a unique APU/device candidate; the actual build is authoritative and a mismatch
   is a hard stop for further writes.
3. `_cs_validate_page` and `_cs_validate_range` always run the original validator first and never
   change its result.  Only accepted pages are inspected.
4. Strict mode-domain routing: a `PAGE` record is only considered by `_cs_validate_page` and a
   `DYLD` record only by `_cs_validate_range` (frozen NRPT v3 §9).  There is no vnode-name gate and no
   pager-offset comparison; page identity is the complete 4 KiB FNV-1a-64 page hash plus every site
   `find` byte.
5. Pages are written at most once per boot (per-record applied-once bitmap), after the full-page hash
   and all site finds matched.  A page already carrying every `replace` byte (shared page cache,
   earlier validation) is marked applied and **not** written again.
6. There are no threads, timers, exec listeners, task references or `vm_map_*` cross-process calls.
   Validation hooks do no allocation, VFS, IORegistry or sleeping; logging is bounded.

## Deferred pages / coverage

A page whose workload does not reach its validator during this boot remains **deferred**.  Deferred is
a normal state, not an error: the extension stays `State=Loaded`, `Reason=None`, and the hooks remain
armed so a later validation of that page can still apply it.  `NRedUserPatchCoverage` reports:

- `complete` — every profile page has been applied (or recognised as already patched);
- `workload-deferred` — loaded and matching, but some pages were not validated during this boot
  (GL pages need a GL client, VDA AddrLib pages need a VDA decode session, etc.);
- `inactive` — not loaded (no profile / identity not accepted).

`DeferredPageList` lists those pages; `AppliedPageList`/`AppliedPageMask` list the applied ones.

## Fail-closed rules

- A profile that violates any structural rule (header, table sizes, checksum, page/site/image table,
  bundle E050–E053, mode/image-kind mismatch E018/E019) is rejected as a whole; the plugin stays
  loaded and inert (`State=NoOp`) and writes nothing.
- Selection is exact: running build, APU mask intersection and device gate.  A mismatched build hint
  or a revoked provisional state stops all further writes (already-applied pages are reported).
- A page whose content hash or any site find does not match is never written; validation continues
  normally.

## Diagnostics (IORegistry)

| Property | Meaning |
| --- | --- |
| `NRedUserPatchState` / `Reason` / `ErrorCode` / `ErrorContext` | engine state and fail-closed reason |
| `NRedUserPatchBuild` / `BuildSource` / `ActualBuild` | accepted profile build and authoritative running build |
| `NRedUserPatchIdentityResolved` / `IdentityAttempts` / `IdentityProvisional` | build discovery status |
| `NRedUserPatchApuMask` / `DeviceID` / `Pages` / `Sites` / `Loaded` | parsed profile identity and size |
| `NRedUserPatchProfileCount` / `SelectedProfileBuild` | bundle size and selected entry |
| `NRedUserPatchHooks` / `RangeHook` | installed validation routes |
| `NRedUserPatchModePageCount` / `ModeDyldCount` | profile pages per mode/route |
| `NRedUserPatchCoverage` | `complete` / `workload-deferred` / `inactive` |
| `NRedUserPatchAppliedPages` / `AppliedPageMask` / `AppliedPageList` | applied-once pages |
| `NRedUserPatchDeferredPageList` | pages not validated in this boot (normal, see above) |
| `NRedUserPatchAlreadyPatchedPages` / `...PageMask` / `...PageList` | pages found already patched (no write) |
| `NRedUserPatchFindMismatches` / `MatchedPages` / `ChunkCalls` / `WriteFailures` | match/write counters |

## Build / packaging

```sh
# from the repository root; needs a sibling AppleForge checkout or $AppleForgePath
xmake f -m release -y && xmake build --project=. -y NootedRedUserPatch
```

Requires Xcode CLT, `xmake` and a sibling AppleForge checkout with Lilu + MacKernelSDK. The kext lands
under `build/branches/<branch>/<platform>/<arch>/userpatch/<mode>/` when built through
`tools/build-branch.sh` (see `../docs/Build-Artifacts.md`); a bare `xmake` uses
`build/branches/shared/...`. Profiles and the `NRedProfiles` bundle are produced by
`NootedRedTool --generate-profile`, checked with `test/nrpt_validator.py` and injected into the kext
`Info.plist` at deploy time (`test/inject_profile.py`); the kext never reads files, boot arguments or
the IORegistry for patch data. A new macOS build needs a new generated profile, not a new kext binary.

Supported macOS range is Catalina → Tahoe (`NRedBeta` is required outside the declared range). Session
control: `-NRedUserPatchOff` disables this kext while leaving the main kext intact;
`-NRedUserPatchDebug` enables logging; `-NRedUserPatchBeta` allows beta builds. **No EFI deployment is
done from this directory** — that belongs to the Lead.

User-facing docs: `../docs/INSTALLATION.md`. Contract: `../docs/PatchProfile-Spec.md`.

## Source layout

| File | Purpose |
| --- | --- |
| `Plugin.cpp` | plugin configuration, IOService runtime, locked profile selection, bounded identity-discovery retry, minimal IORegistry diagnostics |
| `PatchProfile.hpp/.cpp` | NRPT v3 parser/validator, identity gates, strict mode-domain matcher, applied-once atomics |
| `UserPatchBackend.hpp/.cpp` | `_cs_validate_page` / `_cs_validate_range` routing (original validator first) and iGPU identity detection |
| `Info.plist` | bundle identifier, Lilu/NootedRed dependencies, personality (bundle injected at deploy time) |
