#!/usr/bin/env bash
# Run the bridge on this Mac against a fake robot, advertised over Bonjour like the Pi, so the real phone can be
# developed and tested without the robot. Ctrl-C stops everything.
# Usage: scripts/dev-bridge.sh            then: scripts/build-and-install.sh  (or relaunch the app)
#        scripts/dev-bridge.sh --token    print a dev token for `-devToken` (skips the spoken pairing code)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${TONYPI_DEV_DIR:-/tmp/tpdev}"   # Unix socket paths must stay short on macOS
export TONYD_SOCK="$DIR/tonyd.sock" TONYPI_SOCK="$DIR/agent.sock"
export TONYPI_PHONE_TOKENS="$ROOT/build/dev-tokens.json"
cd "$ROOT/bridge"
if [ "${1:-}" = "--token" ]; then
  exec uv run -q tonypi-phone --issue-token "${2:-dev iPhone}"
fi
trap 'kill $(jobs -p) 2>/dev/null' EXIT
uv run -q tonypi-fake-robot "$DIR" &
dns-sd -R "tonypi (dev on $(scutil --get LocalHostName))" _tonypi-phone._tcp local 8766 robot=tonypi v=1 >/dev/null &
sleep 1
uv run -q tonypi-phone "$@"
