# Firefox / Zen 硬件解码启动器

`tools/firefox-hwdecode-launcher.sh` 生成一个带目标 App 图标的桌面启动器，用它启动浏览器时带上
`MOZ_DISABLE_RDD_SANDBOX=1`，让 Firefox/Zen 走硬件 VideoToolbox 解码（NootedRed 的 VCN 路径）。

## 使用

```sh
tools/firefox-hwdecode-launcher.sh                  # 交互：列出 /Applications 下的 App
tools/firefox-hwdecode-launcher.sh \
  --target /Applications/Zen.app \
  --output "$HOME/Desktop/Zen (HW).app" \
  --profile "$HOME/Library/Application Support/zen/Profiles/<你的 profile 目录>"
```

也可以双击 `tools/Firefox-HW-Decode.command`，避免 `.sh` 被文本编辑器打开。产物是
`~/Desktop/<App> (HW).app`。

参数：`--target` 目标 App，`--output` 产物路径，`--profile` 要写入 prefs 的浏览器 profile，
`--no-prefs` 只生成启动器不动 profile，`--no-restart` 不自动退出已运行的 App。

## 启动器行为

生成的 `Contents/MacOS/main` 执行：

```sh
open -n -a "<目标 App>" --env MOZ_DISABLE_RDD_SANDBOX=1 --args "$@"
```

- 默认先退出已运行的目标 App，确保新环境生效；
- 图标从目标 App 的 `Contents/Resources/*.icns` 复制；
- 传入的参数原样转发给浏览器。

## 写入的 prefs

检测到多个 profile 时会让你选，或按 `a` 写入全部、`s` 跳过：

```js
user_pref("media.hardware-video-decoding.enabled", true);
user_pref("media.hardware-video-decoding.force-enabled", true);
user_pref("media.hardware-video-decoding.failed", false);
```

原 `user.js` 备份为 `user.js.before-hwdecode-launcher`。

## 安全说明

`MOZ_DISABLE_RDD_SANDBOX=1` 关闭该浏览器实例的 RDD 媒体沙箱。这是这台机器上启用硬解的已验证
路径，但属于安全权衡：不要用它浏览不可信站点，也不要把这个启动器当作默认浏览器。

硬解是否真的生效按 [VDA-TESTING.md](VDA-TESTING.md) 验证；播放器解码失败不等于硬解没生效，
先看 `NRedVCN*` 标记与 `.gpuRestart` 报告。
