# gl_blend_probe — offscreen OpenGL blending probe (issue #158)

`gl_blend_probe` 是一个自包含的 CGL/OpenGL 4.1-core 探针，用来调查 **issue #158**：用户态的
`AMDRadeonX5000GLDriver` 在 AMD 集显上套用了 Vega 独显的取值，导致 Chromium/Electron 硬件加速
花屏和 GPU reset。

它把内容渲染进 FBO、读回像素并与 CPU 参考值比较。它不写文件、不注入代码、不开窗口、不接管显示。
**但这仍然是一次 GPU 测试，而目标机器的 GPU 当前表现异常——先读安全章节。**

构建与退出码见文末；索引见 [`README.md`](README.md)。

## 文件

| 文件 | 用途 |
| --- | --- |
| `gl_blend_probe.c` | 探针（inspect / link / render 三种模式） |
| `build.sh` | 用 `xcrun clang` 编译到 `build/tools/gl_blend_probe` |

## 安全（先读）

2026-10-18 在目标机（macOS 15.8.1、Renoir `0x1638`、NootedRed 已加载）实测：

- 一个最小的 CGL/FBO 程序在**第一次 `glClear()`** 时就在 `AMDRadeonX5000GLDriver` 里 SIGSEGV：

  ```text
  glrAMD_GFX9_UpdateHwExportBlockState <- glrAMD_GFX9_UpdateDrawBufferInfo <-
  glrATI_Hwl_DrawableChanged <- glrBindContextDrawFramebuffer <-
  gldUpdateDrawFramebuffer <- gleUpdateDrawFramebufferState <- glClear_Exec
  ```

  （`~/Library/Logs/DiagnosticReports/glblend2-2026-10-18-211253.ips`，`glblend4-*` 同栈。）
- 同期系统记录了 12+ 次 WindowServer/Electron GPU reset（`/Library/Logs/DiagnosticReports/Kernel_*.gpuRestart`，
  `DID=0x1638`，restart channel 13/23 GFX）。

早期探针只创建 GL context、没有 drawable，崩溃发生在 draw-framebuffer 更新路径上，此时 `glClear`
碰到的是**默认的（无效）drawable**。因此 `--render` 会先挂一个 **PBuffer drawable** 再清屏/绘制。
这更安全，但并没有被证明安全。

规则：

1. `--inspect`（默认）是唯一不需要批准的档位：只建 CGL context + `glGetString`，实测没有新增 reset。
2. `--link` 编译链接 shader、不提交绘制。实测没有新增 reset，但会走驱动编译/状态路径，属低风险而非零风险。
3. `--render` 必须显式加 `--yes` 才启动。没有负责人批准、全新重启和恢复预案时不要加。
4. 一旦出现 GPU reset（新的 `*.gpuRestart`）、显示异常、卡死、看门狗或 SIGSEGV：**停下**，不要立刻重试，
   重启回到已知良好状态再继续。

## 构建

```sh
./tools/build.sh
```

需要 Xcode 命令行工具（`xcrun clang`，带 `OpenGL.framework` 的 SDK），不需要 Homebrew。构建不碰 GPU。

## 用法

```sh
build/tools/gl_blend_probe --inspect            # 安全：context + GL 字符串
build/tools/gl_blend_probe --exts               # inspect + 完整扩展列表
build/tools/gl_blend_probe --link               # + 编译/链接 shader，不绘制
build/tools/gl_blend_probe --render --yes       # 有风险：FBO 清屏/绘制/读回 + CPU 比较
build/tools/gl_blend_probe --render --yes --timeout 30
```

退出码：`0` 全部 PASS（或仅 SKIP）、`1` 拿不到像素格式/context、`2` shader 编译链接失败、
`3` FBO 不完整、`10` 像素不匹配、`11` PBuffer drawable 不可用（未尝试绘制）、`12` 没给 `--yes` 被拒、
`124` 看门狗超时、`128+N` 被信号 N 杀死。

## 用例与期望值

清屏色是蓝色 `(0,0,1,1)`，绘制一个全屏三角形。

| 用例 | 混合状态 | 片元输出 | 期望像素 (RGBA8) |
| --- | --- | --- | --- |
| 不混合 | 关闭 | `(1,0,0,1)` | `(255,0,0,255)` |
| 经典 alpha | `SRC_ALPHA / 1-SRC_ALPHA` | `(1,0,0,0.5)` | `(128,0,128,255)` |
| dual-source `SRC1_COLOR` | `SRC1_COLOR / 1-SRC1_COLOR` | `c0=(1,0,0,1)`, `c1=(0.25,0.5,0.75,1)` | `(64,0,64,255)` |
| dual-source `SRC1_ALPHA` | `SRC1_ALPHA / 1-SRC1_ALPHA` | `c0=(0.5,0.25,0.75,1)`, `c1=(0.25,0.5,0.75,0.5)` | `(64,32,223,255)` |

每通道容差 ±2。驱动不报告 `GL_ARB/EXT_blend_func_extended` 或
`GL_MAX_DUAL_SOURCE_DRAW_BUFFERS == 0` 时跳过 dual-source 用例。

目标机上的 **dual-source 不匹配**是强复现信号：驱动若静默忽略 index-1 输出、改用 `c0.a` 混合，
`SRC1_ALPHA` 用例会得到 `(128,64,191)` 而不是 `(64,32,223)`。

## 目标机基线（2026-10-18，仅 inspect + link）

```text
GL_VENDOR   = ATI Technologies Inc.
GL_RENDERER = AMD Radeon RX Renoir Graphics OpenGL Engine
GL_VERSION  = 4.1 ATI-7.0.25
GLSL        = 4.10
GL_ARB_blend_func_extended = present
GL_EXT_blend_func_extended = MISSING
GL_MAX_DRAW_BUFFERS = 8, GL_MAX_DUAL_SOURCE_DRAW_BUFFERS = 1, GL_MAX_COLOR_ATTACHMENTS = 8
extension count = 46
c1 bound to frag data index 1: yes
dual-source shaded linked: SRC1_COLOR ok, SRC1_ALPHA ok
```

- `GL_ARB_blend_func_extended` 有而 `GL_EXT_blend_func_extended` 缺失，独立复现了 issue #158 里
  GLEW 的观察结果：ARB 入口在，EXT 别名不在。
- GL 4.1 驱动只有 46 个扩展，偏少：GLEngine 做了过滤。
- **PASS 不能证明驱动没问题。** 探针只提交一次简单绘制；Chromium 经 ANGLE（`libGLESv2`/`libEGL`）
  走的是完全不同的管线。FAIL（崩溃、reset、像素不符）比 PASS 有信息量得多。

## 它不做什么

- 不跑 Chromium/ANGLE——那需要真实的 Electron/Chromium 应用；
- 不验证任何候选修复（修复验证是审批流程，属于用户态 interposer 的工作）；
- 不读写系统文件、kext 或 dyld 共享缓存。

## 事故恢复

卡住时 shell 可能一直阻塞在驱动里：开另一个终端（或 ssh）杀掉它；显示异常就注销以重启 WindowServer，
最坏情况长按电源键。事后第一件事是收集 `/Library/Logs/DiagnosticReports` 下的 `*.gpuRestart` 与
`gl_blend_probe*.ips`。
