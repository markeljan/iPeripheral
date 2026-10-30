#!/usr/bin/env bash
# Downloads pinned third-party binaries into Vendor/ (gitignored). Run by build-and-install.sh; safe to re-run.
# - llama.cpp XCFramework (device slice only: the release has no simulator slice, so Simulator builds use a stub)
# - Apple's YOLOv3-Tiny Core ML object detector (80 COCO classes), compiled by Xcode from App/Models
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LLAMA_BUILD=b11988   # LFM3 needs b11960 or newer
LLAMA_SHA256=733ae95d8fe9fe45eecdf335a8a634424e280c36aa626c0c2fda7488f049c845
mkdir -p "$ROOT/Vendor"
if [ "$(cat "$ROOT/Vendor/llama.version" 2>/dev/null)" != "$LLAMA_BUILD" ]; then
  T="$(mktemp -d)"
  curl -fsSL -o "$T/llama.zip" "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_BUILD/llama-$LLAMA_BUILD-xcframework.zip"
  echo "$LLAMA_SHA256  $T/llama.zip" | shasum -a 256 -c --quiet
  unzip -q "$T/llama.zip" -d "$T"
  rm -rf "$ROOT/Vendor/llama.framework"
  cp -R "$T/build-apple/llama.xcframework/ios-arm64/llama.framework" "$ROOT/Vendor/"
  echo "$LLAMA_BUILD" > "$ROOT/Vendor/llama.version"
  rm -rf "$T"
  echo "llama.cpp $LLAMA_BUILD -> Vendor/llama.framework"
fi

# Optional: the YOLO11n object detector (needs Python + ~2 GB of torch the first time)
"$ROOT/scripts/export-yolo.sh" || echo "YOLO export failed; building without the object detector" >&2
