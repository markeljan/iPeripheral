#!/usr/bin/env bash
# Build the app for the connected iPhone and install + launch it. Re-run weekly: free Personal Team
# provisioning profiles expire after 7 days. Usage: scripts/build-and-install.sh [--console]
# APP_ARGS is passed to the app, e.g. APP_ARGS="-devToken $(scripts/dev-bridge.sh --token)" (Debug builds only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
scripts/fetch-vendor.sh
xcodegen generate --quiet
if [ -z "${DEVICE:-}" ]; then
  J="$(mktemp)"
  xcrun devicectl list devices --json-output "$J" >/dev/null 2>&1 || true
  DEVICE="$(python3 -c 'import json,sys
for d in json.load(open(sys.argv[1])).get("result", {}).get("devices", []):
    if d.get("hardwareProperties", {}).get("deviceType") == "iPhone" and d.get("connectionProperties", {}).get("pairingState") == "paired":
        print(d["identifier"]); break' "$J" 2>/dev/null || true)"
  rm -f "$J"
fi
if [ -z "$DEVICE" ]; then
  echo "No paired iPhone found (xcrun devicectl list devices). Plug it in, unlock it, trust this Mac." >&2
  exit 1
fi
xcodebuild -project iPeripheral.xcodeproj -scheme iPeripheral -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build/dd -allowProvisioningUpdates build \
  | (command -v xcbeautify >/dev/null && xcbeautify --quiet || cat)
APP="build/dd/Build/Products/Debug-iphoneos/iPeripheral.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")"
xcrun devicectl device install app --device "$DEVICE" "$APP"
if [ "${1:-}" = "--console" ]; then
  xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --console "$BUNDLE_ID" -- ${APP_ARGS:-}
else
  xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" -- ${APP_ARGS:-}
fi
