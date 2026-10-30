"""Episodes: what the phone camera saw while Tony moved, next to what tonyd says his body did.

Mostly for companion mode (the phone on a stand, watching Tony): a brain can judge a move it just wrote ("did the arm
go up, did he lean, did he fall"), measure a walk from outside, and keep the clips as training data. An episode is a
folder under ROOT:

  frames/000000.jpg ...   the phone's JPEGs
  frames.jsonl            one line per frame: seq, t (phone clock), rx (bridge clock), tracked box + world, phone pose
  body.jsonl              tonyd state + joint positions (motion space), sampled at joints_hz
  jobs.jsonl              tonyd job events during the episode
  meta.json               summary (seconds, frames, final job results, how far the tracked target moved)

The phone streams frames only while someone needs them (a recording, auto-recording of jobs, a live viewer).
"""

from __future__ import annotations

import asyncio
import collections
import io
import json
import logging
import math
import os
import time
from dataclasses import dataclass, field
from pathlib import Path

from tonypi_phone.hub import PhoneError, PhoneHub
from tonypi_phone.links import TonydError, TonydLink

log = logging.getLogger(__name__)

ROOT = Path(os.environ.get("TONYPI_PHONE_EPISODES", Path.home() / ".local/share/tonypi-phone/episodes"))
PREROLL_S = 1.0  # auto-recording keeps this much from before a job starts
TAIL_S = 1.0  # ... and keeps recording this long after it ends (settling, falling over)
JOB_END = ("done", "failed", "cancelled", "stopped")


class RecorderError(RuntimeError):
    pass


@dataclass
class Episode:
    id: str
    path: Path
    label: str
    source: str  # "manual" or "job"
    max_s: float
    joints_hz: float
    started: float = field(default_factory=time.time)
    frames: int = 0
    tracked: list[tuple[float, list[float]]] = field(default_factory=list)  # (rx, world) while not lost
    jobs: dict[int, dict] = field(default_factory=dict)  # last event per job id
    tasks: list[asyncio.Task] = field(default_factory=list)

    def write(self, name: str, obj: dict) -> None:
        with open(self.path / name, "a") as f:
            f.write(json.dumps(obj, separators=(",", ":")) + "\n")

    def add_frame(self, header: dict, jpeg: bytes, rx: float) -> None:
        (self.path / "frames" / f"{self.frames:06d}.jpg").write_bytes(jpeg)
        line = {"seq": self.frames, "phone_seq": header.get("seq"), "t": header.get("t"), "rx": round(rx, 3),
                "width": header.get("width"), "height": header.get("height"), "tracked": header.get("tracked"),
                "pose": header.get("pose")}
        self.write("frames.jsonl", line)
        tr = header.get("tracked") or {}
        if tr.get("world") and not tr.get("lost"):
            self.tracked.append((rx, tr["world"]))
        self.frames += 1

    def summary(self) -> dict:
        out = {"id": self.id, "label": self.label, "source": self.source, "path": str(self.path),
               "started": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(self.started)),
               "seconds": round(time.time() - self.started, 2), "frames": self.frames,
               "jobs": list(self.jobs.values()), "frames_tracked": len(self.tracked)}
        if len(self.tracked) >= 2:
            (_, a), (_, b) = self.tracked[0], self.tracked[-1]
            # y is up in ARKit's frame: the floor distance is in x and z.
            out["target_moved_m"] = round(math.hypot(b[0] - a[0], b[2] - a[2]), 3)
            out["target_start"], out["target_end"] = a, b
        return out


class Recorder:
    def __init__(self, hub: PhoneHub, tonyd: TonydLink, root: Path = ROOT) -> None:
        self.hub, self.tonyd, self.root = hub, tonyd, root
        self.current: Episode | None = None
        self.auto: dict | None = None  # {"fps", "joints_hz"} while every tonyd job is recorded
        self.ring: collections.deque[tuple[dict, bytes, float]] = collections.deque()
        self.viewers = 0  # live MJPEG viewers
        self.latest: tuple[dict, bytes, float] | None = None
        self.new_frame = asyncio.Condition()
        self._fps = 0.0  # what the phone was last asked for
        self._episode_fps = 5.0
        self._stopping: asyncio.Task | None = None
        hub.on_frame = self._on_frame

    # ---- frames from the phone ----------------------------------------------------------------------------------

    def _on_frame(self, header: dict, jpeg: bytes) -> None:
        rx = time.time()
        self.latest = (header, jpeg, rx)
        if self.current is not None:
            self.current.add_frame(header, jpeg, rx)
        elif self.auto is not None:
            self.ring.append((header, jpeg, rx))
            while self.ring and rx - self.ring[0][2] > PREROLL_S:
                self.ring.popleft()
        asyncio.get_running_loop().create_task(self._notify())

    async def _notify(self) -> None:
        async with self.new_frame:
            self.new_frame.notify_all()

    def wanted_fps(self) -> float:
        fps = 0.0
        if self.current is not None:
            fps = max(fps, self._episode_fps)
        if self.auto is not None:
            fps = max(fps, self.auto["fps"])
        if self.viewers:
            fps = max(fps, 5.0)
        return fps

    async def sync_stream(self, force: bool = False) -> None:
        """Ask the phone for the frame rate the current users need (0 = stop). force: a phone just connected, and
        it starts without a stream."""
        if force:
            self._fps = 0.0
        fps = self.wanted_fps()
        if fps == self._fps:
            return
        if not self.hub.connected:
            self._fps = 0.0
            return
        try:
            await self.hub.request("stream", timeout=5, fps=fps, max_side=640)
            self._fps = fps
        except PhoneError as e:
            log.warning("stream %s fps: %s", fps, e)
            if fps:
                raise RecorderError(str(e)) from e

    # ---- episodes -----------------------------------------------------------------------------------------------

    async def start(self, label: str = "", fps: float = 5, max_s: float = 60, joints_hz: float = 2,
                    source: str = "manual", preroll: bool = False) -> dict:
        if self.current is not None:
            raise RecorderError(f"already recording {self.current.id}")
        if not self.hub.connected:
            raise RecorderError("Tony's phone is not connected")
        stamp = time.strftime("%Y%m%d-%H%M%S")
        slug = "".join(c if c.isalnum() or c in "-_" else "_" for c in label.strip().lower())[:40] or source
        ep = Episode(f"{stamp}-{slug}", self.root / f"{stamp}-{slug}", label or slug, source,
                     max(1.0, min(600.0, float(max_s))), max(0.0, min(2.0, float(joints_hz))))
        (ep.path / "frames").mkdir(parents=True, exist_ok=True)
        if preroll:
            for header, jpeg, rx in self.ring:
                ep.add_frame(header, jpeg, rx)
        self.ring.clear()
        self.current = ep
        self._episode_fps = max(1.0, min(10.0, float(fps)))
        try:
            await self.sync_stream()
        except RecorderError:
            self.current = None
            raise
        ep.tasks = [asyncio.create_task(self._sample_body(ep)), asyncio.create_task(self._time_limit(ep))]
        log.info("recording %s", ep.id)
        return {"recording": ep.id, "path": str(ep.path)}

    async def stop(self) -> dict:
        ep = self.current
        if ep is None:
            raise RecorderError("not recording")
        self.current = None
        for t in ep.tasks:
            if t is not asyncio.current_task():
                t.cancel()
        meta = ep.summary()
        (ep.path / "meta.json").write_text(json.dumps(meta, indent=1))
        await self.sync_stream()
        log.info("recorded %s: %d frames, %.1f s", ep.id, ep.frames, meta["seconds"])
        return meta

    async def _time_limit(self, ep: Episode) -> None:
        await asyncio.sleep(ep.max_s)
        if self.current is ep:
            await self.stop()

    async def _sample_body(self, ep: Episode) -> None:
        if ep.joints_hz <= 0:
            return
        period = 1 / ep.joints_hz
        while True:
            t0 = time.time()
            line: dict = {"t": round(t0, 3)}
            try:
                line["state"] = (await self.tonyd.call("state", timeout=2)).get("state")
                line["joints"] = (await self.tonyd.call("joints", timeout=2)).get("pos")
            except TonydError as e:
                line["error"] = str(e)
            ep.write("body.jsonl", line)
            await asyncio.sleep(max(0.05, period - (time.time() - t0)))

    # ---- recording every tonyd job --------------------------------------------------------------------------

    async def set_auto(self, on: bool, fps: float = 5, joints_hz: float = 2) -> dict:
        self.auto = {"fps": max(1.0, min(10.0, float(fps))), "joints_hz": joints_hz} if on else None
        if not on:
            self.ring.clear()
        await self.sync_stream()
        return {"auto": self.auto is not None, **(self.auto or {})}

    def on_tonyd_event(self, event: dict) -> None:
        """Every tonyd event (from the bridge's subscription): log jobs, and start/stop auto episodes."""
        if event.get("event") != "job":
            return
        job = event.get("job") if isinstance(event.get("job"), dict) else event  # real tonyd sends the job flat
        job = {k: v for k, v in job.items() if k not in ("event", "t")}
        ep = self.current
        if ep is not None:
            ep.write("jobs.jsonl", {"rx": round(time.time(), 3), **job})
            if job.get("id") is not None:
                ep.jobs[job["id"]] = job
        state = job.get("state")
        if self.auto is not None and ep is None and state == "running":
            asyncio.get_running_loop().create_task(self._start_job(job))
        elif ep is not None and ep.source == "job" and state in JOB_END:
            if self._stopping is None or self._stopping.done():
                self._stopping = asyncio.get_running_loop().create_task(self._stop_after_tail(ep))

    async def _start_job(self, job: dict) -> None:
        try:
            await self.start(label=str(job.get("skill") or "job"), fps=self.auto["fps"] if self.auto else 5,
                             max_s=180, joints_hz=self.auto["joints_hz"] if self.auto else 2,
                             source="job", preroll=True)
            if self.current is not None and job.get("id") is not None:
                self.current.jobs[job["id"]] = job
                self.current.write("jobs.jsonl", {"rx": round(time.time(), 3), **job})
        except RecorderError as e:
            log.warning("auto-record %s: %s", job.get("skill"), e)

    async def _stop_after_tail(self, ep: Episode) -> None:
        await asyncio.sleep(TAIL_S)
        busy = any(j.get("state") not in JOB_END for j in ep.jobs.values())
        if self.current is ep and not busy:  # a new job (the next step) keeps the same episode going
            await self.stop()

    # ---- reading episodes back ------------------------------------------------------------------------------

    def list(self, limit: int = 10) -> list[dict]:
        out = []
        for d in sorted((p for p in self.root.glob("*") if p.is_dir()), reverse=True)[: max(1, limit)]:
            meta = d / "meta.json"
            if meta.exists():
                m = json.loads(meta.read_text())
                out.append({k: m.get(k) for k in ("id", "label", "source", "started", "seconds", "frames",
                                                  "frames_tracked", "target_moved_m")}
                           | {"jobs": [{k: j.get(k) for k in ("skill", "state", "max_tilt_deg", "yaw_deg")}
                                       for j in m.get("jobs", [])]})
            else:
                out.append({"id": d.name, "recording": self.current is not None and self.current.path == d})
        return out

    def find(self, episode_id: str) -> Path:
        if episode_id in ("", "latest"):
            done = [d for d in sorted(self.root.glob("*"), reverse=True) if (d / "meta.json").exists()]
            if not done:
                raise RecorderError("no episodes yet")
            return done[0]
        d = self.root / Path(episode_id).name
        if not (d / "meta.json").exists():
            raise RecorderError(f"no finished episode {episode_id!r}")
        return d

    def contact_sheet(self, episode_id: str = "latest", n: int = 8, cols: int = 4) -> tuple[bytes, dict]:
        """N frames spread over the episode in one JPEG grid, each with its time and the tracked box drawn, so a
        brain can watch a move in a single image. Returns (jpeg, meta + which frames were used)."""
        from PIL import Image, ImageDraw

        d = self.find(episode_id)
        meta = json.loads((d / "meta.json").read_text())
        lines = [json.loads(s) for s in (d / "frames.jsonl").read_text().splitlines() if s.strip()]
        if not lines:
            raise RecorderError(f"{d.name} has no frames")
        n = max(1, min(16, n, len(lines)))
        picks = [lines[round(i * (len(lines) - 1) / max(1, n - 1))] for i in range(n)]
        t0 = lines[0]["rx"]
        cell_w = 320
        tiles = []
        for ln in picks:
            im = Image.open(d / "frames" / f"{ln['seq']:06d}.jpg").convert("RGB")
            im = im.resize((cell_w, round(im.height * cell_w / im.width)))
            draw = ImageDraw.Draw(im)
            tr = ln.get("tracked")
            if tr:
                x, y, w, h = (tr["x"] * im.width, tr["y"] * im.height, tr["w"] * im.width, tr["h"] * im.height)
                draw.rectangle([x, y, x + w, y + h], outline="orange" if tr.get("lost") else "lime", width=3)
            draw.rectangle([0, 0, 92, 20], fill="black")
            draw.text((4, 4), f"t={ln['rx'] - t0:5.2f}s", fill="white")
            tiles.append(im)
        cols = max(1, min(cols, n))
        rows = math.ceil(n / cols)
        cell_h = max(t.height for t in tiles)
        sheet = Image.new("RGB", (cols * cell_w, rows * cell_h), "black")
        for i, t in enumerate(tiles):
            sheet.paste(t, ((i % cols) * cell_w, (i // cols) * cell_h))
        buf = io.BytesIO()
        sheet.save(buf, "JPEG", quality=80)
        return buf.getvalue(), meta | {"sheet_times_s": [round(ln["rx"] - t0, 2) for ln in picks]}
