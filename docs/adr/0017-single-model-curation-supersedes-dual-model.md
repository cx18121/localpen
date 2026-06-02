# ADR 0017 — Single-model curation: the dream cycle runs on the transform model

**Status:** Accepted
**Date:** 2026-06-02
**Supersedes:** the "dual local model" decision in [ADR 0015](./0015-autonomous-curation-discipline.md) (the judgment-split writes, hybrid cadence, substance filter, and vault-rules discipline from 0015 all stand — only the *which model* sub-decision changes).

## Context

ADR 0015 specified a **dual local model**: keep Qwen-7B for latency-critical transforms, and bring up a dedicated **~14B** transiently for the nightly curation/synthesis pass, on the premise that a 14B's quality justified the cost on a 24 GB machine.

In practice that premise didn't hold up on the user's hardware:

1. **The 14B lags the machine.** Running the 14B (8.4 GB Q4) for synthesis makes the Mac stutter noticeably during the pass — confirmed live by the user ("the 14b is lowk too big").
2. **The borrow is a stop-the-world swap.** Because the 14B is never the active model, every dream cycle has to *stop the 7B, load 8.4 GB, synthesize, then reload the 7B*. That transient load+heavy-inference spike is the lag — and it happens on a manual "Run curation now" while the user is at the machine, not only overnight.
3. **The quality bump wasn't being realized anyway.** A separate bug (the parser rejecting the model's actual output shape) meant runs reported "Applied 0, queued 0" regardless of model. Once the contract is fixed, a 7B with a tightened prompt extracts people/facts/sources from meeting notes perfectly well — the curation task here is extraction and light synthesis, not the hardest reasoning.

## Decision

**Curate with the already-loaded transform model (Qwen-7B). No dedicated curation model is bundled.**

- The dream cycle runs synthesis **against the live server** — no `stop`/`start`, no second model download, no lag spike. Curation uses a lower sampling temperature (0.3) than transforms (0.4) for faithful, less-inventive synthesis. `DreamCycleRunner` owns this synthesis policy (model, sampling, the long timeout); `AppDelegate` only schedules the run and reports the result.
- The transform model's context is raised to **8k** so a curation batch (capped at ~20k chars) fits without the server silently truncating it. 8k also benefits KB-context asks. A 7B Q4 @ 8k is comfortable on 24 GB.
- **The transient model-borrow path is removed entirely.** The original revision of this ADR kept a dedicated `role = "curation"` model as an opt-in fallback (the `CurationModel` stop→load→synthesize→restore machinery). A follow-up simplification pass deleted it: it was ~250 lines (file + tests + an `AppDelegate` fork) guarding a path nothing bundled and the project had just decided against, and the stop-the-world swap was the very lag this ADR set out to remove. There is now exactly one curation path. Re-introducing a heavier curation model later would mean restoring that machinery deliberately, not leaving it dormant.

## Alternatives considered

- **Keep the 14B, gate it to idle/locked-screen only.** Avoids lag *while working* but still spikes when it runs, still needs the 8.4 GB download, and a manual "Run curation now" is inherently interactive. Rejected: doesn't address the core "too big for this machine" finding.
- **Download a smaller dedicated model (8B).** Another download and another model to keep current, for marginal quality over the 7B that's already loaded. Rejected on YAGNI — the 7B is here and sufficient.
- **Restart the 7B at 8k just for curation, back to 4k after.** Still a stop-the-world reload (twice), for no benefit over simply running the 7B at 8k always. Rejected.

## Consequences

- The dream cycle no longer downloads or swaps models; "Run curation now" is responsive. The 14B can be deleted to reclaim 8.4 GB.
- The transform model always runs at 8k context (slightly larger KV cache; negligible on 24 GB).
- There is one curation path. `CurationModel` and its tests were deleted; `DreamCycleRunner` is the single synthesis entry point. `scripts/download-curation-model.sh` is retained only as a manual convenience for anyone who later chooses to wire a heavier model back in.
- The judgment-split (auto additive vs. queued high-judgment), git backstop, substance filter, hybrid stash→nightly cadence, and "operate under the vault's rules" discipline from ADR 0015 are unchanged.
