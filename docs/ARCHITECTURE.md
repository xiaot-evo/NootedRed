# NootedRed 架构

状态：2026-10-30，对应 NRPT v3 profile 引擎（`feature/profile-driven-userpatch`）。本文只描述当前代码
实际执行的路径；历史上的 embedded PatchData、offset 身份、root patch 方案见 `../research/legacy/`。

## 1. 三个组件

```
Lilu
 ├── NootedRed.kext              内核侧：X5000/X6000/HWLibs/AGDP/Backlight/AppleGFXHDA 补丁，
 │                               FB/DC/PM/SMU/PSP，VCN 内核桥
 │                               └── 发布 NRedVCNBridgeReady（状态量，非卫星页面的开关）
 └── NootedRedUserPatch.kext     卫星：_cs_validate_page/_cs_validate_range 上的用户态页内容补丁
        └── NRedProfiles        personality 属性里注入的 NRPT v3 bundle（部署时写入，无需重编 kext）

NootedRedTool（宿主侧，macOS 15+） 从干净 fixture 语义解析目标驱动，生成/校验/注入 NRPT v3 profile
```

卫星通过 `OSBundleLibraries` 依赖 `org.ChefKiss.NootedRed`，主 kext 存在时自动加载；
`-NRedUserPatchOff` 可单独关掉它。主 kext 必须在卫星缺席时正常构建与运行，这是首要回滚路径。

## 2. 数据流

```
干净的目标系统镜像（version-fixtures/<build> 或未被打补丁的本机）
        │ NootedRedTool --generate-profile：13 条语义规则 → 20 个 site
        ▼
nred-<build>.nrpt  +  nred-<build>-evidence.json        （14 页 / 20 sites / 4 个目标镜像）
        │ test/inject_profile.py 或 NootedRedTool --profile-inject-binary
        ▼
NootedRedUserPatch.kext/Contents/Info.plist  personality 的 NRedProfiles 数组
        │ 内核在首次 code-signing 校验时调用钩子
        ▼
_cs_validate_page / _cs_validate_range
        │ 完整 4 KiB 页内容比对 + 每个 site 的 find 字节
        ▼
写入 replace 字节（内核写保护下），该页记为已打补丁
```

profile 生成必须来自干净镜像。卫星加载后的内核页缓存写入会让在线系统看起来"已打补丁"，
用它生成会把补丁当成原文，因此工具在检测到卫星已加载时拒绝从 `/` 生成。

## 3. 页面身份与匹配

- **身份**：整页 4 KiB 内容的 FNV-1a-64 哈希，加上该页每个 site 的 `find` 字节。页偏移
  （`pageFileOffset`/`pageVmOffset`）、镜像序号、`mode` 都不参与身份判定，只用于路由和诊断。
- **没有 vnode 名门控**：卫星拿不到也不使用 vnode 名，实际交付路径不保证 vnode 名可用。
- **deferred 不是错误**：尚未交付到校验钩子的页记为 deferred，钩子保持挂载，不做进程扫描、
  不做 `vm_map_write_user` 强制写入、不用 watchdog 或内核 worker 兜底（这些路径在 panic 风险
  审计后已删除）。
- **不重写**：已打过补丁的页能被识别，永远不重复写。
- **fail closed**：bundle 缺失/畸形、build、APU mask 或 deviceID 不匹配、页哈希不匹配、site
  find 不匹配，都是 `NoOp`，绝不回落到"最接近的 build"或语义扫描。

## 4. 不变量

1. **能力 ≤ 实际应用**：补丁/引擎真正就位之前，不向系统宣称该能力。
2. **失败即关闭**：身份未知或存在歧义时 no-op 并留一行日志。
3. **不做半套补丁**：一个特性的所有目标要么全应用，要么全不应用。
4. **永不修改未校验的页**：没有整页内容匹配就不写。
5. **身份漂移即停用**：build/驱动身份变化后重新验证，不沿用上一份结论。

## 5. 非目标

- 不用语义指令扫描作为发布路径：发布用的是整页内容哈希 + site find。
- 不做跨 build 的页复用：一个 profile 只服务它生成的那个 build。
- 不在 `NootedRed.kext` 内做用户态页补丁。
- 不做 APFS root patch、dyld 缓存重写、kext 替换（见 `../research/legacy/Root-Patch-Pipeline.md`）。
- 不做运行时文件 I/O：profile 在部署时进入 `Info.plist`，kext 里没有 profile 路径、没有 vnode 名
  校验、没有页偏移表。

## 6. 代码地图

| 路径 | 职责 |
| --- | --- |
| `NootedRed/` | 主 kext 源码；`NRed.cpp` 主逻辑，每个 patcher 模块一个文件，`PenguinWizardry/` 是打补丁 SDK |
| `NootedRed/GPUDriversAMD/` | AMD 驱动 ABI 的重新实现（CAIL/Accel/FB/DC/SMU/PSP…） |
| `NootedRed/Regs/` | 各 IP 块的 MMIO 寄存器定义 |
| `NootedRedUserPatch/PatchProfile.*` | NRPT v3 解析、身份门控、页匹配 |
| `NootedRedUserPatch/UserPatchBackend.*` | 只有 `_cs_validate_page`/`_cs_validate_range` 两条路由 |
| `NootedRedUserPatch/Plugin.cpp` | 服务生命周期与诊断，不做匹配 |
| `NootedRedTool/Sources/NootedRedTool/PatchAnalyzer/` | Mach-O/dyld 缓存/函数/CFG 解析与 profile 生成 |
| `test/nrpt_validator.py` `test/inject_profile.py` | 独立的校验器与注入器 |

规范见 [PatchProfile-Spec.md](PatchProfile-Spec.md)；模块职责与支持范围见
[MODULES-AND-SUPPORT.md](MODULES-AND-SUPPORT.md)。
