# Compatibility Architecture: Multiple macOS Versions and APUs

Status: design + Milestone 1 (2026-10-19). Baseline: `master` at `ca97c42`.

This document is the reference design for making the Chromium/Electron rendering fix and VCN/UVD
hardware encode/decode work across multiple macOS builds and multiple AMD APUs, without duplicating
patch data per (version, APU) pair. It states the model, the invariants, the data pipeline, the branch
integration order, and the milestones with acceptance criteria.

## 1. Problem

Two features must span a matrix of machines:

- **Rendering fix** (`UserPatches`): in-memory patches of the user-space `AMDRadeonX5000GLDriver` and
  `AMDRadeonX5000MTLDriver` that correct the Renoir HwInfo shader-engine count and install a
  per-pipeline `DISABLE_DUAL_QUAD` policy. Currently validated for one build (macOS 15.8.1 / Renoir).
- **VCN/UVD** (`feature/vda-hardware-decode`): a kernel bridge that borrows Apple's native X6000 VCN2
  engine into the X5000 accelerator, plus user-space patches of `AMDRadeonVADriver2` and AppleGVA.
  Currently validated for one build and one device (macOS 15.8.1 / `0x1638`).

The goal is one kext binary and one data model that:

1. selects behaviour from the running machine at runtime;
2. fails closed (no-op, never a wrong-page write or a half-applied feature) on unknown combinations;
3. turns "add a macOS build" or "add an APU" into a data change, not a logic change.

## 2. Current state

| Component | `master` | Feature branches | Problem |
| --- | --- | --- | --- |
| Patch selection | single `PagePatch` table, `-NRedGLFix` | `PatchSet{minVersion,maxVersion,ApuMask}` in `feature/multi-os-multi-apu`, `feature/tahoe-26.7.1` | version and APU are one conjunctive key |
| Site location | exact 4 KiB page image + `find`/`replace` | `SignaturePatch` (32 B masked context) in `research/patch-resolver` | per-build snapshots; resolver is a smaller snapshot |
| Hardware model | `DeviceProfile` (device ID key, media all false) | VDA branch adds VCN generation/firmware/ring fields | version range unused; media fields unreachable |
| VCN data | none | `VCNKernelData.hpp`, `VDAVAData.hpp`, `VDAGVAData.hpp`, generators with `--check` | all data pinned to 15.8.1 / `0x1638` |
| Data collection | `platform-data/`, `tools/collect_platform_data.py`, importer | — | captures binaries but no generated consumer; `kexts.json` has `binary: null` |
| Media capability | personality advertises `IOGVACodec=AMDVCN2` unconditionally | `hasVCN0` from profile, all false | advertisement and kernel capability have different sources |

This section records the state before the branch integration described in §8. After that integration,
`master` carries the `PatchSet` framework, the Tahoe page data and the VDA module; the resolver and the
iGPU/HwInfo research remain on their research branches.

Recent data points that motivate the redesign:
- `0x1638` and `0x164c` on the same macOS 26.7.1 build have identical GL/MTL driver hashes but different
  CU counts (8 vs 7), revisions and VRAM. APU metadata cannot be inferred from the driver binary.
- The VDA branch generates kernel/kext UUIDs, driver versions and segment hashes, but the runtime only
  checks the `24.6` / `24H32` string; the identity pins are never compared.
- `research/patch-resolver` proved the signature path works on hardware, and also showed signature
  contexts must be scoped to a module/page; the Metal signatures currently have no module filter.

## 3. Why the current model does not scale

### 3.1 Two axes are multiplied, but they are independent

The current `PatchSet` keys on `(Darwin major.minor, APU mask)`. In reality:

- *where a patch site is* depends on the **Apple binary build** being patched
  (GL bundle, MTL cache image, X5000/X6000 kext, VADriver2, AppleGVA);
- *whether to patch, and with what value* depends on the **hardware capability**
  (RB+ allowed, real SE/CU configuration, VCN generation, firmware variant).

Doubling each axis creates an N×M table of snapshots. Splitting them gives N+M.

### 3.2 Version numbers are proxies that are both too coarse and too strict

One Darwin `major.minor` can cover several OS builds (point/security updates) while the driver is
unchanged, and the same driver can span several OS versions. A version-keyed table therefore:

- misses builds that would work (new data required even though the binary is identical), and
- silently matches builds whose driver changed within the same Darwin minor (the page gate then turns
  the feature off, which is safe but invisible).

The stable identity of "what I am patching" is the binary, not the OS version string.

### 3.3 Exact-page snapshots cannot be the primary locator

A full 4 KiB page image is an excellent *final* check (zero false positives, works with KASLR because
it is content-based). It is a poor *locator*: any unrelated change in the page invalidates it, so every
build needs a human to extract and validate a snapshot, and GL/MTL targets can be half-matched.

### 3.4 Hardware facts are baked into patch bytes

`kGLDriverHwInfoReplace` embeds `numShaderEngines = 1` directly in the replacement bytes. If an APU or
SKU needs another value, the whole page image must be duplicated. Site and value must be separated.

### 3.5 The VCN bridge is a per-build ABI marriage

Borrowing the X6000 engine means matching six vtable slots per driver, 20 call sites, metaclass pairs,
the engine slot index and the getter semantics. This is the least version-stable construct in the
project. It cannot be made version-independent; it can be made *identity-verified* and *symbol-based*,
and it must degrade atomically.

## 4. Design

### 4.1 Two independent axes

```
PatchPlan = decide(feature,
                   targetIdentity,      // which binary image is loaded
                   capabilityProfile)   // what the APU can do
```

- `targetIdentity`: the Apple binary (kind + UUID + version + page/segment hash). Selects the site list.
- `capabilityProfile`: family/capability facts (RB+ allowed, real SE/CU configuration, VCN generation,
  firmware variant, codec support). Selects whether each site applies and which values are written.

The support matrix is a sparse table of `(targetIdentity, capabilityProfile) -> level`, not a dense
version × APU grid.

### 4.2 Target identity

Every patchable image is described by a `CompatTarget`:

| Field | Meaning | Source |
| --- | --- | --- |
| `kind` | GL bundle / MTL cache image / kernel kext / VADriver2 / AppleGVA | static |
| `uuid` | Mach-O `LC_UUID` (bundle/cache) or kext UUID | binary header, kext info |
| `version` | `CFBundleVersion` / kext version, for logs only | Info.plist, kext info |
| `segmentHash` | hash of the patched segment/page | generated data |
| `sites` | ordered patch sites with anchors and verification | generated data |
| `minVersion`,`maxVersion` | optional OS range *metadata*, not the selector | generated data |

Resolution at runtime, in order of preference:

1. **user-space bundle** (`_cs_validate_page`): the hook has the vnode; read the Mach-O header and
   `LC_UUID`. Scope every write to that vnode/module.
2. **dyld shared-cache image** (`_cs_validate_range`): resolve the cache UUID and the image's file
   offset, never a hardcoded base VA. The cache base moved between 15.8.1 and 26.7.1 and will move
   again.
3. **kernel kext**: `KernelPatcher::KextInfo` UUID/version plus the generated segment hash.

An unknown identity is not an error: it logs one canonical line and installs nothing.

### 4.3 Site vs value

Every site is separated into two parts:

```cpp
struct PatchSite {
    CompatTarget* target;      // identity selects the site list
    uint32_t      pageOffset;  // or "any", or function + offset
    const uint8_t* anchor;     // masked context / symbol anchor
    const uint8_t* mask;
    size_t         anchorSize;
    size_t         siteOffset; // relative to anchor
    PatchValue     value;      // literal bytes OR a capability-derived field
    CapabilityMask requires;   // e.g. rbPlus, vcn2, validatedBuild
};
```

`PatchValue` is either literal bytes or a small enum naming a profile field (`numShaderEngines`,
`vcnRingSize`, `vcnFirmware`, `vaFamily`). Capability-derived values are resolved at apply time, so a
single site list serves every APU that shares the binary.

### 4.4 Capability profile (APU axis)

`DeviceProfile` is the single source of truth. It is device-keyed today and evolves to:

- **family**: `Raven`, `Raven2`, `Picasso`, `Renoir`, `RenoirE`, `GreenSardine`, `Cezanne`, `Barcelo`;
- **graphics policy**: conditional dual-quad fix, HwInfo correction, RB+ allowed, shader-engine count;
- **media policy**: UVD/VCE/VCN presence, VCN generation, firmware name and IP version, ring sizes,
  codec capabilities;
- **validation level**: unavailable / experimental / validated, for the coarse roll-up only.

Where cheap and safe, capabilities are **probed** instead of enumerated: GC IP version and real
SE/CU/RB configuration for graphics, VCN IP version and firmware variant for media, RB+ from the
same predicate Mesa uses (`Stoney`, `Vega12`, `Raven`, `Raven2`, `Renoir`, `gfx10.3+`). A device-ID
table remains the fallback for hardware that cannot be probed that early.

Unknown devices become an explicit "unsupported" outcome instead of a panic. The panic in
`NRed::processPatcher()` currently also makes the `DeviceProfile` fallback unreachable; the unknown
device policy lands in Milestone 2 together with the probe path.

### 4.5 Runtime pipeline

```
discover hardware ──▶ identify loaded binaries ──▶ build plan ──▶ verify every site ──▶ apply atomically ──▶ publish capability
        │                     │                          │                    │
   DeviceProfile        CompatTarget              PatchPlan             fail-closed
```

- The plan is built for a feature (rendering or media) across all its targets.
- Every site is verified (identity, anchor, semantic check) before the first write.
- Writes happen only if the whole plan verifies; otherwise nothing is written and the reason is logged.
- Capability is published last (`hasVCN0`, `conditionalDualQuad`), only after the plan applied.

### 4.6 Invariants

1. **Capability ≤ applied.** Never advertise a feature to the OS before the corresponding patch/engine
   is actually in place. (Legacy NootedRed advertised `HasVCN0` unconditionally and gated only user
   space; that asymmetry caused the historical failures.)
2. **Fail closed.** Unknown identity, version, or site ambiguity means no-op with a log line.
3. **No half patch.** A feature is applied across all of its targets or not at all.
4. **Never patch a page that failed code-signing validation.**
5. **Identity drift disables, never guesses.** A masked anchor may tolerate drift only inside an
   explicitly verified function scope.

### 4.7 Verification ladder

| Level | Mechanism | Cost | Use |
| --- | --- | --- | --- |
| L0 | exact 4 KiB page image equality | 4 KiB per site-page per build | fast path for validated builds |
| L1 | symbol/function-scoped masked anchor | ~32–128 B per site | unknown-but-recognizable builds |
| L2 | instruction-semantic decode before write | code | required for L1 |
| L3 | post-write decode + ambiguity rejection | code | always when L1/L2 is used |

L1 requires symbol resolution: the GL bundle and MTL image have symbol tables; the kernel collection
has C++ symbols. A function-scoped search makes unrelated code churn irrelevant and reduces false
positives by orders of magnitude. `PatcherPlus.hpp` already has `jumpInstDestination()`, so the
instruction decoder has a place to live.

The `research/patch-resolver` prototype is the seed of L1–L3. Its 32-byte full-mask contexts are still
per-build snapshots, and its Metal signatures have no module scope; both are Milestone 3 work.

### 4.8 Support levels and logging contract

Every feature decision emits exactly one canonical line, e.g.:

```
Compat: feature=GLFix target=AMDRadeonX5000GLDriver uuid=... level=validated sites=2 darwin=24.6 apu=Renoir
Compat: feature=VDA target=AMDRadeonVADriver2 level=unavailable reason=uuid-mismatch
```

Coarse roll-up for the current profile (Milestone 1):

```
Compat: profile="Renoir/Green Sardine" family="Green Sardine" level=validated device=0x1638 rev=0xC5
        darwin=24.6 graphics{dualQuad=1 hwInfo=1 rbPlus=1 numSE=1} media{gate=0 vcn=0x0000 fw=none}
```

The same values are published as IORegistry properties (`NRedCompatDeviceID`, `NRedCompatFamily`,
`NRedCompatLevel`, `NRedCompatNumShaderEngines`, `NRedCompatVCNGeneration`) for field triage.

## 5. Media (VCN/VDA) specifics

### 5.1 Kernel bridge: identity by symbol, not by byte snapshots

The X6000 bridge needs to locate vtable slots and call sites in two kernel drivers. Generated data
must verify:

- the vtable symbol (`__ZTV...`) and the slot index;
- the method identity (demangled name, argument shape, `classSize`) rather than raw getter bytes;
- the call-site bytes and their instruction boundaries.

The branch already verifies six slots per driver and applies the 20 call-site patches with rollback.
Moving slot identity from byte snapshots to symbol + method semantics is the Milestone 5 change that
makes the bridge survive more builds.

### 5.2 VCN1 is an architecture fork, not more data

The X6000 VCN2 engine cannot serve Raven/Raven2/Picasso (VCN 1.x). Covering them requires either

- **Option B**: a VCN engine implemented with `RuntimeMC` (own rings, firmware, commands), or
- **command translation** VCN2 → VCN1 (the legacy approach; historically HEVC decoded, H.264 did not).

This decision must be made before the media capability model is finalized. It determines whether
`MediaPolicy` describes "engine borrowed from X6000" or "engine owned by NootedRed", and what the
user-space patch set has to translate.

### 5.3 Personality and capability must share one source

`Personalities/com.apple.kext.AMDRadeonX5000.xml` is embedded at compile time and advertises
`IOGVACodec=AMDVCN2`, H.264 and HEVC unconditionally. On a VCN1 APU, or when `-NRedVDA` is off, this
claims an engine that does not exist. The personality must be generated (or trimmed at injection time
in `DriverInjector::wrapAddDrivers`) from the same `MediaPolicy` that drives `hasUVD0/hasVCE/hasVCN0`,
with codec capabilities matching the VCN generation.

## 6. Data pipeline and manifest

Target state:

```
collect_platform_data.py  ->  platform-data/<dataset>/
        |
        v
build_compat_manifest.py  ->  compat/compat-manifest.json   (git tracked, deterministic, diffable)
        |
        v
gen_compat_header.py      ->  NootedRed/Generated/CompatManifest.hpp  (constexpr tables)
```

Rules:

- The manifest is the only hand-maintained input; headers are generated and committed.
- **Data-only rule**: adding a macOS build or an APU changes `compat/` data and generated headers, not
  selection logic. This is the acceptance test for the architecture.
- CI regenerates and diffs (`--check` pattern already used by `gen_vcn_kernel_data.py`).
- `data-lint` checks: page hash matches the page image, `find`/`replace` bounds, anchor uniqueness per
  `(module, page)`, every device ID has a profile, patch-set ranges do not overlap, every entry has a
  validation level.
- The collector gains: VADriver2/AppleGVA bundles, VCN/PSP/RLC/DMCU firmware blobs and hashes,
  structured IORegistry GPU/media properties, kext versions and Mach-O binaries, and the hardware
  capability probes.

## 7. Support matrix

The matrix is generated from the manifest and printed in the documentation (the table below is
illustrative until Milestone 4):

| macOS build | APU | feature | level | evidence |
| --- | --- | --- | --- | --- |
| 15.8.1 (24H32) | Renoir `0x1638` | GL/Metal fix | validated | `analysis/hwinfo-capability-source.md` |
| 15.8.1 (24H32) | Renoir `0x1638` | VDA decode/encode | validated (`-NRedVDA`, default off) | `analysis/vda-1581-hardware-validation.md` |
| 26.7.1 | `0x1638`/`0x164c` | GL/Metal fix | experimental | `feature/tahoe-26.7.1` data, unverified |
| any | Raven/Raven2/Picasso | GL/Metal fix | experimental | code-compatible, no hardware validation |
| any | Raven/Raven2/Picasso | VDA | unavailable | VCN1 not implemented |
| other builds | any | any | no-op | no target identity match |

The table is a view of the data, not a hand-written claim.

## 8. Branch integration plan

Current branches all cut from `4b4421f` and each edits `UserPatches.cpp` independently
(`+94`, `+113`, `+179`, `+235` lines), so merging them in arbitrary order will conflict. Integrate in
this order:

1. **Framework** (`feature/multi-os-multi-apu`): `PatchSet`/`ApuMask`/selection/generator/tests.
   Rebase onto `master` and keep master's `DeviceProfile::graphics.conditionalDualQuad` gate and the
   `UserPatches::init()` ordering; the branch moved `init()` to after the patcher-load callback.
2. **Resolver** (`research/patch-resolver`): rebase on the framework; harden it (module/page scope,
   function scope, semantic verification) instead of merging its prototype as-is.
3. **Tahoe data** (`feature/tahoe-26.7.1`): data-only commit on the new framework.
4. **VDA** (`feature/vda-hardware-decode`): rebase; replace the exact `24H32` gate with identity
   verification and feed its decisions through the same plan/log path.
5. **Research branches** (`research/igpu-hwinfo-logic`): documentation/analysis, merge last.

Status: steps 1, 3 and 4 are merged into `master` (2026-10-19); step 2
(`research/patch-resolver`) and step 5 remain on their research branches. No branch was rebased: the
conflicts were resolved by keeping the framework's `PatchSet` selection and the VDA module's direct
`processPatcher` wiring, and by merging both halves of `DeviceProfile` (capability/version model from
this work plus the media data from the VDA work).

## 9. Milestones

### Milestone 1 — Foundation (implemented in this change)

- Design document (this file).
- `DeviceProfile` v2:
  - explicit `Cezanne`/`Barcelo` families and corrected device-to-family mapping;
  - `SupportLevel` per profile (coarse roll-up);
  - `GraphicsPolicy::rbPlusAllowed` and `numShaderEngines` capability fields;
  - `MediaPolicy::vcnGeneration` is a `UInt32`-backed `VcnGeneration` enum (it was `UInt8` and could not
    hold `0x0202`); the VDA work merged at the same time adds firmware, ring/fence and decode-capability
    fields, with engine enablement still default-off;
  - version-aware lookup: `forDevice(deviceID, version)` and `current()` honour
    `minVersion`/`maxVersion`;
  - compile-time invariants: unique device IDs, valid ranges, graphics enabled, media enablement limited
    to the hardware-validated profile.
- `CompatTarget` target-identity type and bounds-checked Mach-O `LC_UUID` parser
  (`NootedRed/CompatTarget.{hpp,cpp}`). Boot-time capture is deliberately **not** wired yet: the first
  implementation read the driver file through the VFS during Lilu's patcher-load phase, which turned out to
  be the only new early-boot side effect in the merged tree and is suspected of stalling boot, so it was
  removed. Identity capture returns in Milestone 2 using in-memory page/vnode data.
- Canonical decision log + IORegistry properties (`DeviceProfile::logCurrent()`), emitted once after
  device detection.
- No behaviour change: all existing profiles keep the same graphics policy and disabled media; the log
  additions are passive.

Acceptance: `xmake -m release` builds; the existing default behaviour is unchanged; the log line
contains the profile, family, level, Darwin version and both policies.

### Milestone 2 — Target identity and unknown-device safety

- `CompatTarget`/`PatchSite` types and the generated-table scaffold.
- Runtime identity: capture `LC_UUID` from the code-signing hook's in-memory page data (or vnode name
  resolution at a safe phase), cache UUID + image offset for MTL, kext UUID for kernel patches. Do not
  reintroduce file I/O in Lilu's patcher-load phase.
- Unknown device becomes "unsupported" no-op (no panic) with a probe/log path; `DeviceProfile`
  fallback becomes reachable.
- Wire the multi-OS framework onto these types; add `data-lint` for target tables.

Acceptance: on 15.8.1 the selected target UUIDs are logged; a deliberately renamed/patched driver page
turns the feature off with a reason; adding a build only touches generated data.

### Milestone 3 — Anchors and semantic verification

- Function/symbol-scoped anchors, masked contexts, instruction decode before/after write, ambiguity
  rejection, module/page scoping for both GL and MTL.
- Upgrade `research/patch-resolver` to L1–L3 and keep L0 as the validated fast path.
- Generate anchors from symbols in `gen_patch_data.py`; validate anchor uniqueness offline.

Acceptance: resolver QA mode (`-NRedGLFixResolveOnly`) still passes on 15.8.1; a build whose page
changed but whose function bytes did not is handled without new snapshots; ambiguity is a no-op.

### Milestone 4 — Manifest pipeline

- `compat/compat-manifest.json` + generator + CI `--check` + `data-lint`.
- Extended collector/importer (media bundles, firmware, probes, kext binaries).
- Generated support matrix in docs.

Acceptance: adding a dataset from a collected machine produces headers and a matrix row without
touching `.cpp` logic.

### Milestone 5 — Media multi-build bridge and VCN1 decision

- Bridge identity by symbol/method semantics; capability-gated personality generation.
- VCN1 decision executed (Option B or translation), `MediaPolicy` finalized.
- Decode/encode capability surfaced per VCN generation; no advertisement before application.

Acceptance: the bridge fails closed on an unmatching kernel collection; media capability matches the
validated matrix; VCN1 either works on hardware or is explicitly unavailable.

## 10. Risks and non-goals

- **Anchor false positives.** L1–L3 trade snapshot safety for reach; ambiguity rejection, module
  scope, semantic decode and opt-in boot arguments are mandatory.
- **VCN bridge fragility.** Even with identity checks, a cross-driver ABI can break in any build. It
  must stay default-off until validated for a build, and every failure must leave graphics-only state.
- **Validation capacity.** Only Renoir hardware is available; other APUs need testers and the
  self-describing log lines. A code-level mask is never a hardware validation claim.
- **Non-goals**: supporting every macOS build automatically; advertising decode/encode before the
  engine and user-space halves are both ready; copying generated data from third-party forks.

## 11. References

- [Contributing to UserPatches](CONTRIBUTING-USERPATCHES.md)
- [Chromium/Electron fix usage](Chromium-Fix-Usage.md)
- [Device profile / media capability layer](Device-Profile.md)
- [`analysis/multi-os-multi-apu.md`](../analysis/multi-os-multi-apu.md)
- `analysis/patch-resolver.md` (`research/patch-resolver`, research branch only)
- [VDA implementation plan](VDA-Implementation-Plan.md) and
  [`analysis/vda-1581-hardware-validation.md`](../analysis/vda-1581-hardware-validation.md)
- [Platform data collector](../tools/README-collect-platform-data.md)
- [Platform data index](Platform-Data-Index.md)
