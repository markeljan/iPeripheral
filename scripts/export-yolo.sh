#!/usr/bin/env bash
# Exports Ultralytics YOLO11n (80 COCO classes, NMS included) to Core ML at App/Models/yolo11n.mlpackage (gitignored;
# Xcode compiles it into the app). ~5.4 MB, runs on the Neural Engine. Ultralytics models are AGPL-3.0.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$ROOT/App/Models/yolo11n.mlpackage" ] && exit 0
T="$(mktemp -d)"
cd "$T"
uv run -q -p 3.11 --with ultralytics --with coremltools==8.3.0 --with torch==2.5.1 --with torchvision==0.20.1 \
  --with "numpy<2" python -c "from ultralytics import YOLO; YOLO('yolo11n.pt').export(format='coreml', nms=True, imgsz=640, half=True)"
mkdir -p "$ROOT/App/Models"
mv yolo11n.mlpackage "$ROOT/App/Models/"
rm -rf "$T"
