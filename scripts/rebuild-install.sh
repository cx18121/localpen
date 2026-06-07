#!/usr/bin/env bash
# Rebuild Localpen (Debug) and install it to /Applications, replacing the running app.
# The Xcode GUI installs via a scheme post-action; the `xcodebuild` CLI does NOT — it only
# writes into DerivedData. So we copy the built bundle ourselves, or you keep testing a
# stale /Applications binary. (See memory: build-install gotcha.)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ building Localpen (Debug)…"
xcodebuild build -scheme Localpen -configuration Debug -destination 'platform=macOS' -quiet

APP_DIR="$(xcodebuild -scheme Localpen -configuration Debug -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '{gsub(/^[ \t]+/,"",$1)} $1=="BUILT_PRODUCTS_DIR"{print $2; exit}')"
SRC="$APP_DIR/Localpen.app"
[ -d "$SRC" ] || { echo "✗ built app not found at $SRC"; exit 1; }

echo "▸ installing → /Applications/Localpen.app"
killall Localpen 2>/dev/null || true
sleep 0.5
rm -rf /Applications/Localpen.app
ditto "$SRC" /Applications/Localpen.app

echo "▸ relaunching"
open -a /Applications/Localpen.app
echo "✓ installed $(date +%H:%M:%S) — fresh build is running"
