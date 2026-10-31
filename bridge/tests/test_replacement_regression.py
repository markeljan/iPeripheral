"""Local fake-phone regression: replacement should release old requests."""
import asyncio
import json

import pytest

from test_bridge import rig, authed, recv_type
from tonypi_phone.hub import PhoneError


async def test_replacement_fails_old_inflight_request_promptly(rig):
    bridge, _, _, url = rig
    old = await authed(bridge, url)
    pending = asyncio.create_task(bridge.hub.request("snapshot", timeout=3))
    try:
        await recv_type(old, "request")
        new = await authed(bridge, url)
        try:
            await old.wait_closed()
            with pytest.raises(PhoneError, match="disconnected|replaced"):
                await asyncio.wait_for(asyncio.shield(pending), timeout=0.3)
        finally:
            await new.close()
    finally:
        pending.cancel()
        await asyncio.gather(pending, return_exceptions=True)
        await old.close()


class ControlledSocket:
    def __init__(self):
        self.sent = asyncio.Queue()
        self.close_started = asyncio.Event()
        self.finish_close = asyncio.Event()

    async def send(self, message):
        await self.sent.put(json.loads(message))

    async def close(self, *args):
        self.close_started.set()
        await self.finish_close.wait()


@pytest.mark.parametrize("binary", [False, True])
async def test_replacement_preserves_new_request_and_rejects_stale_reply(rig, binary):
    from tonypi_phone.hub import pack_frame

    bridge, _, _, _ = rig
    old, new = ControlledSocket(), ControlledSocket()
    await bridge.hub.attach(old, "old")
    old_request = asyncio.create_task(bridge.hub.request("old"))
    await old.sent.get()
    replacing = asyncio.create_task(bridge.hub.attach(new, "new"))
    await old.close_started.wait()
    with pytest.raises(PhoneError, match="disconnected"):
        await old_request
    new_request = asyncio.create_task(bridge.hub.request("new"))
    request = await new.sent.get()
    reply = {"type": "reply", "rid": request["rid"], "ok": True}
    raw = pack_frame(reply, b"new") if binary else json.dumps(reply)
    await bridge._on_phone(old, raw)
    bridge.hub.detach(old)
    assert not new_request.done()
    await bridge._on_phone(new, raw)
    assert await new_request == (reply, b"new" if binary else None)
    old.finish_close.set()
    await replacing
    assert bridge.hub.connected
    bridge.hub.detach(new)


async def test_cancelled_request_and_normal_disconnect_clean_up(rig):
    bridge, _, _, _ = rig
    ws = ControlledSocket()
    await bridge.hub.attach(ws, "phone")
    cancelled = asyncio.create_task(bridge.hub.request("cancel"))
    await ws.sent.get()
    cancelled.cancel()
    with pytest.raises(asyncio.CancelledError):
        await cancelled
    assert not bridge.hub._pending
    pending = asyncio.create_task(bridge.hub.request("disconnect"))
    await ws.sent.get()
    bridge.hub.detach(ws)
    with pytest.raises(PhoneError, match="disconnected"):
        await pending
    assert not bridge.hub.connected and not bridge.hub._pending
