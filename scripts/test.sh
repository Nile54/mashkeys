#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/tests"
swiftc -swift-version 5 -O \
  "$ROOT/Tests/main.swift" "$ROOT/Sources/MashKeys/Core.swift" \
  "$ROOT/Sources/MashKeys/BassSpectrum.swift" "$ROOT/Sources/MashKeys/Rules.swift" \
  -framework Accelerate -o "$ROOT/.build/tests/core"
"$ROOT/.build/tests/core"
swiftc -swift-version 5 -DTESTING -O \
  "$ROOT/Tests/Bridge/main.swift" "$ROOT/Sources/MashKeys/Core.swift" \
  "$ROOT/Sources/MashKeys/BassSpectrum.swift" "$ROOT/Sources/MashKeys/Rules.swift" \
  "$ROOT/Sources/MashKeys/AudioTap.swift" "$ROOT/Sources/MashKeys/SpeechGuard.swift" \
  "$ROOT/Sources/MashKeys/BrowserBridge.swift" \
  -framework CoreAudio -framework Accelerate -framework AVFoundation -framework SoundAnalysis \
  -o "$ROOT/.build/tests/bridge"
"$ROOT/.build/tests/bridge"
if command -v node >/dev/null; then
  for file in "$ROOT"/BrowserExtension/*.js; do node --check "$file"; done
  node "$ROOT/Tests/browser.mjs"
fi
