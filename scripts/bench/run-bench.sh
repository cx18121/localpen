#!/usr/bin/env bash
# Offline inference microbenchmark for Localpen's active chat model.
# Wraps llama.cpp's llama-bench with the flags the app actually runs, and stamps
# the result with the server's build. Use this to compare configuration changes
# on a controlled, repeatable benchmark.
set -euo pipefail
cd "$(dirname "$0")/../.."

LLAMA_DIR="${LLAMA_DIR:-}"
BENCH="${LLAMA_BENCH:-${LLAMA_DIR:+$LLAMA_DIR/llama-bench}}"
BENCH="${BENCH:-$(command -v llama-bench || true)}"
SERVER="${SERVER:-${LLAMA_SERVER:-Localpen/Resources/llama-server}}"
MODEL="${MODEL:-$HOME/Library/Application Support/Localpen/models/qwen-2.5-7b-instruct-q4-km.gguf}"
# Two real-workload-ish shapes: rewrite (short prompt, short gen) and ask (long prompt, longer gen).
PROMPTS="${PROMPTS:-128,1024}"
GENS="${GENS:-64,256}"
REPS="${REPS:-3}"
FA="${FA:-1}"
NGL="${NGL:-999}"

[ -x "$BENCH" ] || { echo "✗ llama-bench not found (set LLAMA_BENCH to its executable path, or add it to PATH)"; exit 1; }
[ -f "$MODEL" ] || { echo "✗ model not found at $MODEL (set MODEL=)"; exit 1; }

if [ -x "$SERVER" ]; then
  BUILD="$("$SERVER" --version 2>&1 | awk '/^version:/{print $2}' || echo unknown)"
else
  BUILD=unknown
fi
BUILD="${BUILD:-unknown}"
OUTDIR="docs/superpowers/bench-results"
mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUTDIR/bench-$STAMP.txt"

echo "▸ llama-bench — server build $BUILD — pp=$PROMPTS tg=$GENS reps=$REPS fa=$FA"
{
  echo "# Localpen offline bench"
  echo "# date:        $STAMP"
  echo "# server build: $BUILD"
  echo "# model:       $(basename "$MODEL")"
  echo "# flags:       -p $PROMPTS -n $GENS -r $REPS -fa $FA -ngl $NGL"
  echo
  "$BENCH" -m "$MODEL" -p "$PROMPTS" -n "$GENS" -r "$REPS" -fa "$FA" -ngl "$NGL"
} | tee "$OUT"

echo "✓ wrote $OUT"
