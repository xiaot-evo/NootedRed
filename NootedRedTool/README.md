# NootedRed Toolkit

一个 macOS 15+ 的 SwiftUI 一站式工具，当前包含：

- 系统与 kext 总览
- 健康检查：NootedRed / UserPatch / GPU / SIP / EFI / GPU hang
- 用户态解析：解析 GL Mach-O 与 dyld shared cache，生成并缓存 OffsetProfile
- 启动参数管理：勾选功能写入 NVRAM `boot-args`
- Kext 更新界面（接口预留，不执行写入）
- 诊断信息复制

## 构建

```sh
cd NootedRedTool
swift build -c release
./build_app.sh
open build/NootedRedTool.app
```

要求：

```text
macOS 15+
Xcode Command Line Tools / Xcode 26
```

## 说明

- 参数写入使用 `nvram boot-args`，需要管理员授权。
- EFI 相关检查只在 EFI 已挂载时读取。
- Kext 更新按钮当前只打开接口预留面板，不修改 EFI。
- 用户态解析读取：
  - `/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/.../AMDRadeonX5000GLDriver`
  - `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64h*`
- 生成的 profile 保存在 `~/Library/Application Support/NootedRedTool/offset-profile-<build>.json`。
- 健康检查中的 GPU hang 查询最近 5 分钟系统日志。
