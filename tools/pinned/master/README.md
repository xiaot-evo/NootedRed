# Pinned master table sources

> **Legacy v1 data (retired 2026-10-29).** Nothing here is a build input: the deployed profile is
> generated per macOS build by `NootedRedTool` and injected as `NRedProfiles`. Kept for provenance;
> see [`RETIRED.md`](../../RETIRED.md).

The satellite branch removes the mainline user-space patch code and its exact-page tables from
`NootedRed/`. The host tools need those exact source bytes to derive the checked-in fixtures, the
deployment specs and `PatchData/`, so this directory is a byte-for-byte snapshot of the relevant
master files.

- Source tree: `master` at commit `0efa6f4f36117fb603be968c1341006bf4da8c37`
  (`VCN/GLFIX: Add family fallbacks for nearby macOS builds`).
- Extraction: `git show master:<path> > tools/pinned/master/<path>`, recorded per file in
  [`manifest.json`](manifest.json) with size and SHA-256.
- Do **not** edit these files by hand. Refresh with:

```sh
python3 tools/master_source.py --verify          # default; checks hashes and required files
python3 tools/master_source.py --refresh         # re-pin from master (maintainers only)
```

`tools/extract_userpatch_fixture.py`, `tools/convert_master_patchdata.py` and
`tools/test_userpatch_data.py` read this snapshot by default, so `--check` works at HEAD and in a
source export without git history. An explicit `--source-root <checkout>` (or `--source-git <rev>`)
can be used instead; the fixtures/specs record the expected source SHA-256 so a stale derivation fails
loudly instead of silently changing the data.

The snapshot is data provenance, not build input: nothing in `NootedRed/` or `NootedRedUserPatch/`
includes these files.
