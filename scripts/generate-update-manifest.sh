#!/usr/bin/env bash

set -euo pipefail

VERSION="${1:?usage: generate-update-manifest.sh <version> <zip> <dmg> <output>}"
ZIP_PATH="${2:?missing ZIP path}"
DMG_PATH="${3:?missing DMG path}"
OUTPUT_PATH="${4:?missing output path}"

[[ -f "$ZIP_PATH" ]] || { echo "missing ZIP: $ZIP_PATH" >&2; exit 1; }
[[ -f "$DMG_PATH" ]] || { echo "missing DMG: $DMG_PATH" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || {
  echo "invalid update version: $VERSION" >&2
  exit 1
}

ZIP_NAME="$(basename "$ZIP_PATH")"
DMG_NAME="$(basename "$DMG_PATH")"
ZIP_SIZE="$(stat -f %z "$ZIP_PATH")"
DMG_SIZE="$(stat -f %z "$DMG_PATH")"
ZIP_SHA="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

MANIFEST=$(printf '{\n  "version": "%s",\n  "generatedAt": "%s",\n  "assets": [\n    {"fileName": "%s", "size": %s, "sha256": "%s"},\n    {"fileName": "%s", "size": %s, "sha256": "%s"}\n  ]\n}\n' \
  "$VERSION" "$GENERATED_AT" \
  "$ZIP_NAME" "$ZIP_SIZE" "$ZIP_SHA" \
  "$DMG_NAME" "$DMG_SIZE" "$DMG_SHA")

printf '%s' "$MANIFEST" > "$OUTPUT_PATH"
# Xcode 26 自带的 plutil -lint 仍按 XML/binary plist 路径处理 `.json`，
# 会误报 `Unexpected character {`。-convert json 会走 JSON parser，且不改动原文件。
plutil -convert json -o /dev/null -- "$OUTPUT_PATH"
