# iPeripheral — Tony's mounted iPhone

An iPhone mounted on the TonyPi humanoid becomes its senses (camera, LiDAR depth, ARKit pose, Vision + YOLO
detection, ground/edge check, IMU, mic, sound events), its face, and a small on-device brain (LFM3 via llama.cpp). Read
`PLAN.md` (phases, decisions) and `docs/protocol.md` (the wire protocol) before changing anything.

## Layout
- `App/` SwiftUI app "Tony Eyes" (`org.example.iperipheral`, iOS 18+, Swift 6). `PeripheralLink.swift` is the core:
  connection loop, pairing, answering bridge requests. `Senses.swift` is one ARKit session (camera image + LiDAR depth +
  pose + Vision); `Ears.swift` is on-device speech (iOS 26 SpeechAnalyzer), and `Listener` in TonyLink turns transcripts
  into stop / wake / command. `LocalModel.swift` runs LFM3-1.7B / LFM3-VL-2B (llama.cpp, Metal; GGUFs downloaded to the
  phone on request), `Motion.swift` is the IMU (fall/impact events). Tap on the face = stop the body.
- `Packages/TonyLink/` protocol types + WebSocket client + Bonjour browser. `cd Packages/TonyLink && swift test`.
- `bridge/` Python package `tonypi-phone` that runs on the Pi (WS :8766 on the LAN, MCP on 127.0.0.1:8767).
  `cd bridge && uv run pytest` (fake tonyd/agent sockets, no robot needed).
- `deploy/` systemd unit, Bonjour advert, `install.sh` (rsync + uv sync + restart on `tonypi`).
- `scripts/fetch-vendor.sh` (run by build-and-install) puts pinned llama.cpp into `Vendor/` (gitignored, device slice
  only, so Simulator builds compile a stub via `canImport(llama)`) and runs `scripts/export-yolo.sh` for
  `App/Models/yolo26n.mlpackage` (gitignored, AGPL-3.0 Ultralytics model, NMS-free head parsed in `Senses`; the app
  works without it). Open-vocabulary finding (`locate`) is LFM3-VL-2B grounding, parsed by `TonyLink.Grounding`.
- `scripts/phone-mcp.py TOOL [k=v ...]` calls one bridge MCP tool (`uv run --project bridge scripts/phone-mcp.py list`).
- `scripts/build-and-install.sh [--console]` builds, installs and launches on the iPhone; `scripts/team.sh` writes the
  signing team into `App/Config/Local.xcconfig` (gitignored).

## Rules
- `project.yml` is the source of truth: never edit `iPeripheral.xcodeproj` or `App/Info.plist` (a hook blocks it,
  another regenerates after `project.yml` edits). Swift files are auto-formatted on edit (`.swift-format`).
- The protocol changes in three places together: `docs/protocol.md`, `Packages/TonyLink`, `bridge/`. Unknown types and
  fields are ignored on both sides; bump `v` only for incompatible changes.
- The robot's code lives in `markeljan/tonypi` on the Pi (`/home/pi/tonypi`); other Claude sessions work on it. The bridge
  only talks to its sockets (`/run/tonypi/tonyd.sock`, `/run/tonypi/agent.sock`), never to `/dev/ttyAMA0` or the camera.
  **Message the TonyPi MVP session before deploying to the Pi or restarting any service there.**
- `stop` never depends on the phone. The phone never drives joints; bodies move only through tonyd skills.
- One `xcodebuild` at a time (no parallel builds from subagents: DerivedData locks).

## Dev loop without the robot
`scripts/dev-bridge.sh` runs the bridge on this Mac against `tonypi-fake-robot` (fake tonyd + agent sockets in
`/tmp/tpdev`) and advertises it over Bonjour, so the real phone connects to the Mac exactly as it would to the Pi.
Skip spoken pairing with `APP_ARGS="-devToken $(scripts/dev-bridge.sh --token)" scripts/build-and-install.sh` (Debug
only; tokens in `build/dev-tokens.json`). Needs the sandbox off (it listens on the LAN). Stop the dev bridge before
testing against the Pi, or the phone may pick the Mac. Voice can be tested hands-free: `say -v Samantha "Hey Tony, wave"`
near the phone, then `grep "phone heard\|command:" build/dev-bridge.log`. Simulator: `-bridgeURL ws://127.0.0.1:8766/`
(no ARKit or mic there). Two devices with tokens fight over the one phone slot; run one at a time.

## Device
- iPhone 14 Pro Max (iPhone15,3), iOS 27.0.1, UDID `YOUR_DEVICE_ID`, wired. Free Personal Team `GG7SNY5A85`:
  profiles expire after 7 days (re-run `scripts/build-and-install.sh`), no push/iCloud/App Groups, max 3 sideloaded apps.
- Must be unlocked to launch. `--console` streams stdout/stderr only; use MobileBuildMCP log capture for `os_log`.

## Tools
- MCP: `MobileBuildMCP` (project `.mcp.json`; device, LLDB, SwiftPM workflows, defaults in `.mobilebuildmcp/config.yaml`),
  `xcode` (`xcrun mcpbridge`, needs Xcode open with the project), `sosumi` (Apple docs). The app's iOS Simulator tool
  covers the simulator.
- CLI: `xcodegen`, `xcbeautify`, `swiftlint`, `xcrun swift-format`, `xcrun devicectl`, `uv`.
