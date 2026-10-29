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
        assert names == {"phone_status", "phone_snapshot", "phone_say", "set_face"}


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
