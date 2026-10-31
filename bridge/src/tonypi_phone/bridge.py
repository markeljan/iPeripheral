"""The phone's WebSocket endpoint: auth/pairing, then relay between the phone and the robot (docs/protocol.md)."""

from __future__ import annotations

import asyncio
import json
import logging
import time

from websockets.exceptions import ConnectionClosed

from tonypi_phone import __version__
from tonypi_phone.hub import PhoneHub, unpack_frame
from tonypi_phone.links import AgentLink, LinkDown, TonydError, TonydLink, VoiceLink
from tonypi_phone.pairing import CODE_TTL_S, PairingAttempt, TokenStore
from tonypi_phone.recorder import Recorder

log = logging.getLogger(__name__)
PROTOCOL = 1
AUTH_TIMEOUT_S = 10
STATE_EVERY_S = 1.0
CLOSE_AUTH = 4401


class Bridge:
    def __init__(self, tokens: TokenStore, tonyd_sock: str | None = None, agent_sock: str | None = None,
                 voice_sock: str | None = None, episodes=None) -> None:
        self.hub = PhoneHub()
        self.tokens = tokens
        kw = {} if tonyd_sock is None else {"path": tonyd_sock}
        self.tonyd = TonydLink(self._on_tonyd, **kw)
        kw = {} if agent_sock is None else {"path": agent_sock}
        self.agent = AgentLink(self._relay("agent_event"), **kw)
        kw = {} if voice_sock is None else {"path": voice_sock}
        self.voice = VoiceLink(**kw)
        self.recorder = Recorder(self.hub, self.tonyd, **({} if episodes is None else {"root": episodes}))
        self._tasks: set[asyncio.Task] = set()

    def _relay(self, type_: str):
        def on_event(event: dict) -> None:
            self._spawn(self.hub.push({"type": type_, "event": event}))
        return on_event

    def _on_tonyd(self, event: dict) -> None:
        self.recorder.on_tonyd_event(event)
        self._spawn(self.hub.push({"type": "robot_event", "event": event}))

    # ---- speaking and commands: tonypi-voice when it runs (live mode and the harnesses), else tonypi-agent ----

    async def speak(self, text: str) -> None:
        if self.voice.connected.is_set():
            try:
                await self.voice.call("say", timeout=5, text=text)
                return
            except TonydError as e:
                log.info("voice say: %s; trying the agent", e)
        await self.agent.say(text)

    async def command(self, text: str) -> None:
        """A command the phone heard ("Tony, wave"). With tonypi-voice up and the phone on Tony, the voice service
        heard the same words itself, so passing it on would run it twice: only a companion phone (across the room)
        forwards to voice. Only live mode takes `text`; other voice modes fall through to the agent."""
        if self.voice.connected.is_set():
            if self.hub.status.get("mode") != "companion":
                log.info("not forwarding %r: tonypi-voice hears Tony's own mic", text)
                return
            try:
                r = await self.voice.call("text", timeout=10, text=text, source="phone_mic")
                if r.get("dropped"):  # Tony's own mic heard it too (live.py waits 2.5 s to check): handled
                    log.info("voice dropped %r: %s", text, r["dropped"])
                return
            except TonydError as e:
                log.info("voice text: %s; trying the agent", e)
        await self.agent.command(text)

    def _spawn(self, coro) -> None:
        t = asyncio.get_running_loop().create_task(coro)
        self._tasks.add(t)
        t.add_done_callback(self._tasks.discard)

    async def run_links(self) -> None:
        await asyncio.gather(self.tonyd.run(), self.agent.run(), self.voice.run())

    # ---- connection ---------------------------------------------------------------------------------------------

    async def handler(self, ws) -> None:
        peer = getattr(ws, "remote_address", None)
        try:
            device = await self._authenticate(ws)
        except (ConnectionClosed, TimeoutError, ValueError) as e:
            log.info("phone %s not authenticated: %s", peer, e)
            await ws.close(CLOSE_AUTH, "not authenticated")
            return
        if device is None:
            await ws.close(CLOSE_AUTH, "not authenticated")
            return
        log.info("phone connected: %s (%s)", device, peer)
        await self.hub.attach(ws, device)
        self._spawn(self._push_vocabulary())
        self._spawn(self.recorder.sync_stream(force=True))  # a recording or live view outlives a reconnect
        pusher = asyncio.create_task(self._push_state())
        try:
            async for raw in ws:
                try:
                    await self._on_phone(ws, raw)
                except Exception:
                    log.exception("bad phone message")
        except ConnectionClosed:
            pass
        finally:
            pusher.cancel()
            self.hub.detach(ws)
            log.info("phone disconnected: %s", device)

    async def _authenticate(self, ws) -> str | None:
        """Returns the device name once authenticated, or None after telling the phone why not."""
        first = json.loads(await asyncio.wait_for(ws.recv(), AUTH_TIMEOUT_S))
        device = str(first.get("device", "phone"))
        welcome = {"type": "welcome", "v": PROTOCOL, "robot": "tonypi", "bridge": __version__}
        if first.get("type") == "hello":
            if self.tokens.check(str(first.get("token", ""))):
                await ws.send(json.dumps(welcome))
                return device
            await ws.send(json.dumps({"type": "error", "error": "bad token"}))
            return None
        if first.get("type") != "pair_request":
            await ws.send(json.dumps({"type": "error", "error": "send hello or pair_request first"}))
            return None

        attempt = PairingAttempt()
        log.warning("pairing code for %s: %s (valid %d s)", device, attempt.code, CODE_TTL_S)
        try:
            await self.speak(attempt.spoken)
        except LinkDown:
            log.warning("agent not running, so the code was not spoken; read it from this log")
        await ws.send(json.dumps({"type": "pair_code_sent"}))
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), CODE_TTL_S + 10))
            if msg.get("type") != "pair_confirm":
                continue
            if attempt.confirm(str(msg.get("code", ""))):
                token = self.tokens.issue(device)
                await ws.send(json.dumps({**welcome, "token": token}))
                log.warning("paired %s", device)
                return device
            if attempt.expired() or attempt.tries_left <= 0:
                await ws.send(json.dumps({"type": "error", "error": "pairing failed, start again", "tries_left": 0}))
                return None
            await ws.send(json.dumps({"type": "error", "error": "wrong code", "tries_left": attempt.tries_left}))

    # ---- phone → robot ------------------------------------------------------------------------------------------

    async def _on_phone(self, ws, raw: str | bytes) -> None:
        if isinstance(raw, bytes):
            header, payload = unpack_frame(raw)
            if header.get("type") == "reply":
                self.hub.on_reply(ws, header, payload)
            elif header.get("type") == "frame":
                self.hub.on_frame(header, payload)
            return
        msg = json.loads(raw)
        t = msg.get("type")
        if t == "stop":
            log.warning("stop from phone")
            try:
                await self.tonyd.call("stop", timeout=2)
            except TonydError as e:
                log.error("stop failed: %s", e)
        elif t == "command":
            text = str(msg.get("text", "")).strip()
            if text:
                try:
                    await self.command(text)
                except LinkDown as e:
                    await self.hub.push({"type": "error", "error": str(e)})
        elif t == "pose":
            self.hub.pose = msg | {"t": time.monotonic()}
        elif t == "event":
            self.hub.events.append(msg | {"t": time.monotonic()})
            level = logging.WARNING if msg.get("kind") in ("fall", "impact", "freefall") else logging.INFO
            log.log(level, "phone event: %s", {k: v for k, v in msg.items() if k != "type"})
        elif t == "transcript":
            log.info("phone heard: %s", msg.get("text", ""))
        elif t == "status":
            self.hub.status = {k: v for k, v in msg.items() if k != "type"}
        elif t == "reply":
            self.hub.on_reply(ws, msg)

    async def _push_vocabulary(self) -> None:
        """Skill names, so the phone's speech recognition expects them ("step in place", not "step and place")."""
        try:
            skills = (await self.tonyd.call("skills", timeout=3)).get("skills", [])
        except TonydError as e:
            log.debug("skills: %s", e)
            return
        names = [s if isinstance(s, str) else s.get("name", "") for s in skills]
        words = sorted({n.replace("_", " ") for n in names if n})
        await self.hub.push({"type": "vocabulary", "words": words})

    async def _push_state(self) -> None:
        while True:
            try:
                st = await self.tonyd.call("state", timeout=2)
                await self.hub.push({"type": "robot_state", "state": st["state"]})
            except TonydError as e:
                log.debug("state: %s", e)
            await asyncio.sleep(STATE_EVERY_S)
