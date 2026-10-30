# tools/ — 工具索引

脚本都从仓库根目录运行。当前补丁流水线是 **NRPT v3 profile**：生成在 `NootedRedTool`，校验和注入在
`test/`，本目录只放采集、诊断和部署辅助工具。

## 1. 当前流水线

| 工具 | 用途 |
| --- | --- |
| `NootedRedTool --generate-profile` | 从干净 fixture 语义解析目标驱动，生成 `nred-<build>.nrpt`（见 `../NootedRedTool/README.md`） |
| `../test/nrpt_validator.py` | 独立的 NRPT v3 校验器，字节级拒绝任何可能打错页的 profile |
| `../test/inject_profile.py` | 注入/检查/提取 `Info.plist` 里的 `NRedProfiles` bundle |
| `find_nrpt_page_origin.py` | 把运行时交付的页哈希映射回源镜像与偏移（v3 mode/image 元数据） |

## 2. 构建与产物

| 工具 | 用途 |
| --- | --- |
| `build-branch.sh` | 受支持的构建入口：按分支隔离产物、给 zip 加时间戳（见 `../docs/Build-Artifacts.md`） |
| `build.sh` | 单独编译 `gl_blend_probe`（不碰 GPU） |
| `test_build_artifacts.py` | 检查 `build/branches/...` 下两个产物 glob 是否都齐 |

## 3. 目标机采集

| 工具 | 用途 |
| --- | --- |
| `collect_validation_fixtures.py` | 收集副本树（`.kc`、驱动 bundle、`.map`），供离线校验；输出路径与 `nrpt_validator.py` 的 `DEFAULT_IMAGE_GLOBS` 对齐 |
| `collect_platform_data.py` / `import_platform_data.py` | 采集与归档平台数据（`/platform-data/`，不进 git）；`--full` 才带完整驱动 |
| `adaptation_info.py` | 只读生成一份兼容性报告（系统、kext、GPU、boot-args、EFI 状态），用于 triage |

VDA 专项：`set_vda_bootarg.sh`（读写 `-NRedVDA`，改 config 前自动备份）、`vda_selftest.sh`（只读状态
汇总）、`vda_hwtest.sh`（生成样本、解码比对、抓 reset 报告）、`deploy_vda.sh`（按当前分支产物部署）。
整套流程见 `../docs/VDA-TESTING.md`。

## 4. GPU 诊断探针

| 工具 | 用途 |
| --- | --- |
| `gl_blend_probe.c` | 离屏 CGL/OpenGL 混合测试，用于复现 Chromium/Electron 花屏（issue #158）。**有风险，先读 [`gl_blend_probe.md`](gl_blend_probe.md)** |
| `hwinfo_probe.c` | 从 IOAccelerator 读出 selector `0x100` 的 `0x204` 字节 HwInfo blob（`+0x20` 头、`+0xa0` 起为数据）；`Renoir` 上可直接看出 `GB_ADDR_CONFIG`/CU 数，结果可写 `/tmp/ubm_kernel_blob.bin` 留档 |

## 5. Firefox/Zen 硬解启动器

`firefox-hwdecode-launcher.sh` + `Firefox-HW-Decode.command`：生成带 `MOZ_DISABLE_RDD_SANDBOX=1` 的
桌面启动器，并写入硬解 prefs。用法与安全权衡见 `../docs/FIREFOX-HW-DECODE.md`。

## 6. 已退休的 v1 数据流水线

`userpatch_data.py`、`convert_master_patchdata.py`、`master_source.py`、`master_tables.py`、
`embed_patchdata.py`、`extract_userpatch_fixture.py` 及对应的 `test_*.py`、`specs/`、`fixtures/`、
`pinned/master/`、仓库根的 `PatchData/` 都属于 NRPD v1 时代。kext 已经不读它们，`PatchData/` 也不再
被任何构建步骤使用。清单与替代关系见 [`RETIRED.md`](RETIRED.md)。

> 隐患：`embed_patchdata.py` 仍会生成 `NootedRedUserPatch/PatchDataBlob.cpp`，而 `xmake.lua` 用
> `NootedRedUserPatch/**.cpp` 通配源文件——谁跑一次就会把它编进 kext。除非在复活 v1，否则不要运行。
