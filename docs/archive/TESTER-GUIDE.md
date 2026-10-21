# 测试包交付清单 / Tester Guide

> 历史文档：原 `research/patch-resolver` 分支的测试交付指南。resolver 代码与相关文档已经合入
> `master`，分支已归档；其中 resolver QA 构建的说明保留作为交付参考。

这份文档说明把 NootedRed Chromium 修复发给别人测试时，应该随包提供什么信息。

## 1. 先说明构建来源

测试者必须知道 kext 来自哪个分支/commit，而不是只拿到一个二进制。

当前 resolver QA 构建示例：

```text
branch: research/patch-resolver
build commit: a5dfcbc
```

本地产物：

```text
build/macosx/x86_64/release/NootedRed.kext
build/macosx/x86_64/release/NootedRed-0.9.0-RELEASE.zip
```

校验值：

```text
NootedRed binary MD5:
  9770250a2403151213ba0a4b41c3c372

NootedRed binary SHA-256:
  40fde870bcc6cb3cab7544d25cd6e8a61cc963e2152da03c3366be8720ea48a0

zip SHA-256:
  a628f37a3c6e81bbd969b6e575c758cd24ae86e20120fdecc4a95498ac9c3e53

LC_UUID:
  29C88D68-4806-3F53-B9C8-4467F05AF504
```

测试者可以核对：

```sh
shasum -a 256 NootedRed.kext/Contents/MacOS/NootedRed
dwarfdump --uuid NootedRed.kext/Contents/MacOS/NootedRed
```

## 2. 明确的适用范围

不要只说“测试这个 kext”。至少要给出：

```text
macOS: 15.8.1 (24H32 / Darwin 24.6.0)
GPU: AMD Renoir iGPU (0x1638 已验证)
GL driver: AMDRadeonX5000GLDriver 7.0.25
Lilu: 1.7.2+
NootedRed: 0.9.0 基线
```

并说明：

- 其他 macOS 版本没有页面数据，补丁会 no-op；
- 不要用于 Vega 独显或其他厂商 GPU；
- 不要和 BFixup 等用户态 GL/Metal patcher 混用。

## 3. 提供两种启动方式

### 普通使用（页镜像优先）

```text
keepsyms=1 debug=0x144 itlwm_he=1 -NRedGLFix
```

### QA resolver 验证（仅研究测试）

```text
keepsyms=1 debug=0x144 itlwm_he=1 -NRedGLFix -NRedGLFixResolveOnly
```

说明：

- `-NRedGLFixResolveOnly` 会跳过完整页镜像，强制走 resolver；
- 只用于验证 resolver，不是日常配置；
- 测试结束应删除它，保留 `-NRedGLFix`；
- 当前 resolver 签名只对 15.8.1 做了验证，其他版本不保证命中。

## 4. 安装信息

随包提供：

- kext 或 zip；
- 明确说明放到 `EFI/OC/Kexts/NootedRed.kext`；
- `Kernel -> Add` 中 NootedRed 必须在 Lilu 之后；
- boot-args 的准确位置：
  `NVRAM -> Add -> 7C436110-AB2A-4BBB-A880-FE41995C9F82 -> boot-args`
- 备份/回滚步骤。

完整安装步骤见 [Chromium 使用教程](Chromium-Fix-Usage.md)。

## 5. 测试前基线

要求测试者记录：

```sh
sw_vers
uname -r
ioreg -l | grep GPUConfigurationVariable
kextstat | grep -i NootedRed
```

并确认：

- 测试前该应用是否已经花屏/卡死；
- 是否有 GPU reset 历史；
- 是否有其他 GPU 补丁。

## 6. 测试中要收集的信息

- 应用名称/版本（Chrome、Electron 应用等）；
- 是否开启硬件加速；
- 花屏/卡死/黑块/缩略图缺失的具体表现；
- 是否出现 GPU reset；
- 日志：

```sh
sudo dmesg | grep -iE 'UserPatch|Selected patch set|Resolver'
```

```sh
ls -lt /Library/Logs/DiagnosticReports/Kernel_*.gpuRestart
```

- 如可能，`kextstat -l | grep NootedRed` 的 UUID。

## 7. 成功/失败判断

成功标准：

- Chromium/Electron 开启硬件加速后不再花屏/卡死；
- 没有新的 `Kernel_*.gpuRestart`；
- 多版本构建日志有 `Selected patch set`；
- QA 模式有 `Resolver patched a signature site`。

失败时不要只说“还是不行”，至少提供：

- 系统/驱动/GPU；
- 应用和操作步骤；
- `dmesg` 里的 `UserPatch` 相关行；
- 是否还有 reset；
- 截图或错误文本。

## 8. 回滚说明

- 删除 `-NRedGLFixResolveOnly` / `-NRedGLFix`；
- 或恢复 EFI 备份的旧 `NootedRed.kext`；
- 不要通过修改系统盘上的 Apple 驱动来回滚。

## 9. 不要把什么发出去

- 不要发 `research/hwinfo-capability-source` 的 source-level 版本：已知会产生黑块/缩略图错误；
- 不要把 15.8.1 的构建标成“所有 macOS/APU 通用”；
- 不要省略 commit/hash 和适用范围。
