# 安装与使用

面向已经跑起 macOS 的 AMD 集显（Raven / Renoir / Picasso / Green Sardine / Cezanne / Barcelo）
Hackintosh。项目处于活跃研发阶段，会崩；先做好 EFI 备份再谈安装。

## 1. 前置条件

- OpenCore 引导，Lilu 已正确安装并加载；
- `NootedRed.kext` 与 `NootedRedUserPatch.kext` 两个 kext（同一版本）；
- 已知可用的 EFI 备份和一个能启动的救援引导项；
- 主 kext 声明支持 macOS Catalina → Tahoe，但只有对应 build 的补丁会命中；用户态补丁还需要
  为该 build 生成的 profile（见 [COMPATIBILITY.md](COMPATIBILITY.md)）。

## 2. 安装 kext

1. 把两个 kext 放进 `EFI/OC/Kexts/`。
2. 在 `config.plist` 的 `Kernel > Add` 里按 `Lilu` → `NootedRed` → `NootedRedUserPatch` 的顺序
   各加一条，`Enabled` 为 true，`MinKernel`/`MaxKernel` 留空。
3. 卫星通过 `OSBundleLibraries` 依赖 `org.ChefKiss.NootedRed`，主 kext 不在时它不会加载；反过来
   主 kext 完全不需要卫星。
4. 重启。

只装 `NootedRed.kext` 也能用（内核侧 FB/DC/PM/显示修正），但没有用户态 GL/Metal/VDA 修正。

## 3. 注入 profile（用户态补丁）

卫星不含任何页偏移或哈希数据，必须把目标 build 的 profile 注入到 EFI 中那个 kext 的
`Info.plist`，`NRedProfiles` 数组属性里：

```sh
# 生成 + 独立校验（在干净 fixture 上，不要在已加载卫星的系统上生成）
NootedRedTool/.build/release/NootedRedTool --generate-profile <fixture-root> --out build/profile
python3 test/nrpt_validator.py --profile build/profile/nred-<build>.nrpt \
  --fixtures <fixture-root> --expected-build <build> --device-id 0x1638

# 注入 EFI 中的 kext，然后回读校验
KEXT=/Volumes/EFI/EFI/OC/Kexts/NootedRedUserPatch.kext
python3 test/inject_profile.py --info-plist "$KEXT/Contents/Info.plist" \
  --profile build/profile/nred-<build>.nrpt --build <build> --apumask 0x28 --deviceid 0x1638
python3 test/inject_profile.py --info-plist "$KEXT/Contents/Info.plist" --check
```

`NRedProfiles` 是数组：多个 build/APU/设备可以共存，选择是精确匹配、没有回落。注入后必须
`kextstat` 之外再核对一遍 EFI 里的字节，这一步 inject 工具会做。

没有匹配 profile 时卫星是 fail-closed no-op：kext 加载、钩子挂上、什么都不写，系统照常运行。

## 4. 启动参数

| 参数 | 用途 |
| --- | --- |
| `-NRedVDA` | 请求 VCN 内核桥（硬解/硬编实验路径） |
| `-NRedUserPatchOff` | 关闭用户态补丁，保留内核侧 |
| `-NRedDebug` / `-NRedUserPatchDebug` | 打开调试日志（配合 DEBUG 构建的 Lilu） |
| `-NRedNoAccel` | 只做 FB，不加载加速器 |
| `-NRedOff` | 完全关闭 NootedRed（救援） |

完整列表与含义见 [MODULES-AND-SUPPORT.md](MODULES-AND-SUPPORT.md) §5。

## 5. 验证

```sh
# 两个 kext 是否加载
kextstat | grep -i nootedred

# 卫星状态：身份、profile 页数、已应用/延迟页、coverage
ioreg -l -w0 -n NootedRedUserPatch | grep -E 'NRedUserPatch'

# 主 kext 与 VCN 状态
ioreg -l -w0 -r -n IGPU | grep -E 'NRed'

# 日志
log show --last boot --info --debug \
  --predicate 'eventMessage CONTAINS "NRed" OR eventMessage CONTAINS "UserPatch"'
```

卫星的 coverage 有三个值：`complete`（profile 里所有页都已应用）、`workload-deferred`（还有页
没被交付到钩子）、`inactive`（没有 profile 或身份未解析）。`workload-deferred` 是正常状态，
不是失败——未应用的页只是当前 workload 还没走到。

## 6. 回滚

1. `-NRedUserPatchOff`：立刻关掉用户态补丁，判断问题是否来自卫星；
2. 从 `Kernel > Add` 移除 `NootedRedUserPatch` 或直接删掉 kext：只剩内核侧；
3. `-NRedOff`：连内核侧也关掉；
4. 换回备份 EFI。

已经写进共享缓存页缓存的用户态页到重启前一直有效，关开关只阻止后续页被写。

## 7. 排查常见现象

| 现象 | 先看什么 |
| --- | --- |
| 启动卡在显卡初始化 | 备份 EFI 启动，`-NRedNoAccel` 区分 FB 与加速器；`-NRedOff` 确认是 NootedRed 引起 |
| 桌面/浏览器花屏 | 用户态 GL 页是否应用（ioreg 的 `AppliedPageList`）；该 build 是否有 profile |
| GPU restart / WindowServer 看门狗 | `ls /Library/Logs/DiagnosticReports \| grep -i gpuRestart`；对应 workload 的页是否被写 |
| 硬解不工作 | 是否带 `-NRedVDA`；按 [VDA-TESTING.md](VDA-TESTING.md) 逐项验证 |
| 换了 macOS 小版本后所有补丁失效 | 正常：profile 精确匹配 build，需要为新 build 重新生成 |

提交问题时附上 `NootedRedTool --diagnostics`（或手动的 `sw_vers`、`uname -r`、`ioreg`、
`kextstat`、`log show` 输出）。

## 8. 自己构建

构建、产物路径与按分支隔离的产物目录见 [Build-Artifacts.md](Build-Artifacts.md)；构建环境要求见
仓库根 `README.md`。
