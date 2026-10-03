#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build -c release --disable-sandbox --cache-path "$PWD/.build/package-cache"
APP="$PWD/dist/轻览.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox --cache-path "$PWD/.build/package-cache")"
cp "$BIN_DIR/Qinglan" "$APP/Contents/MacOS/Qinglan"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
