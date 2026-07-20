#!/bin/zsh
# 构建 Tidewatch.app 到 dist/
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/Tidewatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tidewatch "$APP/Contents/MacOS/Tidewatch"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tidewatch</string>
    <key>CFBundleDisplayName</key><string>Tidewatch</string>
    <key>CFBundleIdentifier</key><string>com.zhimahang.tidewatch</string>
    <key>CFBundleVersion</key><string>8</string>
    <key>CFBundleShortVersionString</key><string>0.1.7</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Tidewatch</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 优先用稳定 dev 身份签名(scripts/dev-cert.sh 生成),重构建不触发钥匙串重新授权;
# 没有则回退 ad-hoc(签名标识随构建变,每次重构建会重弹授权框)
IDENTITY="Tidewatch Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$IDENTITY\"" >/dev/null; then
  codesign --force --sign "$IDENTITY" "$APP"
  SIGN_NOTE="签名: $IDENTITY(稳定 dev 身份)"
else
  codesign --force --sign - "$APP"
  SIGN_NOTE="签名: ad-hoc——每次重构建会重弹钥匙串授权;跑一次 ./scripts/dev-cert.sh 可消除"
fi
echo "✅ 已生成 $APP"
echo "   $SIGN_NOTE"
echo "   安装: cp -R $APP /Applications/"
