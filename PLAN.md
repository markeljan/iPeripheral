# iPeripheral — iPhone 14 Pro Max as Tony's mounted senses

Status: plan, 2026-10-29. Nothing built yet.
Decisions: **mounted peripheral only** (no handheld remote UI) · **free Apple ID** signing · **Pi bridge lives in this repo**.

## Goal
Mount a dedicated iPhone 14 Pro Max (iOS 27.0.1) on the TonyPi humanoid and make it Tony's better senses and compute:
48 MP camera, LiDAR depth, ARKit world tracking (real odometry for open-loop walking), 3-mic array + on-device speech
(fixes the weak far-field USB mic), a face on the screen, and the A16 Neural Engine for Vision models.
Every brain (local LFM agent, Claude via MCP, Hermes) gets the phone's senses as tools.

## What the robot already gives us (tonypi repo, `m1-tonyd` branch, uncommitted as of today)
- `tonyd` owns `/dev/ttyAMA0` + robot camera. Unix socket `/run/tonypi/tonyd.sock`, JSON lines:
  `ping, skills, run, stop, state, head, snapshot, relax, subscribe` (events `job`, `warn`).
- `tonypi-mcp` on `127.0.0.1:8765/mcp` (Streamable HTTP, **no auth**): `list_skills, run_skill, stop, get_state, look, snapshot, say`.
- `tonypi-agent` owns the Pi mic + speaker; `/run/tonypi/agent.sock` takes text commands (same path as `tonypi-chat`).
- Skills are a fixed list in `tonyd/skills.py`; brains never send joint targets. Safety lives in tonyd.
- Robot: `tonypi.local` / 192.0.2.1; SSH works from this Mac.

**Inherited hard rules:** the bridge never opens the serial port or the robot camera; all motion through tonyd skills;
`stop` never depends on an LLM or on the phone; no LAN endpoint without auth.

## Architecture
```
iPhone (mounted, app foreground, screen on)            Raspberry Pi
┌─────────────────────────────┐  WebSocket, LAN    ┌──────────────────────────────────────┐
│ Senses: camera, LiDAR depth,│  token auth        │ tonypi-phone  (bridge, this repo)    │
│  ARKit pose, Vision detect  │  Bonjour           │  - WS server :8766                   │
│ Voice: wake phrase + Apple  │  _tonypi-phone._tcp│  - MCP server :8767  phone_* tools   │
│  Speech STT → text command  │◄──────────────────►│  - client of tonyd.sock (state/stop) │
│ Out: TTS, animated face     │                    │  - client of agent.sock (commands)   │
│ Tap face = stop             │                    │  - /run/tonypi/phone.sock (local)    │
└─────────────────────────────┘                    └──────────────────────────────────────┘
                                                      brains add a 2nd MCP server: tonypi-phone
```
- **Decoupled from tonypi.** The bridge speaks tonyd's and the agent's existing socket protocols directly (both are
  small JSON-lines protocols), so the tonypi rewrite and this project don't share code. If tonyd's protocol changes,
  only `bridge/tonyd_link.py` changes. A contract test runs against the real sockets on the Pi.
- **Its own MCP server** (`127.0.0.1:8767/mcp`): `phone_snapshot` (image), `phone_depth_at(x, y)`, `phone_pose`,
  `phone_detect` (people/objects/hands), `phone_say`, `set_face`. Claude Code / Hermes / the Agent SDK add it next to
  `tonypi-mcp`. No change to the tonypi MCP server.
- **Voice in without touching the agent:** the phone does wake phrase + STT, and the bridge sends the transcript to
  `agent.sock` as a text command — the same path `tonypi-chat` uses. The agent replies through the Pi speaker as today.
- **The one tonypi change** (later, coordinated with the MVP session): let the agent's `vision.py` prefer the phone
  camera via `phone.sock` when the phone is connected.
- **Wire format:** JSON control frames + binary frames (JPEG, depth, PCM). Versioned schema in `docs/protocol.md`,
  mirrored by Swift `Codable` types in `Packages/TonyLink` and Python dataclasses in `bridge/`.
- **Safety:** tapping the face sends `stop` → bridge → `tonyd.stop()`. Phone disconnect never starts or blocks motion;
  the board KEY button and voice "stop" keep working with the phone gone.
- **Pairing:** the bridge generates a token; Tony *speaks* a 6-digit code (via `agent.sock`), you type it into the app
  once; the token goes to the Keychain.
- **Later, if latency matters:** move video/audio to WebRTC (aiortc). Not in v1.

## Repo layout (`~/Projects/iPeripheral`, private `github.com/markeljan/iPeripheral`)
```
App/                 SwiftUI app (iOS), XcodeGen project.yml
Packages/TonyLink/   protocol types + WS client, `swift test`
bridge/              Python uv package `tonypi-phone` (WS + MCP + socket clients), pytest with fake tonyd/agent
deploy/              tonypi-phone.service, install.sh (rsync to pi:~/iPeripheral, uv sync, systemctl)
scripts/             build-and-install.sh (xcodebuild → devicectl), logs.sh
docs/protocol.md
```

## Tooling (what I drive)
| Task | How |
|---|---|
| Project generation | XcodeGen `project.yml` (no hand-edited .xcodeproj) |
| Build / test | `xcodebuild`, `swift test`; iOS Simulator for UI and the face |
| Install / launch / logs on the 14 Pro | `xcrun devicectl device install app` / `device process launch --console` |
| See/tap the real phone | iPhone Mirroring on the Mac via computer use (only works while the phone is locked/idle, so mostly for setup) + screenshots from the app's debug endpoint |
| Pi bridge | SSH to `tonypi`, `uv run pytest`, `deploy/install.sh` |
| Free-account re-sign | `scripts/build-and-install.sh` reinstalls in ~1 min; optional weekly reminder |
| Coordination | message the MVP session before any deploy, service restart, or change on the Pi |

## Phases
**P0 — Setup. [done 2026-10-29 except device install]** Me: `git init`, install XcodeGen, scaffold `App/` + `TonyLink` + `bridge/`,
simulator build, bridge tests with fakes. You: "Human steps" below.

**P1 — Link + eyes.** Bridge v0: WS + Bonjour + pairing, `tonyd` state/warn relay, MCP `phone_snapshot`.
App: discover → pair → stream camera on request; minimal face (idle/listening/thinking/warn) driven by tonyd events;
tap = stop; debug overlay (link, fps, battery, thermal state).
*Done when:* Claude Code on the Mac, with both MCP servers, can `phone_snapshot` and describe what the phone sees,
and tapping the screen stops a running `step_in_place`.

**P2 — Mount + balance (needs you).** The 14 Pro Max is 240 g and 16 cm tall, too heavy for the head servo: a low, centred back or chest
cradle (3D-printed or improvised). In a harness: `stand`, `step_in_place`, `walk_forward 2`, `turn_left`, `get_up` with
and without the phone; read tilt from tonyd. Adjust the stand pose if it leans (that's a tonypi change, coordinated).
Power: battery pack, or USB from the Pi (5 A board budget, check `vcgencmd get_throttled`).
*Done when:* Tony walks 5 steps and gets up from its back with the phone on, no falls in 5 tries.

**P3 — Voice.** On-device wake phrase + `SpeechAnalyzer`/`SFSpeechRecognizer` STT → `agent.sock`; `phone_say`
(AVSpeech or Piper audio from the Pi); face lip-sync. Compare WER and latency against the Pi's zipformer and
LFM3-Audio on the same recorded commands. *Done when:* "hey Tony, wave" works from 3 m in a normal room, 9/10 times.

**P4 — Spatial.** ARKit world tracking → `phone_pose` (30 Hz) with the phone→body offset; LiDAR depth for obstacle
distance; Vision person/ball detection → `phone_detect`. Closed-loop "walk to that": detect → head track → walk until
depth < 40 cm, correcting heading from ARKit, not step counts. *Done when:* Tony walks to a ball 2 m away and stops.

**P5 — Phone as compute.** Benchmark LFM2.5-1.2B / LFM3-1.7B / LFM3-VL on the A16 (MLX Swift or llama.cpp Metal)
against the Pi's llama-server, in the model test bench. If faster, the phone serves an OpenAI-compatible endpoint the
local agent can point at. Hermes uses the phone tools once the MVP session lands Hermes.

## Human steps (things I can't do)
1. Plug the iPhone 14 Pro into this Mac, unlock it, tap **Trust**.
2. iPhone: Settings → Privacy & Security → **Developer Mode** → on (reboots; confirm again).
3. Xcode → Settings → Accounts → sign in with your Apple ID (free "Personal Team"; 0 signing identities on this Mac now).
4. First install: iPhone → Settings → General → VPN & Device Management → trust your developer certificate.
5. On first launch, allow Camera, Microphone, Speech Recognition and **Local Network** prompts.
6. Optional: set up iPhone Mirroring so I can see the phone during setup.
7. P2: a phone mount, and stand next to Tony for every first motion test.

## Risks
- **Mass on the robot:** 240 g on a ~35 cm humanoid changes balance; the keyframe walks were tuned without it. Low centred mount, harness tests, stand-pose tweak; worst case peripheral mode for standing/turning/head only.
- **Free Apple ID:** app stops launching after 7 days until reinstalled (one script); max 3 sideloaded apps; no push.
- **Mounted iOS limits:** the app must stay foreground with the idle timer off; thermal throttling with camera + ARKit + screen; watch `ProcessInfo.thermalState` and drop frame rate.
- **Three sessions on one robot:** the audit/LFM and MVP sessions edit and restart services. This project only adds `tonypi-phone` and messages the MVP session before deploying.
- **tonyd protocol drift:** M1 is uncommitted; pin to its protocol, keep a contract test, and rebase when M1 merges.
- **Auth:** tonypi-mcp has none; the bridge never proxies it to the LAN. Bridge MCP stays on 127.0.0.1 (SSH tunnel from the Mac).
