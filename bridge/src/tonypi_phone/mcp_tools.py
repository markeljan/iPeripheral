"""MCP server for the phone's senses (Streamable HTTP, localhost only). Brains add it next to tonypi-mcp."""

from __future__ import annotations

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.server.mcpserver.utilities.types import Image

from tonypi_phone.hub import PhoneError, PhoneHub

DETECT_KINDS = ("people", "faces", "hands")
FACES = ("idle", "listening", "thinking", "speaking", "happy", "sad", "warn", "asleep")


def build_mcp(hub: PhoneHub) -> MCPServer:
    mcp = MCPServer(
        "tonypi-phone",
        instructions=(
            "Tony (the TonyPi humanoid) wears an iPhone 14 Pro Max on its body. These tools use the phone: its back "
            "camera (better than the head camera, and it does not move with the head), LiDAR depth, ARKit position "
            "tracking, on-device detection of people/faces/hands, its speaker and its screen, which shows Tony's "
            "face. Image coordinates are x, y from 0 to 1 in the snapshot image, origin top-left. Body movement is "
            "in the separate tonypi MCP server."
        ),
    )

    async def ask(op: str, timeout: float = 10.0, **args):
        try:
            return await hub.request(op, timeout=timeout, **args)
        except PhoneError as e:
            raise ToolError(str(e)) from e

    @mcp.tool()
    async def phone_status() -> dict:
        """Whether the phone is connected, plus its battery (0-1), charging, thermal state and capabilities."""
        if not hub.connected:
            return {"connected": False}
        header, _ = await ask("status", timeout=5)
        return {"connected": True, "device": hub.device,
                **{k: v for k, v in header.items() if k not in ("type", "rid", "ok")}}

    @mcp.tool()
    async def phone_snapshot(max_side: int = 1280) -> Image:
        """What the phone camera sees right now, as a JPEG (longest side max_side px, 320-1920)."""
        header, jpeg = await ask("snapshot", max_side=max(320, min(1920, int(max_side))))
        if not jpeg:
            raise ToolError("phone sent no image")
        return Image(data=jpeg, format="jpeg")

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
    async def phone_pose() -> dict:
        """Where the phone (so Tony's body) is, from ARKit visual-inertial tracking: x, y, z in metres from where
        tracking started (y is up), yaw_deg (heading, positive = turned left since the start), pitch_deg. Trust it
        only when tracking is "normal". Better than counting steps for how far Tony walked or turned."""
        header, _ = await ask("pose", timeout=5)
        return {k: v for k, v in header.items() if k not in ("type", "rid", "ok")}

    @mcp.tool()
    async def phone_reset_origin() -> dict:
        """Make Tony's current position and heading the new phone_pose origin (0, 0, 0, yaw 0)."""
        await ask("reset_origin", timeout=5)
        return {"reset": True}

    @mcp.tool()
    async def phone_detect(kinds: list[str] | None = None) -> dict:
        """People, faces and hands the phone camera sees now (on-device Vision). kinds: any of people, faces,
        hands (default all). Each object has a box x, y, w, h (0-1, top-left origin), confidence, and m, the
        distance to the box centre in metres when LiDAR has it."""
        args = {} if not kinds else {"kinds": [k for k in kinds if k in DETECT_KINDS]}
        header, _ = await ask("detect", **args)
        return {"objects": header.get("objects", []), "frame_age_s": header.get("age_s")}

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

    return mcp


def _unit(v: float) -> float:
    return max(0.0, min(1.0, float(v)))
