# Chromium / Electron 花屏修复 —— 使用教程

> 这是**实验性**用户态补丁。先读“适用范围”和“回滚”，再安装。

## 适用范围

当前**已验证**的环境：

- macOS 15.8.1（24H32，Darwin 24.6.0）
- `AMDRadeonX5000GLDriver` 7.0.25
- 同一 15.8.1 的 `AMDRadeonX5000MTLDriver` / dyld shared cache
- AMD Renoir 核显（本机 `0x1638`），NootedRed 0.9.0
- Lilu 1.7.2，OpenCore 启动

其他 macOS 版本、其他 GPU、Intel/Apple Silicon **不能直接套用**：

- 页镜像不匹配时补丁会安全地 **no-op**（不损坏，但也不修复）；
- 多版本/多 APU 框架位于开发分支，目前只带 15.8.1 数据；
- 需要新增版本数据时看 [贡献者文档](CONTRIBUTING-USERPATCHES.md)。

## 它做了什么

NootedRed 在用户态驱动页面通过代码签名校验后，在**内存中**修改三个位置：

| 目标 | 修改 | 作用 |
| --- | --- | --- |
| GL `_gfx9_HwInfoInitData` | `numShaderEngines 4 → 1` | 修正 Renoir 的 CU 数（32 → 8） |
| GL `UpdateHwCbDualQuadMode` | 强制 `DISABLE_DUAL_QUAD=1` | 修复 GL 双源混合花屏/卡死 |
| Metal render pipeline 设置 | 条件化 `DISABLE_DUAL_QUAD` | 修复 Chrome/Electron 的 ANGLE Metal 路径 |

Metal 路径是**条件化**的：普通 pipeline 保留 RB+，只有双源 pipeline 关闭 dual-quad。
不写磁盘上的系统缓存或 kext；不匹配的页面不会改。

## 安装前检查

1. 确认系统版本：
   ```sh
   sw_vers
   uname -r
   ```
2. 确认 NootedRed 已能正常驱动 iGPU，且 EFI 有可回滚备份。
3. 只使用与当前系统匹配的构建；不要混用不同分支的 kext。
4. 如果你在使用 `research/*` 分支的 source-level 实验版本，先回到稳定条件化版本：
   - 稳定版本不会启用完整 RB+，不会出现黑块/缩略图缺失；
   - 研究分支的 kext 不是面向普通用户的发布版。

## 安装 kext（OpenCore）

### 1. 备份 EFI

至少备份：

- `EFI/OC/config.plist`
- `EFI/OC/Kexts/NootedRed.kext`

### 2. 挂载 EFI

```sh
diskutil list
sudo diskutil mount disk0s1
```

### 3. 替换 kext

把构建好的 `NootedRed.kext` 放到：

```text
EFI/OC/Kexts/NootedRed.kext
```

构建产物示例：

```text
build/macosx/x86_64/release/NootedRed.kext
build/macosx/x86_64/release/NootedRed-0.9.0-RELEASE.zip
```

### 4. 检查 `Kernel -> Add`

NootedRed 条目必须在 Lilu 之后，且：

```xml
<dict>
  <key>Arch</key><string>Any</string>
  <key>BundlePath</key><string>NootedRed.kext</string>
  <key>Comment</key><string>NootedRed</string>
  <key>Enabled</key><true/>
  <key>ExecutablePath</key><string>Contents/MacOS/NootedRed</string>
  <key>MaxKernel</key><string></string>
  <key>MinKernel</key><string></string>
  <key>PlistPath</key><string>Contents/Info.plist</string>
</dict>
```

### 5. 添加 boot-args

位置：

```text
NVRAM -> Add -> 7C436110-AB2A-4BBB-A880-FE41995C9F82 -> boot-args
```

稳定条件化版本：

```text
keepsyms=1 debug=0x144 itlwm_he=1 -NRedGLFix
```

说明：

- `-NRedGLFix`：启用（默认关闭，必须加）。
- `-NRedGLFixOff`：强制关闭，优先级高于 `-NRedGLFix`。
- `-NRedGLFixResolve`：**只有从 `research/patch-resolver` 分支构建的 kext 才识别这个参数**。
  `master` 和 `feature/*` 的构建不包含 resolver 代码，会直接忽略它，不会产生任何效果；它也必须和
  `-NRedGLFix` 一起使用才有意义。当前没有包含 resolver 的正式发布版，普通用户不要加。

### 如何判断构建是否包含 resolver

- 看分支/commit：只有 `research/patch-resolver` 的构建包含 `SignaturePatch` 和
  `patchSignaturePage`；
- 看源码：`NootedRed/UserPatches.cpp` 中出现 `kBootArgGLFixResolve`；
- 用 `master`/`feature/*` 的 kext 加 `-NRedGLFixResolve` 不会有 resolver 日志，也不会报错。

### 6. 保存并重启

只改 `config.plist` 和 kext，不要改系统磁盘内容。

## 从源码构建

需要 AppleForge 和 xmake；构建说明见仓库根目录 `AGENTS.md`：

```sh
xmake f -m release -y
xmake -y
```

构建产物在 `build/macosx/x86_64/release/`。不要直接把 `research/*` 分支的构建分发给普通用户。

## 验证是否生效

### 1. kext 是否加载

```sh
kextstat | grep -i NootedRed
```

### 2. 查看用户态补丁日志

```sh
sudo log show --last boot --info --debug --predicate 'eventMessage CONTAINS "UserPatch"'
```

多版本/多 APU 构建应看到类似：

```text
Selected patch set "15.8.1 / Renoir-family" for macOS 24.6 / APU mask 0x28
```

旧条件化构建可能只看到：

```text
Enabling user-space GL driver patches (experimental)
Patched ... site(s) ...
```

当前 `master` 还会打印兼容性诊断（`-NRedGLFix` 开启时）：

```text
Compat: profile="Renoir/Green Sardine" family="Green Sardine" level=experimental device=0x1638 ...
```

> 驱动二进制 `LC_UUID` 的捕获推迟到 M2：早期的 VFS 读取版本会在 Lilu patcher-load 阶段读文件，
> 已作为启动卡住的嫌疑点移除，当前构建不会再出现 `target identity` 行。

如果没有任何 `UserPatch` 日志，先检查 boot-args 和 kext 是否加载。

### 3. 实际应用

打开之前会花屏/卡死的 Chromium/Electron 应用，观察几分钟。

- 正常：不再花屏、不再 GPU reset；
- 仍有黑块/缩略图缺失：说明你可能在 source-level 实验版，应该回到条件化版本；
- 应用仍崩溃：检查是否与其他 GL/Metal patch（如 BFixup）冲突。

### 4. GL 小测试（可选）

仓库的 `tools/gl_blend_probe` 可用于检查 GL 双源输出：

```sh
build/tools/gl_blend_probe --inspect
```

`--render` 会触发真实绘制，有风险；只在桌面稳定时使用，并先确认 EFI 可回滚。

### 5. GPU reset 检查

```sh
ls -lt /Library/Logs/DiagnosticReports/Kernel_*.gpuRestart
```

不应出现新的 `gpuRestart`。

## 多系统 / 多 APU 支持现状

当前代码框架支持：

- 按 Darwin 版本选择 `PatchSet`；
- 按 APU family 选择补丁数据；
- 页镜像不匹配时 no-op。

但实际数据状态：

| 项目 | 状态 |
| --- | --- |
| macOS 15.8.1 / Renoir | 已验证 |
| macOS 15.8.1 / Raven、Raven2、Picasso | 代码可匹配，未实机验证 |
| 其他 macOS 版本 | 没有页面数据，默认 no-op |
| resolver fallback | research 原型，未作为稳定功能 |

想在自己系统上使用其他版本，需要按 [贡献者文档](CONTRIBUTING-USERPATCHES.md) 生成页面数据，不能直接改版本号。

## 关闭 / 回滚

### 只关闭用户态补丁

从 boot-args 删除 `-NRedGLFix`，或加上：

```text
-NRedGLFixOff
```

重启即可。NootedRed 的其他内核补丁仍然工作。

### 恢复旧 kext

用自己的 EFI 备份覆盖：

```text
EFI/OC/Kexts/NootedRed.kext
```

### 完全卸载

1. 删除 `EFI/OC/Kexts/NootedRed.kext`；
2. 删除 `Kernel -> Add` 里的 NootedRed 条目；
3. 删除 boot-args 里的 `-NRedGLFix` / `-NRedGLFixResolve`；
4. 保存 `config.plist`，重启。

## 常见问题

### 启动后 kext 没加载

- 检查 OpenCore `Kernel -> Add` 是否启用；
- 确认 NootedRed 在 Lilu 之后；
- 检查 kext 版本与当前 macOS 是否匹配。

### 有 `UserPatch` 日志但没有 `Selected patch set`

旧条件化构建没有这条日志，是正常的；多版本构建应该出现。没有出现且补丁也没生效时，检查 boot-args。

### 黑块、缩略图缺失

这是 source-level 完整 RB+ 实验的已知回归，不是稳定条件化版本应有的行为。回到稳定条件化 build，或按贡献者文档继续修 RB+ 模型。

### 花屏仍然存在

- 确认使用的是 15.8.1 / 对应驱动的构建；
- 确认 boot-args 有 `-NRedGLFix`；
- 确认没有和 BFixup 等用户态 patch 同时使用；
- 其他 macOS 版本当前没有页面数据，会 no-op，不会修复。

### 应用崩溃但没有 GPU reset

检查是否与其他用户态补丁冲突；先只保留 NootedRed 做 A/B。

## 注意

- 实验性功能，默认关闭。
- 只改内存页，不写系统缓存。
- 不要用于 Vega 独显；不要用于其他厂商 GPU。
- 不要与 BFixup 或其他 GL/Metal 用户态 patcher 混用。
- 本项目 License 为 ChefKiss Open Knowledge License v1；分发/修改请遵守。
- 贡献代码或数据前请阅读 [贡献者文档](CONTRIBUTING-USERPATCHES.md)，不要猜偏移，也不要提交未验证的页镜像。
