#!/usr/bin/env bash
# Download the curation model (ADR 0015) to the exact path Localpen's ModelRegistry
# expects: ~/Library/Application Support/Localpen/models/<id>.gguf. Resumable (curl -C -)
# — safe to re-run if interrupted. The id/url/size MUST match the `role = "curation"`
# entry in Localpen/Resources/models.toml.
set -euo pipefail

ID="qwen-2.5-14b-instruct-q4-km"
URL="https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf"
EXPECTED_BYTES=8988110976   # 8.37 GiB — verified against the HF Content-Length

DIR="$HOME/Library/Application Support/Localpen/models"
DEST="$DIR/$ID.gguf"
mkdir -p "$DIR"

if [ -f "$DEST" ] && [ "$(stat -f%z "$DEST")" = "$EXPECTED_BYTES" ]; then
  echo "Already downloaded → $DEST"
  exit 0
fi

echo "Downloading curation model (~8.4 GB) → $DEST"
echo "(resumable — re-run this script if it's interrupted)"
curl -L --fail -C - -o "$DEST" "$URL"

GOT=$(stat -f%z "$DEST")
if [ "$GOT" != "$EXPECTED_BYTES" ]; then
  echo "WARNING: size mismatch — got $GOT, expected $EXPECTED_BYTES. Re-run to resume." >&2
  exit 1
fi
echo "Done. The dream cycle will use it once that phase ships; nothing else to do now."
