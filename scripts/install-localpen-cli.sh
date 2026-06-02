#!/usr/bin/env bash
# Build the `localpen` retrieval CLI (PLAN-brain.md Phase 5) and install it onto PATH.
# A plain copy (not a symlink) so it survives DerivedData being cleared. Re-run after
# pulling changes to update. Honors the repo convention: never touches the app target.
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED="build/cli"
DEST="${1:-/opt/homebrew/bin}"

echo "Building localpen-cli (Release)…"
xcodebuild -scheme localpen-cli -configuration Release \
  -derivedDataPath "$DERIVED" build >/dev/null

BIN="$DERIVED/Build/Products/Release/localpen"
[ -x "$BIN" ] || { echo "build did not produce $BIN" >&2; exit 1; }

if [ ! -w "$DEST" ]; then
  echo "Destination $DEST is not writable. Pass a writable PATH dir, e.g.:" >&2
  echo "  $0 \"\$HOME/.local/bin\"" >&2
  exit 1
fi

cp "$BIN" "$DEST/localpen"
echo "Installed → $DEST/localpen"
"$DEST/localpen" --help >/dev/null 2>&1 && echo "OK: \`localpen\` is ready on PATH."
