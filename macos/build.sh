#!/bin/bash
# 编译通用版（Apple Silicon + Intel 合在一个文件里），打包成 .app 和 .dmg
# 用法: ./build.sh [版本号]
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-0.0.0}"
APP="build/AIQuota.app"
DMG="build/ai-quota-desktop-widget-macos-universal-v${VERSION}.dmg"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AIQuota" "$APP/Contents/MacOS/AIQuota"
sed "s/__VERSION__/${VERSION}/g" Info.plist > "$APP/Contents/Info.plist"

# 本地签名（没有开发者证书，首次打开需要右键 → 打开）
codesign --force --deep --sign - "$APP"

echo "架构:"
lipo -info "$APP/Contents/MacOS/AIQuota"

# DMG：里面放 AIQuota.app 和“应用程序”快捷方式，拖进去即可安装
STAGE="build/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AI 用量" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "打包完成: $DMG"
