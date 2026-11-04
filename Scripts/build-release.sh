#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${ROOT}/Build/DerivedData"
rm -rf "${DERIVED}"
xcodebuild -project "${ROOT}/WorkRouteMenu.xcodeproj" -scheme WorkRouteMenu -configuration Release -derivedDataPath "${DERIVED}" build
xcodebuild -project "${ROOT}/WorkRouteMenu.xcodeproj" -scheme PrivilegedHelper -configuration Release -derivedDataPath "${DERIVED}" build
mkdir -p "${ROOT}/Build/PrivilegedHelper"
cp "${DERIVED}/Build/Products/Release/com.cooper.WorkRouteMenu.helper" "${ROOT}/Build/PrivilegedHelper/"
echo "构建完成：${DERIVED}/Build/Products/Release/WorkRouteMenu.app"
