# 安装与使用

面向已经跑起 macOS 的 AMD 集显（Raven / Renoir / Picasso / Green Sardine / Cezanne / Barcelo）
Hackintosh。项目处于活跃研发阶段，会崩；先做好 EFI 备份再谈安装。

## 1. 前置条件

- OpenCore 引导，Lilu 已正确安装并加载；
- `NootedRed.kext` 与 `NootedRedUserPatch.kext` 两个 kext（同一版本）；
- 已知可用的 EFI 备份和一个能启动的救援引导项；
- 主 kext 声明支持 macOS Catalina → Tahoe；用户态卫星在启动时解析当前系统镜像，不需要
  按 build 生成或注入数据。

## 2. 安装 kext

1. 把两个 kext 放进 `EFI/OC/Kexts/`。
2. 在 `config.plist` 的 `Kernel > Add` 里按 `Lilu` → `NootedRed` → `NootedRedUserPatch` 的顺序
   各加一条，`Enabled` 为 true，`MinKernel`/`MaxKernel` 留空。
3. 卫星通过 `OSBundleLibraries` 依赖 `org.ChefKiss.NootedRed`，主 kext 不在时它不会加载；反过来
   主 kext 完全不需要卫星。
4. 重启。

只装 `NootedRed.kext` 也能用（内核侧 FB/DC/PM/显示修正），但没有用户态 GL/Metal/VDA 修正。

## 3. 用户态补丁与 VDA 开关

卫星在启动时解析当前系统的 dyld shared cache 和驱动镜像，把编译进 kext 的规则解析成精确页偏移。
不需要生成或注入 profile，也没有运行期补丁数据通道。

- 默认只应用 5 条 GL/Metal 规则。
- 需要 VADriver2/VDA 时，在 `boot-args` 加 `-NRedUserPatchVDA`（14 条 VDA 规则）。
- 解析失败的规则会 fail closed，日志会指出 rule id 和原因；它不影响其他规则。
- 规则表不按 build 增长；系统小版本通常不需要改 kext，只有 Apple 改变函数结构时才更新对应规则。

## 4. 启动参数

| 参数 | 用途 |
| --- | --- |
| `-NRedVDA` | 请求 VCN 内核桥（硬解/硬编实验路径） |
| `-NRedUserPatchOff` | 关闭用户态补丁，保留内核侧 |
| `-NRedUserPatchVDA` | 启用 14 条 VADriver2 用户态规则（默认关闭） |
| `-NRedUserPatchDry` | 正常解析和校验，只记录计划写入，不写字节 |
| `-NRedDebug` / `-NRedUserPatchDebug` | 打开调试日志（配合 DEBUG 构建的 Lilu） |
| `-NRedNoAccel` | 只做 FB，不加载加速器 |
| `-NRedOff` | 完全关闭 NootedRed（救援） |

## 5. 验证

```sh
# 两个 kext 是否加载
kextstat | grep -i nootedred

# 主 kext 与 VCN 状态
ioreg -l -w0 -r -n IGPU | grep -E 'NRed'

# 卫星日志（需要 DEBUG Lilu 和 -NRedUserPatchDebug）
log show --last boot --info --debug \
  --predicate 'eventMessage CONTAINS "NRed" OR eventMessage CONTAINS "UserPatch"'
```

卫星日志里应看到 `analyzer: N/M rules resolved (family ...)` 和逐条 unresolved 原因；默认
M=5，加 `-NRedUserPatchVDA` 后 M=19。解析失败的规则不会写入，也不影响其他规则。

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
| 桌面/浏览器花屏 | 日志里 analyzer 是否 resolved；GL/Metal 规则是否写入 |
| GPU restart / WindowServer 看门狗 | `ls /Library/Logs/DiagnosticReports \| grep -i gpuRestart`；对应 workload 的规则是否被写 |
| 硬解不工作 | 是否带 `-NRedVDA` 和 `-NRedUserPatchVDA`；按 [VDA-TESTING.md](VDA-TESTING.md) 逐项验证 |
| 换了 macOS 小版本后部分补丁失效 | 正常：analyzer 按符号/函数结构解析；日志会指出 unresolved 的 rule id，更新对应规则即可 |

提交问题时附上 `NootedRedTool --diagnostics`（或手动的 `sw_vers`、`uname -r`、`ioreg`、
`kextstat`、`log show` 输出）。

## 8. 自己构建

构建命令与产物路径见仓库根 `README.md` 和 `tools/README.md`；用户态解析器的设计见
[USERSPACE-PATCHING.md](USERSPACE-PATCHING.md)。
