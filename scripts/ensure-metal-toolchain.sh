#!/usr/bin/env bash
# SwiftTerm includes Metal shaders even when its AppKit renderer uses CoreGraphics.
# Xcode 26+ distributes the Metal compiler as an optional Apple component.
set -euo pipefail
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "==> 安装 Xcode Metal Toolchain（SwiftTerm 构建依赖）"
  xcodebuild -downloadComponent MetalToolchain
fi
