# VDA 硬解/硬编测试

面向已经在真机上跑起 `-NRedVDA` 的人。这是一条**可选**路径：不带 `-NRedVDA` 时内核不请求 VCN
桥，用户态 VDA 页也没有可落地的目标，普通启动行为不变。

> 先备份 EFI。硬解路径一旦把用户态页写进共享缓存页缓存，到重启前都改不回来。挂死时用备份 EFI
> 或 `-NRedOff` 启动，再回滚。

## 1. 前置

- 主 kext 与卫星都是当前构建，卫星已注入本 build 的 profile；
- Renoir `0x1636` / `0x1638`、Cezanne `0x164C`、Barcelo `0x15E7`（VCN 2.x）；Raven/Raven2/Picasso
  只有 VCN 1.x，媒体路径在内核侧就是关闭的，测不出硬解；
- 没有外接 AMD 独显占用 X6000 路径。

## 2. 打开开关

```sh
tools/set_vda_bootarg.sh --show     # 当前状态
tools/set_vda_bootarg.sh --add      # 写入 -NRedVDA（config 备份在 build/efi-backup/）
tools/set_vda_bootarg.sh --remove   # 回滚
```

第一次实验建议先不带 `-NRedVDA` 启动一次，确认图形路径与原来一致、日志里 VCN 只有
"disabled, add -NRedVDA" 一条；再带参数启动。

## 3. 启动后只读检查

```sh
tools/vda_selftest.sh    # 环境与状态汇总
tools/vda_hwtest.sh      # 自动生成样本、解码比对、抓 reset 报告
```

两者收集的内容：`uname -r` / `sw_vers` / boot-args；`ioreg` 里的 `NRed(VDA|VCN)` 属性；VCN/VDA/
UserPatch 相关日志；`ffmpeg -hwaccels`；最近的 `.gpuRestart` 与 WindowServer 看门狗报告。

成功启动时日志应出现（顺序大致如下）：

```text
VCN: X5000 VCN entry points prepared
VCN: X6000 native load status=0x0 prepared5=1 prepared6=1
VCN: X6000 VCN bridge prepared (N call-site patches)
VCN: X6000 initHardware channel=... result=1        # 创建解码器时出现
X5000: VCN0 media engine enabled from the device profile
```

内核侧成功标记（ioreg）：`NRedVCNX5000ABIValidated=1`、`NRedVCNX6000ABIValidated=1`、
`NRedVCNNativeLoadReady=1`、`NRedVCNEngineAllocated=1`。`NRedVCNX5000Seen`/`NRedVCNX6000Seen`/
`NRedVCNAccelStartSeen=1` 只表示钩子跑过。

## 4. 编解码比对

`tools/vda_hwtest.sh` 会生成 720p H.264、已知的刁钻用例 64×64 H.264 和 720p HEVC，分别用
VideoToolbox 与软解解码，比较原始输出，并检查 VDA 日志与 reset 报告。手动等价操作：

```sh
ffmpeg -hwaccel videotoolbox -i sample_h264.mp4 -f null -
ffmpeg -hwaccel videotoolbox -i sample_hevc.mp4 -f null -
ffmpeg -i sample_h264.mp4 -f null -            # 软件参考
```

再加上真实应用路径（Safari / Apple TV / Chromium 视频）。要盯的失败形态：

- 解码器创建成功但没有帧（VCN 解码 stall）；
- WindowServer 看门狗 / 桌面卡死；
- `Kernel_*.gpuRestart` 报告；
- Apple TV 之类 DRM 场景下的网络/音频 panic（社区 fork 报告过）。

## 5. 记录模板

真机通过时至少记录：kext 二进制 SHA-256、build/APU、`-NRedVDA` 状态、上面的日志四行、四个
内核标记、三类样本的解码比对结果、5 次重复 1080p H.264/HEVC 是否有 `.gpuRestart`。历史基线
（2026-10-19，15.8.1 / `0x1638`）保存在 `../research/legacy/VDA-Baseline.md`。

## 6. 失败处理

内核侧没有 panic 路径：ABI 不匹配、X6000 加载失败、引擎分配失败、页匹配失败都是安全返回并停止
继续安装补丁。用户态 VA/AppleGVA 页是例外——写入后系统范围内生效，不能可靠回滚。

1. 用备份 EFI 启动，或加 `-NRedOff`；
2. `tools/set_vda_bootarg.sh --remove` 去掉 `-NRedVDA`；
3. 换回备份的 kext；
4. 重启清掉页缓存里的已打补丁页。
