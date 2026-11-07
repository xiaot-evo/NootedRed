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
| `NootedRedUserPatch.kext` | 用户态卫星：启动时解析当前系统的 Mach-O，解析编译进 kext 的规则，在 code-signing 校验钩子上写入（默认 GL/Metal 5 条，`-NRedUserPatchVDA` 打开 14 条 VADriver） |
| `NootedRedTool` | 宿主侧 macOS 15+ 诊断工具（旧的 profile 生成流水线已退役） |

用户态补丁的定位在运行期完成：kext 解析当前镜像的符号和函数结构；规则表很小且不按 build
增长。系统小版本更新通常不需要改 kext；只有 Apple 改变函数结构时才更新对应规则。

## 快速开始

1. 备份 EFI，准备好可用的救援引导。
2. 把两个 kext 放进 `EFI/OC/Kexts/`，按 `Lilu` → `NootedRed` → `NootedRedUserPatch` 顺序加入
   `config.plist` 的 `Kernel > Add`。
3. VDA 用户态补丁默认关闭；需要时在 `boot-args` 加 `-NRedUserPatchVDA`。
4. 重启，用 `log show`（DEBUG Lilu）核对 analyzer 的 resolved 汇总。

细节与回滚见 [安装与使用](docs/INSTALLATION.md)。

## 文档

- [安装与使用](docs/INSTALLATION.md) — 安装、boot-args、验证、回滚、排障。
- [用户态补丁架构](docs/USERSPACE-PATCHING.md) — 运行期解析、规则模型、写入路径与不变量。
- [VDA 测试](docs/VDA-TESTING.md) — 硬解/硬编真机验证流程。
- 组件文档：[卫星](NootedRedUserPatch/README.md)、[工具脚本](tools/README.md)。

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
