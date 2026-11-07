# tools/ — 工具索引

脚本都从仓库根目录运行。用户态补丁已经改为运行期解析，不再有 profile / NRPT / 嵌入式
PatchData 流水线；对应工具已删除。分析器设计见 [`../docs/USERSPACE-PATCHING.md`](../docs/USERSPACE-PATCHING.md)。

## 构建与产物

| 工具 | 用途 |
| --- | --- |
| `build-branch.sh` | 按分支隔离产物并给 zip 加时间戳 |
| `build.sh` | 单独编译 `gl_blend_probe`（不碰 GPU） |

## Fixture 采集

| 工具 | 用途 |
| --- | --- |
| `collect_validation_fixtures.py` | 收集干净 fixture 副本树，供 `test/test_analyzer.py` 使用 |

## VDA 专项与探针

- `set_vda_bootarg.sh`、`vda_selftest.sh`、`vda_hwtest.sh`、`deploy_vda.sh`：见
  [`../docs/VDA-TESTING.md`](../docs/VDA-TESTING.md)。
- `gl_blend_probe.c` / `gl_blend_probe.md`：离屏 CGL/OpenGL 混合测试（有风险，先读说明）。
- `hwinfo_probe.c`：从 IOAccelerator 读出 HwInfo blob。

分析器的主机侧回归测试在 `test/test_analyzer.py`；VDA 规则默认关闭，用 `-NRedUserPatchVDA` 打开。
