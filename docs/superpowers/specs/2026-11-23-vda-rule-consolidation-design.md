# VDA 用户态规则收敛 — 设计

日期：2026-11-23
状态：已批准（方案 A+B+删死规则；同时修正 0x1636/0x164C 门槛）
范围：`NootedRedUserPatch` 的规则表与设备家族门控。主 kext、内核 VCN bridge 不改。

## 1. 意图

把 VDA 用户态规则从 14 条降到 8 条、总规则从 19 条降到 13 条，同时保持 15.8.3 / Renoir
`0x1638` 上已验证的硬解/硬编行为不变：

- 用 `VAContext::createVideoProcessor` 公共调用点上的一次 family 覆盖，替代 3 条 VP 工厂补丁
  （原规则 7–9）。
- 把 `Vcn2Encoder::setEncodeParams` 内相邻的两条补丁（原 12/13）合并为一条 25 字节的
  all-or-nothing 补丁。
- 删除 3 条在当前 family-5 VCN 配置下静态不可达的 addrlib 补丁（原 6/17/18）。
- 厘清设备家族门控：`kFamilyVCN2` 改用四颗 VCN2.2 APU 共享的 bit 3（`0x08`）。原 `0x28` 已经
  通过 bit 3 覆盖 0x1636/0x164C，因此这是语义精确化、不是行为修复；把 device-id→family 映射
  移入 freestanding Analyzer，以便主机侧断言。

## 2. 关键证据

- 规则 5 把 `VAAcceleratorInfo::identify` 的 fallback 改为 family 5；`_AVD_CreateAVDAccelerator`
  把 5 存入 `+0x54` 并调用 `AvdCapability::initDriverCapability(5, 1)`。
- `initDriverCapability` 调用 `getExtraIdInfo(5, 1, cfg)`；family-5 分支写
  `cfg+0xC = 3`、`cfg+0x94 = (flag<<7) | 0x3C566`，即 **bit 16 置位**。
- `VAContext` 构造函数把 cfg 存到 `+0x460`，把 `cfg[0]`（内核硬件信息指针）存到 `+0x468`。
- `VAContext::Init` 执行 `testb $1, 0x96(%rax)`；bit 16 置位 → 跳过
  `VAAddrLibInterface::init`，`+0x12548 = 0`。该函数是 `Addr::Lib::Create`（经 `Addr::Create`
  跳板）与 `HwlConvertChipFamily` 的唯一调用入口，因此原 6/17/18 不会执行。
- 由规则 7–11 创建的 `Gfx9*` VP/ImageBlt 类覆写了会解引用 `VAContext+0x12548` 的 `Vi*` 方法
  （`Gfx9ColorFormatConvertor::nv12ToYuy2CopyFullRangeDither`、
  `Gfx9DitheringProcessor::randomPosBlockDitheringY/UV`、`Gfx9Deblocker::avcIntraDeblock`），
  没有隐藏的 addrlib 依赖。
- 15.8.2、live 15.8.3、26.7.2 三个镜像中：
  - 新的 10 字节 VP family 加载序列
    `49 8B 85 60 04 00 00 8B 50 0C` 存在且 **全镜像唯一**（位于
    `VAContext::createVideoProcessor+0x25`）。
  - 新的 25 字节 encode 序列存在，在每个镜像的 `Vcn2Encoder::setEncodeParams` 函数内唯一；
    镜像内另有一份在 `Vcn3Encoder::setEncodeParams`，由函数锚点隔离。
- `Vcn2Encoder::setFeedbackBufParams` 已硬编码 feedback record size `0x30`
  （`0x4CA2F: movl $0x30, 0x10(%rdx)`），而 `getFeedbackSize` 与两个状态解析仍用 Navi10 的
  `0xA4`；这佐证原 14–16 的语义是修正 Apple 内部不一致，而不是猜测。

## 3. 决策

### 3.1 新规则布局（总 13 条，VDA 8 条）

| ID | 镜像 | 锚点 | 函数内偏移 | 作用 |
|---:|---|---|---:|---|
| 0 | GL | `_glrAMD_GFX9_UpdateHwCbDualQuadMode` | `0x2C` | 既有 |
| 1 | GL | `_gfx9_HwInfoInitData` | `0x141` | 既有 |
| 2 | MTL | `-[GFX9_MtlRenderPipelineState initWithDevice:...]` | `0x11C4` | 既有（2 variants） |
| 3 | MTL | 同上 | `0x11F8` | 既有（2 variants） |
| 4 | MTL | `__Z19gfx9_HwInfoInitData...` | `0x141` | 既有 |
| 5 | VADriver2 | `__ZN17VAAcceleratorInfo8identifyEjj` | `0x1B6` | 既有 |
| 6 | VADriver2 | `__ZN9VAContext20createVideoProcessorEjjjj` | `0x25` | 替代原 7–9 |
| 7 | VADriver2 | `__ZN9VAFactory20createGraphicsEngineEP9VAContext` | `0xA` | 既有 10 |
| 8 | VADriver2 | `__ZN9VAFactory14createImageBltEP9VAContextj` | `0xB` | 既有 11 |
| 9 | VADriver2 | `__ZN11Vcn2Encoder15setEncodeParamsEPvP15VAVendorTexture` | `0x31` | 合并原 12+13 |
| 10 | VADriver2 | `__ZN14Vcn2EncCommand15getFeedbackSizeEv` | `0x4` | 既有 14 |
| 11 | VADriver2 | `__ZN26AVDVcn2AvcEncDataProcessor19ProcessEncodeStatus...` | `0x2A` | 既有 15 |
| 12 | VADriver2 | `__ZN27AVDVcn2HevcEncDataProcessor19ProcessEncodeStatus...` | `0x2A` | 既有 16 |

规则 6 的 find/replace：

```
find    = 49 8B 85 60 04 00 00 8B 50 0C
replace = BA 02 00 00 00 90 90 90 90 90
```

规则 9 的 find/replace（25/25 字节）：

```
find    = 8B 8A 84 00 00 00 8B 87 24 04 00 00 0F AF C1 05 FF 00 00 00 25 00 FF FF FF
replace = 8B 82 80 00 00 00 8B 8A 84 00 00 00 90 90 90 90 90 90 90 90 90 90 90 90 90
```

### 3.2 删除的规则

原 6（`VAAddrLibInterface::init` 0x8D→0x8E）、17（`Addr::Lib::Create`）、
18（`Gfx9Lib::HwlConvertChipFamily`）删除。理由见 §2；静态不可达，保留只会增加解析/写入
噪音。删除后其页面不再被写入；若未来 macOS 改变了 family-5 配置，规则表需要重新分析并
重新加入对应 site，而不是保留无依据的补丁。

### 3.3 设备家族门控

- `kFamilyVCN2` 从 `0x28` 改为 `0x08`，即四颗 VCN2.2 APU 共享的 bit 3。原 `0x28` 已经通过
  bit 3 命中 0x1636/0x164C（`0x28 & 0x18 = 0x08`）；本次改动是语义精确化，不是行为修复。
  bit 4 = 0x1636/0x164C 组、bit 5 = 0x1638/0x15E7 组保留给未来的按硅片规则。
- `familyForDeviceID` 从 `AnalyzerRuntime` 移入 `Analyzer/Family.hpp`，保持现有映射：
  0x1636/0x164C → `0x18`，0x1638/0x15E7 → `0x28`，Raven/Picasso → 低 bits，未知 → 0。
- 在 `test_analyzer.cpp` 中断言 `kFamilyVCN2` 等于四颗 VCN2 family 值的交集，四颗 VCN2.2 在
  默认/VDA 规则下命中，Raven/Picasso/未知不命中。

## 4. 非目标

- 不改主 kext、内核 VCN bridge、VCN 数据或内核侧 family 值（`AMD_FAMILY_RAVEN = 0x8E`）。
- 不实现 `MatchPolicy::kAll`、fingerprint/image-unique 锚点；这些是独立清理项。
- 不改规则 5/7/8/10/11/12 的语义（原 5/10/11/14/15/16）。
- 不发布、不 bump 版本、不写 EFI，直到硬件 A/B 通过且用户明确授权。

## 5. 验证

- 主机：`test_analyzer.py`（13/13，含规则 6/9 的 find/replace 精确断言和 `kFamilyVCN2`
  共享位断言）、`test_fixture_probe.py`（13/13）、`test_site_set.py`（含 25 字节 site）、
  `test_block_reader.py`。
- 规则生成器必须在 15.8.2 与 26.7.2 上分别通过 pattern 唯一性和 find 验证；任一失败即
  fail closed，不生成表。
- 硬件（需用户明确授权 EFI 写入）：debug 卫星 +
  `-NRedVDA -NRedUserPatchVDA -NRedUserPatchDebug -liludbgall liludump=60`；检查
  `analyzer: 13/13 rules resolved`、全量 `tools/vda_hwtest.sh`、Bilibili/Safari HEVC 10-bit、
  六路并发 1080p 10-bit HEVC、硬件编码矩阵、无 `.gpuRestart`/panic/`cosWaitForFunc`/VCN0Dec
  reset。失败则恢复 EFI 快照。
- 0x1636/0x164C 没有可测硬件，保持 experimental；只有主机侧映射断言。
