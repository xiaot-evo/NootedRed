# Retired tooling (satellite split)

The `research/satellite-userpatch` branch removed the in-memory user-space patcher (GLFIX/Metal/VDA)
from `NootedRed.kext`. The satellite kext now applies embedded PatchData in `NootedRedUserPatch/`, and
the host pipeline generates/validates/embeds that data as documented in
[`tools/README-userpatch-data.md`](README-userpatch-data.md).

These files were retired with that change. They are recoverable from git history, but running them at
HEAD fails because they parse `NootedRed/UserPatches.cpp`, `GLFixSemanticData.hpp`,
`VDAVAData*.hpp` / `VDAGVAData*.hpp` or other files that no longer exist. **They are expected to be
obsolete; do not treat their failures as regressions.**

| Retired file | What it did | Current replacement |
| --- | --- | --- |
| `tools/test_gl_semantic_data.py` (deleted) | validated semantic GL/Metal contexts from removed `GLFixSemanticData.hpp` | exact-page data in `PatchData/`, validated by `tools/test_userpatch_data.py` |
| `tools/test_patch_data.py` (deleted) | validated `UserPatches.cpp` page arrays and patch-set table | `tools/test_userpatch_data.py` (format + `PatchData/`), `tools/convert_master_patchdata.py --check` |
| `tools/test_patchset_selection.py` (deleted) | reimplemented the deleted `UserPatches::selectPatchSet()` and tested only itself (false green) | — |
| `gen_patch_data.py` (deleted) | emitted C++ page arrays / `PagePatch` rows for the removed in-memory patcher | `tools/userpatch_data.py` (binary `manifest.bin`/`pages.bin`), `tools/convert_master_patchdata.py` (derivation) |
| `gen_vda_va_data.py`, `gen_vda_gva_data.py` (deleted) | emitted `VDAVAData*.hpp` / `VDAGVAData*.hpp` C++ headers | pinned master tables + `tools/convert_master_patchdata.py` → `PatchData/` kinds 3/4 |
| `collect_compat_data.py` (deleted) | rebuilt mainline patch tables/C++ headers from a target machine | `tools/collect_platform_data.py` (generic hardware/driver data); `PatchData/` + pinned master for patch tables |
| `collect_target_data.py`, `README-collect-target-data.md` (deleted) | archived GL/MTL-only target collector before the generic platform collector | `tools/collect_platform_data.py` + `tools/adaptation_info.py` |
| `tools/gen_vcn_kernel_data.py` (deleted) | generated the static `VCNData/24H*.hpp` call-site table | `NootedRed/VCNRuntimeResolver.cpp` (live Mach-O symbol/vtable parsing) |
| `tools/test_vcn_data.py` (deleted) | tested the removed static VCNData table and build selector | `tools/collect_validation_fixtures.py` plus the runtime resolver's own validation |
| `tools/vda_preflight.sh` (deleted) | checked the removed 15.8.1-only static VDA/VCN data and old generators | runtime resolver diagnostics and `tools/collect_validation_fixtures.py` |

Kept because they are still valid:

- `tools/collect_validation_fixtures.py` — collects kernel collections and dyld caches from installers /
  mounted images for offline version validation.
- `tools/test_userpatch_data.py` — format, generator/validator, pinned-source and generated-data tests.
- `tools/test_build_artifacts.py` — guards the CI/build-branch globs for the main and satellite zips.
- `tools/embed_patchdata.py`, `tools/test_embedded_patchdata.py` — deterministic embedding of
  `PatchData/` into `NootedRedUserPatch/PatchDataBlob.{hpp,cpp}` and its host validation (the satellite
  no longer reads external data at runtime).
- `tools/master_source.py`, `tools/master_tables.py`, `tools/convert_master_patchdata.py`,
  `tools/userpatch_data.py`, `tools/extract_userpatch_fixture.py` — the current data pipeline.
- `tools/collect_platform_data.py`, `import_platform_data.py`, `adaptation_info.py`, `hwinfo_probe.c`,
  `gl_blend_probe.c`, the VDA/Firefox shell helpers and their READMEs — independent of the removed
  in-memory backend (some still target the main kext VCN bridge or collection workflows).

Historical descriptions live under [`docs/archive/`](../docs/archive/README.md); they are not
implementation guidance.
