# Firefox/Zen 硬件解码启动器

`firefox-hwdecode-launcher.sh` 参照 `AMD软件修复.sh` 的交互方式，生成一个
带目标 App 图标的桌面启动器。

## 使用

直接运行：

```sh
tools/firefox-hwdecode-launcher.sh
```

也可以双击 [`Firefox-HW-Decode.command`](Firefox-HW-Decode.command)，避免 `.sh` 被
文本编辑器打开。

会列出 `/Applications` 下的 App，输入编号后生成：

```text
~/Desktop/<App> (HW).app
```

也可以非交互生成：

```sh
tools/firefox-hwdecode-launcher.sh \
  --target /Applications/Zen.app \
  --output "$HOME/Desktop/Zen (HW).app" \
  --profile "$HOME/Library/Application Support/zen/Profiles/gm2z6wo8.Default (release)"
```

## 启动器行为

生成的 `Contents/MacOS/main` 会：

```sh
open -n -a "<目标 App>" --env MOZ_DISABLE_RDD_SANDBOX=1 --args "$@"
```

- `MOZ_DISABLE_RDD_SANDBOX=1`：让 Firefox/Zen 使用硬件 VideoToolbox 解码；
- 默认会先退出已运行的目标 App，确保新环境生效；
- 用 `--no-restart` 可以关闭自动退出；
- 图标从目标 App 的 `Contents/Resources/*.icns` 复制。

## 硬件解码 prefs

脚本会检测 Firefox/Zen 的 profile。如果检测到多个 profile，会列出让你选择，
或者选择 `a` 写入全部、`s` 跳过。

写入内容：

```js
user_pref("media.hardware-video-decoding.enabled", true);
user_pref("media.hardware-video-decoding.force-enabled", true);
user_pref("media.hardware-video-decoding.failed", false);
```

原 `user.js` 会备份为：

```text
user.js.before-hwdecode-launcher
```

可以用 `--no-prefs` 只生成环境启动器，不修改 profile。

## 安全说明

`MOZ_DISABLE_RDD_SANDBOX=1` 会关闭该浏览器实例的 RDD 媒体沙箱。它是在这台
Hackintosh 上启用硬件解码的已验证路径，但属于安全权衡；不建议用于不可信网站。
