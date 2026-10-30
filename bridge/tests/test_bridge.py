"""Bridge end to end with fake tonyd + agent sockets and a real WebSocket client playing the phone."""

from __future__ import annotations

import asyncio
import json
import shutil
import tempfile
from pathlib import Path

import pytest
from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

from tonypi_phone.bridge import Bridge
from tonypi_phone.hub import pack_frame, unpack_frame
from tonypi_phone.mcp_tools import build_mcp
from tonypi_phone.pairing import PairingAttempt, TokenStore

STATE = {"busy": False, "job": None, "tilt_deg": 2.0, "lying": False, "asleep": False, "battery_mv": 11560}


class FakeSocket:
    """A JSON-lines Unix socket server that records what it receives; `reply(msg)` decides the answer."""

    def __init__(self, path: str, reply) -> None:
        self.path, self.reply = path, reply
        self.got: list[dict] = []
        self.writers: list[asyncio.StreamWriter] = []

    async def start(self) -> None:
        self.server = await asyncio.start_unix_server(self._client, self.path)

    async def _client(self, reader, writer) -> None:
        self.writers.append(writer)
        async for line in reader:
            msg = json.loads(line)
            self.got.append(msg)
            out = self.reply(msg)
            if out is not None:
                writer.write((json.dumps(out) + "\n").encode())
                await writer.drain()

    async def broadcast(self, msg: dict) -> None:
        for w in self.writers:
            w.write((json.dumps(msg) + "\n").encode())
            await w.drain()


def tonyd_reply(msg: dict) -> dict:
    base = {"rid": msg.get("rid"), "ok": True}
    if msg["op"] == "state":
        return {**base, "state": STATE}
    if msg["op"] == "stop":
        return {**base, "stopped": True}
    if msg["op"] == "skills":
        return {**base, "skills": ["wave", "step_in_place", {"name": "get_up"}]}
    return {**base, "subscribed": True}


@pytest.fixture
async def rig(monkeypatch):
    d = Path(tempfile.mkdtemp(prefix="tp"))  # Unix socket paths must stay short on macOS
    tonyd = FakeSocket(str(d / "tonyd.sock"), tonyd_reply)
    agent = FakeSocket(str(d / "agent.sock"), lambda m: {"type": "accepted", "id": 1})
    await tonyd.start()
    await agent.start()
    monkeypatch.setattr("tonypi_phone.links.RECONNECT_S", 0.05)
    bridge = Bridge(TokenStore(d / "tokens.json"), tonyd_sock=tonyd.path, agent_sock=agent.path)
    links = asyncio.create_task(bridge.run_links())
    await asyncio.wait_for(asyncio.gather(bridge.tonyd.connected.wait(), bridge.agent.connected.wait()), 2)
    server = await serve(bridge.handler, "127.0.0.1", 0)
    url = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/"
    yield bridge, tonyd, agent, url
    server.close()
    links.cancel()
    shutil.rmtree(d, ignore_errors=True)


async def recv_type(ws, type_: str, timeout: float = 2.0) -> dict:
    async def loop():
        while True:
            msg = json.loads(await ws.recv())
            if msg["type"] == type_:
                return msg
    return await asyncio.wait_for(loop(), timeout)


async def pair(bridge, agent, url) -> str:
    async with connect(url) as ws:
        await ws.send(json.dumps({"type": "pair_request", "v": 1, "device": "test phone"}))
        await recv_type(ws, "pair_code_sent")
        said = next(m for m in agent.got if m.get("op") == "say")["text"]
        code = said.split("is ")[1].split(".")[0].replace(" ", "")
        await ws.send(json.dumps({"type": "pair_confirm", "code": "000000" if code != "000000" else "111111"}))
        wrong = await recv_type(ws, "error")
        assert wrong["tries_left"] == 2
        await ws.send(json.dumps({"type": "pair_confirm", "code": code}))
        return (await recv_type(ws, "welcome"))["token"]


async def test_pairing_then_token_login(rig):
    bridge, tonyd, agent, url = rig
    token = await pair(bridge, agent, url)
    assert bridge.tokens.check(token)
    assert token not in (Path(bridge.tokens.path).read_text())  # only the hash is stored
    async with connect(url) as ws:
        await ws.send(json.dumps({"type": "hello", "v": 1, "token": token, "device": "test phone"}))
        welcome = await recv_type(ws, "welcome")
        assert "token" not in welcome


async def test_bad_token_is_closed(rig):
    _, _, _, url = rig
    async with connect(url) as ws:
        await ws.send(json.dumps({"type": "hello", "v": 1, "token": "nope"}))
        assert (await recv_type(ws, "error"))["error"] == "bad token"
        with pytest.raises(ConnectionClosed) as e:
            await ws.recv()
        assert e.value.rcvd.code == 4401


async def test_anything_before_auth_is_refused(rig):
    _, tonyd, _, url = rig
    async with connect(url) as ws:
        await ws.send(json.dumps({"type": "stop"}))
        await recv_type(ws, "error")
    assert not any(m.get("op") == "stop" for m in tonyd.got)


async def test_relay_both_ways(rig):
    bridge, tonyd, agent, url = rig
    token = bridge.tokens.issue("test phone")
    async with connect(url) as ws:
        await ws.send(json.dumps({"type": "hello", "v": 1, "token": token}))
        await recv_type(ws, "welcome")
        assert (await recv_type(ws, "vocabulary"))["words"] == ["get up", "step in place", "wave"]
        assert (await recv_type(ws, "robot_state"))["state"]["battery_mv"] == 11560

        await ws.send(json.dumps({"type": "stop"}))
        await ws.send(json.dumps({"type": "command", "text": "wave"}))
        await ws.send(json.dumps({"type": "status", "battery": 0.8, "thermal": "nominal"}))
        await asyncio.sleep(0.1)
        assert any(m.get("op") == "stop" for m in tonyd.got)
        assert {"text": "wave"} in agent.got
        assert bridge.hub.status["battery"] == 0.8

        await tonyd.broadcast({"event": "warn", "text": "battery low"})
        assert (await recv_type(ws, "robot_event"))["event"]["text"] == "battery low"
        await agent.broadcast({"type": "heard", "text": "wave"})
        assert (await recv_type(ws, "agent_event"))["event"]["type"] == "heard"


async def test_snapshot_request_over_binary_frame(rig):
    bridge, _, _, url = rig
    token = bridge.tokens.issue("test phone")
    mcp = build_mcp(bridge.hub)
    async with connect(url) as ws:
        await ws.send(json.dumps({"type": "hello", "v": 1, "token": token}))
        await recv_type(ws, "welcome")

        async def phone():
            req = await recv_type(ws, "request")
            assert req["op"] == "snapshot" and req["max_side"] == 640
            await ws.send(pack_frame({"type": "reply", "rid": req["rid"], "ok": True, "mime": "image/jpeg"},
                                      b"\xff\xd8jpeg"))

        answer = asyncio.create_task(phone())
        header, payload = await bridge.hub.request("snapshot", max_side=640)
        await answer
        assert header["mime"] == "image/jpeg" and payload == b"\xff\xd8jpeg"
        names = {t.name for t in await mcp.list_tools()}
        assert names == {"phone_status", "phone_snapshot", "phone_say", "set_face", "phone_depth_at",
                         "phone_obstacles", "phone_pose", "phone_reset_origin", "phone_detect", "phone_find",
                         "phone_read_text", "phone_ground_check", "phone_motion", "phone_events", "phone_llm",
                         "phone_look_and_ask", "phone_models", "phone_model_download", "phone_gaze",
                         "phone_face_tracking"}


async def test_newer_phone_replaces_older(rig):
    bridge, _, _, url = rig
    token = bridge.tokens.issue("test phone")
    async with connect(url) as old, connect(url) as new:
        for ws in (old, new):
            await ws.send(json.dumps({"type": "hello", "v": 1, "token": token}))
            await recv_type(ws, "welcome")
        with pytest.raises(ConnectionClosed):
            await asyncio.wait_for(recv_type(old, "never"), 2)
        assert bridge.hub.connected


def test_pairing_attempt_rules():
    a = PairingAttempt(now=0)
    assert not a.confirm("x", now=1) and a.tries_left == 2
    assert not a.confirm(a.code, now=10_000)  # expired
    b = PairingAttempt(now=0)
    for _ in range(3):
        b.confirm("x", now=1)
    assert not b.confirm(b.code, now=1)  # out of tries


def test_frame_round_trip():
    header, payload = unpack_frame(pack_frame({"type": "reply", "rid": 1}, b"abc"))
    assert header == {"type": "reply", "rid": 1} and payload == b"abc"


async def test_obstacles_tool_shapes_the_depth_grid(rig):
    bridge, _, _, url = rig
    token = bridge.tokens.issue("test phone")
    mcp = build_mcp(bridge.hub)
    async with connect(url) as ws:
        await ws.send(json.dumps({"type": "hello", "v": 1, "token": token}))
        await recv_type(ws, "welcome")

        async def phone():
            req = await recv_type(ws, "request")
            assert req["op"] == "depth" and req["grid"] == [3, 3]
            grid = [[None, 2.5, 3.0], [1.2, 0.8, None], [0.5, 0.45, 0.6]]
            await ws.send(json.dumps({"type": "reply", "rid": req["rid"], "ok": True, "grid": grid}))

        answer = asyncio.create_task(phone())
        result = await mcp.call_tool("phone_obstacles", {})
        await answer
        text = json.dumps(result, default=lambda o: getattr(o, "text", str(o)))
        assert '\\"nearest_m\\": 0.45' in text and '\\"centre\\": 0.8' in text


async def authed(bridge, url):
    token = bridge.tokens.issue("test phone")
    ws = await connect(url)
    await ws.send(json.dumps({"type": "hello", "v": 1, "token": token}))
    await recv_type(ws, "welcome")
    return ws


def tool_json(result) -> dict:
    """MCPServer.call_tool result -> the tool's dict (first text content)."""
    return json.loads(result.content[0].text)


async def test_pose_stream_is_cached_and_events_kept(rig):
    bridge, _, _, url = rig
    mcp = build_mcp(bridge.hub)
    ws = await authed(bridge, url)
    await ws.send(json.dumps({"type": "pose", "x": 1.0, "y": 0.2, "z": -0.5, "yaw_deg": 30.5, "tracking": "normal"}))
    await ws.send(json.dumps({"type": "event", "kind": "fall", "value": 75, "tilt_deg": 75}))
    await ws.send(json.dumps({"type": "event", "kind": "sound", "label": "clapping", "confidence": 0.9}))
    await asyncio.sleep(0.1)
    pose = tool_json(await mcp.call_tool("phone_pose", {}))  # no request to the phone: answered from the stream
    assert pose["yaw_deg"] == 30.5 and pose["tracking"] == "normal" and pose["age_s"] < 0.5
    events = tool_json(await mcp.call_tool("phone_events", {}))["events"]
    assert [e["kind"] for e in events] == ["fall", "sound"] and events[1]["label"] == "clapping"
    await ws.close()


async def test_find_picks_nearest_matching_object(rig):
    bridge, _, _, url = rig
    mcp = build_mcp(bridge.hub)
    ws = await authed(bridge, url)

    async def phone():
        req = await recv_type(ws, "request")
        assert req["op"] == "detect" and req["kinds"] == ["objects", "animals"]
        objs = [{"kind": "objects", "label": "sports ball", "x": 0.1, "y": 0.5, "w": 0.1, "h": 0.1, "m": 3.0,
                 "bearing_deg": 20},
                {"kind": "objects", "label": "sports ball", "x": 0.6, "y": 0.6, "w": 0.1, "h": 0.1, "m": 1.2,
                 "bearing_deg": -8},
                {"kind": "objects", "label": "cup", "x": 0.5, "y": 0.5, "w": 0.1, "h": 0.1, "m": 0.5}]
        await ws.send(json.dumps({"type": "reply", "rid": req["rid"], "ok": True, "objects": objs}))

    answer = asyncio.create_task(phone())
    found = tool_json(await mcp.call_tool("phone_find", {"target": "ball"}))
    await answer
    assert found["found"] and found["matches"] == 2 and found["m"] == 1.2 and found["bearing_deg"] == -8
    await ws.close()


async def test_openai_chat_completions_runs_on_the_phone(rig):
    import httpx2 as httpx  # what the mcp SDK ships
    bridge, _, _, url = rig
    app = build_mcp(bridge.hub).streamable_http_app()
    ws = await authed(bridge, url)

    async def phone():
        req = await recv_type(ws, "request")
        assert req["op"] == "llm" and req["model"] == "lfm3-1.7b"
        assert req["messages"] == [{"role": "system", "content": "be brief"}, {"role": "user", "content": "hi"}]
        await ws.send(json.dumps({"type": "reply", "rid": req["rid"], "ok": True, "text": "Hello!",
                                  "model": "lfm3-1.7b", "prompt_tokens": 12, "generated_tokens": 3}))

    answer = asyncio.create_task(phone())
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
        r = await client.post("/v1/chat/completions", json={"model": "lfm3-1.7b", "messages": [
            {"role": "system", "content": "be brief"}, {"role": "user", "content": [{"type": "text", "text": "hi"}]}]})
    await answer
    body = r.json()
    assert r.status_code == 200 and body["choices"][0]["message"]["content"] == "Hello!"
    assert body["usage"]["total_tokens"] == 15
    await ws.close()
