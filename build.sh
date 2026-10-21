#!/bin/bash
# 一键：编译 → 打包成 MacKVM.app（程序 + Info.plist + 资源）→ 签名 → 验签 → 装到 ~/Applications
# 如果本机的 LaunchAgent 已装载，最后顺手重启它，让新版本生效。
#
# 签名：默认 ad-hoc（不需要任何证书，任何人都能编译运行）。ad-hoc 签名的程序每次重新编译后，
# 系统设置里的「辅助功能」授权都要重新打开一次。想免掉这一步，把自己的 Developer ID 写进 local.env
# （见 local.env.example，该文件不入库），或者用环境变量 MACKVM_SIGN_IDENTITY 传进来。
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/MacKVM.app"
DEST="$HOME/Applications/MacKVM.app"
BUNDLE_ID="io.github.leo4stone.mackvm"
LABEL="io.github.leo4stone.mackvm"

[ -f "$ROOT/local.env" ] && source "$ROOT/local.env"
IDENTITY="${MACKVM_SIGN_IDENTITY:--}"

echo "== 编译"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS"
# 只编 Sources/ 下的正式代码；Verify/ 里的自测和离屏渲染入口不进产物（见 Verify/verify.sh）
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
    -o "$APP/Contents/MacOS/MacKVM" \
    Sources/*.swift Sources/UI/*.swift

echo "== 打包"
cp Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
# 资源（程序图标等）：仓库的 Resources/ 整个拷进 Contents/Resources，程序里用 Bundle.main 加载。
# 要在签名之前拷，两种签名都会把它们封进签名里
mkdir -p "$APP/Contents/Resources"
cp -R Resources/. "$APP/Contents/Resources/"

if [ "$IDENTITY" = "-" ]; then
    echo "== 签名（ad-hoc；重新编译后要重新授权辅助功能）"
    codesign --force --sign - -i "$BUNDLE_ID" "$APP/Contents/MacOS/MacKVM"
    codesign --force --sign - -i "$BUNDLE_ID" "$APP"
else
    echo "== 签名（$IDENTITY，由内向外）"
    codesign --force --timestamp --sign "$IDENTITY" -i "$BUNDLE_ID" "$APP/Contents/MacOS/MacKVM"
    codesign --force --timestamp --sign "$IDENTITY" -i "$BUNDLE_ID" "$APP"
fi

echo "== 验签"
codesign --verify --strict --verbose=2 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated

echo "== 安装到 $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --verify --strict --verbose=2 "$DEST"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "== 重启本机 LaunchAgent"
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
fi
echo "完成"
