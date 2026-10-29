"""A fake TonyPi for developing the phone link off the robot: tonyd + agent sockets that answer like the real ones.

Skills take a few seconds and emit `job` events; `stop` ends them. The agent echoes commands as `heard`/`say`/`done`
events and logs what it would speak (so the pairing code shows up here). Usage: tonypi-fake-robot DIR
"""

from __future__ import annotations

import argparse
import asyncio
import itertools
import json
import logging
import time
from pathlib import Path

log = logging.getLogger("fake-robot")
SKILLS = {"stand": 1.5, "wave": 3.0, "bow": 3.0, "step_in_place": 6.0, "walk_forward": 5.0, "turn_left": 3.0,
          "turn_right": 3.0, "get_up": 6.0, "sit": 2.0}


class Clients:
    def __init__(self) -> None:
        self.writers: set[asyncio.StreamWriter] = set()

    async def send(self, w: asyncio.StreamWriter, msg: dict) -> None:
        try:
            w.write((json.dumps(msg) + "\n").encode())
            await w.drain()
        except OSError:
            self.writers.discard(w)

    async def broadcast(self, msg: dict) -> None:
        for w in list(self.writers):
            await self.send(w, msg)


class FakeTonyd:
    def __init__(self) -> None:
        self.subs = Clients()
        self.job: dict | None = None
        self._ids = itertools.count(1)
        self._runner: asyncio.Task | None = None
        self.started = time.monotonic()

    def state(self) -> dict:
        drain = (time.monotonic() - self.started) * 0.2  # mV per second, so the battery visibly drops
        return {"busy": self.job is not None, "job": self.job, "tilt_deg": 1.5, "lying": False, "asleep": False,
                "battery_mv": round(11800 - drain), "torque_on": 16, "hottest": [6, "left elbow", 41],
                "camera": {"ok": True}, "fake": True}

    async def _run(self, skill: str, seconds: float) -> None:
        self.job = {"id": next(self._ids), "skill": skill, "state": "running"}
        await self.subs.broadcast({"event": "job", "job": dict(self.job)})
        try:
            await asyncio.sleep(seconds)
            self.job["state"] = "done"
        except asyncio.CancelledError:
            self.job["state"] = "stopped"
        await self.subs.broadcast({"event": "job", "job": dict(self.job)})
        log.info("job %s %s", skill, self.job["state"])
        self.job = None

    async def handle(self, msg: dict, w: asyncio.StreamWriter) -> dict:
        op = msg.get("op")
        if op == "ping":
            return {"pong": True}
        if op == "skills":
            return {"skills": sorted(SKILLS)}
        if op == "state":
            return {"state": self.state()}
        if op == "subscribe":
            self.subs.writers.add(w)
            return {"subscribed": True}
        if op == "stop":
            log.warning("STOP")
            stopped = self._runner is not None and not self._runner.done()
            if stopped:
                self._runner.cancel()
            return {"stopped": stopped}
        if op == "run":
            skill = msg.get("skill", "")
            if skill not in SKILLS:
                raise ValueError(f"unknown skill {skill!r}")
            if self.job is not None:
                raise ValueError(f"busy with {self.job['skill']}")
            self._runner = asyncio.create_task(self._run(skill, SKILLS[skill]))
            await asyncio.sleep(0)
            return {"job": dict(self.job or {})}
        if op in ("head", "relax"):
            return {}
        if op == "snapshot":
            raise ValueError("the fake robot has no camera")
        raise ValueError(f"unknown op {op!r}")


class FakeAgent:
    def __init__(self, tonyd: FakeTonyd) -> None:
        self.clients = Clients()
        self.tonyd = tonyd

    async def handle(self, msg: dict, w: asyncio.StreamWriter) -> None:
        if msg.get("op") == "say":
            log.warning("SAY: %s", msg.get("text"))
            await self.clients.send(w, {"type": "accepted", "id": 0})
            await self.clients.broadcast({"type": "say", "text": msg.get("text", "")})
            return
        text = str(msg.get("text", ""))
        log.info("command: %s", text)
        await self.clients.send(w, {"type": "accepted", "id": 0})
        await self.clients.broadcast({"type": "heard", "text": text})
        await asyncio.sleep(0.8)  # "thinking"
        skill = next((s for s in SKILLS if s.replace("_", " ") in text.lower()), None)
        if skill:
            await self.clients.broadcast({"type": "action", "skill": skill})
            try:
                await self.tonyd.handle({"op": "run", "skill": skill}, w)
                reply = f"Okay, {skill.replace('_', ' ')}."
            except ValueError as e:
                reply = f"I can't: {e}."
        else:
            reply = f"I heard {text}, but I'm only a fake robot."
        await self.clients.broadcast({"type": "say", "text": reply})
        await self.clients.broadcast({"type": "done"})


async def serve_jsonl(path: Path, handle, clients: Clients | None, replies: bool) -> asyncio.Server:
    async def client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        if clients is not None:
            clients.writers.add(writer)
        try:
            async for line in reader:
                if not line.strip():
                    continue
                msg = json.loads(line)
                try:
                    out = await handle(msg, writer)
                    if replies:
                        out = {"rid": msg.get("rid"), "ok": True, **(out or {})}
                except ValueError as e:
                    out = {"rid": msg.get("rid"), "ok": False, "error": str(e)} if replies else None
                if out is not None:
                    writer.write((json.dumps(out) + "\n").encode())
                    await writer.drain()
        except (OSError, ValueError):
            pass
        finally:
            if clients is not None:
                clients.writers.discard(writer)
            writer.close()

    path.unlink(missing_ok=True)
    return await asyncio.start_unix_server(client, str(path))


async def amain(d: Path) -> None:
    d.mkdir(parents=True, exist_ok=True)
    tonyd = FakeTonyd()
    agent = FakeAgent(tonyd)
    await serve_jsonl(d / "tonyd.sock", tonyd.handle, None, replies=True)
    await serve_jsonl(d / "agent.sock", lambda m, w: agent.handle(m, w), agent.clients, replies=False)
    log.info("fake tonyd on %s, fake agent on %s", d / "tonyd.sock", d / "agent.sock")
    await asyncio.Event().wait()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("dir", type=Path, help="directory for tonyd.sock and agent.sock (keep the path short)")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    asyncio.run(amain(args.dir))


if __name__ == "__main__":
    main()
