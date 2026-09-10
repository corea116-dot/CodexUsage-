#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${1:-$SOURCE_DIR/../Codex Usage.app}"
BUILD_CACHE="${TMPDIR:-/tmp}/codex-usage-swift-cache"
ICON_SOURCE="$SOURCE_DIR/Assets/CodexUsage.png"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$BUILD_CACHE"
python3 "$SOURCE_DIR/Tools/make_icns.py" "$ICON_SOURCE" "$APP_DIR/Contents/Resources/CodexUsage.icns"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -module-cache-path "$BUILD_CACHE" \
  "$SOURCE_DIR/Sources/Usage.swift" "$SOURCE_DIR/Sources/App.swift" \
  -framework AppKit -framework ServiceManagement \
  -o "$APP_DIR/Contents/MacOS/CodexUsage"
cp "$SOURCE_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - --identifier local.codex.usage-menubar "$APP_DIR"
codesign --verify --strict "$APP_DIR"
printf '%s\n' "$APP_DIR"
