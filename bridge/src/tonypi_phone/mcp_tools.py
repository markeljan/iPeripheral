"""MCP server for the phone's senses (Streamable HTTP, localhost only). Brains add it next to tonypi-mcp."""

from __future__ import annotations

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.server.mcpserver.utilities.types import Image

from tonypi_phone.hub import PhoneError, PhoneHub

FACES = ("idle", "listening", "thinking", "speaking", "happy", "sad", "warn", "asleep")


def build_mcp(hub: PhoneHub) -> MCPServer:
    mcp = MCPServer(
        "tonypi-phone",
        instructions=(
            "Tony (the TonyPi humanoid) wears an iPhone 14 Pro on its body. These tools use the phone: its back "
            "camera (better than the head camera, and it does not move with the head), its speaker and its screen, "
            "which shows Tony's face. Body movement is in the separate tonypi MCP server."
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
