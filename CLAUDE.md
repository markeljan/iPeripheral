# iPeripheral — Tony's mounted iPhone

An iPhone mounted on the TonyPi humanoid becomes its senses (camera, later LiDAR/ARKit/mic) and face. Read
`PLAN.md` (phases, decisions) and `docs/protocol.md` (the wire protocol) before changing anything.

## Layout
- `App/` SwiftUI app "Tony Eyes" (`org.example.iperipheral`, iOS 18+, Swift 6). `PeripheralLink.swift` is the core:
  connection loop, pairing, answering bridge requests. Tap on the face = stop the body.
- `Packages/TonyLink/` protocol types + WebSocket client + Bonjour browser. `cd Packages/TonyLink && swift test`.
- `bridge/` Python package `tonypi-phone` that runs on the Pi (WS :8766 on the LAN, MCP on 127.0.0.1:8767).
  `cd bridge && uv run pytest` (fake tonyd/agent sockets, no robot needed).
- `deploy/` systemd unit, Bonjour advert, `install.sh` (rsync + uv sync + restart on `tonypi`).
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

## Device
- iPhone 14 Pro Max (iPhone15,3), iOS 27.0.1, UDID `YOUR_DEVICE_ID`, wired. Free Personal Team `GG7SNY5A85`:
  profiles expire after 7 days (re-run `scripts/build-and-install.sh`), no push/iCloud/App Groups, max 3 sideloaded apps.
- Must be unlocked to launch. `--console` streams stdout/stderr only; use MobileBuildMCP log capture for `os_log`.

## Tools
- MCP: `MobileBuildMCP` (project `.mcp.json`; device, LLDB, SwiftPM workflows, defaults in `.mobilebuildmcp/config.yaml`),
  `xcode` (`xcrun mcpbridge`, needs Xcode open with the project), `sosumi` (Apple docs). The app's iOS Simulator tool
  covers the simulator.
- CLI: `xcodegen`, `xcbeautify`, `swiftlint`, `xcrun swift-format`, `xcrun devicectl`, `uv`.
