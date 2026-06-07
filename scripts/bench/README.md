# Inference bench

Two ways to measure Localpen's local inference.

## 1. Offline microbench (controlled, repeatable)

`./scripts/bench/run-bench.sh`

Runs `llama-bench` against the active chat GGUF with the app's real server flags
and writes a build-stamped table to `docs/superpowers/bench-results/bench-<ts>.txt`.
`pp<N>` rows = prompt-eval throughput (TTFT driver); `tg<N>` rows = decode tok/s.

Override anything via env: `MODEL=`, `PROMPTS=128,1024`, `GENS=64,256`, `REPS=5`,
`FA=1`, `LLAMA_BENCH=`, `SERVER=` (the llama-server binary used only for the build
stamp). Use this to A/B a config change (e.g. KV q8_0) on the
`inference-quickwins` branch — run before, run after, diff the tables.

> Note: the vendored `llama-bench` prints a stale `build:` line (4500) but loads the
> rebuilt 9544 dylibs, so its numbers are valid. The script stamps the real server
> build itself. To make llama-bench's own string match, rebuild it:
> `cmake --build /Users/charliexue/School/clones/llama.cpp/build --target llama-bench`.

## 2. In-app real-workload telemetry (live)

Every real generation appends one JSON row to
`~/Library/Logs/Localpen/inference-metrics.jsonl`, tagged `rewrite` or `ask`:

```
tail -f ~/Library/Logs/Localpen/inference-metrics.jsonl
```

Each row: `ts_ms`, `workload`, `prompt_ms` (TTFT proxy), `tok_per_s`,
`predicted_n`, and `acceptance_rate` (only when a draft model is active —
speculative decoding, the `inference-quickwins` branch). Live tailing without the
file: `log stream --predicate 'subsystem == "app.localpen.Localpen" && category == "Metrics"'`.
