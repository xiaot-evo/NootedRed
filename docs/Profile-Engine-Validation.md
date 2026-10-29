# NRPT v1 profile engine — deployment validation methodology and evidence

Status: **task-8 validation record.** Scope: host-side offline validation, unit tests, release/debug
build verification, tool self-tests, and deployable-package assembly for the profile-driven
`NootedRedUserPatch` engine. Hardware deployment and the post-boot IORegistry check are **Lead-owned**
and are not part of this document.

Normative contract: [`docs/PatchProfile-Spec.md`](PatchProfile-Spec.md) (NRPT v1, frozen 2026-10-29).
Design background: `analysis/lilu-dyld-shared-cache-profile-engine.md`. ABI:
`analysis/xnu-lilu-page-validation.md` (preserved under `build/revert-backup/` if absent).

Host: macOS 15.8.2 (24H232), Darwin 24.6.0, x86_64, AMD Renoir `0x1638` — the target machine itself.
`NootedRedUserPatch` was not loaded during validation, so on-disk Apple images are clean fixtures.

---

## 1. What was validated

| Layer | Artifact | Validation |
| --- | --- | --- |
| Binary profile format | generated `nred-24H232.nrpt` | strict NRPT v1 decode, all `E001`–`E032` rules, payload checksum |
| Host generator output | profile page/site tables | independent fixture resolution + kext-equivalent application (13 pages / 18 sites) |
| Host codec parity | `ProfileCodec.swift` vs `test/nrpt_validator.py` | byte-identical encode on a synthetic golden profile |
| Kext build | release + debug `NootedRedUserPatch.kext` | `xmake` build, ABI symbols, no-hardcoded-data audit |
| Kext profile parser/matcher | `NootedRedUserPatch/PatchProfile.cpp` | read-only semantic audit against spec §8/§11 (same gates, same ordering, atomic page, applied-once) |
| Tool | `NootedRedTool --self-test` | PASS (count recorded in §5) |
| Package | `build/packages/NootedRed-<ver>-<build>-nrpt{,-debug}/` | profile injection round-trip, `SHA256SUMS` verification, hygiene |

```text
### 1.1 Frozen validation inputs (final run)

| Item | Value |
| --- | --- |
| Repository | `feature/profile-driven-userpatch`, `HEAD = b37eb156dfbf3ad86069aa2a4711f6dd561b5bc1` |
| Canonical profile | `build/profile-24H232/nred-24H232.nrpt`, 1096 B, SHA-256 `fddf26a502da55ee18bf6c2eb966b02ff8000b363db18b4b648f76f036047365` |
| Profile identity | NRPT v1; build `24H232`; apuMask `0x28`; deviceID `0x1638` (REQUIRE_DEVICE_ID); 13 pages / 18 sites; all `matchFlags 0x0007`; payload FNV-1a-32 `0xD839E771` |
| Generator | `NootedRedTool --generate-profile / --out …`; output reproduces the canonical profile and evidence byte-identically (deterministic) |
| Generator evidence | `nred-24H232-evidence.json`, 27,021 B, SHA-256 `8bb6893f4e4633ed759131f70fb9a0e9541932f634e0c703477d2f2f5426c5bb` |
| Release kext exe | `71793457bed1e16eb22205a32415b391298a2b09d20d9534ee5f14ff0192065b` (92,832 B) |
| Debug kext exe (packaged) | `09db945d35292fd4af2de475a9f3d8e1f72421ea5a64d202a51fee6a6b390990` (130,064 B, diagnosis only) |
| Main kext (unchanged) | `d291fea4dccd74ff4f24378f3fd863330220896e0340320d770c6be00f456c60` |
| Validator JSON report | `build/validation-report-24H232-final.json`, SHA-256 `0aa330d81e04f198c78666a50c92f7ecf314b964d8628fb20cb64029df724a96` |
| Deployable package | `build/packages/NootedRed-15.8.2-nrpt/` (zip `418724b605f3ed914849313aedf87da4d267ea2c91698e148255d535c469fd56`); debug package `…-nrpt-debug/` (zip `3706bd64462d5349ec6cf4ac8ef48ab301b4c0522fdc4c8bcd4fc22c649f31a0`) |
| Host | macOS 15.8.2 (24H232), Darwin 24.6.0, x86_64, AMD Renoir `0x1638`; clean fixture (no NootedRedUserPatch loaded) |

The generated profile was validated independently of the tool: the tool's own offline validator and
the independent `test/nrpt_validator.py` both PASS, and the profile was regenerated twice with
byte-identical output. `NootedRedTool --self-test` PASS (25 checks; the working-tree legacy suite).

### 1.2 Strict validator result

`python3 test/nrpt_validator.py --profile build/profile-24H232/nred-24H232.nrpt --fixtures / --expected-build 24H232 --device-id 0x1638 --report build/validation-report-24H232-final.json --mutation-sweep` → `RESULT: PASS`:

- 13/13 page records resolved to unique clean fixture pages and applied through the spec §8 algorithm;
  18/18 sites matched their `find` and were replaced, second delivery returned `alreadyApplied`.
- Full-fixture false-positive scan: 13 page hashes over 5.02 GB / 1,225,803 aligned 4 KiB pages,
  0 unintended identity matches.
- Mutation sweep: all 13 pages rejected by the hash gate with no writes.
- `_cs_validate_range` simulation: 7-chunk GL-driver range and 490-chunk `.03` shared-cache range; all
  intended records applied, non-target chunks untouched.
- Identity gates: build `24H232` matched the fixture build; apuMask `0x28` intersects the `0x1638`
  candidate family mask.

| Record class | Result |
| --- | --- |
| All 13 pages (`matchFlags 0x0007`, offset required) | resolved at recorded subcache/file offset + full-page FNV-1a-64 + all site finds → applied |
| AppleGVA page (`.02` `0x6696000`, hash `0xBF4200EAD854986D`, site `0x41B`) | matches the pinned mainline `VDAGVAData.hpp` derivation: `0f84d6030000` → `0f842a000000` (`je` empty-return → AMD-insertion tail in `AVDGetGPUAccelerators`) |
| Content-duplicate page (VADriver2 `.03` `0x867D000` vs legacy VADriver `.03` `0x85C4000`, hash `0xF5B85AA3986640B6`) | byte-identical content elsewhere in the fixture; offset-gated identity makes this **not** a false positive; recorded as warning/evidence in the report |

### 1.3 NRPT v2 validation (task-15)

The frozen v2 contract (`docs/PatchProfile-Spec.md` §0) adds the target-image table and 32-byte page
records used by the direct-patch coverage path. The independent validator now decodes v1 **and** v2,
and for v2 re-resolves every page's `(imageIndex, pageVmOffset)` against the clean fixture instead of
trusting the profile metadata (spec §0.6).

| Item | Value |
| --- | --- |
| Official v2 profile | `build/profile-24H232-v2/nred-24H232-v2.nrpt`, 2,776 B, SHA-256 `56afabe0b7f77346057108ba1b458bbdecc5f436a720f5915484f579257bc3f4` |
| Structure | NRPT v2; build `24H232`; apuMask `0x28`; deviceID `0x1638`; **4 images / 13 pages / 18 sites**; all pages `matchFlags 0x0007`; payload FNV-1a-32 `0x018AB32E` |
| Clean fixture | `version-fixtures/15.8.2` (extracted with `F_NOCACHE`; manifest + SHA-256s present, no Apple binaries committed) |
| v2 validation | `python3 test/nrpt_validator.py --profile build/profile-24H232-v2/nred-24H232-v2.nrpt --fixtures version-fixtures/15.8.2 --expected-build 24H232 --device-id 0x1638 --report build/validation-report-24H232-v2.json --mutation-sweep` → **PASS** |
| v2 report | SHA-256 `661737d0331d061b6b03be8fb0be4902dba7a7d78ac478d076eea029fbc833ba` |
| v1 back-compat (same fixture) | canonical v1 profile `fddf26a5…` → **PASS** (13/13 pages, 18/18 sites); report SHA-256 `b77d66ee4c235626068202aff31d78c3be8e0e2101afcc39ac5bd48be03e73ed` |
| Cross-implementation v2 golden | `test/golden/synthetic-2page-v2.nrpt`, 520 B, SHA-256 `6a36b368f1c03d1e3205eb274e455dde99d52b9d6cb49155153612c346671e85`; reference Swift `ProfileCodec.encode` and this Python encoder produce **byte-identical** bytes |

v2 metadata re-resolution result (reported per page by the validator):

| Image | Kind | Unslid VM address | vmSize | Segments | Sections | Verified |
| --- | --- | --- | --- | --- | --- | --- |
| AMDRadeonX5000GLDriver | standalone file | `0x0` | `0x14D000` | 4 | 12 | yes |
| AMDRadeonX5000MTLDriver | dyld shared cache (`.03`) | `0x7FFB08757000` | `0x44FC11` | 4 | 16 | yes |
| AMDRadeonVADriver2 | dyld shared cache (`.03`) | `0x7FFB08606000` | `0xB8268` | 4 | 11 | yes |
| AppleGVA | dyld shared cache (`.02`) | `0x7FFA06672000` | `0xEE2CF` | 4 | 16 | yes |

- Every page was re-resolved to a real fixture page: `pageStartVA = imageUnslidVmaddr + pageVmOffset`
  located in a parsed `LC_SEGMENT_64`/section (all pages `__TEXT`/`__text`), the recorded
  `pageFileOffset` recomputed from the segment file offset (standalone) or cache mapping table
  (split-cache subfile offset), and the full 4 KiB FNV page hash + all site finds verified before
  applying the v1 matching algorithm.
- AppleGVA page re-resolved to `.02` file offset `0x6696000` (hash `0xBF4200EAD854986D`, site `0x41B`,
  `0f84d6030000` → `0f842a000000`), matching the pinned mainline derivation.
- Mutation sweep: 13/13 records rejected with zero writes; range simulations pass (GL 7 chunks, `.03`
  490 chunks); content-duplicate analysis reports the VADriver2/legacy-VADriver page as an
  offset-gated warning only (not a false positive).
- v2 stable error coverage: `E034`–`E041` each have a crafted-byte unit vector (image count/entry,
  table size, path, page metadata, duplicate path, page vm offset, image geometry) plus model-level
  encode rejection tests. The scanner tool `tools/find_nrpt_page_origin.py` now reads v2 image
  metadata and prints each expected hash's target image/pageVmOffset next to the found origin.
- **Limitation:** the offline validator proves the v2 metadata *reaches* the correct clean fixture
  page; it cannot exercise the runtime direct-patch `vm_map_read_user`/write path (hardware
  validation remains Lead-owned).

### 1.4 Frozen hook-only hardware candidate (task-23)

The hook-only candidate was frozen and fully validated offline (full report:
`build/task23-freeze-validation.md`):

| Item | Value |
| --- | --- |
| Frozen commit | `1627fd723814bab7f71f51aade7c598da6e8435b` (`1627fd7`); working-tree kext sources identical (`git diff 1627fd7 -- NootedRedUserPatch/` empty) |
| Package | `build/packages/NootedRedUserPatch-nrpt-hookonly/{release,debug}` |
| Release exe | `c8a5131b28ca38a9b8b828dacb49f3e84360cb6b13abfabf94707d557917be76`, 139,272 B |
| Debug exe | `e40bc0b14b622d0744cae41f58194f7e6f40f8f3540605dc0ef1aa6ba9d1f187`, 182,192 B (diagnosis only) |
| Injected profile | official NRPT v2 `56afabe0…257bc3f4` (extracted bytes identical); injected `Info.plist` SHA-256 `7b1170f8…e0213c5e` both matrices |
| Zips | release `fd8dd77a168805a80c1fb818e03d963b8aa7a54a55796c8bbe871a7e1d080e30`, debug `c3693b94221f55f41a2ffc8c600bf87c55883ec43b2477badb344c79856e50ca` |
| Build provenance | clean rebuild from `1627fd7` is content-identical to the packaged release exe except the 16-byte Mach-O `LC_UUID` |

Verification result: **PASS / so FROZEN for the hardware reboot.** `SHA256SUMS` verify; v2 and v1
profiles both PASS the strict offline matrix on `version-fixtures/15.8.2` (v2 report
`661737d0…833ba`, v1 report `b77d66ee…73ed`); direct-patch artifacts are absent from both binaries
(no `DirectPatch`/`vm_map_read_user`/`vm_map_write_user`/`task_for_pid`/worker symbols); the
7-arg/6-arg hook ABI, `_cs_validate_page`/`_cs_validate_range` routes and the `_vnode_getname`/
`_vnode_putname` vnode gate are present. Correction to the round's expectation wording:
`thread_call_allocate/enter/free` imports remain, but only for the bounded identity-discovery retry
and the diagnostics refresh timer — there is no direct-patch worker.

Expected hook-only runtime behaviour with the injected v2 profile: vnode gate `active` (wrong-vnode
pages rejected and counted), full-page FNV content hash alone identifies pages (no pager-offset
requirement; different-offset content matches are recorded as `HashOnlyAppliedPages`), all site
`find` bytes must match before an atomic write, already-patched pages are marked applied without a
rewrite (`AlreadyPatchedPages`), and v1 profiles / missing vnode resolvers keep the legacy
fail-closed offset gate (`VnodeGate=legacy-offset`). Hardware assertions (`AppliedPages→13`,
`FindMismatches=0`, `WriteFailures=0`, `VnodeGate=active`, full ioreg block on failure) are
Lead-owned; see `build/task23-freeze-validation.md` §6.

### 1.5 Package and binary audit (final)

- Both kext matrices built cleanly from frozen HEAD; release is bit-reproducible, debug embeds an
  AppleForge build-date tag and is diagnosis-only.
- Debug ABI symbols: `wrapCsValidatePage` 7-arg `void`, `wrapCsValidateRange` 6-arg `boolean_t`;
  `PatchProfile::loadFromData/applyChunk/applyPage` present; no `PatchData`/`UserPatchData` symbols.
- No profile find/replace byte sequences (≥6 bytes) embedded in either kext binary; profile data comes
  only from the injected `NRedOffsetProfile` personality property.
- Package `Info.plist` contains `NRedOffsetProfile` byte-identical to the canonical profile (both
  matrices) and `NRedSystemBuild=24H232`; all other plist keys preserved.
- `SHA256SUMS.txt` in both packages verifies with `shasum -a 256 -c`; no `.DS_Store`/`._*`/`.dSYM`/git
  artifacts in the package trees.
- No EFI writes were made. Hardware boot/reboot acceptance (`NRedUserPatchAppliedPages` climbing to 13,
  `FindMismatches=0`, `WriteFailures=0`) remains Lead-owned.

```

## 2. Independent offline validator (`test/nrpt_validator.py`)

Pure Python 3, stdlib only; deliberately independent from the Swift codec and the tool generator so a
generator bug cannot validate itself.

1. **Strict decode.** Header (magic/version/header size/build/NUL padding/APU mask/device ID/header
   flags/reserved), derived count and table-size equalities, 64 KiB ceiling, FNV-1a-32 payload
   checksum over `[64, end)`, canonical contiguous page→site ranges, site bounds/padding/no-op/flags,
   non-overlapping writes, identity uniqueness. Rejects with the stable spec error codes.
2. **Clean-fixture resolution.** For each page record, locate the exact 4 KiB window whose
   FNV-1a-64 equals `pageHash` among candidate images (AMD GL/MTL/VDA/GVA driver bundles, every
   `dyld_shared_cache_x86_64h*` subcache file) under the fixture root. `REQUIRE_OFFSET` records are
   resolved at the recorded file/pager offset; hash-only records scan aligned windows. Exactly one
   match is required; zero = unresolved, more than one hash-only match = ambiguous (fail closed).
3. **Kext-equivalent application.** Each intended page is delivered as one 4 KiB chunk; the full
   record table is scanned in profile order with the spec §8 gates: offset (when set) → full-page
   FNV-1a-64 → applied-once bit → all site `find` bytes → replace writes. A site mismatch writes
   nothing (atomic page) and never falls through to another record.
4. **False-positive rejection.** Same-offset cross-image scan for offset-gated records, full-fixture
   page-hash scan for hash-only records, and a mutation sweep (one flipped byte per intended page
   must be rejected by the hash gate with zero writes).
5. **Range simulation.** Contiguous runs of resolved pages in the same image are delivered through
   the `_cs_validate_range` path (ascending 4 KiB chunks, trailing partial chunk ignored) and every
   intended record must apply, with non-target chunks untouched.
6. **Report.** Deterministic JSON + human summary with per-page (resolution image/offset, hash match,
   matched record, sites, bytes changed, clean/patched page hashes, second-delivery status) and
   per-site (offset, `find`/`replace` hex, find match, written bytes) detail, identity-gate results,
   warnings, and the deployability verdict.

## 3. Test coverage (`test/test_nrpt_validator.py`, 61 tests)

| Area | Tests |
| --- | --- |
| FNV-1a reference vectors, page-hash length | spec §16.1/16.2/16.3 |
| encode/decode round trip, canonical size (`64 + 24·pages + 40·sites`), determinism | spec §16.4/16.5 |
| every stable error code `E001`–`E032` via crafted byte vectors | spec §16.6/§11 |
| offset/hash/site gates, atomic page, applied-once, first-match authoritative, range, partial chunk | spec §8/§9/§16.8 |
| fixture resolution, unresolved/ambiguous identity, false positives, mutation sweep, CLI end-to-end | spec §13 |
| cross-implementation golden (`test/golden/synthetic-2page.nrpt`) | spec §16.9 |

The golden profile is synthetic (no Apple bytes) and is verified byte-identical against
`ProfileCodec.encode`; the Python decoder/encoder round-trips it exactly.

## 4. How to reproduce

```sh
# unit tests (no Apple binaries, no hardware)
python3 test/test_nrpt_validator.py

# real profile vs clean host fixture (read-only; writes build/validation-report.json)
test/run-validation.sh build/packages/NootedRed-15.8.2-nrpt/nred-24H232.nrpt
# or explicitly:
NRPT_DEVICE_ID=0x1638 NRPT_EXPECTED_BUILD=24H232 \
    test/run-validation.sh <profile.nrpt>

# package profile injection round trip
test/inject_profile.py --check --profile <profile.nrpt> \
    --info-plist build/packages/<pkg>/Kexts/NootedRedUserPatch.kext/Contents/Info.plist

# kext builds
export AppleForgePath=/Volumes/WorkSpace/Projects/Hackintosh/AppleForge
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export XMAKE_STATS=false
xmake f -m release -y && xmake build --project=. -y NootedRedUserPatch
xmake f -m debug -y   && xmake build --project=. -y NootedRedUserPatch

# tool
cd NootedRedTool && swift build -c release && ./.build/release/NootedRedTool --self-test
```

## 5. Results

```text
The full evidence trail (commands, logs under `/tmp/nred-task8-logs/`, per-page/per-site results,
package hashes) is kept in `build/task8-validation-report.md` and
`build/validation-report-24H232-final.json` (gitignored runtime artifacts). Summary:

| Check | Evidence |
| --- | --- |
| NRPT v1 structural validation | strict decode PASS; payload FNV-1a-32 `0xD839E771`; 13 pages / 18 sites; all sites canonical and non-overlapping |
| Clean-fixture application | 13/13 pages applied, 18/18 sites replaced, 0 find mismatches |
| False positives | 0 over 1,225,803 fixture pages; one content-duplicate page is offset-gated and reported as evidence |
| False-positive rejection | mutation sweep 13/13 rejected with zero writes |
| Range path | contiguous range simulations pass (GL 7 chunks; shared cache 490 chunks) |
| Identity gates | build/APU/device gates PASS |
| Kext engine cross-check | C++ engine harness golden profile applies to byte-identical patched pages in the Python simulator (`test/golden/engine-crosscheck/`) |
| Codec parity | reference Swift `ProfileCodec` and independent Python codec encode the same golden profile byte-identically (`test/golden/synthetic-2page.nrpt`) |
| Real profile | canonical `fddf26a5…` PASS as above; generator reproduces it deterministically |
| Package | both matrices assembled, injected, summed and verified; hardware deploy NOT RUN (Lead-owned) |

```

## 6. Limitations / explicit non-goals

- FNV-1a-64 is an accidental-corruption/content-identity gate, not a cryptographic signature (spec
  §18). The trust boundary remains the EFI partition / injected kext.
- Offline validation proves the profile matches the clean fixture and that the kext algorithm would
  apply every intended page there. It cannot prove the runtime pager offset namespace on hardware
  for `REQUIRE_OFFSET` records beyond the generator's evidence; the post-boot counters
  (`NRedUserPatchAppliedPages`, `NRedUserPatchFindMismatches`, `NRedUserPatchMatchedPages`) are the
  hardware acceptance check and are owned by the Lead.
- No EFI writes, no reboot, no hardware deployment were performed by task-8.
- The deployable package is assembled but not installed; rollback documentation is in the package
  `README.txt`.
