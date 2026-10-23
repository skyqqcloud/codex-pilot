#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/app"
DIST="$ROOT/dist"
STAGE="$DIST/dmg-stage"
APP_NAME="Codex Pilot"
BIN_NAME="CodexSwap"
APP="$DIST/${APP_NAME}.app"
DMG="$DIST/${APP_NAME}.dmg"

# 为什么固定 SDK 26：
# CLT 27（2026-09-21 更新）自带的 macOS 27 SDK 把 SwiftUI 属性包装器改成了宏
# （@State/@Entry 等 → 需要 SwiftUIMacros 宏插件），而 Command Line Tools 不携带
# 该插件（只有完整 Xcode 才有），导致直接编译报：
#   "plugin for module 'SwiftUIMacros' not found"
# 系统里保留了旧版 SDK（MacOSX26.sdk），按它编译时 @State 仍是普通属性包装器，
# 可正常编译。等以后装了完整 Xcode 或 CLT 修复此问题后可删掉这段固定。
SDK="$(xcrun --show-sdk-path)"
SDK_PINNED=0
SDK26="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [ -n "${CODEX_PILOT_SDK:-}" ]; then
  if [ ! -d "$CODEX_PILOT_SDK" ]; then
    echo "!! CODEX_PILOT_SDK 不是有效的 SDK 目录：$CODEX_PILOT_SDK" >&2
    exit 1
  fi
  SDK="$CODEX_PILOT_SDK"
elif [ -d "$SDK26" ]; then
  SDK="$SDK26"
  SDK_PINNED=1
else
  echo "!! 警告：未找到 MacOSX26.sdk，使用系统默认 SDK（若报 SwiftUIMacros 错误，见脚本注释）"
fi
if ! swiftc -version 2>&1 | grep -q "swiftlang"; then
  echo "!! 未找到 swiftc，请确认已安装 Command Line Tools"
  exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST/build" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 SwiftUI (arm64)  SDK=$(basename "$SDK")"
if [ "$SDK_PINNED" = "1" ]; then
  echo "    （固定 SDK 26 编译：绕开 CLT 27 SDK 的 SwiftUI 宏插件问题）"
fi
swiftc -parse-as-library -O -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  -file-prefix-map "$ROOT=." -debug-prefix-map "$ROOT=." \
  -module-cache-path "$DIST/build/ModuleCache" \
  -o "$DIST/build/$BIN_NAME" \
  "$APP_SRC/"*.swift \
  "$APP_SRC/Telemetry/"*.swift

echo "==> 图标"
python3 "$APP_SRC/make_icon.py" "$DIST/build/icon.ppm"
sips -s format png "$DIST/build/icon.ppm" --out "$DIST/build/icon_1024.png" >/dev/null
ICONSET="$DIST/build/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16     "$DIST/build/icon_1024.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$DIST/build/icon_1024.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$DIST/build/icon_1024.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$DIST/build/icon_1024.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$DIST/build/icon_1024.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$DIST/build/icon_1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$DIST/build/icon_1024.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$DIST/build/icon_1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$DIST/build/icon_1024.png" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$DIST/build/icon_1024.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> 组装 .app"
cp "$DIST/build/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
chmod +x "$APP/Contents/MacOS/$BIN_NAME"
cp "$APP_SRC/Info.plist" "$APP/Contents/Info.plist"
cp -R "$APP_SRC/Resources/"*.lproj "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/backend/codex-swap.py" "$APP/Contents/Resources/codex-swap.py"
cp "$ROOT/backend/tps-capture.py" "$APP/Contents/Resources/tps-capture.py"
cp "$ROOT/backend/request-context.py" "$APP/Contents/Resources/request-context.py"
chmod +x "$APP/Contents/Resources/codex-swap.py"
cp -R "$ROOT/ThirdParty" "$APP/Contents/Resources/ThirdParty"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$APP/Contents/Resources/"

echo "==> ad-hoc 签名"
codesign --force --sign - \
  --identifier local.wmy.CodexSwap \
  --entitlements "$APP_SRC/CodexSwap.entitlements" \
  --timestamp=none \
  "$APP/Contents/MacOS/$BIN_NAME"
codesign --force --sign - \
  --identifier local.wmy.CodexSwap \
  --entitlements "$APP_SRC/CodexSwap.entitlements" \
  --timestamp=none \
  "$APP"

echo "==> 打 DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/首次打开说明.txt" <<'TXT'
Codex Pilot — 安装说明

1. 把「Codex Pilot」拖进「应用程序」。
2. 第一次打开如果提示「无法验证开发者」：
   在「应用程序」里右键点它 → 打开 → 再点一次「打开」；
   或：系统设置 → 隐私与安全性 → 「仍要打开」。
3. 需要 macOS 14 或更高。
4. 本工具常驻 macOS 状态栏，不显示 Dock 图标。
   点击状态栏的双向箭头或双行数值打开面板。
5. 先登录 Codex，再打开本工具：
   「保存登录」记录当前账号；「添加账号」登录另一个账号。
   添加账号时不要点 Codex 里的 Log out。

切换账号前会确认；确认后退出并重新打开 Codex。
本机吞吐来自本地用量记录，不发起模型请求。
TXT
cat > "$STAGE/Getting Started.txt" <<'TXT'
Codex Pilot — Installation

1. Drag Codex Pilot into Applications, then open it.
2. If macOS blocks the first launch, allow it in System Settings → Privacy & Security.
3. Requires Apple Silicon, macOS 14+, Python 3.9+, and a signed-in Codex desktop client.
4. Click the menu bar icon and choose Save login to save your current account.
5. Enable Local speed capture in Settings, then restart Codex to collect new calls.

The interface follows your macOS language. You can choose English or Simplified
Chinese for Codex Pilot in System Settings → General → Language & Region → Applications.
TXT
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo
echo "App: $APP"
echo "DMG: $DMG"
codesign -dv "$APP" 2>&1 | head -12
ls -lh "$DMG"
