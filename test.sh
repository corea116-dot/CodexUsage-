#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
mkdir -p "$TEST_BUILD/cache"
xcrun swiftc -parse-as-library -module-cache-path "$TEST_BUILD/cache" \
  "$SOURCE_DIR/Sources/Usage.swift" "$SOURCE_DIR/Tests/UsageTests.swift" \
  -o "$TEST_BUILD/UsageTests"
"$TEST_BUILD/UsageTests"
