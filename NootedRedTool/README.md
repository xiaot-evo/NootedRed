# NootedRed Toolkit

macOS 15+ 的 SwiftUI 工具（附 CLI）：检查本机 NootedRed 状态、挂载 EFI、管理 boot-args、汇总诊断信息。
当前版本 **0.2.0**。

用户态补丁已经改为运行期解析：卫星在启动时分析当前系统的 Mach-O 并应用编译进 kext 的规则。
本工具不再生成或注入 profile，卫星也不读取任何 profile 数据。旧的 `--generate-profile` /
`--bundle-profiles` / `--profile-*` 命令属于已退役流水线，保留仅为历史代码，不应再使用。

界面按功能分为四个组、七个页面：

| 分组 | 页面 | 作用 |
| --- | --- | --- |
| 系统 | 总览 | 机器信息、健康摘要、部署流程 |
| 系统 | 健康检查 | 逐项检查主 kext、卫星、GPU、SIP、EFI、OpenCore 配置、kext 文件、GPU hang 与 VDA |
| EFI 与补丁 | EFI 分区 | 发现/挂载/卸载 EFI，读取 OpenCore 配置摘要 |
| EFI 与补丁 | Kext 管理 | 对比 `EFI/OC/Kexts` 与 `config.plist` 的 `Kernel > Add`（只显示，不执行更新） |
| 系统配置 | 启动参数 | 按功能补丁/调试/日志/救援分组勾选 boot-args，写入 NVRAM |
| 支持 | 诊断信息 | 汇总系统/kext/EFI/OpenCore 信息，一键复制 |

## 命令行模式

```sh
.build/release/NootedRedTool --efi-probe              # 只读探测 EFI 分区与 OpenCore 摘要
.build/release/NootedRedTool --self-test              # 无界面自检
.build/release/NootedRedTool --snapshot [输出目录]     # 离屏渲染页面为 PNG
.build/release/NootedRedTool --diagnostics            # 汇总诊断信息
```

`--parser` / `--parse` / `--decode` / `--decode-run` 兼容旧用法：打开应用并进入（或自动开始）驱动解码页。
驱动解码页仍可用于查看目标镜像和生成诊断数据，但产出的数据不再进入卫星的补丁路径。

## 构建

要求 macOS 15+、Xcode Command Line Tools 或 Xcode 26。注意：kext 支持 Catalina → Tahoe，但本工具
本身只能在 15+ 上运行。

```sh
cd NootedRedTool
swift build -c release
./build_app.sh
open build/NootedRedTool.app
```
