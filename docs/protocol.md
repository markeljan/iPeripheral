# Phone ↔ bridge protocol (v1)

One WebSocket per phone: `ws://tonypi.local:8766/` (Bonjour `_tonypi-phone._tcp`). One phone is active at a time;
a newly authenticated connection replaces the old one.

## Frames
- **Text frames**: one JSON object with a `type` field.
- **Binary frames**: `[u32 big-endian header length][header JSON, UTF-8][payload bytes]`. The header is a normal
  message object (usually `{"type": "reply", "rid": …, "ok": true, "mime": "image/jpeg", …}`); the payload is the blob.

Unknown `type`s and unknown fields are ignored by both sides, so either side can add things without a version bump.
`v` changes only for incompatible changes.

## Auth
The first message from the phone is `hello` (with a token) or `pair_request`. Anything else before auth closes the
socket (close code 4401).

```
phone → {"type":"hello","v":1,"token":"<token>","device":"iPhone 14 Pro","app":"0.1.0"}
bridge → {"type":"welcome","v":1,"robot":"tonypi","bridge":"0.1.0"}
     or {"type":"error","error":"bad token"} + close 4401
```

Pairing (no token yet): Tony speaks a 6-digit code through its speaker (it is also logged to
`journalctl -u tonypi-phone`). Codes expire after 120 s; 3 wrong tries end the attempt.

```
phone → {"type":"pair_request","v":1,"device":"iPhone 14 Pro"}
bridge → {"type":"pair_code_sent"}
phone → {"type":"pair_confirm","code":"123456"}
bridge → {"type":"welcome","v":1,"robot":"tonypi","bridge":"0.1.0","token":"<token>"}
     or {"type":"error","error":"wrong code","tries_left":2}
```
The bridge stores only a SHA-256 of each token (`~/.config/tonypi-phone/tokens.json`).

## Phone → bridge (after welcome)
| type | fields | effect |
|---|---|---|
| `stop` | | `tonyd stop` immediately (face tap). Never waits on anything else. |
| `command` | `text` | sends the text to the agent, same as `tonypi-chat`. The phone sends what follows "Tony …" (on-device SpeechAnalyzer, iOS 26+); "stop"/"freeze"/"halt" heard anywhere sends `stop` instead, with no wake word and no LLM |
| `pose` | `x,y,z,yaw_deg,pitch_deg,tracking` (as the `pose` request) | ~10 Hz while connected; the bridge caches the latest |
| `event` | `kind` + fields: `fall`/`impact`/`freefall`/`upright` (`value`, `tilt_deg`) from the phone IMU; `sound` (`label`, `confidence`) from the built-in sound classifier | as they happen; the bridge keeps the last 100 |
| `transcript` | `text` | every finished phrase the phone heard (logged by the bridge; for tuning, not acted on) |
| `status` | `battery` 0–1, `charging`, `thermal` (`nominal/fair/serious/critical`), `caps` [..] | phone health, every ~5 s |
| `reply` | `rid`, `ok`, `error?`, … | answer to a bridge `request` (binary frame when it carries a blob) |

## Bridge → phone
| type | fields | meaning |
|---|---|---|
| `robot_state` | `state` (tonyd `state` dict) | every ~1 s while connected |
| `robot_event` | `event` (tonyd event: `job` or `warn`) | as they happen |
| `agent_event` | `event` (agent event: `heard`, `say`, `action`, `info`, `done`, …) | as they happen |
| `vocabulary` | `words` [..] (tonyd skill names, `_` → space) | once after welcome; speech recognition favours them |
| `request` | `rid`, `op`, args | the bridge needs something from the phone; the phone answers with `reply` |

### Requests
| op | args | reply |
|---|---|---|
| `snapshot` | `max_side` (px, default 1280), `quality` (0–1, default 0.7) | binary: JPEG, header has `width`, `height`, `lens` |
| `say` | `text` | `{"ok":true}` when speaking starts (phone TTS) |
| `face` | `face` (`idle/listening/thinking/speaking/happy/sad/warn/asleep`), `seconds` (override duration) | `{"ok":true}` |
| `status` | | same fields as the `status` message |
| `depth` | `points` [[x,y],…] and/or `grid` [cols,rows] (1–16) | `points` [{x,y,m,confidence 0–2}], `grid` [[m\|null]] row 0 = top, nearest (5th percentile) per cell |
| `pose` | | `x,y,z` m (y up, origin where tracking started), `yaw_deg` (+ = turned left), `pitch_deg`, `tracking` (`normal`, `limited:<reason>`, `not_available`), `age_s` |
| `reset_origin` | | `{"ok":true}`; the current pose becomes the origin |
| `detect` | `kinds` [`people`,`faces`,`hands`,`animals`,`objects`,`text`,`codes`] (default: the first five) | `objects` [{kind,label?,x,y,w,h,confidence,m,bearing_deg,elevation_deg,world?[x,y,z]}], `age_s`. `objects` = YOLO11n (80 COCO classes, `label` = class); `text` label = the text; `codes` label = `symbology: payload` |
| `ground` | | `surface_below_m`, `lanes` [{lane: left/centre/right, clear_m, edge_m, drop_m, obstacle_m}], `age_s`: ground ahead from LiDAR heights; edge = a drop > 8 cm, obstacle = a rise > 6 cm |
| `gaze` | | `face_tracking`, `mode` (auto/on/off), `viewer` {x,y} (the face looking at the screen, -1…1, x right, y down) or null, `eyes` {x,y} or null (wandering) |
| `face_tracking` | `mode` `auto` (thermal governor) / `on` / `off` | same as `gaze` |
| `motion` | | `tilt_deg` (0 upright … 90 lying), `roll_deg`, `fallen` |
| `llm` | `model` (`lfm3-1.7b` default, `lfm3-vl-2b` for images), `prompt` + `system`, or `messages` [{role,content}]; `image` (bool: the current camera frame, VL only), `image_side` (256–1024, default 512), `max_tokens` (default 256), `thinking` (default false: the assistant turn starts with an empty `<think></think>`, as LFM3's template does for `enable_thinking=false`), `backend` (`gpu` default, or `cpu`) | `text`, `thinking` (the reasoning, when on), `model`, `backend`, `prompt_tokens`, `generated_tokens`, `prefill_tok_s`, `decode_tok_s`, `load_s`, `total_s` |
| `models` | | `models` [{id,file,vision,downloaded,loaded,size_mb,downloading?%,error?}], `runtime` |
| `model_download` | `model` | starts the download (Hugging Face, ~1 GB); same reply as `models` |
| `model_unload` | | frees the loaded model |

Image coordinates (`x,y,w,h`) are 0–1 in the portrait snapshot image, origin top-left. Depth is LiDAR (ARKit
`smoothedSceneDepth`, 256×192), median of a small patch, low-confidence pixels dropped; `m` is null when nothing is
reliable. One ARKit session owns the back camera, so snapshot, depth, pose and detect all read the same latest frame.
`bearing_deg` is the horizontal angle from the body's heading (positive = left), `elevation_deg` from the horizon,
both gravity-referenced; `world` is the point in pose coordinates (needs depth), so a target can be walked to after
it leaves the view. The same session tracks the face of whoever looks at the screen (front camera) for the eyes'
gaze; it is switched off when the phone's thermal state is serious.

On-device models: Liquid's official QAD Q4_0 GGUFs (`LiquidAI/LFM3-1.7B-GGUF`, `LiquidAI/LFM3-VL-2B-GGUF` +
`mmproj-LFM3-VL-2B-Q8_0.gguf`), llama.cpp b11988 on Metal, 4096-token context, sampling temperature 0.1, top-k 50,
repeat penalty 1.1. One model is loaded at a time; `llm` requests are refused when the phone is thermally critical.

## Bridge internals (not on the wire)
- tonyd: `/run/tonypi/tonyd.sock`, JSON lines `{"op":…, "rid":n}` → `{"rid":n,"ok":true,…}`; `{"op":"subscribe"}` → events
  `{"event":"job"|"warn",…}`.
- agent: `/run/tonypi/agent.sock`, JSON lines; send `{"text":"…"}` (command) or `{"op":"say","text":"…"}`; every
  connected client gets the agent's events `{"type":…}`.
- MCP: `http://127.0.0.1:8767/mcp` (Streamable HTTP, localhost only): `phone_status`, `phone_snapshot`,
  `phone_detect`, `phone_find`, `phone_read_text`, `phone_depth_at`, `phone_obstacles`, `phone_ground_check`,
  `phone_pose` (from the 10 Hz stream), `phone_reset_origin`, `phone_motion`, `phone_events`, `phone_llm`,
  `phone_look_and_ask`, `phone_models`, `phone_model_download`, `phone_say`, `set_face`.
- OpenAI-compatible: `POST http://127.0.0.1:8767/v1/chat/completions` (non-streaming, text) and `GET /v1/models`,
  answered by the phone's LFM3 via the `llm` op, so a local agent can use the phone as its model server.
