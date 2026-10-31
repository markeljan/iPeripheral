"""The connected phone: one at a time. Pushes messages to it and turns `request`/`reply` into awaitable calls."""

from __future__ import annotations

import asyncio
import collections
import itertools
import json
import logging
import struct
import time
from collections.abc import Callable

log = logging.getLogger(__name__)


class PhoneError(RuntimeError):
    pass


def pack_frame(header: dict, payload: bytes) -> bytes:
    """Binary frame: [u32 BE header length][header JSON][payload] (docs/protocol.md)."""
    h = json.dumps(header, separators=(",", ":")).encode()
    return struct.pack(">I", len(h)) + h + payload


def unpack_frame(data: bytes) -> tuple[dict, bytes]:
    if len(data) < 4:
        raise ValueError("binary frame too short")
    (n,) = struct.unpack(">I", data[:4])
    if len(data) < 4 + n:
        raise ValueError("binary frame header length past the end")
    return json.loads(data[4 : 4 + n]), data[4 + n :]


class PhoneHub:
    def __init__(self) -> None:
        self.ws = None
        self.device: str | None = None
        self.status: dict = {}
        self.pose: dict | None = None  # latest streamed pose, with "t" = time.monotonic() when it arrived
        self.events: collections.deque[dict] = collections.deque(maxlen=100)  # falls, impacts, sounds; newest last
        self.on_frame: Callable[[dict, bytes], None] = lambda header, jpeg: None  # streamed camera frames
        self._rids = itertools.count(1)
        self._pending: dict[int, tuple[object, asyncio.Future]] = {}

    @property
    def connected(self) -> bool:
        return self.ws is not None

    async def attach(self, ws, device: str) -> None:
        """A newly authenticated phone replaces the old one."""
        old = self.ws
        self.ws, self.device, self.status, self.pose = ws, device, {}, None
        if old is not None and old is not ws:
            self._fail_pending(old)
            await old.close(4000, "replaced by a newer connection")

    def detach(self, ws) -> None:
        if self.ws is not ws:
            return
        self.ws = None
        self._fail_pending(ws)

    def _fail_pending(self, ws) -> None:
        for rid, (owner, fut) in list(self._pending.items()):
            if owner is not ws:
                continue
            if not fut.done():
                fut.set_exception(PhoneError("phone disconnected"))
            self._pending.pop(rid, None)

    async def push(self, msg: dict) -> None:
        """Best effort: a phone that just left is not an error."""
        ws = self.ws
        if ws is None:
            return
        try:
            await ws.send(json.dumps(msg))
        except Exception as e:  # ConnectionClosed and friends
            log.debug("push failed: %s", e)

    async def request(self, op: str, timeout: float = 10.0, **args) -> tuple[dict, bytes | None]:
        ws = self.ws
        if ws is None:
            raise PhoneError("Tony's phone is not connected")
        rid = next(self._rids)
        fut = asyncio.get_running_loop().create_future()
        self._pending[rid] = (ws, fut)
        try:
            await ws.send(json.dumps({"type": "request", "rid": rid, "op": op, **args}))
            header, payload = await asyncio.wait_for(fut, timeout)
        except TimeoutError as e:
            raise PhoneError(f"phone did not answer {op} within {timeout} s") from e
        finally:
            self._pending.pop(rid, None)
        if not header.get("ok"):
            raise PhoneError(header.get("error", "error"))
        return header, payload

    def fresh_pose(self, max_age_s: float = 0.5) -> dict | None:
        if self.pose is None or time.monotonic() - self.pose["t"] > max_age_s:
            return None
        return {k: v for k, v in self.pose.items() if k not in ("type", "t")} | {
            "age_s": round(time.monotonic() - self.pose["t"], 3)}

    def recent_events(self, since_s: float, kinds: set[str] | None = None) -> list[dict]:
        now = time.monotonic()
        return [{k: v for k, v in e.items() if k not in ("type", "t")} | {"ago_s": round(now - e["t"], 1)}
                for e in self.events if now - e["t"] <= since_s and (kinds is None or e.get("kind") in kinds)]

    def on_reply(self, ws, header: dict, payload: bytes | None = None) -> None:
        pending = self._pending.get(header.get("rid"))
        if pending is not None:
            owner, fut = pending
            if owner is ws and not fut.done():
                fut.set_result((header, payload))
