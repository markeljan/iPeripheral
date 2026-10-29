"""Call one tool on the tonypi-phone MCP server and print the result; images are saved to a file.
Usage: uv run --project bridge scripts/phone-mcp.py TOOL [key=value ...] [--url URL] [--out snap.jpg]
On the Pi, tunnel first: ssh -N -L 8767:127.0.0.1:8767 tonypi
"""

import argparse
import asyncio
import base64
import json

from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamable_http_client


def parse(kv: str):
    k, _, v = kv.partition("=")
    try:
        return k, json.loads(v)
    except ValueError:
        return k, v


async def main(a: argparse.Namespace) -> int:
    async with streamable_http_client(a.url) as streams:
        async with ClientSession(streams[0], streams[1]) as s:
            await s.initialize()
            if a.tool == "list":
                for t in (await s.list_tools()).tools:
                    print(f"{t.name}: {t.description}")
                return 0
            res = await s.call_tool(a.tool, dict(parse(kv) for kv in a.args))
            for c in res.content:
                if c.type == "image":
                    data = base64.b64decode(c.data)
                    with open(a.out, "wb") as f:
                        f.write(data)
                    print(f"image {c.mime_type} {len(data)} bytes -> {a.out}")
                else:
                    print(getattr(c, "text", c))
            return 1 if res.is_error else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("tool", help="tool name, or `list`")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--url", default="http://127.0.0.1:8767/mcp")
    ap.add_argument("--out", default="snap.jpg")
    raise SystemExit(asyncio.run(main(ap.parse_args())))
