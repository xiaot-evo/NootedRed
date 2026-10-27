# Supplementary 24H32 sources

These are exact-page sources that are not part of the pinned master snapshot. They are appended to
the master-derived 24H32 spec by `tools/convert_master_patchdata.py` and pinned by SHA-256.

## metal-hwinfo-page.bin

- Target: macOS 15.8.1 (24H32), `AMDRadeonX5000MTLDriver`, `gfx9_HwInfoInitData` Renoir branch.
- Source: `research/apucaps-planb` `NootedRed/MTLHwInfoData.hpp` (`kPage`); the page was extracted
  from the 15.8.1 shared cache at `0x7ffb087ef000`.
- SHA-256: `37f265b415c6a56daf9bf6c80239b55c1aa670b9329e664ab1a562907f41d556`
- Site: offset `0x51D`, find `c7477804000000`, replace `c7477801000000`
  (`numShaderEngines 4 -> 1`).
- Purpose: align the Metal driver's HwInfo topology with Renoir's one shader engine before the
  compute/scratch path runs. On 15.8.1 / `0x1638` this removed the repeated `sips`/wallpaper HEIC
  conversion GPU resets (`computeUQ2`, `VTMTSComputeFunction`).
- Validation: controlled `sips -s format jpeg -Z 1080 ...DefaultDesktop.heic` runs completed twice
  with no new `.gpuRestart` reports; the satellite reported aggregate
  `NRedUserPatchAppliedPages=5`.

The page is a stock Apple driver page image, handled the same way as the master page arrays. Do not
hand-edit it; regenerate with the converter and verify with `tools/test_userpatch_data.py`.
