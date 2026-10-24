# Inference benchmarks

## Offline benchmark

Build `llama-bench` from the same llama.cpp revision as your server, then run:

```sh
LLAMA_BENCH=/path/to/llama.cpp/build/bin/llama-bench ./scripts/bench/run-bench.sh
```

The script also finds `llama-bench` on `PATH`, or in the directory set by
`LLAMA_DIR`. It uses Localpen's default chat model and writes results under
`docs/superpowers/bench-results/`, which is ignored by Git.

`pp<N>` rows measure prompt processing. `tg<N>` rows measure token generation.
Compare runs on the same hardware and model when changing inference settings.

Overrides include `MODEL`, `PROMPTS=128,1024`, `GENS=64,256`, `REPS=5`, `FA=1`,
`NGL=999`, and `SERVER`. The server executable is used only to record its version.

## In-app measurements

Localpen writes generation metrics to a local JSONL file:

```sh
tail -f "$HOME/Library/Logs/Localpen/inference-metrics.jsonl"
```

Each row includes `ts_ms`, `workload`, `prompt_ms`, `tok_per_s`, and `predicted_n`.
`acceptance_rate` is present when the server reports speculative-decoding metrics.
These records stay on the Mac. They are not sent to an analytics service.
