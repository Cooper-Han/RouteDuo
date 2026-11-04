#!/bin/bash
set -euo pipefail
if [[ "$(id -u)" -ne 0 ]]; then exec sudo "$0" "$@"; fi
launchctl bootout system/com.cooper.WorkRouteMenu.helper 2>/dev/null || true
rm -f /Library/PrivilegedHelperTools/com.cooper.WorkRouteMenu.helper /Library/LaunchDaemons/com.cooper.WorkRouteMenu.helper.plist
echo "特权辅助服务已卸载。"
