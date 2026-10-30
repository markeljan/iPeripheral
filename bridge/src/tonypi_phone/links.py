"""Clients for the robot's Unix sockets (JSON lines): tonyd (body, camera), tonypi-voice (speech and the live brain)
and tonypi-agent (the older voice front end; commands, speech). Voice and agent never run together.

The protocols belong to the tonypi repo (tonyd/server.py, voice/service.py, agent/daemon.py); this file is the only
place that knows them, so a change there is a change here. All links stay connected and reconnect every 2 s.
"""

from __future__ import annotations

import asyncio
import itertools
import json
import logging
import os
from collections.abc import Awaitable, Callable

log = logging.getLogger(__name__)

TONYD_SOCK = os.environ.get("TONYD_SOCK", "/run/tonypi/tonyd.sock")
AGENT_SOCK = os.environ.get("TONYPI_SOCK", "/run/tonypi/agent.sock")
VOICE_SOCK = os.environ.get("TONYPI_VOICE_SOCK", "/run/tonypi/voice.sock")
RECONNECT_S = 2.0


class LinkDown(RuntimeError):
    pass


class TonydError(RuntimeError):
    pass


class JsonlLink:
    """A persistent JSON-lines connection; every incoming object goes to `on_message`."""

    def __init__(self, path: str, on_message: Callable[[dict], None],
                 on_connect: Callable[[], Awaitable[None]] | None = None, name: str = "") -> None:
        self.path, self.name = path, name or os.path.basename(path)
        self.on_message, self.on_connect = on_message, on_connect
        self._writer: asyncio.StreamWriter | None = None
        self.connected = asyncio.Event()

    async def run(self) -> None:
        while True:
            try:
                reader, writer = await asyncio.open_unix_connection(self.path, limit=1 << 20)
            except OSError as e:
                log.debug("%s not reachable: %s", self.name, e)
                await asyncio.sleep(RECONNECT_S)
                continue
            self._writer = writer
            log.info("connected to %s", self.name)
            try:
                if self.on_connect:
                    await self.on_connect()
                self.connected.set()
                async for line in reader:
                    if line.strip():
                        try:
                            self.on_message(json.loads(line))
                        except Exception:
                            log.exception("%s: bad message %r", self.name, line[:200])
            except OSError:
                pass
            finally:
                self.connected.clear()
                self._writer = None
                writer.close()
                log.warning("lost %s", self.name)
                self.on_disconnect()
            await asyncio.sleep(RECONNECT_S)

    def on_disconnect(self) -> None:
        pass

    async def send(self, obj: dict) -> None:
        if self._writer is None:
            raise LinkDown(f"{self.name} not connected")
        self._writer.write((json.dumps(obj) + "\n").encode())
        await self._writer.drain()


class RpcLink(JsonlLink):
    """Request/reply by `rid` ({"op", "rid", ...} -> {"rid", "ok", ...}); lines with "event" go to `on_event`."""

    def __init__(self, path: str, name: str, on_event: Callable[[dict], None] | None = None,
                 on_connect: Callable[[], Awaitable[None]] | None = None) -> None:
        super().__init__(path, self._on_message, on_connect, name)
        self.on_event = on_event or (lambda e: None)
        self._rids = itertools.count(1)
        self._pending: dict[int, asyncio.Future] = {}

    def _on_message(self, msg: dict) -> None:
        if "event" in msg:
            self.on_event(msg)
            return
        fut = self._pending.pop(msg.get("rid"), None)
        if fut is not None and not fut.done():
            fut.set_result(msg)

    def on_disconnect(self) -> None:
        for fut in self._pending.values():
            if not fut.done():
                fut.set_exception(TonydError(f"connection to {self.name} lost"))
        self._pending.clear()

    async def call(self, op: str, timeout: float = 10.0, **kw) -> dict:
        rid = next(self._rids)
        fut = asyncio.get_running_loop().create_future()
        self._pending[rid] = fut
        try:
            await self.send({"op": op, "rid": rid, **kw})
            msg = await asyncio.wait_for(fut, timeout)
        except LinkDown as e:
            raise TonydError(str(e)) from e
        except TimeoutError as e:
            raise TonydError(f"{self.name} did not answer {op} within {timeout} s") from e
        finally:
            self._pending.pop(rid, None)
        if not msg.get("ok"):
            raise TonydError(msg.get("error", "error"))
        return {k: v for k, v in msg.items() if k not in ("ok", "rid")}


class TonydLink(RpcLink):
    """tonyd: request/reply, plus the `job`/`warn` event stream (subscribed on every connect)."""

    def __init__(self, on_event: Callable[[dict], None], path: str = TONYD_SOCK) -> None:
        super().__init__(path, "tonyd", on_event, self._subscribe)

    async def _subscribe(self) -> None:
        await self.send({"op": "subscribe", "rid": 0})


class VoiceLink(RpcLink):
    """tonypi-voice: `say` speaks (GPT-Live or Piper), `text` hands a request to the live brain. Never `attach`:
    that would make the bridge the brain and detach the real one."""

    def __init__(self, path: str = VOICE_SOCK) -> None:
        super().__init__(path, "voice")


class AgentLink(JsonlLink):
    """tonypi-agent: send text commands or `say`; every connected client receives the agent's events."""

    def __init__(self, on_event: Callable[[dict], None], path: str = AGENT_SOCK) -> None:
        super().__init__(path, self._on_message, name="agent")
        self.on_event = on_event

    def _on_message(self, msg: dict) -> None:
        if msg.get("type") != "accepted":  # acks go only to the sender; events go to everyone
            self.on_event(msg)

    async def command(self, text: str) -> None:
        await self.send({"text": text})

    async def say(self, text: str) -> None:
        await self.send({"op": "say", "text": text})
