#!/bin/bash
# 构建「肤色助手」：用 swiftc 直接编译并打包成可双击运行的 .app
#
# 说明：本机只安装了 Command Line Tools（未安装 Xcode），该 CLT 的 SwiftPM
# 在编译 Package.swift 清单时存在链接缺陷，因此这里直接调用 swiftc 编译，
# 效果与 `swift build` 一致。Package.swift 仍保留，安装 Xcode 后可正常使用。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="SkinTone"
APP_DIR="Build/肤色助手.app"
DEPLOYMENT_TARGET="arm64-apple-macos13.0"

echo "==> 编译源码 (release, arm64)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc -O \
  -parse-as-library \
  -target "$DEPLOYMENT_TARGET" \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
  Sources/SkinTone/*.swift

cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# 本地临时签名（签名异常时全局快捷键可能被系统拦截）
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || echo "  (临时签名跳过，不影响运行)"

echo "==> 完成: $APP_DIR"
echo "    运行: open \"$APP_DIR\""
echo "    命令行验证: \"$APP_DIR/Contents/MacOS/$APP_NAME\" --analyze '#C0504D'"
