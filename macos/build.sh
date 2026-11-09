#!/bin/bash
# 编译通用版（Apple Silicon + Intel 合在一个文件里）并打包成 .app 和 zip
# 用法: ./build.sh [版本号]
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-0.0.0}"
APP="build/AIQuota.app"
ZIP="build/ai-quota-desktop-widget-macos-universal-v${VERSION}.zip"

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

ditto -c -k --keepParent "$APP" "$ZIP"
echo "打包完成: $ZIP"
