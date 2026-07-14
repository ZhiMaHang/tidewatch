#!/bin/zsh
# 构建 universal(arm64 + x86_64)Tidewatch.app,并打成 .dmg(拖拽安装)。
# 未做 Apple 公证(ad-hoc 签名);安装指引见 README。
# 用法:./scripts/build-dmg.sh [version]   缺省 0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APPNAME="Tidewatch"

echo "▸ universal build (arm64 + x86_64) …"
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/${APPNAME}"
[ -f "$BIN" ] || { echo "❌ 找不到 universal 产物 $BIN"; exit 1; }
echo "  架构: $(lipo -archs "$BIN")"

APP="dist/${APPNAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APPNAME}"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APPNAME}</string>
    <key>CFBundleDisplayName</key><string>${APPNAME}</string>
    <key>CFBundleIdentifier</key><string>com.zhimahang.tidewatch</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>${APPNAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "✅ $APP  ($(lipo -archs "$APP/Contents/MacOS/${APPNAME}"))"

echo "▸ 打包 .dmg …"
DMG="dist/${APPNAME}-${VERSION}.dmg"
rm -f "$DMG"
STAGING="dist/dmg-staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"    # 拖拽到「应用程序」
hdiutil create -volname "${APPNAME}" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "✅ $DMG"
shasum -a 256 "$DMG"
