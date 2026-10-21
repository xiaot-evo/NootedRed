#!/bin/bash
# Generate a Firefox/Zen launcher that enables hardware video decoding.
#
# The generated app is a small wrapper with the target browser's icon. It sets
# MOZ_DISABLE_RDD_SANDBOX=1 (required on this Hackintosh for Apple hardware
# VideoToolbox decoding) and optionally writes the required prefs to the
# browser's default profile.
#
# Usage:
#   tools/firefox-hwdecode-launcher.sh
#   tools/firefox-hwdecode-launcher.sh --target /Applications/Zen.app --output "$HOME/Desktop/Zen (HW).app" --no-prefs

set -eo pipefail

APPS_DIR="/Applications"
TARGET_APP=""
OUTPUT_APP=""
WRITE_PREFS="ask"
RESTART="yes"
PROFILE=""

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET_APP="${2:-}"; shift 2 ;;
        --output) OUTPUT_APP="${2:-}"; shift 2 ;;
        --profile) PROFILE="${2:-}"; WRITE_PREFS="yes"; shift 2 ;;
        --no-prefs) WRITE_PREFS="no"; shift ;;
        --prefs) WRITE_PREFS="yes"; shift ;;
        --no-restart) RESTART="no"; shift ;;
        -h|--help) usage ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

echo "⚠️  项目感谢：《NootedRed》 https://github.com/ChefKissInc/NootedRed"
echo "🍎 Firefox/Zen 硬件解码启动器生成器"
echo "用户：$USER    桌面：$HOME/Desktop"

if [[ -z "$TARGET_APP" ]]; then
    apps=()
    while IFS= read -r -d '' app; do
        apps+=("$app")
    done < <(find "$APPS_DIR" -maxdepth 1 -name "*.app" -print0 2>/dev/null)

    if [[ ${#apps[@]} -eq 0 ]]; then
        echo "注意：未找到任何应用程序" >&2
        exit 1
    fi

    echo "选择要生成硬件解码启动器的 App："
    for i in "${!apps[@]}"; do
        app_name="$(basename "${apps[$i]}" .app)"
        printf "  %2d) %s\n" $((i + 1)) "$app_name"
    done

    selected=0
    while ! [[ "$selected" =~ ^[0-9]+$ ]] || (( selected < 1 || selected > ${#apps[@]} )); do
        read -rp "➡️  请输入编号选择 (1-${#apps[@]}) 或 q 退出: " input
        [[ "$input" == "q" ]] && echo "操作取消" && exit 0
        selected="$input"
        if ! [[ "$selected" =~ ^[0-9]+$ ]] || (( selected < 1 || selected > ${#apps[@]} )); then
            echo "输入无效，请重新选择。"
        fi
    done
    TARGET_APP="${apps[$((selected - 1))]}"
fi

if [[ ! -d "$TARGET_APP" ]]; then
    echo "找不到目标 App：$TARGET_APP" >&2
    exit 1
fi

APP_NAME="$(basename "$TARGET_APP" .app)"
is_firefox_like() {
    local app="$1"
    local name
    name="$(basename "$app" .app)"
    case "$name" in
        *[Ff]irefox*|*Zen*|*Floorp*|*Waterfox*|*LibreWolf*|*Mullvad*) return 0 ;;
    esac
    if [[ -f "$app/Contents/Resources/application.ini" ]] \
        && grep -qiE '^(Name|Vendor)=(Mozilla|Zen|Floorp|Waterfox|LibreWolf|Mullvad)' \
            "$app/Contents/Resources/application.ini" 2>/dev/null; then
        return 0
    fi
    return 1
}

if ! is_firefox_like "$TARGET_APP"; then
    echo "⚠️  $APP_NAME 看起来不是 Firefox/Zen 系浏览器。" >&2
    read -rp "仍然继续生成？[y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 0
fi

if [[ -z "$OUTPUT_APP" ]]; then
    OUTPUT_APP="$HOME/Desktop/${APP_NAME} (HW).app"
fi

echo
echo "目标：$TARGET_APP"
echo "输出：$OUTPUT_APP"

# --- profile prefs ---------------------------------------------------------
find_profiles() {
    local support_dir=""
    local name_lc
    name_lc="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]')"
    if [[ "$name_lc" == *zen* ]]; then
        support_dir="$HOME/Library/Application Support/zen"
    else
        support_dir="$HOME/Library/Application Support/Firefox"
    fi

    local -a dirs=()
    local add_dir
    add_dir() {
        local d="$1" existing
        [[ -n "$d" && -d "$d" ]] || return 0
        for existing in "${dirs[@]}"; do
            [[ "$existing" == "$d" ]] && return 0
        done
        dirs+=("$d")
    }

    local ini="$support_dir/profiles.ini"
    if [[ -f "$ini" ]]; then
        local line
        while IFS= read -r line; do
            [[ "$line" == Path=* ]] && add_dir "$support_dir/${line#Path=}"
        done < "$ini"
    fi
    local dir
    for dir in "$support_dir"/Profiles/*; do
        [[ -d "$dir" ]] && add_dir "$dir"
    done
    ((${#dirs[@]})) && printf '%s\n' "${dirs[@]}"
}

write_prefs() {
    local profile="$1"
    local user_js="$profile/user.js"
    local backup="$profile/user.js.before-hwdecode-launcher"
    if [[ -f "$user_js" && ! -f "$backup" ]]; then
        cp -p "$user_js" "$backup"
    fi
    local tmp
    tmp="$(mktemp)"
    if [[ -f "$user_js" ]]; then
        grep -v 'media\.hardware-video-decoding\.' "$user_js" > "$tmp" || true
    fi
    cat >> "$tmp" <<'PREFS'

// Added by firefox-hwdecode-launcher.sh
user_pref("media.hardware-video-decoding.enabled", true);
user_pref("media.hardware-video-decoding.force-enabled", true);
user_pref("media.hardware-video-decoding.failed", false);
PREFS
    if mv "$tmp" "$user_js"; then
        echo "已写入硬件解码 prefs：$user_js"
        [[ -f "$backup" ]] && echo "原 user.js 备份：$backup"
    else
        rm -f "$tmp"
        echo "⚠️  prefs 写入失败（已跳过，不影响启动器生成）：$user_js" >&2
        return 1
    fi
}

# Profile handling is best-effort: a read-only/sandboxed profile must never
# prevent the launcher itself from being generated.
set +e
if [[ "$WRITE_PREFS" != "no" ]]; then
    if [[ -z "$PROFILE" ]]; then
        profiles=()
        while IFS= read -r profile_line; do
            [[ -n "$profile_line" ]] && profiles+=("$profile_line")
        done < <(find_profiles)
        if ((${#profiles[@]} == 0)); then
            echo "未找到 Firefox/Zen profile；只生成环境启动器。"
        elif ((${#profiles[@]} == 1)); then
            PROFILE="${profiles[0]}"
            echo "检测到 profile：$PROFILE"
            if [[ "$WRITE_PREFS" == "ask" ]]; then
                read -rp "写入硬件解码 prefs？[Y/n] " answer
                [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]] || WRITE_PREFS="no"
            fi
        else
            echo "检测到多个 profile："
            for i in "${!profiles[@]}"; do
                printf "  %2d) %s\n" $((i + 1)) "${profiles[$i]}"
            done
            if [[ "$WRITE_PREFS" == "ask" ]]; then
                read -rp "选择要写入 prefs 的 profile (1-${#profiles[@]}), a=全部, s=跳过: " choice
                case "$choice" in
                    s|S) WRITE_PREFS="no" ;;
                    a|A)
                        for p in "${profiles[@]}"; do write_prefs "$p"; done
                        WRITE_PREFS="no" ;;
                    *)
                        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#profiles[@]} )); then
                            PROFILE="${profiles[$((choice - 1))]}"
                            WRITE_PREFS="yes"
                        else
                            echo "无效选择，跳过 prefs。"
                            WRITE_PREFS="no"
                        fi
                        ;;
                esac
            else
                PROFILE="${profiles[0]}"
            fi
        fi
    fi
    if [[ "$WRITE_PREFS" == "yes" && -n "$PROFILE" ]]; then
        write_prefs "$PROFILE"
    fi
fi
set -e

# --- build the .app --------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/Contents/MacOS" "$TMP_DIR/Contents/Resources"

ICON_SOURCE="$(find "$TARGET_APP/Contents/Resources" -maxdepth 1 -name '*.icns' -print -quit 2>/dev/null || true)"
if [[ -n "$ICON_SOURCE" ]]; then
    cp "$ICON_SOURCE" "$TMP_DIR/Contents/Resources/AppIcon.icns"
fi
echo "图标：${ICON_SOURCE:-未找到，使用默认 App 图标}"

SAFE_NAME="$(printf '%s' "$APP_NAME" | tr -c 'A-Za-z0-9._-' '-')"
INFO_DIR="$TMP_DIR/Contents"
cat > "$INFO_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>main</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key>
    <string>local.nred.hwdecode.${SAFE_NAME}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME} (HW)</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME} (HW)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

quoted_app_name="$(printf '%s' "$APP_NAME" | sed 's/"/\\"/g')"
quoted_target="$(printf '%s' "$TARGET_APP" | sed 's/"/\\"/g')"
cat > "$INFO_DIR/MacOS/main" <<LAUNCHER
#!/bin/bash
# Generated by firefox-hwdecode-launcher.sh
LAUNCHER
if [[ "$RESTART" == "yes" ]]; then
    cat >> "$INFO_DIR/MacOS/main" <<LAUNCHER
/usr/bin/osascript -e 'tell application "${quoted_app_name}" to quit' >/dev/null 2>&1 || true
sleep 2
LAUNCHER
fi
cat >> "$INFO_DIR/MacOS/main" <<LAUNCHER
exec /usr/bin/open -n -a "${quoted_target}" --env MOZ_DISABLE_RDD_SANDBOX=1 --args "\$@"
LAUNCHER
chmod +x "$INFO_DIR/MacOS/main"

cat > "$INFO_DIR/Resources/README.txt" <<README
Generated by firefox-hwdecode-launcher.sh

Target: $TARGET_APP
Environment: MOZ_DISABLE_RDD_SANDBOX=1
$( [[ "$WRITE_PREFS" == "yes" && -n "$PROFILE" ]] && echo "Prefs written to: $PROFILE" )

This disables the Firefox RDD media sandbox for hardware VideoToolbox decoding on
this Hackintosh. Use only for trusted media.
README

mkdir -p "$(dirname "$OUTPUT_APP")"
rm -rf "$OUTPUT_APP"
mv "$TMP_DIR" "$OUTPUT_APP"
trap - EXIT

echo
echo "✅ 已创建硬件解码启动器："
echo "   $OUTPUT_APP"
echo
if [[ "$RESTART" == "yes" ]]; then
    echo "启动器会自动退出已有的 $APP_NAME，然后用 MOZ_DISABLE_RDD_SANDBOX=1 启动新实例。"
else
    echo "启动器会用 MOZ_DISABLE_RDD_SANDBOX=1 启动新实例；请先手动退出已有的 $APP_NAME。"
fi
echo "RDD 媒体沙箱会为该实例关闭，不建议用于不可信网站。"
if [[ ! -d "$OUTPUT_APP" ]]; then
    echo "❌ 启动器没有生成：$OUTPUT_APP" >&2
    exit 1
fi
ls -ld "$OUTPUT_APP"
/usr/bin/open -R "$OUTPUT_APP" >/dev/null 2>&1 || true
