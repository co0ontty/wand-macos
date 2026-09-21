#!/usr/bin/env bash
# 在无法使用 `xcodebuild test` 的环境（testmanagerd 不可达）里跑 WandTests。
#
# 做法：先 `build-for-testing`，再把测试 bundle 注入宿主 App 进程里跑 XCTest，
# 参数与 Xcode 自己的 test runner 一致，结果同样进 stdout。
#
# 用法：./scripts/run-tests.sh [测试名过滤，可选]
set -euo pipefail

cd "$(dirname "$0")/.."

if ! xcodebuild -version >/dev/null 2>&1; then
  for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
    if [[ -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi
xcodebuild -version >/dev/null

DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData}"
FILTER="${1:-All}"

echo "==> build-for-testing"
xcodebuild \
  -project Wand.xcodeproj \
  -scheme Wand \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build-for-testing \
  | grep -E "error:|warning: .*Wand/(.*)\.swift|TEST BUILD (SUCCEEDED|FAILED)" || true

PRODUCTS=$(find "$DERIVED_DATA" -maxdepth 4 -type d -path "*Wand-*/Build/Products/Debug" 2>/dev/null | head -1)
if [[ -z "$PRODUCTS" ]]; then
  echo "找不到构建产物，请先跑一次 xcodebuild" >&2
  exit 1
fi

APP="$PRODUCTS/Wand.app"
BUNDLE="$APP/Contents/PlugIns/WandTests.xctest"
DEVELOPER_DIR_PATH=$(xcode-select -p)

echo "==> xctest（注入 $BUNDLE）"
LOG=$(mktemp)
set +e
DYLD_INSERT_LIBRARIES="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/usr/lib/libXCTestBundleInject.dylib" \
DYLD_FRAMEWORK_PATH="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
DYLD_LIBRARY_PATH="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/usr/lib" \
XCTestBundlePath="$BUNDLE" \
  "$APP/Contents/MacOS/Wand" -XCTest "$FILTER" >"$LOG" 2>&1
STATUS=$?
set -e

grep -E "error:|XCTAssert|Executed [0-9]+ tests" "$LOG" | tail -30
if [[ $STATUS -ne 0 ]]; then
  echo "==> 失败。完整日志：$LOG" >&2
  exit $STATUS
fi
echo "==> 全部通过"
rm -f "$LOG"
