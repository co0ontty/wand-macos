#!/usr/bin/env bash
# 编译 macOS 版 Wand.app,ad-hoc 签名,然后直接打开。
# 风格对齐 ios/debug.sh:iOS 端有模拟器/安装/启动三步,
# macOS 端更简单——本地直接 build + open 即可。
#
# 用法:
#   ./debug.sh
#   BUILD_CONFIGURATION="Release" DERIVED_DATA_PATH="$PWD/.release-derived-data" ./debug.sh
#   SKIP_OPEN=1 ./debug.sh    # 编译+签名但不自动打开,便于 CI / 远程调试
#   SKIP_SIGN=1 ./debug.sh    # Debug 编译出来的 .app 自带 Xcode 签名,本地运行可跳过 ad-hoc
#
# 退出码:成功 0;编译失败 1;签名失败 2;启动失败 3。

set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "错误:debug.sh 只能在 macOS 上运行(当前系统 $(uname))。" >&2
  exit 1
fi

for command in xcodebuild codesign; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "错误:找不到 $command,请先安装并选择 Xcode Command Line Tools。" >&2
    exit 1
  fi
done

cd "$(dirname "$0")"

BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/.debug-derived-data}"
PROJECT="Wand.xcodeproj"
SCHEME="Wand"
APP_NAME="Wand"
BUNDLE_ID="com.wand.app"
APP_BUNDLE_PATH="$DERIVED_DATA_PATH/Build/Products/$BUILD_CONFIGURATION/$APP_NAME.app"
ENTITLEMENTS="$PWD/Wand/$APP_NAME.entitlements"

# Liquid Glass 前置条件:Xcode 26+ 才能编译链接出 macOS 26 SDK 视觉。
# 老 SDK 编出的包在 macOS 26(Tahoe)上会被系统按「兼容模式」渲染成旧外观。
# 警告不阻断,跟 ios/build.sh 行为一致。
XCODE_MAJOR=$(xcodebuild -version | awk 'NR==1{print int($2)}')
if (( XCODE_MAJOR < 26 )); then
  echo "提示:当前 Xcode 主版本 $XCODE_MAJOR < 26,产物不会启用 macOS 26 Liquid Glass 外观。" >&2
fi

echo "==> 重新编译 $APP_NAME($BUILD_CONFIGURATION)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$BUILD_CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination "generic/platform=macOS" \
  build

if [[ ! -d "$APP_BUNDLE_PATH" ]]; then
  echo "错误:找不到编译产物 $APP_BUNDLE_PATH" >&2
  exit 1
fi

# Debug 编译出来的二进制自带 Xcode 临时签名,本地运行没问题;
# 但要分发(DMG / 别人机器)必须 ad-hoc 重签一次。SKIP_SIGN=1 可跳过。
if [[ "${SKIP_SIGN:-0}" != "1" ]]; then
  echo "==> ad-hoc codesign(--deep --options runtime)"
  codesign --sign - --force --deep --options runtime \
           --entitlements "$ENTITLEMENTS" \
           "$APP_BUNDLE_PATH"
  if ! codesign --verify --strict --verbose=2 "$APP_BUNDLE_PATH" >/dev/null 2>&1; then
    echo "错误:codesign 验证失败,签名可能不合法。" >&2
    exit 2
  fi
fi

if [[ "${SKIP_OPEN:-0}" == "1" ]]; then
  echo ""
  echo "完成:$APP_BUNDLE_PATH(SKIP_OPEN=1,未自动打开)"
  exit 0
fi

# 先把可能还在跑的旧进程清掉(同 bundle id 已经在跑会接管而不重启),
# 然后用 open 启动。open 返回值非 0 时才报错。
echo "==> 关闭可能残留的 Wand 进程"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
pkill -f "$APP_BUNDLE_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 1

echo "==> 打开 $APP_NAME"
if ! open "$APP_BUNDLE_PATH"; then
  echo "错误:open 启动 $APP_NAME 失败。" >&2
  exit 3
fi

# 给 Launch Services 一点时间,顺手验证进程真的起来了
sleep 2
if pgrep -f "$APP_BUNDLE_PATH/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
  echo ""
  echo "完成:$APP_NAME 已启动。"
else
  echo "提示:$APP_NAME 没检测到运行进程(可能在 dock 里等点击,或者在 ConnectView 等服务器)。" >&2
fi
