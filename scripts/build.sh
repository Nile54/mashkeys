#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build"
APP="$BUILD/MashKeys.app"
mkdir -p "$BUILD"
for ARCH in arm64 x86_64; do
  swiftc -swift-version 5 -O -whole-module-optimization \
    -target "$ARCH-apple-macos14.2" "$ROOT"/Sources/MashKeys/*.swift \
    -framework AppKit -framework CoreAudio -framework Accelerate -framework AVFoundation \
    -framework SoundAnalysis -framework ServiceManagement -framework Carbon \
    -o "$BUILD/MashKeys-$ARCH"
done
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BUILD/MashKeys-arm64" "$BUILD/MashKeys-x86_64" -output "$APP/Contents/MacOS/MashKeys"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
swiftc -swift-version 5 -O "$ROOT/scripts/icon.swift" -framework AppKit -o "$BUILD/icon-generator"
"$BUILD/icon-generator" "$BUILD/MashKeys.iconset"
iconutil -c icns "$BUILD/MashKeys.iconset" -o "$APP/Contents/Resources/MashKeys.icns"
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --options runtime --entitlements "$ROOT/MashKeys.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (universal arm64 + x86_64, macOS 14.2+)"
