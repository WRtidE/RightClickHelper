#!/bin/bash
# Build and package the Apple Silicon development-signed test app.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
if [[ ! -f Config/Local.xcconfig ]]; then bash scripts/configure-signing.sh; fi

xcodebuild -project RightClickHelper.xcodeproj -scheme RightClickHelper \
  -configuration Release -derivedDataPath build/ReleaseDerivedData \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build

APP="$PROJECT_ROOT/build/ReleaseDerivedData/Build/Products/Release/RightClickHelper.app"
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
NAME="RightClickHelper-$VERSION-macOS-arm64"
mkdir -p build dist
STAGING=$(mktemp -d "$PROJECT_ROOT/build/package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/$NAME"
ditto "$APP" "$STAGING/$NAME/RightClickHelper.app"
cp docs/INSTALL-APP.txt "$STAGING/$NAME/安装说明.txt"
codesign --verify --deep --strict "$STAGING/$NAME/RightClickHelper.app"
ARCHIVE="$PROJECT_ROOT/dist/$NAME.zip"
# Remove the previous archive so ditto cannot retain stale entries.
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$STAGING/$NAME" "$ARCHIVE"
(cd dist && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
printf '已打包：%s\n' "$ARCHIVE"
