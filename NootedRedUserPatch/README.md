# NootedRedUserPatch

Satellite Lilu plugin for NootedRed. It owns the **user-space** AMD graphics/media patch backend:
the `_cs_validate_page` / `_cs_validate_range` hooks and the exact 4 KiB page tables that used to live
in the main `NootedRed.kext`.

Status: **Phase 2, hardened after independent review, embedded-data runtime**. The patch data is
compiled into the kext as generated `const` arrays; the plugin performs **no runtime file I/O**. The
target builds, but nothing in this directory has been validated on real hardware yet. Do not treat a
successful build as evidence of a working patch set.

Design background: [`docs/Satellite-UserPatch-Plan.md`](../docs/Satellite-UserPatch-Plan.md).
On-disk/generator data contract: [`docs/UserPatch-Data-Format.md`](../docs/UserPatch-Data-Format.md).

## What it does

- Installs `_cs_validate_page` and `_cs_validate_range` routes **unconditionally** from the Lilu
  patcher-load callback. Data availability gates page *writes* only: until validated data is published,
  the hooks are safe no-ops. This keeps all kernel-text routing inside the normal Lilu patcher-load
  context instead of patching kernel text later from `IOService::start` (review D2).
- Resolves the running build identity from the kernel only: `sysctl kern.osversion`, then XNU's
  `osversion` global. There is no file/plist fallback and no filesystem work (see
  [Build identity sources](#build-identity-sources)).
- Selects the **embedded** PatchData set whose exact build string equals the running build, from the
  generated `NRedUserPatchData::kBuilds[]` index (currently `24H32`, `25G241`, `23J631`).
- Validates the whole embedded manifest before trusting a single byte: magic, format version, header
  size, record layout, canonical table/page/site ranges, build string, Darwin version, APU mask and both
  FNV-1a checksums, then validates the embedded `pages` size/checksum and every site. Any mismatch is a
  logged **NoOp**: no page is ever written and the system is left untouched.
- Retries transient boot-time identity/readiness failures with a bounded kernel `thread_call` timer
  (review D3); see [Runtime states and bounded retry](#runtime-states-and-bounded-retry).
- For every page the kernel validator presents, compares the **complete 4 KiB page** against the
  embedded page image. Only on exact equality are the site `find` bytes verified at their recorded
  offsets and the `replace` bytes written, synchronously inside the callback under
  `MachInfo::setKernelWriting`.
- Serialises page writes with its own spinlock and skips pages that already contain the replacement
  bytes (shared page caches re-validate the same page for several processes).
- Applies VDA/AppleGVA pages only while a **cached** readiness flag, refreshed outside the hooks, says
  the main kext's VCN bridge is ready (see below).
- Publishes its state and counters as IORegistry properties on its own service for diagnostics.

## What it does not do

- No kernel/kext patching (that stays in `NootedRed.kext`).
- No runtime file access of any kind: **no VFS reads, no `/Library` PatchData directory, no
  `SystemVersion.plist`/`PlatformSupport.plist` parsing, no path from a boot argument**. Patch data is
  compiled into the kext; external `PatchData/` is generator input only.
- No semantic/instruction-context scanner.
- No byte-pattern search for patch sites: `SiteRecord.offset` is authoritative and `find` is only
  verified there. In-page find uniqueness is explicitly **not** required.
- No deferred page writes and no stored page/pager/vnode pointers: patching happens only inside the
  validation callback while the mapping is valid. This is the specific failure mode that caused the
  research branch's kernel page-fault panic.
- No IOKit registry matching inside the validation hooks (review D5). The hooks only acquire-load the
  published data flag and the cached VDA readiness flag; all IOKit work happens in the plugin's own
  early-boot/service/timer contexts.

## Auto-enable and boot arguments

The plugin is enabled automatically when NootedRed is present:

- `Info.plist` declares `org.ChefKiss.NootedRed` in `OSBundleLibraries`, so the satellite is resolved
  and loaded only when the main kext is installed; the version value is `$(MODULE_VERSION)` and keeps
  in sync with the main target because both share the project version.
- At runtime the plugin logs whether the NootedRed `IOService` is already visible in the IORegistry as
  a diagnostic; it does not gate the backend on that timing-sensitive lookup, because the kext loader
  has already enforced the dependency.

Debug boot arguments:

| Boot argument | Effect |
| --- | --- |
| `-NRedUserPatchOff` | Lilu's disable-argument handling rejects the plugin before `pluginStart`, so no data is selected, no routes are installed, and nothing is published. A defensive check in `init()` logs the state if the plugin is ever started despite the flag. |
| `-NRedUserPatchDebug` | Enables Lilu verbose logging for this plugin (`DBGLOG`). |
| `-NRedUserPatchBeta` | Allows loading on non-release kernels (Lilu beta gate). |

There is no boot argument that changes the embedded data selection.

## Building

Requirements: macOS, Xcode Command Line Tools, `xmake`, and a sibling AppleForge checkout with its
`Lilu` and `MacKernelSDK` submodules initialised. `xmake.lua` includes AppleForge from the
`AppleForgePath` environment variable, or `../AppleForge` when unset.

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export AppleForgePath=/path/to/AppleForge

xmake f -m release -y
xmake -y
```

**Git-worktree note.** xmake 3 resolves the *outermost* ancestor `xmake.lua` as the project. If this
tree is a git worktree nested inside another xmake checkout (for example
`/path/to/NootedRed/.agents/worktrees/...`), plain `xmake` silently builds the parent checkout instead
of this tree. Pin the project explicitly:

```sh
xmake f --project=. -m release -y
xmake --project=. -y
```

Allowed modes are `release`, `releasedbg` and `debug`.

Artifacts (per branch, platform, architecture and mode):

```
build/branches/<branch>/macosx/x86_64/<mode>/NootedRed.kext
build/branches/<branch>/macosx/x86_64/<mode>/NootedRed-<version>-<MODE>.zip
build/branches/<branch>/macosx/x86_64/userpatch/<mode>/NootedRedUserPatch.kext
build/branches/<branch>/macosx/x86_64/userpatch/<mode>/NootedRedUserPatch-<version>-<MODE>.zip
```

`<branch>` comes from `NRED_BUILD_BRANCH` and defaults to `shared` for direct `xmake` invocations. The
satellite artifact directory is a **sibling** of the per-mode directories (`.../<arch>/userpatch/<mode>`),
not nested inside them: AppleForge's `after_build` recursively archives `targetdir`, so nesting made the
NootedRed archive include the satellite bundle and intermittently race with the satellite build's file
moves. Keeping them siblings gives each target its own archive tree.

`NootedRedUserPatch.kext` is built with `AppleForge` (`LiluPlugIn`) and a Catalina deployment target
(`10.15`); `PluginConfiguration` restricts loading to `KernelVersion::Catalina .. KernelVersion::Tahoe`.

The embedded data source files (`PatchDataBlob.hpp/.cpp`) are generated and picked up by the existing
`NootedRedUserPatch/**.cpp` glob, so **no xmake change is needed** when the data set changes. They add a
bounded amount of generated code and `const` data to the kext.

## Installing

This scaffold does **not** install kexts or reboot anything. Manual install outline (OpenCore):

1. Keep the main kext installed. `Lilu.kext` and `NootedRed.kext` are required; the satellite declares
   `NootedRed` as a library dependency and will not load without it.
2. Copy `Lilu.kext`, `NootedRed.kext` and `NootedRedUserPatch.kext` into `EFI/OC/Kexts/`.
3. Add `NootedRedUserPatch.kext` to `Kernel -> Add` in `config.plist` (`Enabled = true`,
   `BundlePath = NootedRedUserPatch.kext`). Lilu must load first; the kernel resolves the NootedRed
   dependency regardless of the entry order.
4. Reboot. There is **no data directory to install**: the patch data for the supported builds is
   already inside the kext.
5. Verify that the plugin loaded and what it decided:
   `ioreg -l -n NootedRedUserPatch | grep NRedUserPatch`.
6. Rollback: remove the `NootedRedUserPatch.kext` entry from `config.plist` and the file from
   `EFI/OC/Kexts/`, or boot once with `-NRedUserPatchOff`. The main kext must remain fully functional
   with the satellite absent; that is the primary rollback path.

The kext must be loaded by the kernel through OpenCore/Lilu; it is not a user-space tool and there is
no installer script in this scaffold. Adding or updating a build is a **kext rebuild/re-sign**, not a
data drop-in (see below).

## Embedded patch data (no runtime file I/O)

The satellite does **not** read `/Library`, the kext `Resources` directory or any other path at
runtime. The exact-page data for every supported build is compiled into the kext by the data-pipeline
generator:

```
NootedRedUserPatch/PatchDataBlob.hpp   # generated index: NRedUserPatchData::kBuilds[], kBuildCount
NootedRedUserPatch/PatchDataBlob.cpp   # generated const manifest/pages byte arrays per build
```

Embedded builds (sorted by build string): `23J631`, `24H32`, `25G241` — exact-page tables of kinds
1 GL, 2 Metal, 3 VDA/VA and 4 VDA/AppleGVA as generated from the repo-root `PatchData/` tree.
`PatchData/23J631` (14.8.9) deliberately contains only VDA/VA and VDA/AppleGVA tables; a GL/Metal set
for that build is a documented data-pipeline gap, so GL/Metal stay unpatched there.

The generated files are owned by the data-pipeline task. Do not hand-edit them. Regenerate/verify after
any `PatchData/` change:

```sh
python3 tools/embed_patchdata.py               # deterministic regenerate PatchDataBlob.*
python3 tools/embed_patchdata.py --check       # staleness/CI check
python3 tools/test_embedded_patchdata.py       # array round-trip, index metadata, no-VFS tokens
python3 tools/test_userpatch_data.py           # independent v1 validator + malformed-data tests
python3 tools/convert_master_patchdata.py --check  # regenerate/verify the committed PatchData sets
```

Because the data is static, **adding a build requires regenerating `PatchDataBlob.*` and rebuilding and
re-signing the kext** — the approved stability tradeoff (no runtime data-path/VFS risk, no
unreadable-volume failure mode). A build that is not embedded is a terminal `BuildUnsupported` NoOp; it
is never guessed from Darwin.

External `PatchData/<build>/` remains only the generator input; it is not consumed by the running kext.
There is no runtime data directory to copy or remove.

The satellite parser enforces the same v1 contract as `tools/test_userpatch_data.py` on the embedded
bytes: packed little-endian records, `headerSize == 72`, `manifestSize = 72 + 24*tableCount +
16*pageCount + 76*siteCount`, canonical contiguous table/page/site ranges with strictly ascending table
kinds, limits (16 tables / 64 pages / 1024 sites, 128 KiB manifest, 256 KiB pages), zeroed
reserved/padding bytes, `find != replace`, no overlapping site writes, and both FNV-1a checksums. The
generated index metadata (checksums, Darwin, apuMask, counts) is used only as an early filter/diagnostic
mirror; the embedded bytes are always parsed and validated. The parser's record sizes are compile-time
asserted, so a compiler/ABI change cannot silently alter the format.

### Build identity sources

The loader resolves the running build from the kernel only and stops at the first non-empty source:

| Order | Source | Notes |
| --- | --- | --- |
| 1 | `sysctlbyname("kern.osversion")` | exact kernel build string, when the BSD layer is available in the calling context |
| 2 | XNU `osversion` global | populated by the kernel from the booter-provided build string |

There is deliberately **no filesystem/plist fallback**: forcing early kernel file I/O (including the
PatchData reads and the plist fallback from the previous external-data design) hung the boot, so the
embedded-data model keeps the boot path free of VFS work. If neither source is populated yet, the
loader reports the retryable `BuildUnavailable` state and the bounded timer retries while doing no file
I/O. The retry delay is converted with `NSEC_PER_MSEC`: `clock_interval_to_deadline()` is a raw
`interval * scale` in mach absolute-time units, so the earlier raw `1000` scale factor made every
nominal 2 s retry fire ~2 ms later and exhausted the whole bounded chain during early boot. On x86_64
`mach_absolute_time` is nanosecond-based (timebase 1:1), so the two-second spacing is now real.

Every identity source goes through the same strict validation (`[0-9A-Za-z._-]`, 1–15 bytes, no `.`/`..`,
single embedded-data key); an over-long or malformed value is rejected and never truncated. A build is
never derived from the Darwin version, and no source is a boot-argument path. `LoadAttempts` keeps
counting and the bounded retry still applies to transient identity/IOKit failures.

### Selection and APU matching

1. The embedded build table is searched for an entry whose `build` exactly equals the running
   `kern.osversion` string (for example `24H32`). There is no prefix, nearest-build or filesystem
   fallback; no match is a terminal `BuildUnsupported` NoOp.
2. The manifest `darwinMajor`/`darwinMinor` must match the running kernel; `darwinPatch` must match
   `kern.osrelease` when the kernel exposes a non-zero patch level, otherwise it must be `0`.
3. `apuMask` is an **intersection** test, not an equality test:
   `accept = (manifest.apuMask & candidateFamilyMask) != 0`. The embedded index `apuMask` is also used
   as a cheap early filter; the parsed manifest remains authoritative. Candidate bits are derived from
   the AMD iGPU device ID (`vendor-id == 0x1002`, display class) without reading NootedRed symbols:

   | Device ID | Candidate bits |
   | --- | --- |
   | `0x15DD` Raven | bit 0 |
   | `0x15D8` Raven2/Picasso | bits 1 and 2 (the STRAP0 revision is not read, so both are accepted) |
   | `0x1636`, `0x164C` Renoir/RenoirE | bits 3 and 4 |
   | `0x15E7`, `0x1638` Barceló/Green Sardine | bits 3 and 5 |
   | anything else | none: `NoOp` |

   A conservative candidate set cannot cause a mismatched write: the complete 4 KiB page equality
   check is the final gate.
4. Any validation failure leaves the plugin loaded but inert (`State = NoOp` in the log and IORegistry).
   The routes remain installed and no-op.

## VDA readiness contract with the main kext

GL and Metal pages apply independently. VDA/VA and VDA/AppleGVA pages (table kinds 3 and 4) are only
applied while the main kext reports the VCN bridge ready:

- property name: `NRedVCNBridgeReady`
- type: 32-bit property, value non-zero while ready
- location: the AMD iGPU `IOPCIDevice` only (published by `NRed::setProp32`, task-3 merged). There is
  no `NootedRed`-service fallback: the main kext does not write that property anywhere else.
- semantics: written only after `VCNBridge::loadReady()` is true (requested + X5000 prepared + X6000
  prepared + loadCompleted), and withdrawn on rollback/failure paths.

The satellite resolves the property only from safe contexts (patcher load, `IOService::start`, and the
bounded readiness refresh timer) and caches a boolean in `UserPatchBackend`. The validation hooks read
that cached boolean with a single acquire load; they never walk the IORegistry (review D5).

If the property is absent or zero, VDA pages are left unpatched (logged once) and decode falls back to
the stock behaviour. An already-patched or skipped page is not revisited for a later mapping, so a VDA
page validated before readiness is simply left stock.

## Runtime states and bounded retry

State transitions are serialised by a single `IOLock` owned by `UserPatchRuntime` (review D4). The
validation hooks do not take that lock; they acquire-load the immutable published data flag and the
cached readiness flag, and update their counters with atomics.

| State | Meaning |
| --- | --- |
| `Idle` | plugin kmod started; no data attempt yet. |
| `Loaded` | validated embedded manifest/pages are published; hooks may now write matching pages. |
| `NoOp` (retryable) | transient failure (`BuildUnavailable`, `ApuUnknown`). The bounded retry keeps trying; no file I/O. |
| `NoOp` (terminal) | deterministic failure (`BuildInvalid`, `BuildUnsupported`, `BuildMismatch`, `DarwinMismatch`, `ApuMismatch`, malformed/checksum/size/site errors, limits, memory). No further load attempts for this boot. |

Entry points:

| Entry point | What it does |
| --- | --- |
| plugin kmod start (`init`) | allocates the state lock and registers the Lilu patcher-load callback; no IOKit/VFS work. |
| Lilu patcher load (`onPatcherLoad`) | installs both routes unconditionally, then attempts embedded-data selection + readiness refresh, then arms the retry timer if work remains. |
| `IOService::start` (`serviceStart`) | retries selection + readiness refresh and publishes diagnostics. It never routes kernel text and cannot install a second time. |
| delayed `thread_call` (`retryCallback`) | bounded retries of identity/selection/readiness in a kernel thread; never touches page pointers. |

Bounded retry policy:

- load retries: up to 15 attempts, 2 s apart (covers `kern.osversion`/IOKit not being ready when the
  plugin starts). The delay is converted with `NSEC_PER_MSEC` because
  `clock_interval_to_deadline()` expects absolute-time units, not milliseconds;
- readiness refreshes: up to 12 attempts, 5 s apart, after data is loaded (covers the VCN bridge
  becoming ready slightly later during boot);
- once either bound is reached, the plugin logs `delayed retries finished: ...` with the final state
  and stops scheduling timers. The routes stay installed and inert.

If the plugin is disabled (`-NRedUserPatchOff`), Lilu rejects it before `init()` and no lock, routes,
timers or properties exist.

## Diagnostics

Log tags: `init` (plugin lifecycle/state machine), `UserPatchData` (embedded data selection/validation),
`UserPatch` (hook installation, readiness, page application). Explicit `no-op: <Reason> (<detail>)`
lines are emitted for every fail-closed decision.

IORegistry properties on the `NootedRedUserPatch` service (republished on every entry point/retry):

| Property | Meaning |
| --- | --- |
| `NRedUserPatchState` | `Idle` / `Loaded` / `NoOp` |
| `NRedUserPatchReason` | last reason (`None`, `BuildUnsupported`, `BuildMismatch`, `ApuMismatch`, ...) |
| `NRedUserPatchBuild` | running build string used for selection |
| `NRedUserPatchBuildSource` | identity source (`sysctl:kern.osversion` or `xnu:osversion`) |
| `NRedUserPatchDataSource` | `embedded:<build>` after selection; empty before it (not a filesystem path) |
| `NRedUserPatchApuMask` | candidate APU bits derived from the iGPU |
| `NRedUserPatchAppliedApuMask` | intersection with the manifest `apuMask` |
| `NRedUserPatchPages`, `NRedUserPatchSites` | validated table sizes |
| `NRedUserPatchHooks` | `1` when the `_cs_validate_page` route is installed (installed even when data is NoOp) |
| `NRedUserPatchRangeHook` | `1` when the `_cs_validate_range` route is installed (optional extra) |
| `NRedUserPatchVdaReady` | cached `NRedVCNBridgeReady` state used by the VDA gate |
| `NRedUserPatchAppliedPages` | distinct pages patched, as of the last state publish |
| `NRedUserPatchLoadAttempts` | data-selection attempts so far |
| `NRedUserPatchReadinessRefreshes` | readiness-refresh attempts so far |
| `NRedUserPatchRetryPending` | `1` while a bounded retry timer is armed |

## Failure paths

Every one of these is an expected, safe state; the plugin stays loaded, the routes stay installed and
no page is written:

| Reason | Cause |
| --- | --- |
| `BuildUnavailable` | no build identity yet: `kern.osversion` sysctl and XNU `osversion` are empty/not populated (retryable) |
| `BuildInvalid` | build string empty, over-long or not a usable embedded-data key (terminal) |
| `ApuUnknown` | iGPU missing or device ID not in the supported APU table, or IOKit not ready yet (retryable) |
| `BuildUnsupported` | the running build has no embedded PatchData set; the available build strings are logged (terminal) |
| `ManifestTooLarge` | embedded manifest exceeds the 128 KiB v1 ceiling (terminal) |
| `ManifestInvalid` / `ManifestChecksumMismatch` | magic/version/header/layout/ranges/padding/checksum mismatch, including an empty blob (terminal) |
| `BuildMismatch` / `DarwinMismatch` / `ApuMismatch` | exact embedded/manifest selection failed (terminal) |
| `PagesTooLarge` / `PagesSizeMismatch` / `PagesChecksumMismatch` | embedded pages size limit, length or FNV-1a 32 mismatch (terminal) |
| `SiteInvalid` | site outside its page, find bytes absent at the offset, bad size/padding, overlap (terminal) |
| `LimitExceeded` / `MemoryFailure` | counts beyond v1 limits / allocation failure (terminal) |

`BuildUnavailable` and `ApuUnknown` are retryable and are retried by the bounded timer described above;
all other reasons are terminal for the boot because the embedded data cannot become valid later.
`-NRedUserPatchOff` is not a runtime reason: Lilu rejects the plugin before it starts.

This directory has no host test runner for the kernel parser itself because it depends on kernel/Lilu
headers. The equivalent host validation is the independent `tools/userpatch_data.py`/
`tools/test_userpatch_data.py`, `tools/embed_patchdata.py --check` and
`tools/test_embedded_patchdata.py`; the generated arrays are round-trip checked against the committed
`PatchData/` bytes.

## Source layout

| File | Purpose |
| --- | --- |
| `Plugin.cpp` | `PluginConfiguration`, own `IOService`, locked runtime state machine, bounded `thread_call` retry, IORegistry diagnostics |
| `PatchData.hpp/.cpp` | embedded build selection, kernel build/APU identity, manifest parser/validator, checksums, iGPU readiness query |
| `PatchDataBlob.hpp/.cpp` | **generated** embedded PatchData index and byte arrays (data-pipeline owned; do not hand-edit) |
| `UserPatchBackend.hpp/.cpp` | `_cs_validate_page` / `_cs_validate_range` routes, exact-page compare, cached VDA readiness, atomic counters, serialised writes |
| `Info.plist` | bundle identifier, Lilu + NootedRed dependencies, IOKit personality |

## Known limitations (phase 2)

- No hardware/boot validation yet. The embedded builds (`24H32`, `25G241`, `23J631`) have not been
  exercised by a boot of this kext on real hardware.
- Only the embedded builds can run: any other macOS build is a terminal `BuildUnsupported` NoOp.
  Adding/updating a build requires regenerating `PatchDataBlob.*` and rebuilding/re-signing the kext.
- The kext carries the embedded data payload (currently ~135 KiB of generated `const` arrays) plus its
  generated source; this increases the bundle size compared with an external-data design.
- `PatchData/23J631` is VDA-only (no GL/Metal kinds), so GL/Metal stay stock on 14.8.9 until the data
  pipeline pins a build-exact GL/Metal set.
- Manifest v1 has no driver-binary hash: the exact 4 KiB page equality is the driver identity gate.
- Data is keyed by exact build only; one build cannot carry per-APU-divergent page sets in v1.
- APU family detection is conservative and does not read the STRAP0 revision register, so it accepts
  the family's candidate bit set (never a different family).
- The VDA readiness cache is refreshed for a bounded window after boot. A readiness withdrawal later
  than that window (for example an accelerator stop/restart after boot) is not observed, so VDA pages
  could remain eligible on a stale cached `true`. Exact-page gating still applies; this is a
  boot-timing/rollback limitation to validate on hardware.
- If the bounded retries are exhausted, the satellite stays inert for the rest of the boot; it does not
  poll indefinitely.
- No installer helper (`NootedRedUserPatchCtl`) in this scaffold.
