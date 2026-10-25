#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/tests"
swiftc -swift-version 5 -O \
  "$ROOT/Tests/main.swift" "$ROOT/Sources/MashKeys/Core.swift" \
  "$ROOT/Sources/MashKeys/BassSpectrum.swift" "$ROOT/Sources/MashKeys/Rules.swift" \
  -framework Accelerate -o "$ROOT/.build/tests/core"
"$ROOT/.build/tests/core"
