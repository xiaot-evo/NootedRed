# PatchAnalyzer — host-side Mach-O / dyld-cache function analysis and NRPT generation

Status: implementation notes for `NootedRedTool/Sources/NootedRedTool/PatchAnalyzer/`.
Contract: `docs/PatchProfile-Spec.md` (NRPT v1) and `analysis/lilu-dyld-shared-cache-profile-engine.md`.

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
| `SemanticRules.swift` | The rule engine and the 12 semantic rules that resolve the 18 sites on macOS 15.8.2/24H232 (GL/Metal gfx9 HwInfo, GL dual-quad, Metal RB+ gate/allow, VDA accelerator/addrlib/factory/feedback-stride/chip-family, AppleGVA AVDGetGPUAccelerators). Each rule resolves a function through symbols or parsed ObjC metadata, matches instructions by decoded semantics, requires exactly one unambiguous match, derives `find` from the image and synthesises a same-length `replace` whose decoded effect is re-validated. |
| `ProfilePipeline.swift` | Fixture environment (build, APU mask, device ID, user-patch-loaded guard), image set, NRPT profile construction through `ProfileCodec.encode`, page hashes/flags, identity-collision scan over every target `__TEXT` page, offline validator built on `ProfileCodec.applyPage`, JSON evidence and the CLI. |

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

## Page identity flags

`ProfileCodec.encode` derives counts, table sizes and the payload checksum; the generator only
supplies the page/site model. **Every** page record sets
`REQUIRE_OFFSET | REQUIRE_HASH | REQUIRE_SITES` (`0x0007`): standalone bundles are paged with their
file offset, and for split dyld shared caches the pager offset equals the subcache file offset
(spec §4.3); the offset gate was validated against the fixture for all 13 pages. The offset is also
the disambiguator for identical 4 KiB content reached through a different image offset, e.g. the
VADriver2 `.03` page at `0x867D000` versus the legacy VADriver page at `0x85C4000`: both have the
same FNV-1a-64 hash, but only the `.03` chunk base matches, so the legacy page is rejected before
any hash comparison. There are no hash-only page records.

## 15.8.2 (24H232) result

Generated on the clean host system (no UserPatch loaded) with `--generate-profile / --out <dir>`:

- offline validation PASS, 1858 `__TEXT` pages scanned, 13 page records matched, 0 find mismatches
- 13 pages / 18 sites / 1096 bytes, all 13 page records with `matchFlags = 0x0007`
- sha256 `fddf26a502da55ee18bf6c2eb966b02ff8000b363db18b4b648f76f036047365`

The AppleGVA record is the mainline-validated `AVDGetGPUAccelerators` patch: page `.02` file offset
`0x6696000`, page hash `0xBF4200EAD854986D`, site `0x41B`, `find 0F84D6030000` (the `je` to the
empty-return block after the Intel-accelerator null test) replaced by `0F842A000000` (the AMD
accelerator insertion tail after the output-vector capacity check, storing the accelerator
collected at `[rbp-0x130]`). The function is symbol-less on 24H232, so the rule resolves it by full
image-wide CFG parsing: the unique function containing both the AMD insertion sequence and exactly
one Intel-slot null guard whose fall-through path also converges on the same empty-return block.
The candidate function address, both branch targets and the insertion instruction are recorded in
the evidence. Two remaining deliberate semantic choices (Metal RB+ allow `31 C0 90` from the
mainline source instead of the old table's `31 C9 90`; VDA family sites derived from the 24H232
images rather than first-occurrence byte order) are documented in the rule descriptions and
evidence.
