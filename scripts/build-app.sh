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
    <key>CFBundleVersion</key><string>3</string>
    <key>CFBundleShortVersionString</key><string>0.1.2</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Tidewatch</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "✅ 已生成 $APP"
echo "   安装: cp -R $APP /Applications/"
