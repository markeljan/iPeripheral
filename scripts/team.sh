#!/usr/bin/env bash
# Write App/Config/Local.xcconfig with your Personal Team ID (from the Apple Development certificate Xcode created).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM="${1:-$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)}"
if [ -z "$TEAM" ]; then  # no certificate yet: the Personal Team Xcode knows about
  TEAM="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | sed -n 's/.*teamID = \([A-Z0-9]\{10\}\);.*/\1/p' | head -1)"
fi
if [ -z "$TEAM" ]; then
  echo "No Apple Development certificate yet. Xcode → Settings → Accounts → sign in, then Manage Certificates → + Apple Development." >&2
  exit 1
fi
echo "DEVELOPMENT_TEAM = $TEAM" > "$ROOT/App/Config/Local.xcconfig"
echo "team $TEAM → App/Config/Local.xcconfig"
