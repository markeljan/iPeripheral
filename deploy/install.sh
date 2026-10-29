#!/usr/bin/env bash
# Deploy the bridge to the robot: rsync bridge/ + deploy/, uv sync there, install the unit + Bonjour advert, restart.
# Usage: deploy/install.sh [ssh-host]   (default: tonypi). Coordinate with other sessions before running.
set -euo pipefail
HOST="${1:-tonypi}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rsync -az --delete --exclude .venv --exclude __pycache__ --exclude .pytest_cache \
  "$ROOT/bridge" "$ROOT/deploy" "$HOST:/home/pi/iPeripheral/"
ssh "$HOST" bash -s <<'REMOTE'
set -euo pipefail
cd /home/pi/iPeripheral/bridge
~/.local/bin/uv sync --no-dev -q 2>/dev/null || uv sync --no-dev -q
sudo install -m 644 ../deploy/tonypi-phone.service /etc/systemd/system/tonypi-phone.service
if [ -d /etc/avahi/services ]; then
  sudo install -m 644 ../deploy/tonypi-phone.avahi.xml /etc/avahi/services/tonypi-phone.service
fi
sudo systemctl daemon-reload
sudo systemctl enable --now tonypi-phone
sudo systemctl restart tonypi-phone
sleep 2
systemctl --no-pager -l status tonypi-phone | head -15
REMOTE
