#!/bin/bash
# 打包 CAM.app（universal）→ DMG，用 Developer ID 签名并公证。
# 用法：scripts/release.sh 0.1.0
# 公证凭据只需配置一次（密码用 appleid.apple.com 生成的 App 专用密码）：
#   xcrun notarytool store-credentials cam-notary --apple-id <Apple ID> --team-id 32LD2F272J
# NOTARY_PROFILE= （置空）可跳过公证，仅供本地自用构建。
set -euo pipefail
VERSION=${1:?用法: scripts/release.sh <版本号>}
IDENTITY=${IDENTITY:-"Developer ID Application: Wiseria LLC (32LD2F272J)"}
NOTARY_PROFILE=${NOTARY_PROFILE-cam-notary}
cd "$(dirname "$0")/.."

# 先确认公证凭据可用，免得编译完才失败
if [ -n "$NOTARY_PROFILE" ] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null; then
    echo "公证配置 $NOTARY_PROFILE 不可用，先按脚本开头的说明执行 store-credentials" >&2
    exit 1
fi

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/cam"

APP=dist/CAM.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/cam"
# assets/icon.svg → AppIcon.icns
ICONSET=dist/AppIcon.iconset && mkdir -p "$ICONSET" "$APP/Contents/Resources"
for s in 16 32 128 256 512; do
    sips -s format png -z $s $s assets/icon.svg --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -s format png -z $((s*2)) $((s*2)) assets/icon.svg --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>cam</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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

if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl -a -t open --context context:primary-signature -v "$DMG"
fi
echo "$DMG"
