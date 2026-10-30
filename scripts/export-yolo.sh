#!/usr/bin/env bash
# Exports Ultralytics YOLO26n (80 COCO classes) to Core ML at App/Models/yolo26n.mlpackage (gitignored; Xcode compiles
# it into the app). NMS-free end-to-end head: output [1, 300, 6] = x1, y1, x2, y2 (640-px input space), score, class;
# class names are in the model metadata. ~4.8 MB, runs on the Neural Engine. Ultralytics models are AGPL-3.0.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$ROOT/App/Models/yolo26n.mlpackage" ] && exit 0
T="$(mktemp -d)"
cd "$T"
uv run -q -p 3.11 --with ultralytics --with coremltools==8.3.0 --with torch==2.5.1 --with torchvision==0.20.1 \
  --with "numpy<2" python -c "from ultralytics import YOLO; YOLO('yolo26n.pt').export(format='coreml', imgsz=640, half=True, end2end=True)"
mkdir -p "$ROOT/App/Models"
mv yolo26n.mlpackage "$ROOT/App/Models/"
rm -rf "$T"
