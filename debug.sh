#!/usr/bin/env bash
# 编译 macOS 版 Wand.app,自动打开。
# 风格对齐 ios/debug.sh:iOS 端有模拟器/安装/启动三步,
# macOS 端更简单——本地直接 build + open 即可。
#
# 重要:默认 BUILD_CONFIGURATION=Release。
# Xcode Debug 配置默认会把产物拆成 Wand + Wand.debug.dylib 两份,本地 ad-hoc 重签
# 时 --deep 在 macOS 26 (Tahoe) 会让 dyld 报 "different Team IDs" 拒绝启动;Release
# 是单二进制,绕开这个坑。如果一定要 Debug,加 RESIGN=1 + Debug 会单独处理(见下)。
#
# 用法:
#   ./debug.sh
#   BUILD_CONFIGURATION=Debug ./debug.sh
#   SKIP_OPEN=1 ./debug.sh                  # 编译但不打开
#   RESIGN=1 ./debug.sh                     # 编译后用 ad-hoc 重新签名整个 .app
#                                          # (注意:Debug 拆 dylib 时仍可能 crash,只建议 Release 用)
#   DERIVED_DATA_PATH=/tmp/foo ./debug.sh   # 自定义派生数据目录
#
# 退出码:成功 0;编译失败 1;签名失败 2;启动失败 3。

set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "错误:debug.sh 只能在 macOS 上运行(当前系统 $(uname))。" >&2
  exit 1
fi

for command in xcodebuild; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "错误:找不到 $command,请先安装并选择 Xcode Command Line Tools。" >&2
    exit 1
  fi
done

cd "$(dirname "$0")"

# 默认 Release:单二进制,无 dylib 拆分,本地启动稳。
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Release}"
case "$BUILD_CONFIGURATION" in
  Debug|Release) ;;
  *)
    echo "错误:BUILD_CONFIGURATION 必须是 Debug 或 Release,当前是 '$BUILD_CONFIGURATION'。" >&2
    exit 1
    ;;
esac

# 派生数据按配置分目录,避免 Debug/Release 互相覆盖。
case "$BUILD_CONFIGURATION" in
  Debug)   DEFAULT_DD="$PWD/.debug-derived-data"   ;;
  Release) DEFAULT_DD="$PWD/.release-derived-data" ;;
esac
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$DEFAULT_DD}"

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

# 默认 Xcode 自带签名(dev-mode + entitlements)够本地跑,不再额外 ad-hoc 重签。
# macOS 26 + Debug 会拆 dylib,--deep 重签后 dylib 跟主二进制 Team ID 不一致导致
# dyld 拒绝启动;只有显式 RESIGN=1 才走"对每个 Mach-O 单独签"的路径,且只建议 Release 用。
if [[ "${RESIGN:-0}" == "1" ]]; then
  if [[ "$BUILD_CONFIGURATION" == "Debug" ]]; then
    echo "提示:Debug 配置下 Xcode 会拆 dylib(Wand.debug.dylib),RESIGN=1 重签后仍可能" >&2
    echo "      触发 dyld 'different Team IDs' 拒绝启动。推荐:去掉 RESIGN=1 跑默认路径。" >&2
  fi
  echo "==> ad-hoc 重签(逐个 Mach-O,--no-strict 容忍 entitlements 子集差异)"
  # 先签所有 dylib / nested 二进制,最后签主二进制(macOS 签名顺序:内→外)
  for bin in \
    "$APP_BUNDLE_PATH/Contents/Frameworks"/*.framework \
    "$APP_BUNDLE_PATH/Contents/PlugIns"/*.appex \
    "$APP_BUNDLE_PATH/Contents/MacOS"/*.dylib \
    "$APP_BUNDLE_PATH/Contents/MacOS/__preview.dylib"
  do
    if [[ -e "$bin" ]]; then
      codesign --sign - --force \
               --entitlements "$ENTITLEMENTS" \
               "$bin" >/dev/null 2>&1 || true
    fi
  done
  codesign --sign - --force \
           --entitlements "$ENTITLEMENTS" \
           "$APP_BUNDLE_PATH/Contents/MacOS/$APP_NAME"
  if ! codesign --verify "$APP_BUNDLE_PATH" >/dev/null 2>&1; then
    echo "错误:codesign 验证失败。" >&2
    exit 2
  fi
  echo "    签名完成。"
fi

if [[ "${SKIP_OPEN:-0}" == "1" ]]; then
  echo ""
  echo "完成:$APP_BUNDLE_PATH(SKIP_OPEN=1,未自动打开)"
  exit 0
fi

# 关掉可能还在跑的旧进程(同 bundle id 已经在跑会接管而不重启),
# 然后用 open 启动。open 失败才报错。
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
