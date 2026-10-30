# 模块职责与支持范围

状态日期：2026-10-30。本文按当前代码树描述模块边界（谁做什么、谁不许做什么）、硬件档位和开关。
架构与数据流见 [ARCHITECTURE.md](ARCHITECTURE.md)，逐 build/APU 状态见
[COMPATIBILITY.md](COMPATIBILITY.md)。

## 1. 模块职责

| 模块 | 职责 | 不许做 |
| --- | --- | --- |
| `NootedRed.kext` | 内核补丁、FB/DC/PM/SMU/PSP、VCN 内核桥、发布 `NRedVCNBridgeReady` 状态属性 | 用户态页补丁、启动期 VFS 读取 |
| `NootedRed/X5000.cpp` `X6000FB.cpp` `HWLibs.cpp` `AGDP.cpp` `Backlight.cpp` `AppleGFXHDA.cpp` | 各 Apple kext 的字节模式补丁与 vtable 修正 | 生成或携带用户态页数据 |
| `NootedRed/VCNRuntimeResolver.cpp` | 运行时解析 X5000/X6000 的符号与 vtable | 依赖写死的 build 字符串或静态表 |
| `NootedRed/DeviceProfile.*` | 设备 ID → 家族/VCN/媒体能力；`GraphicsPolicy`/`MediaPolicy` | 猜测未知设备（未知即 panic，见 §3） |
| `NootedRedUserPatch.kext` | `_cs_validate_page`/`_cs_validate_range` 上的整页内容补丁 | 内核 kext 补丁、运行时读文件/读 plist、语义扫描 |
| `NootedRedTool` | 从干净 fixture 生成/校验/注入 NRPT v3 profile | 在卫星已加载的系统上生成 profile |
| `test/nrpt_validator.py` `test/inject_profile.py` | 独立校验与注入 | 参与构建产物 |

`NootedRed/Kexts.cpp` 是「要打哪些 Apple kext」的唯一清单（`KernelPatcher::KextInfo` + 磁盘路径）。
新增 patcher 模块时同时更新它，否则补丁永远不会被投递。

## 2. 硬件档位（DeviceProfile）

`MediaPolicy` 描述每个设备的媒体能力，字段与固件对应关系如下：

| device ID | 家族 | VCN | 版本码 | 固件 | H.264 | HEVC | 内核媒体 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `0x1636` | Renoir | 2.2 | `0x0202` | `ativvaxy_nv.dat` | 启用 | 启用 | 开 |
| `0x1638` | Renoir / Green Sardine | 2.2 | `0x0202` | `ativvaxy_nv.dat` | 启用 | 启用 | 开（硬件验证目标机） |
| `0x164C` | Cezanne | 2.2 | `0x0202` | `ativvaxy_nv.dat` | 启用 | 启用 | 开 |
| `0x15E7` | Barcelo | 2.2 | `0x0202` | `ativvaxy_nv.dat` | 启用 | 启用 | 开 |
| `0x15DD` | Raven | 1.0-class | `0x0100` | `ativvaxy_rv.dat` | 启用 | 启用 | 关（无 VCN 2.x 路径） |
| `0x15D8` | Raven2 / Picasso | 1.0-class | `0x0100` | `ativvaxy_rv.dat` | 启用 | 启用 | 关（无 VCN 2.x 路径） |

`ring`/`fence` 尺寸对 VCN 2.2 是 `0x10000`/`0x1000`；`av1` 恒为 0。启动日志形如：

```text
media{gate=0 vcn=0x0202 fw=ativvaxy_nv.dat ring=0x10000 fence=0x1000 h264=1 hevc=1 av1=0}
```

## 3. 未知设备

`DeviceProfile::forDevice()` 对未登记的 device ID 返回空，但 `NRed::processPatcher()` 在此之前就会
**panic**（Barcelo 的显式分支之后没有通用回落）。所以「未知设备 = 安全降级」这条路径实际不可达：
新增 APU 必须先登记 `DeviceProfile`，再谈用户态数据。

## 4. 内核侧启动顺序

1. OpenCore 加载 Lilu，然后 `NootedRed.kext`；卫星因 `OSBundleLibraries` 依赖随后加载。
2. 主 kext `processPatcher()` 按 `Kexts.cpp` 表完成内核补丁，登记 IBM 加速器 personality。
3. 加速器 start 时按 `-NRedVDA` 决定是否请求 VCN 桥；桥就绪后发布 `NRedVCNBridgeReady=1`。
4. 卫星在 Lilu patcher load 阶段装钩子、选 profile；主 kext 的 readiness 属性只作状态/诊断，
   **不再是卫星的页面开关**。

## 5. 启动参数

| 参数 | 作用 |
| --- | --- |
| `-NRedOff` | 完全关闭 NootedRed（救援用） |
| `-NRedNoAccel` | 只做 FB，不加载加速器（调试用） |
| `-NRedVDA` | 请求 VCN 内核桥（硬解/硬编实验路径） |
| `-NRedBeta` | 允许在不支持的 macOS 版本上加载（内部） |
| `-NRedDebug` | 打开 `DBGLOG` 输出 |
| `-NRedUserPatchOff` | 关闭卫星，保留主 kext |
| `-NRedUserPatchDebug` | 卫星日志 |
| `-NRedUserPatchBeta` | 卫星允许 beta 版本（内部） |

另有若干诊断用参数（`-NRedDelayPanic`、`-NRedDebugUltra`、`-NRedDPDelay`、`-NRedCursorDebug`），
只供排查单点问题，不要写进日常配置。

把 `-NRedNoAccel` 和 `-NRedVDA` 一起加没有意义：前者根本不启动加速器。

## 6. 支持范围与回滚

- 主 kext 声明支持 Catalina → Tahoe；内核补丁按版本门控，没有对应版本的补丁就是不匹配而非崩溃。
- 卫星的 profile 只覆盖生成它的那一个 build，其余 build fail-closed no-op。
- 回滚顺序：`-NRedUserPatchOff` → 从 EFI 移除卫星 kext → `-NRedOff` → 换回备份的 EFI。
- 用户态页一旦写入共享缓存页缓存，到重启前都保持已打补丁状态，无法可靠回退；此时关闭补丁
  只能阻止后续页被写。
