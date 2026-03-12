---
name: renovate-merge
description: Bulk-merge open Renovate PRs safely. Analyses breaking changes, fetches upstream release notes, classifies risk, builds a dependency-ordered merge plan with user approval gates, executes the rollout, and monitors cluster health between waves. Use when asked to merge Renovate PRs, review dependency updates, or roll out pending updates.
---

# Renovate Merge

Bulk-merge open Renovate dependency-update PRs with breaking-change analysis, a dependency-ordered rollout plan, and post-merge cluster health monitoring.

Read the [merge playbook](references/playbook.md) for the full procedure. The sections below are a quick reference.

## Quick Reference

### 1. Analyse

```bash
# List all open Renovate PRs
gh pr list --label renovate/container --json number,title,labels \
  --jq '.[] | "\(.number)|\(.title)|\([.labels[].name] | join(","))"'
```

Classify every PR into a **risk tier** and **merge wave** using the rules in the playbook.

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
