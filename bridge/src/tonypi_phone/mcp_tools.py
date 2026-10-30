"""MCP server for the phone's senses (Streamable HTTP, localhost only). Brains add it next to tonypi-mcp.

The same server also answers OpenAI-style `/v1/chat/completions` with the phone's on-device LFM3, so a local agent on
the Pi can use the phone as its model server, and `/live` streams the phone camera as MJPEG for a person watching
(localhost only, like the MCP endpoint: `ssh -L 8767:127.0.0.1:8767 tonypi`, then http://127.0.0.1:8767/live).
"""

from __future__ import annotations

import asyncio
import time
import uuid

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.server.mcpserver.utilities.types import Image
from starlette.requests import Request
from starlette.responses import JSONResponse, StreamingResponse

from tonypi_phone.hub import PhoneError, PhoneHub
from tonypi_phone.recorder import Recorder, RecorderError

DETECT_KINDS = ("people", "faces", "hands", "animals", "objects", "text", "codes")
FACES = ("idle", "listening", "thinking", "speaking", "happy", "sad", "warn", "asleep")
MODELS = ("lfm3-1.7b", "lfm3-vl-2b")
LLM_TIMEOUT_S = 180.0  # includes loading the model (a few seconds) on first use


def build_mcp(hub: PhoneHub, recorder: Recorder | None = None) -> MCPServer:
    mcp = MCPServer(
        "tonypi-phone",
        instructions=(
            "Tony (the TonyPi humanoid) wears an iPhone 14 Pro Max on its body. These tools use the phone: its back "
            "camera (better than the head camera, and it does not move with the head), LiDAR depth, ARKit position "
            "tracking, on-device detection (people, faces, hands, animals, 80 everyday objects, text, QR codes), "
            "ground/edge checking, its own motion sensor, sound events, an on-device LFM3 language and vision model, "
            "its speaker and its screen, which shows Tony's face. Image coordinates are x, y from 0 to 1 in the "
            "snapshot image, origin top-left. Angles are degrees, positive = left (bearing) or up (elevation). "
            "World positions are metres in phone_pose's frame. Body movement is in the separate tonypi MCP server. "
            "The phone has two modes (phone_mode): mounted (on Tony, as above) and companion (on a stand or in a "
            "hand, watching Tony from outside: phone_track follows him, phone_record / phone_record_jobs record "
            "what he does next to tonyd's joint and tilt data, phone_episode_review shows a recording as one image, "
            "so you can watch your own body move, check clearance before a new move, and measure a walk from "
            "outside). In companion mode phone_pose and phone_motion are the phone's, not Tony's."
        ),
    )

    async def ask(op: str, timeout: float = 10.0, **args):
        try:
            return await hub.request(op, timeout=timeout, **args)
        except PhoneError as e:
            raise ToolError(str(e)) from e

    def fields(header: dict) -> dict:
        return {k: v for k, v in header.items() if k not in ("type", "rid", "ok")}

    # ---- status ---------------------------------------------------------------------------------------------

    @mcp.tool()
    async def phone_status() -> dict:
        """Whether the phone is connected, plus its battery (0-1), charging, thermal state and capabilities."""
        if not hub.connected:
            return {"connected": False}
        header, _ = await ask("status", timeout=5)
        return {"connected": True, "device": hub.device, **fields(header)}

    # ---- seeing ---------------------------------------------------------------------------------------------

    @mcp.tool()
    async def phone_snapshot(max_side: int = 1280) -> Image:
        """What the phone camera sees right now, as a JPEG (longest side max_side px, 320-1920)."""
        header, jpeg = await ask("snapshot", max_side=max(320, min(1920, int(max_side))))
        if not jpeg:
            raise ToolError("phone sent no image")
        return Image(data=jpeg, format="jpeg")

    @mcp.tool()
    async def phone_detect(kinds: list[str] | None = None) -> dict:
        """What the phone camera sees now (on-device Vision + YOLO26n on the Neural Engine). kinds: any of people,
        faces, hands, animals, objects (YOLO26n, 80 COCO classes: ball, cup, chair, bottle, ...), text (OCR), codes (QR and
        barcodes). Default: people, faces, hands, animals, objects. Each object has kind, label (object class, text
        or code payload), box x, y, w, h (0-1, top-left origin), confidence, m (distance to the box centre, LiDAR),
        bearing_deg (positive = left of Tony's heading), elevation_deg, and world [x, y, z] in phone_pose's frame."""
        args = {} if not kinds else {"kinds": [k for k in kinds if k in DETECT_KINDS]}
        header, _ = await ask("detect", **args)
        return {"objects": header.get("objects", []), "frame_age_s": header.get("age_s")}

    @mcp.tool()
    async def phone_find(target: str) -> dict:
        """Find one thing and say where it is, for turning and walking toward it: a kind (person, face, hand, animal,
        text, code) or an object class ("sports ball", "cup", "chair", "bottle", "dog", ...). Returns the nearest
        match with bearing_deg (turn this much: positive = left), m (distance), world position, and how many
        matches there were; found is false when nothing matches."""
        t = target.strip().lower()
        kind_aliases = {"person": "people", "people": "people", "face": "faces", "hand": "hands",
                        "animal": "animals", "text": "text", "code": "codes", "qr": "codes"}
        kind = kind_aliases.get(t) or kind_aliases.get(t.rstrip("s"))
        kinds = [kind] if kind else ["objects", "animals"]
        header, _ = await ask("detect", kinds=kinds)
        objs = header.get("objects", [])
        if not kind:
            objs = [o for o in objs if t in (o.get("label") or "").lower() or (o.get("label") or "").lower() in t]
        if not objs:
            return {"found": False, "target": target}
        best = min(objs, key=lambda o: (o.get("m") is None, o.get("m") or 0, -o["w"] * o["h"]))
        return {"found": True, "target": target, "matches": len(objs), **best}

    @mcp.tool()
    async def phone_locate(target: str, image_side: int = 768) -> dict:
        """Find anything you can describe in words ("the red mug", "the charging cable", "the door handle") with the
        on-device LFM3-VL-2B vision model: open-vocabulary, unlike phone_detect/phone_find's 80 fixed classes, but
        takes seconds. Each match comes back like phone_detect's objects (box, m, bearing_deg, world), placed from
        the depth and pose of the moment the picture was taken. Use it to find a target once, then phone_find or
        phone_pose to track it while moving."""
        header, _ = await ask("locate", timeout=LLM_TIMEOUT_S, target=target,
                              image_side=max(256, min(1024, int(image_side))))
        out = fields(header)
        out["found"] = bool(out.get("objects"))
        return out

    @mcp.tool()
    async def phone_read_text() -> dict:
        """Read the text the phone camera sees (signs, labels, screens), top to bottom, with distances."""
        header, _ = await ask("detect", kinds=["text"], timeout=15)
        lines = sorted(header.get("objects", []), key=lambda o: (round(o["y"], 2), o["x"]))
        return {"lines": [{"text": o.get("label"), "m": o.get("m"), "bearing_deg": o.get("bearing_deg")}
                          for o in lines]}

    # ---- space ----------------------------------------------------------------------------------------------

    @mcp.tool()
    async def phone_depth_at(x: float = 0.5, y: float = 0.5) -> dict:
        """Distance in metres (LiDAR, reliable to about 5 m) to whatever is at image point (x, y), 0-1 from the
        top-left of phone_snapshot's image. m is null where there is no reliable reading (sky, glass, too far)."""
        header, _ = await ask("depth", points=[[_unit(x), _unit(y)]])
        return header["points"][0]

    @mcp.tool()
    async def phone_obstacles() -> dict:
        """Nearest distance in metres ahead of Tony, split into left / centre / right and upper / middle / lower
        thirds of the camera view (null = nothing reliable within LiDAR range). Use before and while walking."""
        header, _ = await ask("depth", grid=[3, 3])
        grid = header["grid"]
        cols = ("left", "centre", "right")
        out = {row: dict(zip(cols, grid[i])) for i, row in enumerate(("upper", "middle", "lower"))}
        vals = [v for r in grid for v in r if v is not None]
        out["nearest_m"] = min(vals) if vals else None
        return out

    @mcp.tool()
    async def phone_ground_check() -> dict:
        """Is the ground ahead safe to walk on? For left / centre / right lanes: clear_m (the surface Tony stands on
        continues this far), edge_m + drop_m (the ground drops away there, e.g. a table edge or stairs: never walk
        past it), obstacle_m (something rises from the ground there). surface_below_m is the phone's height above
        that surface. Check before every walk; lanes with no numbers had no readable ground."""
        header, _ = await ask("ground")
        return fields(header)

    @mcp.tool()
    async def phone_pose() -> dict:
        """Where the phone (so Tony's body, when mounted) is, from ARKit visual-inertial tracking: x, y, z in metres from where
        tracking started (y is up), yaw_deg (heading, positive = turned left since the start), pitch_deg. Trust it
        only when tracking is "normal". Better than counting steps for how far Tony walked or turned. Streamed at
        10 Hz, so this is instant."""
        cached = hub.fresh_pose()
        if cached is not None:
            return cached
        header, _ = await ask("pose", timeout=5)
        return fields(header)

    @mcp.tool()
    async def phone_reset_origin() -> dict:
        """Make Tony's current position and heading the new phone_pose origin (0, 0, 0, yaw 0)."""
        await ask("reset_origin", timeout=5)
        return {"reset": True}

    # ---- body and surroundings ------------------------------------------------------------------------------

    @mcp.tool()
    async def phone_motion() -> dict:
        """The phone's own motion sensor: tilt_deg from upright (0 standing, 90 lying), roll_deg (sideways lean,
        positive = right), fallen, and motion events (fall, impact, freefall, upright) in the last 60 s."""
        header, _ = await ask("motion", timeout=5)
        return {**fields(header),
                "events": hub.recent_events(60, {"fall", "impact", "freefall", "upright"})}

    @mcp.tool()
    async def phone_events(since_s: float = 120) -> dict:
        """What the phone noticed by itself recently: sounds (clapping, door_bell, knock, dog_bark, baby_crying,
        smoke_detector, glass_breaking, laughter, ...) and motion events (fall, impact, freefall, upright), each
        with ago_s. Newest last."""
        return {"events": hub.recent_events(max(1.0, float(since_s)))}

    # ---- thinking (on-device LFM3) --------------------------------------------------------------------------

    @mcp.tool()
    async def phone_llm(prompt: str, system: str | None = None, max_tokens: int = 256, thinking: bool = False,
                        backend: str = "gpu") -> dict:
        """Run Liquid LFM3-1.7B on the phone (llama.cpp, no cloud): fast, private, offline. Good for short
        classification, extraction, tool-call drafting and quick answers; not for long reasoning. thinking=true lets
        the model reason first (slower; the reasoning comes back in `thinking`). backend: gpu (Metal) or cpu.
        Returns text plus token counts and speed."""
        header, _ = await ask("llm", timeout=LLM_TIMEOUT_S, prompt=prompt, system=system, thinking=bool(thinking),
                              backend="cpu" if backend == "cpu" else "gpu",
                              max_tokens=max(1, min(2048, int(max_tokens))), model="lfm3-1.7b")
        return fields(header)

    @mcp.tool()
    async def phone_look_and_ask(question: str = "Describe what you see.", max_tokens: int = 200,
                                 image_side: int = 512) -> dict:
        """Ask Liquid LFM3-VL-2B on the phone about what the camera sees right now (on-device vision-language
        model, no cloud). image_side (256-1024) trades detail for speed. Returns the answer plus speed stats."""
        header, _ = await ask("llm", timeout=LLM_TIMEOUT_S, prompt=question, image=True, model="lfm3-vl-2b",
                              max_tokens=max(1, min(1024, int(max_tokens))),
                              image_side=max(256, min(1024, int(image_side))))
        return fields(header)

    @mcp.tool()
    async def phone_models() -> dict:
        """The phone's on-device models: downloaded, loaded, download progress (%) and size."""
        header, _ = await ask("models", timeout=5)
        return fields(header)

    @mcp.tool()
    async def phone_model_download(model: str) -> dict:
        """Start downloading an on-device model to the phone (~1 GB from Hugging Face over Wi-Fi): lfm3-1.7b (text)
        or lfm3-vl-2b (vision). Check progress with phone_models."""
        if model not in MODELS:
            raise ToolError(f"unknown model {model!r}; one of {', '.join(MODELS)}")
        header, _ = await ask("model_download", timeout=10, model=model)
        return fields(header)

    # ---- face and voice -------------------------------------------------------------------------------------

    @mcp.tool()
    async def phone_gaze() -> dict:
        """Who is looking at Tony's screen: viewer is where their face is (x right, y down, -1..1, null = nobody),
        eyes is where the drawn eyes are looking, face_tracking says whether the front camera is tracking."""
        header, _ = await ask("gaze", timeout=5)
        return fields(header)

    @mcp.tool()
    async def phone_face_tracking(mode: str = "auto") -> dict:
        """Front-camera face tracking for the eyes: auto (off when the phone is thermally serious), on, or off."""
        if mode not in ("auto", "on", "off"):
            raise ToolError("mode is auto, on or off")
        header, _ = await ask("face_tracking", timeout=5, mode=mode)
        return fields(header)

    @mcp.tool()
    async def phone_say(text: str) -> dict:
        """Speak through the phone's speaker (clearer than Tony's own). Returns when speaking starts."""
        await ask("say", text=text)
        return {"said": text}

    @mcp.tool()
    async def set_face(face: str, seconds: float = 5.0) -> dict:
        """Show an expression on Tony's face (the phone screen) for `seconds`: one of idle, listening, thinking,
        speaking, happy, sad, warn, asleep."""
        if face not in FACES:
            raise ToolError(f"unknown face {face!r}; one of {', '.join(FACES)}")
        await ask("face", face=face, seconds=max(0.5, min(60.0, float(seconds))))
        return {"face": face}

    # ---- companion mode: watching Tony from outside ---------------------------------------------------------

    def rec() -> Recorder:
        if recorder is None:
            raise ToolError("recording is not available in this bridge")
        return recorder

    @mcp.tool()
    async def phone_mode(mode: str | None = None) -> dict:
        """The phone's mode: "mounted" (on Tony: his senses and face) or "companion" (on a stand or in a hand,
        watching Tony from outside: the screen shows the camera instead of a face). Pass mode to switch; the person
        moving the phone should say which. Returns the phone's status."""
        if mode is not None and mode not in ("mounted", "companion"):
            raise ToolError("mode is mounted or companion")
        header, _ = await ask("mode", timeout=5, **({"mode": mode} if mode else {}))
        return fields(header)

    @mcp.tool()
    async def phone_track(target: str = "the small humanoid robot", box: list[float] | None = None,
                          stop: bool = False) -> dict:
        """Follow something in the phone camera at 10 Hz (Vision object tracker): in companion mode, usually Tony.
        Finds `target` with LFM3-VL first (a few seconds), or starts from `box` [x, y, w, h] (0-1, top-left origin,
        e.g. from phone_detect or phone_locate). Re-finds it by itself when lost. Every recorded frame then carries
        the tracked box, distance and world position. stop=true ends tracking."""
        args: dict = {"stop": True} if stop else {"target": target}
        if box and not stop:
            if len(box) != 4:
                raise ToolError("box is [x, y, w, h]")
            args["box"] = [_unit(v) for v in box]
        header, _ = await ask("track", timeout=LLM_TIMEOUT_S, **args)
        return fields(header)

    @mcp.tool()
    async def phone_record(action: str = "start", label: str = "", fps: float = 5, max_s: float = 60,
                           joints_hz: float = 2) -> dict:
        """Record an episode: the phone camera at fps (1-10) plus tonyd state and joint positions at joints_hz
        (0-2; mid-job tonyd answers joints in ~0.5 s, positions can be null), until action="stop" or max_s. Start it, run the move with the tonypi tools, stop it, then
        phone_episode_review. Stopping returns the summary: frames, the jobs that ran (max_tilt_deg, yaw_deg),
        and target_moved_m (how far the tracked target moved on the floor, when phone_track was on)."""
        r = rec()
        try:
            if action == "stop":
                return await r.stop()
            if action != "start":
                raise ToolError("action is start or stop")
            return await r.start(label=label, fps=fps, max_s=max_s, joints_hz=joints_hz)
        except RecorderError as e:
            raise ToolError(str(e)) from e

    @mcp.tool()
    async def phone_record_jobs(on: bool = True, fps: float = 5, joints_hz: float = 2) -> dict:
        """Record every tonyd job automatically (a skill, a pose, your own keyframes): each becomes an episode from
        1 s before it starts to 1 s after it ends, named after the skill. Keeps the phone streaming while on."""
        try:
            return await rec().set_auto(on, fps=fps, joints_hz=joints_hz)
        except RecorderError as e:
            raise ToolError(str(e)) from e

    @mcp.tool()
    async def phone_episodes(limit: int = 10) -> dict:
        """Recorded episodes, newest first: id, label, seconds, frames, the jobs in it (skill, state, max_tilt_deg,
        yaw_deg) and target_moved_m."""
        r = rec()
        return {"episodes": r.list(max(1, min(100, int(limit)))), "recording": r.current.id if r.current else None,
                "auto": r.auto is not None, "folder": str(r.root)}

    @mcp.tool()
    async def phone_episode_review(episode_id: str = "latest", frames: int = 8) -> list:
        """Watch an episode: `frames` (1-16) pictures spread over it in one image, in time order left to right,
        top to bottom, each stamped with its time, the tracked target boxed (green, orange = lost). Plus the
        episode's summary. Use it to judge a move you just ran: direction, clearance, balance, a fall."""
        try:
            jpeg, meta = await asyncio.to_thread(rec().contact_sheet, episode_id, max(1, min(16, int(frames))))
        except RecorderError as e:
            raise ToolError(str(e)) from e
        return [Image(data=jpeg, format="jpeg"), meta]

    @mcp.custom_route("/live", methods=["GET"])
    async def live(request: Request) -> StreamingResponse | JSONResponse:
        """MJPEG of the phone camera for a person (a browser); the phone streams while someone watches."""
        if recorder is None or not hub.connected:
            return JSONResponse({"error": "phone not connected"}, status_code=503)

        async def frames():
            recorder.viewers += 1
            try:
                await recorder.sync_stream()
                while True:
                    async with recorder.new_frame:
                        await asyncio.wait_for(recorder.new_frame.wait(), 10)
                    _, jpeg, _ = recorder.latest
                    yield b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + jpeg + b"\r\n"
            except TimeoutError:
                return
            finally:
                recorder.viewers -= 1
                await recorder.sync_stream()

        return StreamingResponse(frames(), media_type="multipart/x-mixed-replace; boundary=frame")

    # ---- OpenAI-compatible endpoint -------------------------------------------------------------------------

    @mcp.custom_route("/v1/models", methods=["GET"])
    async def openai_models(request: Request) -> JSONResponse:
        return JSONResponse({"object": "list", "data": [{"id": m, "object": "model", "owned_by": "phone"}
                                                        for m in MODELS]})

    @mcp.custom_route("/v1/chat/completions", methods=["POST"])
    async def openai_chat(request: Request) -> JSONResponse:
        """Non-streaming chat completions on the phone. Text only; `image_url` parts are ignored (use
        phone_look_and_ask for the camera)."""
        body = await request.json()
        model = body.get("model") if body.get("model") in MODELS else "lfm3-1.7b"
        messages = [{"role": m.get("role", "user"), "content": _text(m.get("content"))}
                    for m in body.get("messages", []) if m.get("role") in ("system", "user", "assistant")]
        if not any(m["role"] == "user" for m in messages):
            return JSONResponse({"error": {"message": "no user message"}}, status_code=400)
        try:
            header, _ = await hub.request("llm", timeout=LLM_TIMEOUT_S, model=model, messages=messages,
                                          thinking=bool(body.get("thinking", False)),
                                          max_tokens=max(1, min(2048, int(body.get("max_tokens") or 256))))
        except PhoneError as e:
            return JSONResponse({"error": {"message": str(e)}}, status_code=503)
        return JSONResponse({
            "id": f"chatcmpl-{uuid.uuid4().hex[:12]}", "object": "chat.completion", "created": int(time.time()),
            "model": header.get("model", model),
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": header.get("text", "")}}],
            "usage": {"prompt_tokens": header.get("prompt_tokens", 0),
                      "completion_tokens": header.get("generated_tokens", 0),
                      "total_tokens": header.get("prompt_tokens", 0) + header.get("generated_tokens", 0)},
        })

    return mcp


def _text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):  # OpenAI content parts
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
    return ""


def _unit(v: float) -> float:
    return max(0.0, min(1.0, float(v)))
