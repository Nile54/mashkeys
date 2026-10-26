#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 speech-44100.wav music-44100.wav" >&2
  exit 2
fi
mkdir -p "$ROOT/.build/tests"
swiftc -swift-version 5 -DTESTING -O \
  "$ROOT/Tests/Audio/main.swift" "$ROOT/Sources/MashKeys/Core.swift" \
  "$ROOT/Sources/MashKeys/AudioSpectrum.swift" "$ROOT/Sources/MashKeys/AudioTap.swift" \
  "$ROOT/Sources/MashKeys/SpeechGuard.swift" \
  -framework CoreAudio -framework Accelerate -framework AVFoundation -framework SoundAnalysis \
  -o "$ROOT/.build/tests/audio"
"$ROOT/.build/tests/audio" "$1" "$2"
