#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
tools/firefox-hwdecode-launcher.sh
status=$?
echo
read -rp "按回车关闭窗口..." _
exit "$status"
