---
name: renovate-merge
description: Bulk-merge open Renovate PRs safely. Analyses breaking changes, fetches upstream release notes, classifies risk, builds a dependency-ordered merge plan with user approval gates, executes the rollout, and monitors cluster health between waves. Use when asked to merge Renovate PRs, review dependency updates, or roll out pending updates.
---

# Renovate Merge

Bulk-merge open Renovate dependency-update PRs with breaking-change analysis, a dependency-ordered rollout plan, and post-merge cluster health monitoring.

Read the [merge playbook](references/playbook.md) for the full procedure. The sections below are a quick reference.

## Cost-aware model routing

When this skill is run manually, via `/skill:renovate-merge`, or from a command/extension that delegates subtasks, match model cost to task complexity. Prefer the cheapest capable model, batch simple work, and escalate selectively.

| Subtask | Default tier | Suggested model |
|---------|--------------|-----------------|
| PR inventory, labels, file lists, grouping checks | Low-cost | `openai-codex/gpt-5.3-codex-spark:minimal` or `openai-codex/gpt-5.4-mini:low` |
| Patch/digest leaf-app classification | Low-cost | `openai-codex/gpt-5.4-mini:low` |
| Minor release-note summarisation for leaf apps | Low/medium | `openai-codex/gpt-5.4-mini:low` or `openai-codex/gpt-5.4-mini:medium` |
| Config grep and cross-reference | Low-cost for search; escalate only for interpretation | `openai-codex/gpt-5.4-mini:low` |
| Major bumps, infra minor bumps, approval-gated PRs, known breaking changes | Frontier | `openai-codex/gpt-5.5:high` |
| Dependency wave planning with coupled PRs or many PRs | Medium by default; frontier if complex | `openai-codex/gpt-5.4-mini:medium`, escalate to `openai-codex/gpt-5.5:high` |
| Rollout execution and routine health checks | Low-cost/current | No frontier model needed |
| Persistent failure triage, especially storage/network/GitOps | Frontier | `openai-codex/gpt-5.5:high` or `openai-codex/gpt-5.5:xhigh` |

Do **not** run a frontier model once per PR by default. Batch low-risk PRs through a cheaper model and escalate only PRs or excerpts that meet the escalation criteria in the playbook.

## Quick Reference

### 1. Analyse

```bash
# List all open Renovate PRs
gh pr list --label renovate/container --json number,title,labels \
  --jq '.[] | "\(.number)|\(.title)|\([.labels[].name] | join(","))"'
```

Use a low-cost model for the mechanical inventory pass. Classify every PR into a **risk tier** and **merge wave** using the rules in the playbook, then escalate only approval-gated or ambiguous PRs.

### 2. Plan

Present the merge plan as a table grouped by wave. Flag any PRs that require **user approval** before proceeding (see approval gates in the playbook).

### 3. Roll out

Merge wave-by-wave using `gh pr merge <number> --rebase`. Monitor cluster health between waves.

### 4. Monitor

```bash
# Firing alerts
kubectl exec -n observability svc/kube-prometheus-stack-alertmanager -- \
  wget -qO- 'http://localhost:9093/api/v2/alerts?silenced=false&inhibited=false&active=true' | \
  jq -r '.[] | select(.labels.alertname != "Watchdog") | "\(.labels.alertname) | \(.labels.namespace // "cluster") | \(.annotations.summary // "")"'

# Broken HelmReleases / Kustomizations
kubectl get hr -A --no-headers | grep -v "True"
kubectl get ks -A --no-headers | grep -v "True"

# Pods not running
kubectl get pods -A --field-selector 'status.phase!=Running,status.phase!=Succeeded' --no-headers
```
