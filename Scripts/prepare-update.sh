#!/bin/bash
# Local release preparation. Sparkle's EdDSA private key stays in your Keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${SPARKLE_TOOLS:=$ROOT/Build/SourcePackages/artifacts/sparkle/Sparkle/bin}"
APP="$ROOT/Build/Installer/Payload/Applications/RouteDuo.app"
INFO="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")
OUT="$ROOT/Build/Updates/$VERSION-$BUILD"
mkdir -p "$OUT"
# Rebuilding the same release must not reuse an old archive signature.
rm -f "$OUT/appcast.xml" "$OUT/RouteDuo-$VERSION.zip" "$OUT/RouteDuo-Installer.pkg"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/RouteDuo-$VERSION.zip"
"$SPARKLE_TOOLS/generate_appcast" --account RouteDuo --download-url-prefix "https://github.com/Cooper-Han/RouteDuo/releases/download/v$VERSION/" "$OUT"
# The pkg is for first-time installations; the feed must update using the App zip.
python3 "$ROOT/Scripts/validate-appcast.py" "$OUT/appcast.xml" "$APP"
cp "$ROOT/Build/Installer/RouteDuo-Installer.pkg" "$OUT/RouteDuo-Installer.pkg"
echo "Release assets: $OUT"
echo "Upload appcast.xml, RouteDuo-$VERSION.zip and RouteDuo-Installer.pkg together to release v$VERSION."
