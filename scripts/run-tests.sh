#!/usr/bin/env bash
# 构建并运行本次 macOS XCTest 宿主，不依赖 testmanagerd，不寻找或复用旧测试产物。
# 用法：DERIVED_DATA=/tmp/wand-macos-tests ./scripts/run-tests.sh [测试名过滤]
set -euo pipefail

# Local opt-in storage policy; unconfigured machines and CI retain normal paths.
NATIVE_BUILD_ENV="${WAND_NATIVE_BUILD_ENV:-$HOME/.config/wand-build/environment.sh}"
if [[ -f "$NATIVE_BUILD_ENV" ]]; then
  source "$NATIVE_BUILD_ENV"
elif [[ -n "${WAND_NATIVE_BUILD_ENV:-}" ]]; then
  echo "Native build environment file not found: $NATIVE_BUILD_ENV" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
if ! xcodebuild -version >/dev/null 2>&1; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi
xcodebuild -version >/dev/null
DEVELOPER_DIR_PATH="${DEVELOPER_DIR:-$(xcode-select -p)}"
DEFAULT_DD="$PWD/.debug-derived-data"
if [[ -n "${WAND_BUILD_STORAGE_ROOT:-}" ]]; then
  DEFAULT_DD="$WAND_BUILD_STORAGE_ROOT/macos/tests"
fi
DERIVED_DATA="${DERIVED_DATA:-$DEFAULT_DD}"
if type wand_assert_external_build_path >/dev/null 2>&1; then
  wand_assert_external_build_path "$DERIVED_DATA"
fi
mkdir -p "$DERIVED_DATA"
DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"
FILTER="${1:-All}"
BUILD_LOG="$DERIVED_DATA/build-for-testing.log"
TEST_LOG="$DERIVED_DATA/xctest.log"

bash scripts/ensure-metal-toolchain.sh
echo "==> build-for-testing（日志：${BUILD_LOG}）"
if xcodebuild \
  -project Wand.xcodeproj \
  -scheme Wand \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64' \
  build-for-testing >"$BUILD_LOG" 2>&1; then
  grep -E 'warning: .*Wand/.*\.swift|TEST BUILD SUCCEEDED' "$BUILD_LOG" || true
else
  STATUS=$?
  grep -E 'error:|TEST BUILD FAILED' "$BUILD_LOG" || true
  echo "构建失败（退出码 ${STATUS}），未运行任何旧测试产物：${BUILD_LOG}" >&2
  exit "$STATUS"
fi

APP="$DERIVED_DATA/Build/Products/Debug/Wand.app"
BUNDLE="$APP/Contents/PlugIns/WandTests.xctest"
[[ -d "$BUNDLE" && -x "$APP/Contents/MacOS/Wand" ]] || {
  echo "本次构建缺少 XCTest 宿主或 bundle：$APP" >&2
  exit 1
}
echo "==> xctest（日志：${TEST_LOG}）"
set +e
# App 的 XCTest guard 不挂载生产主壳；不通过 Argument-domain 覆盖干扰隔离 suite。
DYLD_INSERT_LIBRARIES="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/usr/lib/libXCTestBundleInject.dylib" \
DYLD_FRAMEWORK_PATH="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
DYLD_LIBRARY_PATH="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/usr/lib" \
XCTestBundlePath="$BUNDLE" \
  "$APP/Contents/MacOS/Wand" -XCTest "$FILTER" >"$TEST_LOG" 2>&1
STATUS=$?
set -e
grep -E 'error:|XCTAssert|Executed [0-9]+ tests' "$TEST_LOG" | tail -30 || true
if [[ $STATUS -ne 0 ]]; then
  echo "测试失败（退出码 ${STATUS}）：${TEST_LOG}" >&2
  exit "$STATUS"
fi
# 注入失败可能以 0 退出；必须有 XCTest 完成证据，不能只依赖宿主退出码。
grep -Eq 'Executed [1-9][0-9]* tests?, with ([0-9]+ tests? skipped and )?0 failures' "$TEST_LOG" || {
  echo "未发现通过的 XCTest 汇总：$TEST_LOG" >&2
  exit 1
}
echo "==> 全部通过"
