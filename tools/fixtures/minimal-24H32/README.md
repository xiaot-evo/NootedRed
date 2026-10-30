# Fixture: minimal 24H32 loader test vector

> **Legacy v1 data (retired 2026-10-29).** Nothing here is a build input: the deployed profile is
> generated per macOS build by `NootedRedTool` and injected as `NRedProfiles`. Kept for provenance;
> see [`RETIRED.md`](../../RETIRED.md).

One GL table, one page, one site, `apuMask` bit 5 (GreenSardine), for Darwin 24.6.0 / build `24H32`.
This is the smallest valid manifest the generator can emit (188-byte `manifest.bin`, 4096-byte
`pages.bin`) and is meant to let the satellite loader/selection tests exercise the format with a
single record of each kind.

It is **test data only**, not an installable patch directory.

## Provenance

This is a strict subset of [`../master-15.8.1`](../master-15.8.1/README.md): the page image is the
same real `kGLDriverDualQuadPage` bytes (page file SHA-256
`e8a5f32bb90c9e5bd130d6bc490410f16b76183ea02e87c3eb77b002bc7da932`) and the single site is the real
dual-quad site (offset `0x160`, `83e0fe` → `83c801`, occurrence 1 of 2) from master's
`kGLDriverPatches[]` table. Nothing is invented or paraphrased.

`apuMask` is `0x20` (bit 5 only) rather than the `0x3F` union used by the full fixture: mainline maps
the 0x1638/0x15E7 devices to its Renoir+GreenSardine attributes, so their
candidate family set contains bit 5; a manifest declaring only bit 5 matches those devices via the
`apuMask & candidateMask != 0` rule. The page/site data is identical to the full fixture, which is why
this narrower mask is still real data. Exact page equality remains the final runtime gate.

## Generate

From the repository root:

```sh
python3 tools/userpatch_data.py \
    --spec tools/fixtures/minimal-24H32/spec.json \
    --out build/PatchData
# -> build/PatchData/24H32/{manifest.bin,pages.bin,manifest.json}
```

Expected generated output (deterministic):

| File | Size | SHA-256 |
| --- | --- | --- |
| `manifest.bin` | 188 | `bedb1d897c8415643280cebab58dd7c72a5bd2775eefc4376c57c9be90ab5bf3` |
| `pages.bin` | 4096 | `e8a5f32bb90c9e5bd130d6bc490410f16b76183ea02e87c3eb77b002bc7da932` |

`manifest.json` is deterministic too; `tools/test_userpatch_data.py` validates it against the binary.
