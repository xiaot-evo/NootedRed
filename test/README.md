# NRPT v1 offline validator

Independent host-side validation for the NootedRedUserPatch profile-driven page patch engine.
It applies an **NRPT v1** profile to a **clean fixture** with exactly the algorithm the kext must
execute, and rejects false positives. Normal normative contract: `docs/PatchProfile-Spec.md`
(sections 8, 13, 16).

Implemented in pure Python 3 (stdlib only) and intentionally independent from the Swift
`ProfileCodec` reference codec and the tool's generator, so a generator bug cannot validate itself.

## Contents

| File | Purpose |
| --- | --- |
| `nrpt_validator.py` | strict NRPT v1 decoder/encoder (all `E001`–`E032` codes), kext-algorithm simulator (offset gate, full-page FNV-1a-64, all site finds, atomic replace writes, applied-once, no try-next-record), clean-fixture resolver, false-positive checks, JSON + human report, CLI |
| `test_nrpt_validator.py` | 69 synthetic unit tests: FNV vectors, round trip/canonical size/determinism, one crafted-byte vector for every stable error code, identity/apply semantics, fixture resolution, ambiguity, mutation/duplicate sweeps, native hash-scan parity, CLI end-to-end |
| `run-validation.sh` | one-shot runner: unit tests, then real-profile validation against the clean host fixture |
| `inject_profile.py` | inject / check / extract the `NRedOffsetProfile` + `NRedSystemBuild` personality properties in a kext `Info.plist` (deterministic package build; used when the tool's injection CLI is unavailable) |
| `golden/synthetic-2page.nrpt` | synthetic golden profile that the reference Swift codec and this Python codec encode byte-identically (cross-implementation parity) |
| `golden/engine-crosscheck/` | synthetic vectors from the independent C++ engine harness; the Python simulator must reproduce the engine's patched page bytes exactly |
| `hash_scan.c` | optional native FNV-1a-64 page scanner (compiled on demand with clang) used for full-cache hash-only identity / duplicate-content scans; pure-Python fallback keeps the tool dependency-free |

No Apple binaries are used by the tests or committed to the repository. `run-validation.sh` reads the
host's existing system images in place (read-only) when a real profile is supplied.

## Package profile injection

The deployable package ships `NootedRedUserPatch.kext` with the profile embedded in its
`org.ChefKiss.NootedRedUserPatch` personality. `inject_profile.py` performs that step and proves the
result:

```sh
test/inject_profile.py --profile build/packages/<pkg>/nred-24H232.nrpt \
    --info-plist build/packages/<pkg>/Kexts/NootedRedUserPatch.kext/Contents/Info.plist
test/inject_profile.py --check --profile build/packages/<pkg>/nred-24H232.nrpt \
    --info-plist build/packages/<pkg>/Kexts/NootedRedUserPatch.kext/Contents/Info.plist
```

All other `Info.plist` keys (`OSBundleLibraries`, versions, personalities) are preserved; `--extract`
can prove the embedded bytes are identical to the generated `.nrpt` file.

## Quick start

Relevant CLI flags: `--no-hash-only-scan` (skip the hash-only identity scan; not deployable),
`--no-native-hash-scan` (force pure-Python scanning; very slow on multi-GB caches),
`--no-duplicate-content-scan` (skip the content-duplicate evidence pass), `--mutation-sweep`.

```sh
# synthetic unit tests only (no Apple binaries, no profile needed)
python3 test/test_nrpt_validator.py

# validate a real generated profile against the clean host system (this Mac)
test/run-validation.sh build/packages/NootedRed-15.8.2-nrpt/nred-24H232.nrpt
# or with explicit identity gates:
NRPT_DEVICE_ID=0x1638 NRPT_EXPECTED_BUILD=24H232 \
    test/run-validation.sh /path/to/nred-24H232.nrpt
```

`run-validation.sh` writes `build/validation-report.json` by default (`NRPT_REPORT` overrides).
Exit code 0 means every intended page resolved to a unique clean 4 KiB page, matched its identity,
applied all sites atomically, was applied only once, and no unintended fixture page matched any
record identity.

## What the validator does (spec section 8 / 13)

1. **Strict decode** — all-or-nothing acceptance of the 64-byte header, 24-byte page records and
   40-byte site records; FNV-1a-32 payload checksum over `[64, end)`; canonical site ranges and
   identity uniqueness; stable error codes (`E001` … `E032`) with the same ordering as
   `ProfileCodec.swift`.
2. **Fixture resolution** — for each page record, locate the clean 4 KiB window whose FNV-1a-64
   equals `pageHash`:
   - `REQUIRE_OFFSET` records: the exact `pageFileOffset` in every candidate image
     (AMD GL/MTL/VDA/GVA driver bundles, every `dyld_shared_cache_x86_64h*` subcache);
   - hash-only records: every aligned 4 KiB window of every candidate image.
   Exactly one match is required. Apple binaries are read in place at `--fixtures` (default `/`).
3. **Kext-equivalent application** — each intended page is delivered as one validated 4 KiB chunk
   (`chunkBase = pageFileOffset`), then the full record table is scanned in profile order:
   offset gate (when set) → full-page FNV-1a-64 → applied-once bit → all site `find` bytes →
   replace writes. A site mismatch writes nothing for the page (atomic); there is no fallback to
   another record.
4. **Post-conditions** — exact replace bytes written, resulting page hash recorded, second delivery
   returns `alreadyApplied` without writes, `_cs_validate_range` runs are simulated over contiguous
   pages of each image, and the optional mutation sweep flips one byte per page and requires the hash
   gate to reject it.
5. **False-positive checks** — no other candidate image/window may match a record's identity
   (offset+hash for `REQUIRE_OFFSET` records, full-fixture hash scan for hash-only records). The
   optional content-duplicate analysis additionally records byte-identical 4 KiB pages elsewhere in
   the fixture: for offset-gated records a duplicate at another offset is not an identity match (and
   is reported as evidence, not a failure); for hash-only records any duplicate is a false positive.
6. **Identity gates** — profile `build` must equal the fixture/target build; with `--device-id`,
   `apuMask` must intersect the candidate family mask and a `REQUIRE_DEVICE_ID` profile must match
   the running device exactly (fail closed on unknown devices).

## Report

The JSON report is deterministic (no timestamps, sorted keys) and contains:

- profile identity: size, SHA-256, build, apuMask, deviceID, counts, payload checksum;
- fixture: build, candidate images (names/sizes);
- identity checks: build, APU mask/device gate, warnings;
- per page: resolution image/offset, hash match, matched record index, sites, bytes changed,
  clean/patched page hashes, applied-once repeat status;
- per site: `siteInPage`, `find`/`replace` hex, find match, written, original/patched bytes;
- false-positive checks, mutation sweep, range simulations, warnings, summary, `result`.

## Test matrix (synthetic, committed)

| ID | Case |
| --- | --- |
| T1 | FNV-1a 32/64 reference vectors; page-hash length rejection |
| T2 | encode→decode round trip, canonical byte size (`64 + 24·pages + 40·sites`), determinism |
| T3 | every stable error code `E001`–`E032` via crafted byte vectors (+`E033`) |
| T4 | offset gate: wrong/unaligned base rejected; cleared `REQUIRE_OFFSET` matches content only |
| T5 | hash gate: single-byte mutation rejected with zero writes |
| T6 | site gate: wrong `find` on one site → whole page rejected, no partial write |
| T7 | applied-once: repeat delivery is a no-op |
| T8 | first-matching record is authoritative (no try-next-record) |
| T9 | range delivery: correct chunks applied, others untouched, trailing partial chunk ignored |
| T10 | fixture resolution: unresolved identity fails; duplicate hash-only content is ambiguous |
| T11 | false-positive/mutation sweep rejects foreign/mutated pages |
| T12 | deterministic report (two runs byte-identical) |
| T13 | CLI end-to-end PASS on a synthetic fixture tree; corrupted profile exits ≠0 with `E00x` |
| T14 | cross-implementation: reference Swift codec golden is byte-identical; independent C++ engine harness patched bytes reproduced exactly |

The real-profile end-to-end check (host clean images, 13 pages / 18 sites for 24H232) is executed by
`run-validation.sh` and recorded in the task-8 validation report under `build/`.
