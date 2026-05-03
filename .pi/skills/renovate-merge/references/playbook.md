# Renovate Merge Playbook

Complete procedure for safely bulk-merging Renovate PRs in this home-ops repository.

## Overview

This is a three-phase workflow:

1. **Analyse** — Investigate every open Renovate PR for breaking changes and risk
2. **Plan** — Build a dependency-ordered merge plan with user approval gates
3. **Roll out** — Execute the plan wave-by-wave with cluster health checks

---

## Model Routing Policy

The workflow may be run by a human, the main Pi agent, or a Pi command/extension that delegates subtasks to subagents. Route each subtask to the cheapest model tier that is likely to be reliable, and reserve high-cost frontier models for judgment-heavy risk analysis.

### Default model tiers

| Subtask | Default tier | Suggested model |
|---------|--------------|-----------------|
| Gather PR list, labels, titles, branches, changed files | Low-cost | `openai-codex/gpt-5.3-codex-spark:minimal` or `openai-codex/gpt-5.4-mini:low` |
| Detect bump type, component namespace/app, obvious split-image/grouping issues | Low-cost | `openai-codex/gpt-5.4-mini:low` |
| Summarise minor release notes for leaf applications | Low/medium | `openai-codex/gpt-5.4-mini:low` or `openai-codex/gpt-5.4-mini:medium` |
| Run repository greps and config cross-references | Low-cost for mechanical search | `openai-codex/gpt-5.4-mini:low` |
| Interpret major releases, infra/storage/network updates, or known breaking changes | Frontier | `openai-codex/gpt-5.5:high` |
| Build the merge-wave plan for simple all-low-risk batches | Medium | `openai-codex/gpt-5.4-mini:medium` |
| Build the merge-wave plan for approval-gated or coupled PR batches | Frontier | `openai-codex/gpt-5.5:high` |
| Execute merges and routine health checks | Low-cost/current | No frontier model required |
| Triage persistent post-merge failures | Frontier | `openai-codex/gpt-5.5:high` or `openai-codex/gpt-5.5:xhigh` |

### Escalation criteria

Use a high-cost frontier model only when at least one of these is true:

- The PR is a **major** version bump.
- The PR touches Talos, Kubernetes, Cilium, Rook-Ceph, Flux, cert-manager, CloudNativePG, Envoy Gateway, External Secrets, VolSync, or another platform dependency.
- Release notes mention breaking changes, migrations, removed configuration, changed defaults, auth/security changes, CRD/API changes, UID/security-context changes, storage behaviour, or networking behaviour.
- Multiple Renovate PRs must be merged together, or the same component is split across chart/image/registry-prefix PRs.
- The merge plan has approval-gated waves or multiple infrastructure/storage/network components whose order matters.
- Post-merge health checks show persistent failures or ambiguous symptoms.

Stay on lower-cost models for mechanical or low-risk work: PR inventory, `gh pr diff --name-only`, patch/digest leaf-app updates, table formatting, command execution, routine `kubectl`/`flux`/`gh` checks, and final summaries when health checks are normal.

Do **not** run a frontier model once per PR by default. Batch low-risk PRs through a cheaper model, then escalate only the specific PRs, release-note excerpts, or failure symptoms that meet the criteria above.

---

## Phase 1: Analyse

Start with a cheap, mechanical pre-screen. The first pass should gather metadata, detect obvious low-risk updates, and identify only the PRs that need deeper release-note or breaking-change analysis.

### 1.1 Gather PRs

```bash
gh pr list --json number,title,headRefName,labels,body \
  --jq '.[] | "\(.number)|\(.title)|\(.headRefName)|\([.labels[].name] | join(","))"'
```

### 1.2 Classify each PR

Use a low-cost model for this pass unless the PR already meets an escalation criterion. For every PR, determine:

| Field | How to determine |
|-------|-----------------|
| **Version bump type** | Parse from title: `vX.Y.Z → vX.Y.Z`. Classify as major / minor / patch / digest |
| **Component tier** | Map the changed app to a tier (see [Merge Waves](#merge-waves) below) |
| **Risk level** | Combine bump type + tier (see [Risk Classification](#risk-classification)) |
| **Files changed** | `gh pr diff <number> --name-only` |
| **Grouping issues** | Check if the same image is split across multiple PRs (different registry prefixes like `docker.io/` vs bare name). If so, flag for the user. |

### 1.3 Fetch release notes for non-trivial updates

Do this selectively. Use low/medium-cost analysis for routine minor leaf-application updates. Escalate to a frontier model for major bumps, infrastructure/storage/network updates, approval-gated components, or release notes that mention breaking changes.

For any PR that is **minor** or **major** bump, or touches infrastructure components, fetch upstream release notes:

```bash
# For GitHub-hosted projects
gh api repos/<owner>/<repo>/releases/tags/<tag> --jq '.body' | head -200
```

Look specifically for:
- **Breaking changes** sections
- Deprecated configuration keys that the current HelmRelease values use
- Changed defaults (ports, UIDs, security contexts, metric names)
- Removed features or APIs

### 1.4 Cross-reference with current config

Use cheap mechanical search first, then escalate only if interpreting the match requires judgment. For each flagged breaking change, check whether it affects this repo:

```bash
# Example: check if a deprecated Helm value is used
rg "<deprecated_key>" kubernetes/apps/<namespace>/<app>/ --type yaml

# Example: check if a changed metric is referenced in dashboards or rules
rg "<metric_name>" kubernetes/ --type yaml
```

### 1.5 Check for paired PRs

Some components have both a **chart** and an **image** PR that must be merged together:
- VolSync: chart (`charts-mirror/volsync-perfectra1n`) + image (`perfectra1n/volsync`)
- Any app where Renovate creates separate PRs for the Helm chart OCI tag and the container image tag

Flag these as **must merge together** in the plan.

### 1.6 Present analysis

Keep the table-generation step on a low-cost/current model unless the analysis itself is still unresolved. Output a summary table:

```
| PR | Update | Bump | Risk | Notes |
|----|--------|------|------|-------|
| #1234 | cert-manager v1.19→v1.20 | minor | 🔴 HIGH | UID changed to 65532, key rotation policy now GA |
| #1235 | adguard v0.107.72→73 | patch | 🟢 LOW | Bug fix only |
```

---

## Phase 2: Plan

### Risk Classification

| Risk | Criteria | Action |
|------|----------|--------|
| 🔴 **HIGH** | Major version bump of any component; minor bump of infrastructure (Talos, Kubernetes, Cilium, cert-manager, Rook-Ceph, Flux); any PR with known breaking changes | Requires explicit user approval |
| 🟡 **MEDIUM** | Minor version bump of observability/network/storage components (Loki, Vector, Envoy, CloudNativePG); chart version jumps that skip versions | Highlight to user, merge unless user objects |
| 🟢 **LOW** | Patch bumps, digest-only updates, minor bumps of leaf applications | Auto-merge |

### Approval Gates

**Always require explicit user approval before merging:**

1. **Talos Linux** updates (node OS — requires rolling reboot of all nodes)
2. **Kubernetes** version bumps (control plane + kubelet upgrade)
3. **Cilium** updates (CNI — brief network disruption possible)
4. **Rook-Ceph** updates (storage — data plane risk)
5. **Flux Operator** updates (GitOps engine — reconciliation disruption)
6. **Any major version bump** (any component)
7. **cert-manager minor+** (TLS infrastructure — can break all ingress if misconfigured)

Present these to the user with the breaking change analysis and wait for confirmation before including them in the rollout.

### Merge Waves

Order merges by dependency depth — infrastructure first, leaf apps last. Allow 30-60 seconds between waves for Flux to reconcile via webhook.

| Wave | Tier | Components | Why first |
|------|------|-----------|-----------|
| **1** | Platform | Talos, Kubernetes (via Tuppr), Cilium | Node-level, everything depends on these |
| **2** | Infrastructure | cert-manager, Flux, External Secrets (1Password), Rook-Ceph, OpenEBS | Cluster services that apps depend on |
| **3** | Storage & Backup | VolSync (chart + image together), CloudNativePG, Dragonfly | Data layer |
| **4** | Observability | Prometheus stack, Loki, Vector (all instances grouped), Grafana | Log/metric pipeline — merge Loki before Vector |
| **5** | Network | Envoy Gateway, Cloudflared, ExternalDNS, AdGuard, Authelia, LLDAP | Routing and DNS |
| **6** | System | Descheduler, Reloader, Spegel, node-feature-discovery | Cluster utilities |
| **7** | Applications | All leaf apps (media, automation, default namespace) | No downstream dependents |

### Present the plan

Use a medium-cost model for simple all-low-risk batches. Use a frontier model for plan synthesis only if the batch includes approval-gated PRs, coupled chart/image PRs, major updates, or more than one infrastructure/storage/network component.

Output the merge plan as a table grouped by wave:

```
## Merge Plan

### Wave 1: Platform [REQUIRES APPROVAL]
| PR | Update | Risk |
|----|--------|------|
| #1234 | Talos v1.12.4 → v1.12.5 | 🔴 HIGH |

### Wave 2: Infrastructure
| PR | Update | Risk |
|----|--------|------|
| #1235 | cert-manager v1.19.4 → v1.20.0 | 🟡 MEDIUM |

... (remaining waves)

Proceed with rollout? (Waves requiring approval are gated separately)
```

Wait for the user to confirm before starting the rollout.

---

## Phase 3: Roll Out

### 3.1 Pre-flight checks

Before starting any merges, verify the cluster is healthy:

```bash
# All HelmReleases reconciled
kubectl get hr -A --no-headers | grep -v "True"

# All Kustomizations reconciled
kubectl get ks -A --no-headers | grep -v "True"

# No crashing pods
kubectl get pods -A --field-selector 'status.phase!=Running,status.phase!=Succeeded' --no-headers

# Check current firing alerts (baseline — note any pre-existing alerts)
kubectl exec -n observability svc/kube-prometheus-stack-alertmanager -- \
  wget -qO- 'http://localhost:9093/api/v2/alerts?silenced=false&inhibited=false&active=true' | \
  jq -r '.[] | select(.labels.alertname != "Watchdog") | .labels.alertname' | sort -u
```

Record any pre-existing issues so they aren't confused with merge-induced problems.

### 3.2 Merge method

This repository only allows **rebase merges**:

```bash
gh pr merge <number> --rebase
```

### 3.3 Execute wave by wave

For each wave:

1. **Check approval** — If the wave contains approval-gated PRs and the user hasn't approved, skip and ask.
2. **Merge all PRs in the wave** sequentially (one `gh pr merge` at a time to avoid rebase conflicts).
3. **Wait 30-60 seconds** for Flux webhook reconciliation to kick in.
4. **Health check** — Run the monitoring commands below. If any **new** alerts fire or HelmReleases/Kustomizations fail, **stop and report** before continuing to the next wave.

### 3.4 Health monitoring between waves

Routine monitoring and command execution do not need a frontier model. Escalate only when a health check shows a persistent or ambiguous new failure.

```bash
# New firing alerts (compare against pre-flight baseline)
kubectl exec -n observability svc/kube-prometheus-stack-alertmanager -- \
  wget -qO- 'http://localhost:9093/api/v2/alerts?silenced=false&inhibited=false&active=true' | \
  jq -r '.[] | select(.labels.alertname != "Watchdog") | "\(.labels.alertname) | \(.labels.namespace // "cluster")"'

# Failed HelmReleases
kubectl get hr -A --no-headers | grep -v "True"

# Failed Kustomizations
kubectl get ks -A --no-headers | grep -v "True"

# Pods not running
kubectl get pods -A --field-selector 'status.phase!=Running,status.phase!=Succeeded' --no-headers | head -20

# Recent warning events (last 5 minutes)
kubectl get events -A --sort-by='.lastTimestamp' --field-selector 'type=Warning' --no-headers | tail -10
```

### 3.5 Handling failures

If a health check shows problems after a wave:

1. **Do NOT proceed** to the next wave.
2. Report the issue to the user with:
   - Which PR(s) were just merged
   - The specific error (HelmRelease status, pod logs, alert details)
   - Suggested remediation
3. Check if it's **transient** (e.g. `KubeDeploymentReplicasMismatch` during a rolling update — these resolve within ~5 minutes) vs **persistent** (e.g. CrashLoopBackOff, failed Helm upgrade).
4. For transient issues: wait 2-3 minutes and re-check before escalating.
5. For persistent issues: the user needs to decide whether to fix-forward or revert.

### 3.6 Transient alerts to expect

These alerts commonly fire during bulk merges and **self-resolve** within 5-15 minutes:

| Alert | Cause | Self-resolves? |
|-------|-------|---------------|
| `KubeDeploymentReplicasMismatch` | Rolling updates during HelmRelease upgrades | ✅ Yes (once rollout completes) |
| `KustomizationReconciliationFailure` | Flux contention from rapid successive reconciliations | ✅ Yes (once queue drains) |
| `KubePodNotReady` | Pods restarting during upgrades | ✅ Yes (once new pods pass readiness) |
| `CPGClusterNotHealthy` | Brief CloudNativePG failover during operator updates | ✅ Yes (within 30s usually) |

If these alerts persist for **more than 15 minutes** after the last merge in a wave, treat them as persistent failures.

### 3.7 Post-rollout

After all waves are complete:

1. Run a final health check (same commands as 3.4).
2. Sync local jj state:
   ```bash
   jj git fetch
   jj new main
   ```
3. Verify no open Renovate PRs remain:
   ```bash
   gh pr list --json number,title --jq 'length'
   ```
4. Report summary to the user:
   - Total PRs merged
   - Any alerts that fired and resolved
   - Any issues that required intervention
   - Current cluster health status

---

## Appendix: Common Gotchas

### Split image PRs
Renovate may create separate PRs for the same image if referenced with different registry prefixes (e.g. `docker.io/org/image` vs `org/image`). The fix is to normalize the `repository:` field in the HelmRelease to always include the full registry prefix, and add a Renovate grouping rule in `.renovate/groups.json5`.

### Missing digest pins
Container images should always include a digest: `tag: v1.0.0@sha256:abc123...`. If a PR updates an image that lacks a digest, note it in the analysis. The current digest can be obtained:
```bash
skopeo inspect --raw docker://<repository>:<tag> | sha256sum | awk '{print "sha256:" $1}'
```

### cert-manager CRD updates
cert-manager uses `installCRDs: true` in its Helm values. Minor version bumps may update CRDs which can briefly disrupt certificate issuance. This is transient.

### Descheduler side effects
Descheduler updates can trigger pod evictions across the cluster as the new version rebalances workloads. This causes cascading `KubeDeploymentReplicasMismatch` alerts. Merge descheduler in a later wave (Wave 6) to avoid compounding with other rollouts.

### Talos upgrades via Tuppr
Talos version bumps (in `talconfig.yaml` and `talosupgrade.yaml`) don't immediately upgrade nodes — Tuppr orchestrates the rolling upgrade. However, the Taskfile `TALOS_VERSION` variable is also updated, so manual `task talos:upgrade` would use the new version. The actual rollout is controlled and safe, but the user should be aware nodes will reboot.
