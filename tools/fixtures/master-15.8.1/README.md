# Fixture: master 15.8.1 exact UserPatch data

This directory is a small, real, deterministic fixture for the host-side UserPatch data tooling. It
lets `tools/test_userpatch_data.py` exercise the generator and the binary manifest parser without any
private Apple driver image or a live macOS install.

It is **test data only**. It is not an installable patch directory and it carries no claim about the
machine it was collected on beyond what the master source already records.

## Provenance

The three 4 KiB page images and the four patch sites are decoded from the exact-page tables in
[`NootedRed/UserPatches.cpp`](../../../NootedRed/UserPatches.cpp), the same tables the mainline kext
uses for its exact-page user-space backend:

| Fixture page | Master array | Driver build recorded in master |
| --- | --- | --- |
| `pages/gl-driver-hwinfo-0xE000.bin` | `kGLDriverHwInfoPage` | `AMDRadeonX5000GLDriver 7.0.25`, macOS 15.8.1 (Darwin 24.6.0), `kern.osversion` 24H32, page at file offset `0xE000` |
| `pages/gl-driver-dualquad-0x8000.bin` | `kGLDriverDualQuadPage` | same GL driver/build, page at file offset `0x8000` |
| `pages/mtl-driver-control-page.bin` | `kMTLControlPage` | `AMDRadeonX5000MTLDriver`, macOS 15.8.1 shared-cache page (master records no file offset) |

The sites come from the `kGLDriverPatches[]` `PagePatch` table (find/replace arrays and
`skip`/`count`). `tools/extract_userpatch_fixture.py` derives every site offset and occurrence index
from that table instead of trusting hand-written offsets, and verifies the find bytes against the
page. The source file SHA-256 is pinned in `spec.json` under `provenance.sourceFiles`.

The mainline comments say these page arrays were themselves extracted from the real driver build
(`dd`/`xxd` workflow documented in the source). No driver bytes are invented or paraphrased, and no
Apple driver binary is copied into the repository. The fixture pages are exactly the arrays master
patches.

The 15.8.1 Renoir-family, Raven-family and gfx9-fallback patch sets in master share byte-identical
page tables, so the fixture declares the union APU mask `0x3F`. A per-family deployment would keep
the same pages with a narrower mask.

### Independent sanity check of the extraction method

The same array parser was run against the gitignored 26.7.1 `platform-data` collection (real machine
data, not part of this repository): it reproduces master's `kTahoeGLHwInfoPage` and
`kTahoeGLDualQuadPage` byte-for-byte from the collected `GL-page-00E000.bin` / `GL-page-008000.bin`,
matches the corresponding `GLDriver.bin` slices, and locates `kTahoeMTLControlPage` inside the
collected MTL `__TEXT` image. That confirms master's page arrays really are exact copies of driver
bytes, which is why decoding the 15.8.1 fixture from the C++ arrays is sound. The 26.7.1 collection is
not needed to run the tests.

## Contents

| File | SHA-256 |
| --- | --- |
| `spec.json` | `8a7e32095cc81884abc1e36bf93bef07ca7fdd54aabb58e3e9f0d477ccf8ea96` |
| `pages/gl-driver-hwinfo-0xE000.bin` | `94fca357fefd7de0508910c0d9c42e9a1a771760b05242ec543cbf1b775e5af9` |
| `pages/gl-driver-dualquad-0x8000.bin` | `e8a5f32bb90c9e5bd130d6bc490410f16b76183ea02e87c3eb77b002bc7da932` |
| `pages/mtl-driver-control-page.bin` | `0fbfa6814c46170cd02589d17f62ce8c7732b75056f0ba83a82d0f5c9920f7a1` |

Site layout (`spec.json` → `tables`):

| Table | Page | Offset | Find → replace | Size | Occurrence | Note |
| --- | --- | --- | --- | --- | --- | --- |
| GL (1) | `gl-driver-hwinfo-0xE000` | `0x81` | `c7477804000000` → `c7477801000000` | 7 | 0 of 3 | `_gfx9_HwInfoInitData` shader-engine count |
| GL (1) | `gl-driver-dualquad-0x8000` | `0x160` | `83e0fe` → `83c801` | 3 | 1 of 2 | dual-quad `CB_COLOR_CONTROL` |
| Metal (2) | `mtl-driver-control-page` | `0x164` | `750b` → `eb0b` | 2 | 0 of 1 | RB+ gate |
| Metal (2) | `mtl-driver-control-page` | `0x198` | `0f94c0` → `31c090` | 3 | 0 of 2 | `allowRBPlus` |

The duplicate finds are intentional: real 15.8.1 data has more than one occurrence of the HwInfo,
dual-quad and Metal-allow byte sequences on their pages. This is why the format addresses sites by
explicit offset and why the generator requires a `findOccurrence` acknowledgement for ambiguous
finds. It is also why the validator must not require in-page find uniqueness.

## Regenerate / verify

From the repository root:

```sh
python3 tools/master_source.py --verify                # pinned master snapshot hashes
python3 tools/extract_userpatch_fixture.py             # rewrite fixture from the pinned source
python3 tools/extract_userpatch_fixture.py --check      # fail if the checked-in fixture is stale
python3 tools/userpatch_data.py \
    --spec tools/fixtures/master-15.8.1/spec.json \
    --out build/PatchData
```

At HEAD `NootedRed/UserPatches.cpp` is deleted, so the extractor defaults to the byte-identical pinned
snapshot (`tools/pinned/master/NootedRed/UserPatches.cpp`, also the source of the deployable
`PatchData/24H32` set). `--source <path>` selects a live/extracted tree explicitly; a source whose
SHA-256 differs is rejected by the spec provenance check.

The last command writes `build/PatchData/24H32/{manifest.bin,pages.bin,manifest.json}`; the test
suite uses a temporary directory instead.
