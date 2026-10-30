# 兼容性矩阵

状态日期：2026-10-30。本表描述当前代码树实际启用的东西，不是硬件理论能力。一个特性只有在该
build **和** 该 APU 上完成真实启动与对应功能测试，才算 `validated`。

> **数据面**：用户态 GL/Metal/VDA 补丁由卫星 `NootedRedUserPatch.kext` 执行，profile 是部署时
> 注入 `Info.plist` 的 NRPT v3 `NRedProfiles` bundle，kext 内没有页偏移表。主 kext 只做内核侧
> 启用，并在卫星缺席时照常工作。

## 状态词表

| 状态 | 含义 |
| --- | --- |
| **validated** | 该 build/APU 上完成真实启动 + 功能测试。 |
| **experimental** | 代码与数据存在，已离线或静态校验，但没有硬件测试记录。 |
| **supported** | 该 build 的内核路径存在，不代表下面的特性数据可用。 |
| **unsupported** | 没有数据或没有代码路径；特性是 no-op 或拒绝运行。 |
| **no-op** | 代码在，但 build/驱动页不匹配，什么也不写。 |

## macOS build 矩阵

| macOS build | Darwin | 内核/图形 | GL/Metal 页 | VDA/VCN 内核桥 | VDA/AppleGVA 页 | HEVC 编码 |
| --- | --- | --- | --- | --- | --- | --- |
| **15.8.2（24H232）** | 24.6 | supported | experimental（离线校验通过） | experimental | experimental（离线校验通过） | experimental |
| 15.8.1（24H32） | 24.6 | supported | 旧数据面，已停用 | supported | 旧数据面，已停用 | — |
| 其他 15.x | 24.x | supported（仅内核） | unsupported（无 profile） | unsupported | unsupported | unsupported |
| Catalina–Sonoma、Tahoe | 18–25 | supported（仅内核补丁） | unsupported | unsupported | unsupported | unsupported |

补充说明：

- 「内核/图形」指 NootedRed 主 kext 能加载、X5000/HWLibs/显示相关补丁生效，**不代表**用户态
  GL/Metal/VDA 补丁可用。
- 24H232 的 v3 profile 是 14 页 / 20 sites / 4 个目标镜像，离线校验：扫描 1858 个 `__TEXT` 页、
  0 个 find 不匹配、页记录逐条可应用。
- 旧数据面（13 页 / 18 sites，按 pager offset + matchFlags 匹配）曾在 15.8.2 真机上启动：
  名义启动应用 8/13 页，`FindMismatches=0`、`WriteFailures=0`，H.264/HEVC VideoToolbox 编码、
  AVFoundation H.264 解码、QQ/Metal、X5000GLDriver 链接均通过。这是 v2 引擎的证据，v3 引擎的
  硬件复验仍是待办。
- 没有「最接近的 build」回落：build 不在 profile bundle 里就是 fail-closed no-op。

## APU 矩阵

| APU / device ID | VCN | GL/Metal | VDA/VA + AppleGVA |
| --- | --- | --- | --- |
| Renoir / Green Sardine `0x1638` | 2.2 | experimental（硬件验证目标机） | experimental |
| Renoir `0x1636` | 2.2 | experimental（同一批 gfx9 页） | experimental |
| Cezanne `0x164C` | 2.2 | experimental | experimental |
| Barcelo `0x15E7` | 2.2 | experimental | experimental |
| Raven `0x15DD` | 1.x | experimental | unsupported（无 VCN 2.x 媒体路径） |
| Raven2 / Picasso `0x15D8` | 1.x | experimental | unsupported（无 VCN 2.x 媒体路径） |

gfx9 APU 共用同一批 GL/Metal 页数据，但只有 `0x1638` 有真实启动记录。VCN 1.x 的媒体引擎在
`DeviceProfile` 里就是关闭的，VDA 页不会被应用。

> 未知 device ID 会在 `NRed::processPatcher()` 里 **panic**（`NRed.cpp` 的显式 Barcelo 分支），
> 通用回落分支实际上到不了。新增 APU 必须先在 `DeviceProfile` 里登记。

## 特性/开关

| 特性 | 承载方 | 状态 |
| --- | --- | --- |
| GL 双光源（dual-source）修正 | 卫星 GL 页 | experimental |
| Metal dual-quad / RB+ gate / allow | 卫星 Metal 页 | experimental |
| Metal HwInfo A1（`numShaderEngines 4 -> 1`） | 卫星补充 Metal 页 | experimental |
| VDA/AppleGVA 用户态页 | 卫星 VDA/GVA 页 | experimental |
| VCN 2.x 硬解/硬编 | 主 kext VCN 桥 + 卫星 VDA 页 | experimental |
| X5000 compute-submit / GFXOFF | 主 kext vtable 修正 | 真机观测有效（`0x1638`） |
| 关闭用户态补丁 | `-NRedUserPatchOff` | 可用 |
| 只保留内核侧 | 移除卫星 kext | supported |

X5000 compute-submit 钩子在 PM4 计算提交前重置 GFXOFF 空闲计时器，避免空闲电源门控卡住计算队列。
上游实现把版本相关的 `ObjectField` 偏移加在 `__ZTV` 符号上而不是 vtable 地址点上，改到了错误的
虚函数槽；现实现补上 Itanium C++ ABI 的两个头部槽、校验该槽仍等于解析出的
`AMDPM4HWChannel::submitCommandBuffer`，不匹配就跳过安装而不是改坏 vtable。

## 新增一个 build

没有通用回落，必须整份生成：

1. `tools/collect_validation_fixtures.py` 收集目标系统的 `SystemKernelExtensions.kc` 与
   VADriver/AppleGVA 等驱动镜像；
2. `NootedRedTool --generate-profile <fixture-root> --out <dir>` 语义解析并生成 profile；
3. `python3 test/nrpt_validator.py --profile ... --fixtures ... --expected-build ... --device-id ...`
   独立校验；
4. `python3 test/inject_profile.py` 注入 `NRedProfiles`，并回读确认字节一致；
5. 按 [VDA-TESTING.md](VDA-TESTING.md) 完成硬解/硬编与 GL/Metal 真机测试后，才把它标成
   `validated`。

## 已知问题

- Chromium/Electron 的 OpenGL 花屏（issue #158）根因在 Apple 的用户态 `AMDRadeonX5000GLDriver`，
  只能靠用户态 GL 页修正；历史的 `-NRedGLFix*` 系列 boot-arg 已全部移除，不要再照着旧教程加。
- 逐页应用与 workload 时序相关：同一份 profile 在不同启动里应用到的页数会不同，未应用的页
  记为 deferred，不是失败。
