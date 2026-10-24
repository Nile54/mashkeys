#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/MashKeys.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Info.plist")"
test -d "$APP"
mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/MashKeys-$VERSION-universal.zip"
DMG="$ROOT/dist/MashKeys-$VERSION.dmg"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
STAGE="$(mktemp -d "$ROOT/.build/dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/MashKeys.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname MashKeys -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
(cd "$ROOT/dist" && shasum -a 256 "MashKeys-$VERSION-universal.zip" "MashKeys-$VERSION.dmg" > SHA256SUMS.txt)
echo "Release files: $ROOT/dist"
