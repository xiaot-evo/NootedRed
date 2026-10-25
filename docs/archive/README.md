# Archived documentation

These documents describe **previous** architectures and research. They are kept for history and
debugging context only. They are **not** current implementation guidance.

The current architecture is:

- [Architecture](../ARCHITECTURE.md) — kernel `NootedRed.kext` + `NootedRedUserPatch.kext` satellite +
  external `PatchData/`
- [Satellite UserPatch plan](../Satellite-UserPatch-Plan.md)
- [UserPatch data format](../UserPatch-Data-Format.md)

Why the old documents were archived:

- `Root-Patch-Architecture.md` — the abandoned "Plane B `NootedRedRootPatch`" OCLP-style root-patch
  design (APFS mount, dyld-cache/kext replacement, snapshot/bless). Its implementation pipeline is
  still in-tree as [`../ROOT-PATCH-PIPELINE.md`](../ROOT-PATCH-PIPELINE.md) but carries a superseded
  banner. Both are superseded by the approved satellite-kext split, which keeps user-space patches in
  memory behind exact-page hooks instead of rewriting the root volume.
- `Compatibility-Architecture.md`, `Patch-Architecture.md`, `Device-Profile.md`,
  `CONTRIBUTING-USERPATCHES.md` — describe the `_cs_validate_page` in-memory page-cache patcher,
  exact-page snapshots, resolver/semantic fallbacks and multi-version C++ page tables. The current
  satellite keeps the exact-page idea but moves the tables to the external `PatchData/` format; the
  mainline kext no longer contains this code.
- `VDA-Implementation-Plan.md`, `VDA-Deployment.md` — in-memory VDA user-space flow and now-deleted
  opt-in boot args; the kernel VCN bridge part remains relevant and is described in the current
  architecture. VDA user-space data now ships as `PatchData` kinds 3/4.
- `Chromium-Fix-Usage.md` — end-user boot args for the removed in-memory GLFIX path
  (`-NRedGLFix...`); the satellite auto-loads and `-NRedUserPatchOff` is the only new debug override.
- `IGPU-HwInfo-Research-Plan.md`, `TESTER-GUIDE.md`, `Tahoe-26.7.1-Support.md` — historical research and
  test handoff notes.

The generators referenced by these archived documents (`tools/gen_patch_data.py`,
`tools/gen_vda_va_data.py`, `tools/gen_vda_gva_data.py`, `tools/collect_compat_data.py` and their
READMEs) were retired in the split; see [`tools/RETIRED.md`](../../tools/RETIRED.md) for replacements
and [`tools/README-userpatch-data.md`](../../tools/README-userpatch-data.md) for the current pipeline.

The analyses under [`../../analysis/`](../../analysis/) are also historical research records. Some of them
describe data derivation that is still useful for payload generation, but their runtime patching
recommendations are superseded by the current architecture.
