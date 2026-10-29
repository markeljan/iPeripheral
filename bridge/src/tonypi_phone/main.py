"""tonypi-phone: WebSocket for Tony's phone (LAN, token auth) + MCP server for its senses (localhost)."""

from __future__ import annotations

import argparse
import asyncio
import logging
import os

from websockets.asyncio.server import serve

from tonypi_phone.bridge import Bridge
from tonypi_phone.mcp_tools import build_mcp
from tonypi_phone.pairing import TokenStore


async def amain(args: argparse.Namespace) -> None:
    bridge = Bridge(TokenStore())
    mcp = build_mcp(bridge.hub)
    async with serve(bridge.handler, args.host, args.port, max_size=16 << 20, ping_interval=10, ping_timeout=10):
        logging.info("phone WebSocket on ws://%s:%d/, MCP on http://127.0.0.1:%d/mcp", args.host, args.port, args.mcp_port)
        await asyncio.gather(bridge.run_links(), mcp.run_streamable_http_async(host="127.0.0.1", port=args.mcp_port))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default=os.environ.get("TONYPI_PHONE_HOST", "0.0.0.0"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("TONYPI_PHONE_PORT", "8766")))
    ap.add_argument("--mcp-port", type=int, default=int(os.environ.get("TONYPI_PHONE_MCP_PORT", "8767")))
    ap.add_argument("--issue-token", metavar="DEVICE",
                    help="print a new phone token and exit (pairing without the spoken code, e.g. for dev installs)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    if args.issue_token:
        print(TokenStore().issue(args.issue_token))
        return
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("websockets").setLevel(logging.WARNING)
    asyncio.run(amain(args))


if __name__ == "__main__":
    main()
