# NootedRed ![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/ChefKissInc/NootedRed/main.yml?branch=master&logo=github&style=for-the-badge) [![Release Badge](https://img.shields.io/github/v/release/ChefKissInc/NootedRed?include_prereleases&style=for-the-badge&sort=semver&color=blue)](https://github.com/ChefKissInc/NootedRed/releases) [![Downloads Badge](https://img.shields.io/github/downloads/ChefKissInc/NootedRed/total?style=for-the-badge)](https://github.com/ChefKissInc/NootedRed/releases/latest) ![Written by humans, not AI](https://img.shields.io/badge/written_by_humans-not_ai-blue?style=for-the-badge)

> [!CAUTION]
> Please consider donating: donations help me stay alive and pay costs; if the Hackintosh projects don't receive funding, I will (have to) stop working on them.
>
> PayPal or credit/debit card: https://ko-fi.com/chefkiss
>
> BTC: `bc1qgu56kptepex2csuzl5nhzc4vxuj8c6ggjzhcem`
>
> SOL: `4PJU3iB5rimN9BNcpzduvmTnptJyedZiAd23so33SAdi`
>
> ETH: `0x038A25849c23Bc5A736484351a8B6Ad71bC46676`

AMD 集显（Raven / Renoir / Picasso / Green Sardine / Cezanne / Barcelo）的 macOS 内核扩展：修复
Apple AMD 驱动里的 bug、改善体验、扩展硬件支持。它不是驱动替代品，而是在运行时对 Apple 原版
kext 做字节级补丁。

```
Copyright (C) 2022-2026  ChefKiss

Licensed under the ChefKiss Open Knowledge License version 1.

This work is licensed to you under the terms of the ChefKiss Open Knowledge
License, either version 1 of the License, or (at your option) any later
version published by ChefKiss.

This work may not be used to train or develop artificial intelligence,
and may not be used with artificial intelligence in any other way. See
the ChefKiss Open Knowledge License for details.

This work is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
ChefKiss Open Knowledge License for more details.

You should have received a copy of the ChefKiss Open Knowledge License
along with this work.  If not, see https://git.chefkiss.dev/ChefKiss/OpenKnowledge/raw/branch/master/LICENSE-v1.md.
```

> [!WARNING]
> 项目处于活跃研发阶段，会有崩溃——它是既有 AMD 驱动之间的胶水层。
>
> 问题与更多信息见仓库 issues 和 [项目主页](https://chefkiss.dev/applehax/nootedred)。

## 组成

| 组件 | 作用 |
| --- | --- |
| `NootedRed.kext` | 内核侧：FB/DC/PM/SMU、X5000/X6000/HWLibs/AGDP/Backlight 等补丁 |
| `NootedRedUserPatch.kext` | 用户态卫星：在 code-signing 校验钩子上做整页内容补丁（GL/Metal/VDA/AppleGVA） |
| `NootedRedTool` | 宿主侧 macOS 15+ 工具：从干净镜像生成/校验/注入 NRPT v3 profile |

用户态补丁不含任何写死的页偏移：kext 里只有匹配逻辑，补丁数据是部署时注入 `Info.plist` 的
profile。换 macOS 小版本需要重新生成 profile，而不是换 kext。

## 快速开始

1. 备份 EFI，准备好可用的救援引导。
2. 把两个 kext 放进 `EFI/OC/Kexts/`，按 `Lilu` → `NootedRed` → `NootedRedUserPatch` 顺序加入
   `config.plist` 的 `Kernel > Add`。
3. 为目标 build 生成并注入 profile（或用随发布提供的 profile）。
4. 重启，用 `ioreg`/`log show` 核对状态。

细节与回滚见 [安装与使用](docs/INSTALLATION.md)。

## 文档

- [文档索引](docs/README.md) — 全部文档的分类入口。
- [安装与使用](docs/INSTALLATION.md) — 安装、profile 注入、boot-args、验证、回滚、排障。
- [架构](docs/ARCHITECTURE.md) — 组件边界、数据流、页面身份与不变量。
- [兼容性矩阵](docs/COMPATIBILITY.md) — 逐 build / 逐 APU 状态与新增 build 的流程。
- [模块与支持](docs/MODULES-AND-SUPPORT.md) — 模块职责、硬件档位、启动参数。
- [构建产物](docs/Build-Artifacts.md) — 按分支隔离的产物布局。
- [VDA 测试](docs/VDA-TESTING.md) — 硬解/硬编真机验证流程。
- [Firefox 硬解](docs/FIREFOX-HW-DECODE.md) — 浏览器硬解启动器。
- [Profile 规范](docs/PatchProfile-Spec.md) — NRPT v3 格式（英文）。
- 组件文档：[卫星](NootedRedUserPatch/README.md)、[工具](NootedRedTool/README.md)、
  [校验器](test/README.md)、[工具脚本](tools/README.md)。

研究记录（设计取舍、验证证据、已被取代的方案）在本地 `research/`，不进版本库；
工作约定见 `AGENTS.md`。

## 构建

需要 [AppleForge](https://git.chefkiss.dev/AppleHax/AppleForge)（xmake 封装）与 xmake：

```sh
git clone --recurse-submodules https://git.chefkiss.dev/AppleHax/AppleForge.git  # 放在同级目录
brew install xmake
tools/build-branch.sh -y        # 产物在 build/branches/<branch>/...
```

也可以直接 `xmake f -m release -y && xmake -y`。三种模式（`debug`/`releasedbg`/`release`）CI 都会
构建。产物布局见 [构建产物](docs/Build-Artifacts.md)。
