# PatchAnalyzer — host-side Mach-O / dyld-cache function analysis and NRPT generation

Status: implementation notes for `NootedRedTool/Sources/NootedRedTool/PatchAnalyzer/`.
Contract: `../../docs/PatchProfile-Spec.md` (NRPT v3, frozen 2026-10-29). Design background:
`../../analysis/lilu-dyld-shared-cache-profile-engine.md` (local, untracked).

> This pipeline is CLI-only. The SwiftUI 「驱动解码」page still writes the retired
> `NRedOffsetProfile`/`NRP3` blob, which the satellite does not read — see `../README.md`
> 「已知缺口」. Only `--generate-profile` / `--bundle-profiles` produce a profile the kext accepts.

The analyzer replaces the fixed page/find/replace tables with **semantic discovery from the
target image**: every value written into the NRPT profile is derived from the clean driver
binaries, decoded x86_64 instructions and validated control-flow graphs. There are no hardcoded
patch addresses, page offsets, `find` or `replace` bytes in the generator.

## Components

| File | Responsibility |
| --- | --- |
| `BinaryImage.swift` | Bounds-checked little-endian reader; full 64-bit Mach-O parser (LC_SEGMENT_64 with sections, LC_SYMTAB, LC_DYSYMTAB, LC_FUNCTION_STARTS); split dyld-shared-cache store that unions every subcache mapping table, discovers the image-text array from the cache header (structural validation, `.map` fallback) and translates VM addresses to `(subcache file, file offset)`. |
| `Decoding.swift` | Real x86_64 disassembler: Capstone 5 loaded dynamically (`dlopen`), `cs_insn` layout verified by a self-test before use; strict Intel-syntax operand parser (registers, immediates, memory base/index/scale/displacement). Fails closed when Capstone is unavailable — no byte-scan fallback. |
| `FunctionAnalysis.swift` | Function extents from `LC_FUNCTION_STARTS` (symbol/next-symbol fallback), whole-body decode with 100% byte-coverage validation, basic blocks, branch-target-on-boundary checks, reachability, and an Objective-C metadata parser (`__objc_classlist` → `class_ro_t` → method lists, relative and classic layouts). |
| `SemanticRules.swift` | The rule engine and the 13 semantic rules that resolve the 20 sites on macOS 15.8.2/24H232 (GL/Metal gfx9 HwInfo, GL dual-quad, Metal RB+ gate/allow, VDA accelerator/addrlib/factory/feedback-stride/chip-family, VDA encoder source pitch, AppleGVA AVDGetGPUAccelerators). Each rule resolves a function through symbols or parsed ObjC metadata, matches instructions by decoded semantics, requires exactly one unambiguous match, derives `find` from the image and synthesises a same-length `replace` whose decoded effect is re-validated. |
| `ProfilePipeline.swift` | Fixture environment (build, APU mask, device ID, user-patch-loaded guard), image set, NRPT v3 profile construction through `ProfileCodec.encode` (image table with kind/canonical path/unslid VM address/`__TEXT` extent, per-page `mode`+`imageIndex`+`pageVmOffset`), page hashes, identity-collision scan over every target `__TEXT` page, offline validator built on `ProfileCodec.applyPage` with mode routing plus image-metadata re-resolution and selector simulation, JSON evidence and the CLI (single profile and bundle). |
| `ProfileBundle.swift` | `--bundle-profiles` manifest parsing (fixture-root and/or prebuilt-profile entries, identity overrides that must match the header) and the bundle evidence JSON. Plist serialization is delegated to `ProfileCodec.encodeBundlePlist` / `nredProfilesArray`; the tool does not reimplement the `NRedProfiles` wire format. |

## CLI

```
NootedRedTool --generate-profile <fixture-root> --out <dir>
NootedRedTool --validate-profile <profile.nrpt> --fixture-root <fixture-root>
```

- `<fixture-root>` is an extracted `collect_validation_fixtures.py` tree (containing
  `System/...`), or `/` for the running clean system. When `NootedRedUserPatch` is loaded,
  generating from `/` is refused; pass an extracted fixture root (or set `NRED_FIXTURE_ROOT`)
  instead so the profile is never derived from patched pages.
- Output: `nred-<build>.nrpt` plus `nred-<build>-evidence.json`. The evidence contains the parsed
  function extent, matched instruction text, semantic intent, find/replace, page file offset,
  page hash, match flags, the decoder used, identity-collision scan and the full offline-validation
  report. The profile itself is byte-identical for identical inputs (no timestamps/paths).
- `NRED_ANALYZER_DEBUG=1` prints cache/image discovery and image-wide scan diagnostics.
- `NRED_CAPSTONE_LIBRARY=<path>` overrides the Capstone dynamic library.

Generation fails closed (no profile written) on: missing Capstone, unresolved/ambiguous function,
zero or multiple semantic matches in the expected function(s), non-decodable function body, a page
whose 4 KiB read is short, an unintended page matching a profile page identity, any model rule
violation from `ProfileCodec.encode`, or a failure of the built-in offline validation.

## NRPT v3 patch modes and target-image metadata

The profile is NRPT **v3** (docs/PatchProfile-Spec.md). Every page record states the validation
route it belongs to: `mode` is `PAGE` (1) for a page of a standalone file-backed image (the GL
driver bundle, applied from `_cs_validate_page`) and `DYLD` (2) for a page of a dyld shared-cache
image (Metal/VADriver2/AppleGVA, applied from `_cs_validate_range`). The mode is derived from the
parsed image kind and is never guessed from addresses; v3 also rejects a mode/image-kind mismatch.
There is no offset identity and no matchFlags: page identity is the full-page FNV-1a-64 hash plus
every site `find`, scoped by mode. `pageFileOffset` (derived from the parsed dyld-cache mapping, for
human cross-reference only) and `pageVmOffset`
(`pageStart - image mach-header unslid VM address`) remain 4 KiB-aligned diagnostic evidence only.
Image entries are the simplified v3 form: kind, canonical absolute path derived from the parsed
image (fixture-root prefix stripped, so fixtures and the live system produce the same bytes),
unslid mach-header VM address and `__TEXT` vmsize. Segment/section names and the parsed function
evidence stay in the JSON report, not in the wire profile. The built-in validator re-resolves every
`(imageIndex, pageVmOffset)` to the exact fixture page, simulates the mode-routed matcher over every
target `__TEXT` page, checks the already-patched pass and the one-entry bundle selector, and fails
if any unintended fixture page satisfies a record identity.

## Multi-profile bundle

`NootedRedTool --bundle-profiles <manifest.json> --out <dir>` generates one NRPT v3 profile per
manifest entry (or re-validates a prebuilt `.nrpt` entry), wraps them in the codec's
`NRedProfilesBundle` and writes `nred-profiles.plist` via `ProfileCodec.encodeBundlePlist` plus
`nred-profiles-evidence.json`. The plist has the `NRedProfiles` root array; each dictionary carries
exactly `Build` (String), `APUMask` (Integer), `DeviceID` (Integer, 0 = no gate) and `Profile`
(Data). Entries preserve the manifest order (selection is by exact build/APU/device, so order has no
runtime semantics) and identical inputs produce byte-identical plists. Duplicate builds, bundle
metadata differing from the embedded profile header, or invalid profiles are rejected by the codec
(E050-E053).

Manifest example (fixture entries generate from a clean fixture; `profile` entries reuse a
prebuilt `.nrpt`; optional `build`/`apuMask`/`deviceID` overrides must equal the profile header):

```json
{
  "schema": 1,
  "profiles": [
    { "fixtureRoot": "/path/to/version-fixtures/15.8.2" },
    { "profile": "/path/to/nred-24H232.nrpt", "fixtureRoot": "/path/to/version-fixtures/15.8.2" }
  ]
}
```

Generation must use a **clean fixture**. The live root is refused when `NootedRedUserPatch` is
loaded; even without the hook the running system's patched driver pages can leak through the
unified buffer cache, so `version-fixtures/<build>` is extracted with `F_NOCACHE` source reads and
passed as the `--generate-profile` root. Identical inputs produce byte-identical profiles.

## Page identity and mode

`ProfileCodec.encode` derives counts, table sizes and the payload checksum; the generator only
supplies the image/page/site model. NRPT v3 has **no offset identity and no matchFlags**: every page
record is identified by its validated `mode` (`PAGE` for the standalone GL bundle, `DYLD` for dyld
shared-cache images) plus the full-page FNV-1a-64 hash and all site `find` bytes. `pageFileOffset`
and `pageVmOffset` are 4 KiB-aligned diagnostic evidence only and are re-resolved against the
fixture by the built-in validator; v3 also has no offset gate that could reject an already-patched
or differently-paged delivery. Identical 4 KiB content reached through another image is not a
problem by construction: the mode-scoped content identity is the same record, and the producer-side
collision scan fails generation only if an unintended page of a target image satisfies a record.
There are no hash-only page records.

## 15.8.2 (24H232) result

Generated on the clean host system (no UserPatch loaded) with `--generate-profile / --out <dir>`:

- offline validation PASS, 1858 `__TEXT` pages scanned, 14 page records matched, 0 find mismatches
- 14 pages / 20 sites / 4 target images / 1736 bytes, mode PAGE=2 (standalone GL pages) and
  DYLD=12 (Metal/VADriver2/AppleGVA cache pages)
- profile sha256 `8cf524b479f1f8d779bf2048b0ddab3f5b5b62c0abce9ba10c53118269d341d6`
- bundle `nred-profiles.plist` sha256 `615cbd893a3e4eeffba0cdae9ffd9ea1c1c43639e8dfe2bff5d3c4deaa4b8329`
  (1 entry: Build 24H232 / APUMask 0x28 / DeviceID 0x1638)
- generated from the clean `F_NOCACHE` fixture `version-fixtures/15.8.2`; profile and plist are
  byte-identical across repeated runs; artifacts published under `build/profile-24H232-v3/`
  (the pre-pitch-rule artifact is archived under `build/profile-24H232-v3/archive-pre-vcn-pitch/`)

The `vda.encoder.source_pitch` rule adds the upstream `Vcn2Encoder::setEncodeParams` fix on the new
VADriver2 `.03` page at image offset `0x46000` (FNV-1a-64 `d773bc6223a083ac`): `[rdx+0x80]` (source
pitch) and `[rdx+0x84]` (element size) are read directly instead of reconstructing the pitch from
the encoded width (`imul; add 0xff; and ~0xff`), and the untouched `xor edx,edx; div ecx` conversion
and stores are kept. The upstream 15.8.x table expresses this as one 32-byte byte patch that starts
two bytes inside the preceding `vxorps` (`57 C0 C5 F8 …`), which would leave the VEX prefix `C5 F8`
in front of `mov eax,[rdx+0x80]` — not decodable. The generator therefore works on parsed
instruction boundaries and splits the 25-byte reconstruction block into two length-preserving v3
sites (12 + 13 bytes; the wire limit is 16 bytes per site), which is why the page has two sites.

The 4-image set is GL (`kind 0`, unslid 0), Metal, VADriver2 and AppleGVA (`kind 1`, cache unslid
addresses `0x7FFB08757000` / `0x7FFB08606000` / `0x7FFA06672000`). The AppleGVA record is the
mainline-validated `AVDGetGPUAccelerators` patch: page `.02` file offset
`0x6696000`, page hash `0xBF4200EAD854986D`, site `0x41B`, `find 0F84D6030000` (the `je` to the
empty-return block after the Intel-accelerator null test) replaced by `0F842A000000` (the AMD
accelerator insertion tail after the output-vector capacity check, storing the accelerator
collected at `[rbp-0x130]`). The function is symbol-less on 24H232, so the rule resolves it by full
image-wide CFG parsing: the unique function containing both the AMD insertion sequence and exactly
one Intel-slot null guard whose fall-through path also converges on the same empty-return block.
The candidate function address, both branch targets and the insertion instruction are recorded in
the evidence. Two remaining deliberate semantic choices (Metal RB+ allow `31 C0 90` from the
mainline source instead of the old table's `31 C9 90`; VDA family sites derived from the 24H232
images rather than first-occurrence byte order) are evidence.

## 被否决的补丁形态

新增语义规则时不要走这些路，它们都在真机上失败过：

- **源码层 `0x4D -> 0x4F` 的 HwInfo 补丁换 RB+**：它会打开 RB+ 寄存器编程，而对应 tiling 表并不
  建模 Renoir，结果是黑块和缩略图缺失。Metal 侧固定用 gate/allow 两个 site。
- **与其它用户态 GL/Metal 补丁器混用**（例如 BFixup）：同一批页会被两个实现写。
- **把 APU 数据套到 Vega 独显**：HwInfo 模型与 RB+ 支持都不同。
- **写 `/System/Library/Extensions` 或 dyld 共享缓存**：补丁只存在于内存页缓存，重启即失效。
- **匹配失败当成错误处理**：必须是 no-op；panic 或强制写入已经在审计中被判定为不可接受。

生成器必须继续 fail closed：缺 Capstone、函数解析不唯一、语义规则零匹配或多匹配、函数体无法
完整解码、页面短读、非目标页命中同一身份，任一情况都不写 profile。
