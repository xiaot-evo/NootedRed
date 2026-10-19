# External Platform Data Index

This index records datasets collected from external machines. The full archives are intentionally kept
outside git (see `.gitignore`) because they contain Apple driver binaries, `nvram` output and hardware
identifiers.

## 2026-10-19 — macOS 26.7.1 (25G241), Ryzen 5 5500U

| Field | Value |
| --- | --- |
| macOS | 26.7.1 (25G241) |
| Darwin | 25.6.0 |
| CPU | AMD Ryzen 5 5500U |
| GPU | AMD Radeon RX Renoir Graphics |
| Device ID | `0x164c` |
| Revision | `0xc2` |
| Archive | `NootedRed-platform-data-full.zip` |
| Archive SHA-256 | `c7c166125d7e18ca9a9a37711b357924e6175b847cd7638158f5eba4788c77f7` |
| Collection mode | `--full` |
| Local path | `platform-data/2026-10-19_macos-26.7.1_25G241_ryzen5-5500u_0x164c/` |

### Initial driver findings

- GL `_gfx9_HwInfoInitData` at `0xdf80` (15.8.1: `0xdf40`).
- GL `_amdUbm_HWL_Init` at `0x5e550` (15.8.1: `0x5ee3a`).
- GL `_glrAMD_GFX9_UpdateHwCbDualQuadMode` at `0x819e`.
- GL `numShaderEngines=4` stores at `0xE0C1`, `0xE10C`, `0xE149`; no `=1` store in the binary.
- GL branch flags: `or ecx,0x4d` at `0xE0E2` and `0xE16A`; `or ecx,0x4f` at `0xE12D`.
- MTL `gfx9_HwInfoInitData` at `0x7ffb10c53fe0`; pipeline-state init at `0x7ffb10c766ee`.
- MTL symbols include `amdMtl_HWL_InitDeviceSettings`, `amdMtl_HWL_InitAddrLibHwRegFields`, and
  RB+ setup helpers (`amdMtl_GFX9_SetUpRBPlusRegs`, `SetupRBPlusMrtBlendOpts`).

The archive is untrusted external data and is not executed. Use it only for offline analysis.

## Adding a dataset

1. Copy the archive under `platform-data/<date>_<os>_<cpu>_<device-id>/`.
2. Record its SHA-256.
3. Add an entry here with OS, Darwin, APU/device ID, archive hash and initial findings.
4. Never commit the archive or extracted Apple binaries.
