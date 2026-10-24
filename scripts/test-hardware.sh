#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "This optional test briefly changes the real keyboard light and restores its settings. Stop other lighting apps first."
mkdir -p "$ROOT/.build/tests"
swiftc -swift-version 5 -O "$ROOT/Tests/Hardware/main.swift" \
  "$ROOT/Sources/MashKeys/Core.swift" "$ROOT/Sources/MashKeys/KeyboardBacklight.swift" \
  "$ROOT/Sources/MashKeys/LightAnimator.swift" -o "$ROOT/.build/tests/hardware"
"$ROOT/.build/tests/hardware"
