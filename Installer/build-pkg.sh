#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${ROOT}/Build/PackageDerivedData"
OUT="${ROOT}/Build/Installer"
: "${DEVELOPER_ID_APPLICATION:=Developer ID Application: Shenyang Dadong District Duomisuo Education Technology Co., Ltd. (959Y964X4N)}"
: "${DEVELOPER_ID_INSTALLER:=Developer ID Installer: Shenyang Dadong District Duomisuo Education Technology Co., Ltd. (959Y964X4N)}"

rm -rf "$DERIVED" "$OUT"
mkdir -p "$OUT/Payload/Applications"
xcodebuild -project "$ROOT/WorkRouteMenu.xcodeproj" -scheme WorkRouteMenu -configuration Release -arch arm64 -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$ROOT/Build/SourcePackages" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" DEVELOPMENT_TEAM=959Y964X4N build
xcodebuild -project "$ROOT/WorkRouteMenu.xcodeproj" -scheme PrivilegedHelper -configuration Release -arch arm64 -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$ROOT/Build/SourcePackages" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" DEVELOPMENT_TEAM=959Y964X4N build

cp -R "$DERIVED/Build/Products/Release/RouteDuo.app" "$OUT/Payload/Applications/RouteDuo.app"
# 将安装所需文件同时放入 App 资源，确保把 App 单独复制到其他 Mac 时也能安装辅助程序。
cp "$DERIVED/Build/Products/Release/com.cooper.WorkRouteMenu.helper" "$OUT/Payload/Applications/RouteDuo.app/Contents/Resources/"
cp "$ROOT/PrivilegedHelper/com.cooper.WorkRouteMenu.helper.plist" "$OUT/Payload/Applications/RouteDuo.app/Contents/Resources/"
# 清理复制过程中可能生成的 AppleDouble/扩展属性文件，避免签名后内容被判定为已修改。
find "$OUT/Payload" -name '._*' -delete
xattr -cr "$OUT/Payload/Applications/RouteDuo.app" 2>/dev/null || true
# 辅助程序仅随 App 分发，由用户在 App 内确认安装；先签嵌套代码，再签 App。
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$OUT/Payload/Applications/RouteDuo.app/Contents/Resources/com.cooper.WorkRouteMenu.helper"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$OUT/Payload/Applications/RouteDuo.app"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OUT/Payload/Applications/RouteDuo.app/Contents/Info.plist")

pkgbuild --root "$OUT/Payload" \
  --identifier com.cooper.WorkRouteMenu.installer \
  --version "$APP_VERSION" --install-location / "$OUT/RouteDuo-Installer-unsigned.pkg"

if [[ -n "$DEVELOPER_ID_INSTALLER" ]]; then
  productsign --sign "$DEVELOPER_ID_INSTALLER" "$OUT/RouteDuo-Installer-unsigned.pkg" "$OUT/RouteDuo-Installer.pkg"
  rm "$OUT/RouteDuo-Installer-unsigned.pkg"
else
  mv "$OUT/RouteDuo-Installer-unsigned.pkg" "$OUT/RouteDuo-Installer.pkg"
  echo "未配置 Developer ID Installer，当前生成的是未签名 pkg。"
fi
echo "安装包：$OUT/RouteDuo-Installer.pkg"
