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
| `command` | `text` | sends the text to the agent, same as `tonypi-chat` (voice transcripts from the phone) |
| `status` | `battery` 0–1, `charging`, `thermal` (`nominal/fair/serious/critical`), `caps` [..] | phone health, every ~5 s |
| `reply` | `rid`, `ok`, `error?`, … | answer to a bridge `request` (binary frame when it carries a blob) |

## Bridge → phone
| type | fields | meaning |
|---|---|---|
| `robot_state` | `state` (tonyd `state` dict) | every ~1 s while connected |
| `robot_event` | `event` (tonyd event: `job` or `warn`) | as they happen |
| `agent_event` | `event` (agent event: `heard`, `say`, `action`, `info`, `done`, …) | as they happen |
| `request` | `rid`, `op`, args | the bridge needs something from the phone; the phone answers with `reply` |

### Requests
| op | args | reply |
|---|---|---|
| `snapshot` | `max_side` (px, default 1280), `quality` (0–1, default 0.7) | binary: JPEG, header has `width`, `height`, `lens` |
| `say` | `text` | `{"ok":true}` when speaking starts (phone TTS) |
| `face` | `face` (`idle/listening/thinking/speaking/happy/sad/warn/asleep`), `seconds` (override duration) | `{"ok":true}` |
| `status` | | same fields as the `status` message |

Later (P4): `depth_at {x,y}`, `pose`, `detect {kinds}`.

## Bridge internals (not on the wire)
- tonyd: `/run/tonypi/tonyd.sock`, JSON lines `{"op":…, "rid":n}` → `{"rid":n,"ok":true,…}`; `{"op":"subscribe"}` → events
  `{"event":"job"|"warn",…}`.
- agent: `/run/tonypi/agent.sock`, JSON lines; send `{"text":"…"}` (command) or `{"op":"say","text":"…"}`; every
  connected client gets the agent's events `{"type":…}`.
- MCP: `http://127.0.0.1:8767/mcp` (Streamable HTTP, localhost only): `phone_status`, `phone_snapshot`, `phone_say`, `set_face`.
