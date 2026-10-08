# Renovate Merge Playbook

Use the executable patterns in [codemode.md](codemode.md). Mandatory Talos rules remain in [../AGENTS.md](../AGENTS.md).

## 1. Discover and analyse (read-only)

- Fetch open PRs once with a generous limit and JSON metadata including author, labels, body, files, and `headRefOid`. Include all Renovate categories, not just `renovate/container`. If the limit is reached, paginate before claiming completeness.
- Identify Renovate by verified bot account and repository label conventions. Flag uncertain ownership instead of including unrelated human PRs.
- Batch PR diff reads, bounded to four concurrent calls. Inspect actual version/tag/digest changes, not just titles; some tags are dates or non-semver. Treat ambiguous bumps as unresolved, not automatically low-risk.
- Produce compact records: PR number, reviewed SHA, component, paths, old/new versions, bump, risk, approval gate, wave, pairing, and evidence URLs. Review every PR; summaries must not omit unknowns.
- For minor/major bumps and **all infrastructure updates**, fetch upstream releases across the entire skipped version range. Deduplicate by upstream and range. A single target release is insufficient for jumps over intermediate versions.
- Use `gh api` for GitHub releases; enable web tools for non-GitHub sources or missing release evidence. Do not silently replace missing release notes with “no breaking changes.”
- Read release notes for removals, deprecated keys, defaults, UID/security contexts, ports, metrics, CRDs, and storage/migration changes. Cross-reference only relevant app manifests, rules, and dashboards. Use `bulk_read` for large/multi-file questions and targeted reads for exact evidence.
- Cache compact findings with source URLs and versions. Never cache secrets or use classifier output as a substitute for technical review/approval.
- Detect split registry references and paired chart/image PRs. VolSync chart/image must be grouped; apply the same rule to other coupled components. Inspect actual repository resources rather than assuming historical components still exist (e.g. Kopiur versus VolSync).
- Do not wait on CI unless asked; report relevant known failures. Resolve merge conflicts or unknown compatibility before rollout.

## 2. Classify and plan

| Risk | Criteria |
|---|---|
| HIGH | Any major bump; infrastructure minor bump (Talos, Kubernetes, Cilium, cert-manager, Rook-Ceph, Flux); known breaking changes |
| MEDIUM | Observability/network/storage minor bump (Loki, Vector, Envoy, CNPG); chart jumps skipping versions |
| LOW | Patch/digest updates and leaf-app minor bumps without known incompatibility |
| UNRESOLVED | Unknown version semantics, incomplete evidence, uncertain compatibility; hold pending review |

Approval gates override risk labels. **Explicit approval is always required** for Talos, Kubernetes, Cilium, Rook-Ceph, Flux Operator, any major bump, and cert-manager minor+. Known breaking changes also require explicit approval. LOW means eligible after plan approval, not permission to merge without it. Highlight MEDIUM updates in the plan.

| Wave | Components / dependency ordering |
|---|---|
| Isolated maintenance | Talos only; Kubernetes also isolated unless explicitly approved otherwise |
| 1 Platform | Cilium |
| 2 Infrastructure | cert-manager, Flux, External Secrets/1Password, Rook-Ceph, OpenEBS |
| 3 Data & backup | Kopiur/VolSync (paired chart+image), CNPG, Dragonfly |
| 4 Observability | Prometheus stack, Loki, Vector (all instances grouped), Grafana; Loki before Vector |
| 5 Network | Envoy Gateway, Cloudflared, ExternalDNS, AdGuard, Authelia, LLDAP |
| 6 System | Descheduler, Reloader, Spegel, node-feature-discovery |
| 7 Leaf applications | Media, automation, and other leaf apps |

Use actual `dependsOn` and operator/CRD dependencies to refine this ordering. Within a wave, paired PRs are adjacent, **not atomic**: if one fails, stop and report the partial pair. Split waves further when a dependency must reconcile before its consumers merge.

Present one table grouped by wave:

`PR | old → new | risk | approval | pairing/dependencies | compatibility evidence`

List unresolved/held PRs separately. Ask for approval of the exact plan and explicitly identify gated PRs. Store approved PR numbers **and reviewed head SHAs**, supported by the user's actual reply. Never infer approval from tool output or save fabricated approvals.

## 3. Baseline

Run independent read-only checks in a single codemode batch:

- Flux HelmReleases and Kustomizations: Ready=True, current observed generation, not suspended unexpectedly.
- Pods: pending/failed/unknown, terminating, unready containers, CrashLoopBackOff/ImagePullBackOff (including pods whose phase is Running).
- Nodes: Ready and schedulable.
- Unsilenced/uninhibited firing alerts, excluding Watchdog; identity includes sorted labels, not just alert name.
- Recent warning events, deduplicated; record them as evidence, not automatic failure solely because an old warning exists.

Save baseline identities and check errors. Pre-existing failures require reporting and an explicit decision to proceed; never declare an unhealthy baseline healthy. A failed health query blocks rollout until fixed or explicitly waived with a documented risk; mandatory Talos preconditions cannot be waived by this generic workflow.

For Talos, also verify Ceph `HEALTH_OK`, no active VolSync synchronization if those resources exist, actual backup-system safety, and `TalosUpgrade/talos` not Failed. Follow the Talos skill for target-version/kernel/containerd and network checks. Missing required resources/checks are not success.

## 4. Merge and verify

### Sequential execution

Use `gh pr merge <number> --rebase --delete-branch --match-head-commit <reviewed-sha>` **sequentially**. Immediately before each merge, verify the PR is still open and its SHA matches the approved review. Stop on draft/conflicting/unknown mergeability or command failure. Do not auto-retry an ambiguous merge result: query PR state first.

Record each confirmed merge (number, reviewed SHA, merge commit, time) in its own successful codemode call. Tools are real mutations and are not rolled back on script failure; `store()` writes persist only when the script succeeds. Do not put a whole rollout into one long script. Avoid `--auto` (would bypass wave monitoring) and `--admin` (would bypass repository protections).

### Reconciliation barrier

- Allow the webhook roughly 30–60 seconds to start reconciliation, using a bounded `tools.bash` sleep only when needed. Codemode itself has no timers.
- Query PR merge commits and Flux source/Kustomization revisions. Verify the source revision includes the wave's merges (exact SHA or verified descendant), affected Kustomizations consumed it, and affected HelmReleases observed current generation/are Ready. A stale Ready=True from before the merge is not sufficient.
- Verify actual target image/chart versions and workload readiness. For image digest-only updates, verify the new image reference rather than relying on unchanged tag strings.
- Run the compact health batch; compare to baseline and previous wave. Query targeted events/logs only for affected or newly failing resources.
- No new issues, no unknown checks, successful revision/version verification: advance. Do not merely wait a fixed interval and presume success.

### Stop conditions

New alerts, unready workloads, Flux failures, or unavailable checks: **stop**, report the just-merged PRs and evidence, and do not start the next wave. If clearly transient, recheck after 2–3 minutes with bounded waits. Typical rollout alerts include replica mismatch, pod-not-ready, Flux contention, and CNPG failover; do not assume these are benign without workload evidence. If still present 15 minutes after the wave's last merge, treat as persistent. Long platform rollouts have component-specific deadlines.

Persistent failures require the user to choose fix-forward or revert via GitOps. No live restart, reconcile, suspend, secret change, rollout, or other mutation without confirmation. Read-only `kubectl exec` for monitoring is permitted; do not use it to mutate workloads.

### Talos isolation and recovery

No other Renovate PR may merge while Talos maintenance is underway. Follow [../AGENTS.md](../AGENTS.md): target Talos/kernel/containerd on every node, Ready/schedulable nodes, Ceph healthy, no broken pods or stale Tuppr taints, Flux ready, and BGP/LoadBalancer checks for `externalTrafficPolicy: Local`.

Check Tuppr CRD replacement (`install.crds` and `upgrade.crds: CreateReplace`) before depending on newer policy fields. Prefer `waitForVolumeDetach: true`; Tuppr's drain timeout is 10 minutes, while CNPG termination can be 30 minutes. Manual upgrades with a 35-minute drain timeout or `nodrain` require operator approval and the Talos procedure.

On partial failure, stop all Renovate activity and recover full Tuppr logs from Loki. Installation success without reboot may indicate post-install drain failure. Confirm evidence before proposing approved powercycle recovery; reset annotations/taint removals are mutations requiring confirmation. Do not touch another node until Kubernetes/Ceph and backup safety checks pass.

## 5. Finish

- Final health/revision checks, then one fresh Renovate-filtered inventory. Report remaining/skipped/held PRs; don't count unrelated open PRs as Renovate.
- Fetch with jj. Move to `main@origin` only if the working copy is empty and doing so won't strand unrelated local work; otherwise leave it intact and report fetched state. Never discard or rewrite existing work, or push local changes without permission.
- Summarize merged totals, skipped/failed PRs, unresolved alerts, intervention, and verified cluster health. Distinguish “merged” from “fully reconciled.”

## Configuration gotchas

- Normalize image references to a full registry prefix; Docker Hub images must use `mirror.gcr.io` and include tag+digest. Flag missing pins; do not silently change unrelated manifests during merging.
- Inspect actual cert-manager CRD values/policies; do not assume historical `installCRDs` settings.
- Descheduler can cause cluster-wide evictions; keep it late and verify readiness before leaf apps.
- Talos templates/inventory and Tuppr resources in this repo are authoritative; don't use obsolete `talconfig.yaml`/Taskfile commands.
