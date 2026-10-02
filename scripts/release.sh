#!/bin/bash
# 打包 CAM.app（universal）→ DMG，并用 Developer ID 签名；设置 NOTARY_PROFILE 时顺带公证。
# 用法：NOTARY_PROFILE=<notarytool 钥匙串配置名> scripts/release.sh 0.1.0
set -euo pipefail
VERSION=${1:?用法: scripts/release.sh <版本号>}
IDENTITY=${IDENTITY:-"Developer ID Application: Wiseria LLC (32LD2F272J)"}
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/cam"

APP=dist/CAM.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/cam"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>cam</string>
    <key>CFBundleIdentifier</key><string>ai.wiseria.cam</string>
    <key>CFBundleName</key><string>CAM</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
# DMG 里放 app 和「应用程序」快捷方式，拖进去即安装
DMG="dist/CAM-$VERSION.dmg"
mkdir -p dist/dmg && cp -R "$APP" dist/dmg/ && ln -s /Applications dist/dmg/Applications
hdiutil create -volname CAM -srcfolder dist/dmg -ov -format UDZO "$DMG"
codesign --timestamp -s "$IDENTITY" "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
echo "$DMG"
