---
name: renovate-merge
description: Efficient, codemode-first review and rollout of Renovate PRs. Batch read-only discovery, cache release evidence, build dependency-ordered waves with approval gates, merge sequentially, and verify Flux and cluster health between waves. Use when asked to merge Renovate PRs, review dependency updates, or roll out pending updates.
---

# Renovate Merge

Use **codemode as the default orchestration layer**, not a series of individual tool calls. Optimize tool latency and model context without weakening safety checks.

## Read gates

Read [AGENTS.md](AGENTS.md) first, then the [playbook](references/playbook.md) and [codemode recipes](references/codemode.md). Also follow repository `AGENTS.md` and `docs/agent/operations.md`. Read component-specific skills/docs only when needed (especially Talos, Kopiur, and secrets).

## Workflow

1. **Discover:** one PR inventory including chart, image, digest, and platform updates; filter Renovate ownership in JavaScript. Batch independent file/diff lookups with bounded concurrency.
2. **Analyse:** deduplicate release-note requests by upstream/version range; inspect changed configuration only where relevant. Store compact evidence and PR head SHAs, not raw logs/diffs.
3. **Plan:** classify every PR; group paired chart/image updates; order dependency waves. Present one table and request rollout approval. Talos is always isolated maintenance.
4. **Baseline:** batch read-only cluster checks; save issue identities and failures. Failed/unavailable checks are **unknown**, never healthy.
5. **Merge:** only the approved wave, **one PR at a time**, pinned to its reviewed head SHA. Stop on failure or changed heads; record each success immediately.
6. **Verify:** batch checks after each wave; verify Flux has consumed the new revision and affected workloads are ready. Stop for new issues; do not equate a fixed sleep with successful reconciliation.
7. **Finish:** final checks, remaining Renovate inventory, safe local jj sync, concise result summary.

## Efficiency contract

- Use `Promise.allSettled()` for independent reads, with concurrency normally **4**. Never parallelize merges, node operations, or dependent steps.
- Filter JSON inside codemode before calling `text()`. Print evidence summaries, new issues, and errors—not full successful responses.
- Use `store()` / `load()` for small JSON state: inventory, classifications, approvals, baseline, release cache, merge ledger. Revalidate mutable evidence before acting.
- Check rejected promises, bash `exit_code`, `truncated`, and JSON parse errors. Do not hide failures behind `grep`, `head`, `|| true`, or empty output.
- All calls must be awaited. Codemode has no filesystem, network, Node APIs, or timers: use tools for those capabilities. Set realistic per-tool and whole-script deadlines.
- Use direct tools if codemode is unavailable, retaining all safety gates. Do not change Pi settings just to run this skill.

**Never initiate a rollout merely because this skill was invoked.** Analysis is read-only; merging requires approval of the presented plan and explicit approval of gated updates.
