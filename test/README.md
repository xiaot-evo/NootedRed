# NRPT v3 offline validator

Independent host-side validation for the NootedRedUserPatch profile-driven page patch engine.
It decodes an **NRPT v3** profile (or an `NRedProfiles` multi-profile bundle), selects the profile
for a target identity, and applies it to a **clean fixture** with exactly the hook semantics the
kext must execute — then rejects anything that could patch the wrong page. Strictness is
intentional: profiles are an attack surface against kernel memory, so the tool is a semantic
reference implementation, not a convenience linter.

Normative contract: `docs/PatchProfile-Spec.md` (NRPT v3, frozen 2026-10-29) plus
`NootedRedTool/Sources/NootedRedTool/ProfileCodec.swift`. The validator is an **independent**
implementation: it shares no code with the Swift codec or the C++ engine, and cross-implementation
parity is pinned by a synthetic golden profile.

## What the validator does

- **v3 only.** v1/v2 profiles are rejected with `E003`; there is no compatibility mode. Stable
  errors `E001`–`E041` (profile) and `E050`–`E053` (bundle) all have crafted-byte test vectors.
- **Strict codec.** 64-byte header, 32-byte page records (mode `u8` at 22, image index at 24,
  page VM offset at 28), 40-byte site records, image table; FNV-1a-32 payload checksum over
  page+site+image tables; canonical encoding derives counts/table sizes/checksum.
- **Bundle selection.** `NRedProfiles` plist array of dicts `{Build, APUMask, DeviceID, Profile}`;
  exact-build selection, APU-mask intersection, exact device ID when the profile gates on it, and
  no cross-build/APU fallback.
- **Hook-domain simulation.** `PAGE` records are applied only through the page-validation route
  (`_cs_validate_page`, one 4 KiB chunk), `DYLD` records only through the range route
  (`_cs_validate_range`, consecutive chunks). Mode-domain filtering is mandatory and tested.
- **Identity without offsets.** Identity is the full-page FNV-1a-64 plus **all** site `find` bytes.
  `pageFileOffset`, `pageVmOffset` and the kernel-reported chunk base are diagnostic only and never
  used for matching; a different chunk base still matches, and the evidence offsets are reported.
- **Vnode gate (validator only).** The validator can model a vnode-name gate: standalone images
  require the target dylib basename, dyld-shared-cache images require a `dyld`/`dyld_shared_cache`
  vnode. **The shipped engine does not implement it** (`UserPatchBackend.cpp` ignores the vnode) —
  real deliveries do not guarantee a resolvable vnode name. `docs/PatchProfile-Spec.md` §9.1 still
  describes the gate as defense in depth; treat the engine as authoritative and the validator's gate
  as a stricter model.
- **Applied-once / already-patched.** A record applies once per boot; a delivery that already
  carries every `replace` byte is marked applied with **no** write. Site mismatches abort with
  zero writes.
- **Fixture re-resolution.** Every record is re-resolved against the clean fixture: image kind,
  path, `__TEXT` geometry, split-cache image-text/mapping data, page start VA
  (`unslidVmaddr + pageVmOffset`), recomputed file offset (diagnostic evidence), page hash and
  sites. Nothing from the profile is trusted.
- **False positives.** The tool scans the records' mode-domain page space (target standalone file
  for `PAGE`, all dyld cache files for `DYLD`). A byte-identical duplicate page in the same mode+vnode domain is
  reported as a warning (the patched bytes are identical) and fails with
  `--strict-false-positives`; the candidate space is already domain-scoped
  (`PAGE`: target standalone file only, `DYLD`: dyld cache files), so a strict failure means
  same-domain identity ambiguity, never cross-route confusion.
- **Reports.** Per-page/per-site JSON + human output, image/page metadata, identity gates, route
  simulations, mutation sweep, bundle selection; deterministic and SHA-256-able.

## Files

| File | Purpose |
| --- | --- |
| `nrpt_validator.py` | NRPT v3 codec/bundle model, hook-domain simulation, fixture validation, CLI |
| `test_nrpt_validator.py` | 42 synthetic tests: codec/model/error vectors, modes, vnode gate, offset-free identity, fixture resolution, bundle selection, golden parity, CLI |
| `inject_profile.py` | inject / check / extract the `NRedProfiles` bundle in a kext `Info.plist` |
| `test_inject_profile.py` | 7 injection-tool tests: round trip, determinism, legacy-key removal, manifest, rejection cases |
| `hash_scan.c` | native 4 KiB page FNV scanner used by the fixture false-positive scan and the origin tool |
| `golden/synthetic-2page-v3.nrpt` | synthetic v3 golden; reference Swift `ProfileCodec.encode` and this Python encoder produce byte-identical bytes |
| `find_nrpt_page_origin.py` (in `tools/`) | maps runtime-delivered page hashes back to the source image/offset with v3 mode/image metadata |
| `run-validation.sh` | convenience wrapper around the validator CLI |

## Usage

```sh
# NRPT v3 profile against an extracted clean fixture
python3 test/nrpt_validator.py \
    --profile build/profile-24H232-v3/nred-24H232-v3.nrpt \
    --fixtures version-fixtures/15.8.2 \
    --expected-build 24H232 --device-id 0x1638 \
    --report build/validation-report-24H232-v3.json --mutation-sweep

# multi-profile bundle: validate the whole bundle, then select and validate one entry
python3 test/nrpt_validator.py \
    --bundle-plist NRedProfiles.plist --fixtures version-fixtures/15.8.2 \
    --expected-build 24H232 --device-id 0x1638 \
    --report build/validation-report-bundle.json

# runner wrapper
NRPT_DEVICE_ID=0x1638 NRPT_EXPECTED_BUILD=24H232 FIXTURES=version-fixtures/15.8.2 \
    test/run-validation.sh build/profile-24H232-v3/nred-24H232-v3.nrpt

# injection into a kext Info.plist
python3 test/inject_profile.py --info-plist Info.plist \
    --profile nred-24H232-v3.nrpt --build 24H232 --apumask 0x28 --deviceid 0x1638 \
    --output /tmp/out/Info.plist
python3 test/inject_profile.py --info-plist /tmp/out/Info.plist --check
python3 test/inject_profile.py --info-plist /tmp/out/Info.plist --extract /tmp/extracted
```

Exit codes: `0` PASS/OK, `1` validation/verification failure, `2` usage/IO error.
The validator reads the fixture in place; it never writes to system volumes or EFI.

## Tests

`python3 test/test_nrpt_validator.py` — 42 tests, and `python3 test/test_inject_profile.py` —
7 tests. The suite includes one crafted-byte or model vector for **every** stable NRPT v3 error code
(`E001`–`E041`, `E050`–`E053`), golden parity against the reference Swift codec, synthetic
standalone-Mach-O and split-dyld-cache fixtures for metadata re-resolution and route simulation,
and CLI end-to-end runs.

Goldens are synthetic only (no Apple binaries), pinned by SHA-256; the fixture images are read from
the user-provided clean fixture tree and are never committed.
