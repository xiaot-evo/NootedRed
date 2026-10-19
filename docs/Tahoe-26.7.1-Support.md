# macOS 26.7.1 (Tahoe) Support

Experimental branch `feature/tahoe-26.7.1`, based on the multi-OS PatchSet work.

## Data source

External dataset:

- macOS 26.7.1 (25G241), Darwin 25.6.0
- AMD Ryzen 5 5500U, Radeon Renoir `0x164C`
- Archive SHA-256: `c7c166125d7e18ca9a9a37711b357924e6175b847cd7638158f5eba4788c77f7`
- Second dataset: `0x1638` Renoir, same 25G241 build, archive SHA-256
  `b45d3f6a4cf3eda5089965a82a45bdd167065820ec9820155acb7ec6123f188b`
- Both datasets have byte-identical GL/MTL drivers, so this page data is shared across
  Renoir/Green Sardine and APU selection stays in DeviceProfile.

## Patch sites

GL driver (`AMDRadeonX5000GLDriver`):

| Patch | 15.8.1 | 26.7.1 |
| --- | --- | --- |
| `_gfx9_HwInfoInitData` | `0xDF40` | `0xDF80` |
| `_glrAMD_GFX9_UpdateHwCbDualQuadMode` | `0x8160` | `0x819E` |
| A1 site (`numShaderEngines=4`) | `0xE081` | `0xE0C1` |
| A2 `and eax,~1` | `0x8160` | `0x81CA` |
| A2 find-skip | 1 | 1 |

Exact 4 KiB pages are generated in `NootedRed/TahoePatchData.hpp`.

## Current coverage

- GL A1/A2 patches are included for Darwin 25.6 (26.7.1).
- Metal 26.7.1 is included as an **experimental direct-field patch**:
  - 15.8.1 uses `test [HwInfo+0xA0],2` + `jnz` + `setz al` and writes pipeline ctx `+0x28` bit 0.
  - 26.7.1 has no matching gate/setz sequence. Its pipeline init writes the CB_COLOR_CONTROL boolean
    at `+0xE4` with `and edx,~1 / or edx,ecx` at `0x7FFB10C77CD1`.
  - The new patch changes `and edx,~1` to `or edx,1` using an exact 13-byte page pattern.
  - The separate 26.7.1 `test [r13+0x220],2` gate at `0x7FFB10C77C9C` controls a different field
    (`+0x44` bit 16), so it is not patched.
  - Runtime validation is still required; this is the highest-risk part of the branch.
- The pages only match the 26.7.1 GL driver from this exact build, so other builds are a no-op.

## Verification

- Host patch-set selection test passes for Darwin 25.6.
- Release build passes in this worktree.
- Runtime validation on 26.7.1 is pending; do not merge to master before a tester confirms Chromium and
  Metal behavior.

## Next

1. Test the experimental Metal direct-field patch on the 5500U dataset machine.
2. If it is wrong, use the `r13+0x220` gate or the `+0x44` path as the next candidate.
3. Add a second 26.7.1 APU dataset (5800H/7730U) before declaring generic 26.7.1 support.
