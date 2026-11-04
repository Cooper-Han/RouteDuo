#!/bin/bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
BUILD_DIR="${ROOT}/Build/PrivilegedHelper"
HELPER="/Library/PrivilegedHelperTools/com.cooper.WorkRouteMenu.helper"
PLIST="/Library/LaunchDaemons/com.cooper.WorkRouteMenu.helper.plist"
if [[ "$(id -u)" -ne 0 ]]; then exec sudo "$0" "$@"; fi
mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons
SOURCE_HELPER="${2:-${BUILD_DIR}/com.cooper.WorkRouteMenu.helper}"
if [[ -d "$SOURCE_HELPER" ]]; then
  SOURCE_HELPER="$(find "$SOURCE_HELPER" -maxdepth 1 -type f -perm -111 -print -quit)"
fi
SOURCE_PLIST="${ROOT}/PrivilegedHelper/com.cooper.WorkRouteMenu.helper.plist"
if [[ -z "$SOURCE_HELPER" || ! -f "$SOURCE_HELPER" ]]; then echo "找不到辅助服务：$BUILD_DIR" >&2; exit 71; fi
if [[ ! -f "$SOURCE_PLIST" ]]; then echo "找不到服务配置：$SOURCE_PLIST" >&2; exit 71; fi
cp "$SOURCE_HELPER" "$HELPER"
chmod 755 "$HELPER"
chown root:wheel "$HELPER"
cp "$SOURCE_PLIST" "$PLIST"
chmod 644 "$PLIST"
chown root:wheel "$PLIST"
launchctl bootout system/com.cooper.WorkRouteMenu.helper 2>/dev/null || true
launchctl bootstrap system "${PLIST}"
echo "特权辅助服务安装成功。"
