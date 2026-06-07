#!/usr/bin/env bash
# Offline inference microbenchmark for Localpen's active chat model.
# Wraps llama.cpp's llama-bench with the flags the app actually runs, and stamps
# the result with the *server's* real build (llama-bench's own --version is stale;
# see docs/superpowers/plans/2026-06-07-inference-harness.md). Use this to compare
# config changes (the inference-quickwins branch) on a controlled, repeatable bench.
set -euo pipefail
cd "$(dirname "$0")/../.."

LLAMA_DIR="${LLAMA_DIR:-/Users/charliexue/School/clones/llama.cpp/build/bin}"
BENCH="${LLAMA_BENCH:-$LLAMA_DIR/llama-bench}"
SERVER="${LLAMA_SERVER:-Localpen/Resources/llama-server}"
MODEL="${MODEL:-$HOME/Library/Application Support/Localpen/models/qwen-2.5-7b-instruct-q4-km.gguf}"
# Two real-workload-ish shapes: rewrite (short prompt, short gen) and ask (long prompt, longer gen).
PROMPTS="${PROMPTS:-128,1024}"
GENS="${GENS:-64,256}"
REPS="${REPS:-3}"
FA="${FA:-1}"
NGL="${NGL:-999}"

[ -x "$BENCH" ] || { echo "✗ llama-bench not found/executable at $BENCH (set LLAMA_BENCH=)"; exit 1; }
[ -f "$MODEL" ] || { echo "✗ model not found at $MODEL (set MODEL=)"; exit 1; }

BUILD="$("$SERVER" --version 2>&1 | awk '/^version:/{print $2}' || echo unknown)"
OUTDIR="docs/superpowers/bench-results"
mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUTDIR/bench-$STAMP.txt"

echo "▸ llama-bench — server build $BUILD — pp=$PROMPTS tg=$GENS reps=$REPS fa=$FA"
{
  echo "# Localpen offline bench"
  echo "# date:        $STAMP"
  echo "# server build: $BUILD   (llama-bench binary build string is stale — ignore it)"
  echo "# model:       $(basename "$MODEL")"
  echo "# flags:       -p $PROMPTS -n $GENS -r $REPS -fa $FA -ngl $NGL"
  echo
  "$BENCH" -m "$MODEL" -p "$PROMPTS" -n "$GENS" -r "$REPS" -fa "$FA" -ngl "$NGL"
} | tee "$OUT"

echo "✓ wrote $OUT"
