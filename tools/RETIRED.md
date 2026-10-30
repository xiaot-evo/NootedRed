# Retired tooling

Two retirement waves. **Their failures are expected; do not treat them as regressions.** Everything
here is recoverable from git history.

- **Wave 1 (satellite split, 2026-10-23):** the in-memory user-space patcher was removed from
  `NootedRed.kext` and moved into `NootedRedUserPatch`. Tools that generated or tested C++ page arrays
  for the main kext died with it.
- **Wave 2 (NRPT v3, 2026-10-29):** the embedded NRPD v1 `PatchData` blob was replaced by an injected
  v3 profile bundle. The whole blob pipeline stopped being a build input.

## Wave 1 — deleted files

| Retired file | What it did | Replacement |
| --- | --- | --- |
| `tools/test_gl_semantic_data.py` | validated semantic GL/Metal contexts from `GLFixSemanticData.hpp` | NRPT v3 profile, validated by `test/nrpt_validator.py` |
| `tools/test_patch_data.py` | validated `UserPatches.cpp` page arrays and the patch-set table | `test/nrpt_validator.py` |
| `tools/test_patchset_selection.py` | reimplemented the deleted `UserPatches::selectPatchSet()` and tested only itself (false green) | profile selection in `PatchProfile.cpp`, simulated by the validator |
| `gen_patch_data.py` | emitted C++ page arrays / `PagePatch` rows for the in-memory patcher | `NootedRedTool --generate-profile` |
| `gen_vda_va_data.py`, `gen_vda_gva_data.py` | emitted `VDAVAData*.hpp` / `VDAGVAData*.hpp` | VDA sites resolved by `SemanticRules.swift` |
| `collect_compat_data.py` | rebuilt mainline patch tables/C++ headers from a target machine | `collect_platform_data.py` + `NootedRedTool` |
| `collect_target_data.py`, `README-collect-target-data.md` | GL/MTL-only target collector before the generic one | `collect_platform_data.py`, `collect_validation_fixtures.py` |
| `tools/gen_vcn_kernel_data.py` | generated the static `VCNData/24H*.hpp` call-site table | `NootedRed/VCNRuntimeResolver.cpp` (live symbol/vtable parsing) |
| `tools/test_vcn_data.py` | tested the removed static VCNData table and build selector | runtime resolver diagnostics |
| `tools/vda_preflight.sh` | checked the removed 15.8.1-only static VDA/VCN data | `vda_selftest.sh`, `vda_hwtest.sh` |

## Wave 2 — present but superseded

These files still exist because they are cheap to keep and occasionally useful for archaeology. None
of them is on the current path: the kext parses only `NRedProfiles` (`PatchProfile.cpp`), and
`xmake.lua` compiles no generated data.

| File / directory | Why it is dead |
| --- | --- |
| `PatchData/` (data + `README.md`) | NRPD v1 sets (`24H32`). No consumer: `PatchDataBlob.*` was deleted with the v3 move. |
| `userpatch_data.py`, `test_userpatch_data.py` | NRPD v1 codec and its tests |
| `convert_master_patchdata.py`, `master_source.py`, `master_tables.py` | derive `PatchData/` from the pinned master snapshot |
| `extract_userpatch_fixture.py` | builds v1 fixtures for the above |
| `embed_patchdata.py`, `test_embedded_patchdata.py` | generate/validate the `PatchDataBlob.*` C++ arrays |
| `specs/`, `fixtures/`, `pinned/master/`, `sources/` | v1 inputs, test vectors and provenance |

Replacement for all of the above: `NootedRedTool --generate-profile` →
`test/nrpt_validator.py` → `test/inject_profile.py`. Contract:
`../docs/PatchProfile-Spec.md`. Format history: `../research/legacy/NRPD-v1-Format.md`.

> **Hazard:** `embed_patchdata.py --write` still emits `NootedRedUserPatch/PatchDataBlob.cpp`, and
> `xmake.lua` globs `NootedRedUserPatch/**.cpp`. Running it silently adds the dead blob to the kext and
> it will be compiled and signed. Don't run it unless you are deliberately reviving v1, and delete the
> generated files afterwards.

## Still current

- `build-branch.sh`, `build.sh`, `test_build_artifacts.py` — build entry points and artifact guards.
- `collect_validation_fixtures.py`, `collect_platform_data.py`, `import_platform_data.py`,
  `adaptation_info.py` — collection and triage; version-independent.
- `find_nrpt_page_origin.py` — maps delivered page hashes back to images (v3).
- `gl_blend_probe.c`, `hwinfo_probe.c` — GPU diagnostics.
- `set_vda_bootarg.sh`, `vda_selftest.sh`, `vda_hwtest.sh`, `deploy_vda.sh` — VDA opt-in and validation.
- `firefox-hwdecode-launcher.sh`, `Firefox-HW-Decode.command` — browser HW-decode launcher.
