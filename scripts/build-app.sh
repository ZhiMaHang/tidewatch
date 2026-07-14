#!/bin/zsh
# 构建 QuotaBar.app 到 dist/
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/QuotaBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/QuotaBar "$APP/Contents/MacOS/QuotaBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>QuotaBar</string>
    <key>CFBundleDisplayName</key><string>QuotaBar</string>
    <key>CFBundleIdentifier</key><string>com.zhouxiajie.quotabar</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>QuotaBar</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "✅ 已生成 $APP"
echo "   安装: cp -R $APP /Applications/"
