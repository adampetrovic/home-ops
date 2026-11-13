# Renovate Merge Playbook

Use the executable patterns in [codemode.md](codemode.md). Mandatory Talos rules remain in [../AGENTS.md](../AGENTS.md).

## How updates reach `main`

- Renovate (the `bot-adam` GitHub App) marks every patch, minor and digest update for auto-merge and turns on GitHub auto-merge when it opens or updates the PR. Majors and Kritika's own chart are never marked.
- The `main` ruleset requires the `Kritika / Review` status from the Kritika app and one approval from someone other than the last pusher. Rebase is the only merge method.
- Kritika (`bot-kritika[bot]`) approves a Renovate update when the review scores 5/5 and the risk is low. Paths under `confidence.floors` in `kubernetes/apps/kritika/kritika/app/helmrelease.yaml` are always rated high, so those updates are never approved by Kritika.
- An approved PR merges by GitHub auto-merge when its flag is on. Without the flag, Renovate merges it on a later run, at most two PRs per run.
- A PR Kritika did not approve stays open until the operator approves it. That approval is this skill's merge step.

## 1. Discover (read-only)

- Fetch open PRs once with a generous limit and JSON metadata including author, labels, files, `headRefOid`, `reviewDecision`, `reviews`, `statusCheckRollup`, and `autoMergeRequest`. Include all Renovate categories, not just `renovate/container`. If the limit is reached, paginate before claiming completeness.
- Identify Renovate by the verified `bot-adam` app account and repository label conventions. Flag uncertain ownership instead of including unrelated human PRs.
- For each PR, read the Kritika evidence for the **current head**:
  - the `Kritika / Review` commit status and its description, for example `kritika: confidence 5/5, no findings`, `kritika: confidence 4/5, below 5, no findings`, or `kritika: skipped (...)`
  - the summary comment that starts with `<!-- kritika:pr-<number> -->`: score, risk level and its reason, the `Approved` or `**Not approved**: <reason>` line, findings by priority, the sources under "Review context", and the "Last reviewed commit"
  - an `APPROVED` review by `bot-kritika[bot]` whose commit is the head
- Assign one Kritika state per PR:

| State | Evidence | What happens next |
|---|---|---|
| APPROVED | Kritika approval on the head and status `success` | Merges without this skill. Report it; verify it after it lands |
| HELD-RISK | Status `success`, 5/5, not approved because the risk is above low or a floor holds it | Operator decision on blast radius and timing |
| HELD-SCORE | Status `failure`, score below 5 | Resolve the concern the reason names; the failing status blocks the merge until a new review passes |
| HELD-POLICY | 5/5 and low risk but not approved: a major, a file that configures Kritika, or another stated reason | Operator decision; read the reason |
| UNREVIEWED | No status on the head, `pending` beyond a few minutes, `error`, a skipped or capped review, or a last reviewed commit that is not the head with no review of the head | Request a review before analysing further |

- Kritika usually skips an unchanged Renovate rebase and carries the earlier score to the new head. That is a reviewed PR when the diff is the same as the one reviewed. A head with new content and only an older review is not.
- Do not wait on other CI unless asked; report relevant known failures. Resolve merge conflicts or unknown compatibility before rollout.

## 2. Analyse the held PRs

Start from the Kritika review, then fill what it leaves open.

- Read the reason beside the risk level in full. It says what the review compared and, often, what it did **not** check ("did not open the migration files", "no source read beyond the description"). Each unchecked item is your work.
- Read every finding. P0 and P1 block the PR until resolved. P2 and P3 do not lower the score: list them in the plan with a judgement, because a version skew or a missing pairing often sits there.
- Check the sources and commands under "Review context". A review with no sources judged the update from the PR description alone: treat its 5/5 as weak evidence.
- Do your own upstream research, across the **entire skipped version range**, for: every infrastructure update, every major, every HELD-SCORE PR, and any review with no sources. Deduplicate by upstream and range. A single target release is insufficient for jumps over intermediate versions.
- For a leaf-app minor that is HELD-RISK with a sourced, complete review, Kritika's evidence is enough. Confirm its claims about this repository against the actual manifests, and move on.
- Use `gh api` for GitHub releases; enable web tools for non-GitHub sources or missing release evidence. Do not silently replace missing release notes with "no breaking changes."
- Read release notes for removals, deprecated keys, defaults, UID/security contexts, ports, metrics, CRDs, and storage/migration changes. Cross-reference only relevant app manifests, rules, and dashboards. Use `bulk_read` for large/multi-file questions and targeted reads for exact evidence.
- Inspect actual version/tag/digest changes in the diff, not just titles; some tags are dates or non-semver. Treat ambiguous bumps as unresolved.
- Detect split registry references and paired chart/image PRs. Kopiur chart/image must be grouped; apply the same rule to other coupled components, such as an operator image and its CRD manifest. Kritika reviews each PR alone and can approve one half of a pair: check APPROVED PRs for a held partner and say so in the plan.
- Produce compact records: PR number, reviewed SHA, component, paths, old/new versions, bump, Kritika state, score, Kritika risk, your risk, approval gate, wave, pairing, and evidence URLs. Review every held PR; summaries must not omit unknowns.
- Cache compact findings with source URLs and versions. Never cache secrets or use Kritika's or any classifier's output as a substitute for the operator's approval.

### Getting an unreviewed or failed PR reviewed

- Request a review with a PR comment: `@bot-kritika review`, or `@bot-kritika review <what to look at>` to point it at the gap you found. The comment is posted from the operator's account, subscribes them to the thread, and costs tokens, so list the PRs and get one approval for the batch first.
- Kritika handles at most five mentions per PR per hour and 100 reviews a day. A capped review reports `success` with no approval and no new score: check the status description, not just the state.
- A re-review reads the rules and context from the PR's merge base, so a PR on an old base is judged without rules added since.
- To contest a finding, reply in its thread with the reason. Kritika weighs the reply on its next review and dismisses the finding if the reason holds.
- If Kritika is unavailable, do the full analysis yourself and present it, but the required status cannot be produced by this skill. Hand those merges to the operator.

## 3. Classify and plan

Kritika's risk is the floor. Raise it by these criteria when they apply; never lower it.

| Risk | Criteria |
|---|---|
| HIGH | Kritika rates it high or critical (including every pinned path); any major bump; infrastructure minor bump (Talos, Kubernetes, Cilium, cert-manager, Rook-Ceph, Flux); known breaking changes |
| MEDIUM | Kritika rates it medium; observability/network/storage minor bump (Loki, Vector, Envoy, CNPG); chart jumps skipping versions; forward-only data migrations |
| LOW | Kritika rates it low and your evidence agrees |
| UNRESOLVED | Unreviewed by Kritika, a failing score not yet explained, unknown version semantics, incomplete evidence; hold pending review |

Approval gates override risk labels. **Explicit approval is always required** for Talos, Kubernetes, Cilium, Rook-Ceph, Flux Operator, any major bump, and cert-manager minor+. Known breaking changes and open P0/P1 findings also require explicit approval. Every held PR needs plan approval: Kritika declining it is the reason it is in the plan.

| Wave | Components / dependency ordering |
|---|---|
| Isolated maintenance | Talos only; Kubernetes also isolated unless explicitly approved otherwise |
| 1 Platform | Cilium |
| 2 Infrastructure | cert-manager, Flux, External Secrets/1Password, Rook-Ceph, OpenEBS |
| 3 Data & backup | Kopiur (paired chart+image), CNPG, Dragonfly |
| 4 Observability | Prometheus stack, Loki, Vector (all instances grouped), Grafana; Loki before Vector |
| 5 Network | Envoy Gateway, Cloudflared, ExternalDNS, AdGuard, Authelia, LLDAP |
| 6 System | Descheduler, Reloader, Spegel, node-feature-discovery |
| 7 Leaf applications | Media, automation, and other leaf apps |

Use actual `dependsOn` and operator/CRD dependencies to refine this ordering. Within a wave, paired PRs are adjacent, **not atomic**: if one fails, stop and report the partial pair. Split waves further when a dependency must reconcile before its consumers merge.

Present one table grouped by wave:

`PR | old → new | Kritika (score, risk, state) | your risk | approval | pairing/dependencies | evidence beyond Kritika's`

Then list separately:

- **Merging on their own:** APPROVED PRs, whether auto-merge is on, and any held partner.
- **Unreviewed:** PRs that need a Kritika review, with the request you propose.
- **Blocked by a failing score:** what the concern is and what would resolve it.

Ask for approval of the exact plan and explicitly identify gated PRs. Store approved PR numbers **and reviewed head SHAs**, supported by the user's actual reply. Never infer approval from tool output, from Kritika's approval, or save fabricated approvals.

## 4. Baseline

Run independent read-only checks in a single codemode batch:

- Flux HelmReleases and Kustomizations: Ready=True, current observed generation, not suspended unexpectedly.
- Pods: pending/failed/unknown, terminating, unready containers, CrashLoopBackOff/ImagePullBackOff (including pods whose phase is Running).
- Nodes: Ready and schedulable.
- Unsilenced/uninhibited firing alerts, excluding Watchdog; identity includes sorted labels, not just alert name.
- Recent warning events, deduplicated; record them as evidence, not automatic failure solely because an old warning exists.
- Renovate PRs merged in the last day: confirm Flux consumed each merge commit and the affected workloads are ready. Nobody watched those merges land.
- APPROVED PRs still open: they can merge at any moment during the rollout. Either let them land and include them in the baseline, or note them so a new issue can be attributed.

Save baseline identities and check errors. Pre-existing failures require reporting and an explicit decision to proceed; never declare an unhealthy baseline healthy. A failed health query blocks rollout until fixed or explicitly waived with a documented risk; mandatory Talos preconditions cannot be waived by this generic workflow.

For Talos, also verify Ceph `HEALTH_OK`, no active Kopiur snapshot or restore, actual backup-system safety, and `TalosUpgrade/talos` not Failed. Follow the Talos skill for target-version/kernel/containerd and network checks. Missing required resources/checks are not success.

## 5. Merge and verify

### Sequential execution

A held PR merges when the operator approves it on GitHub. For each PR in the approved wave, **sequentially**:

1. Verify it is still open, not a draft, mergeable, its head SHA matches the approved review, and `Kritika / Review` is `success` on that head. A failing or missing status blocks the merge: stop and report it.
2. Approve it: `gh pr review <number> --approve`. This posts the operator's approval and is the mutation the plan approval covers. Never approve a PR outside the approved plan.
3. If GitHub auto-merge is on for the PR, the approval merges it. Do not also run a merge command; confirm the merge in the next call.
4. Otherwise merge it: `gh pr merge <number> --rebase --delete-branch --match-head-commit <reviewed-sha>`.

Stop on draft/conflicting/unknown mergeability or command failure. Do not auto-retry an ambiguous result: query PR state first.

Record each confirmed merge (number, reviewed SHA, merge commit, time, and whether GitHub or the command merged it) in its own successful codemode call. Tools are real mutations and are not rolled back on script failure; `store()` writes persist only when the script succeeds. Do not put a whole rollout into one long script.

Do not turn on auto-merge for a held PR to save a step: it would merge the moment it is approved, outside wave monitoring. Do not use `--admin`: it skips the ruleset this flow depends on. A PR that cannot merge within the ruleset goes back to the operator.

To clear a backlog of APPROVED PRs that have no auto-merge flag, propose it in the plan as its own wave and merge them one at a time with the merge command. They need no further approval on GitHub.

### Reconciliation barrier

- Allow the webhook roughly 30–60 seconds to start reconciliation, using a bounded `tools.bash` sleep only when needed. Codemode itself has no timers.
- Query PR merge commits and Flux source/Kustomization revisions. Verify the source revision includes the wave's merges (exact SHA or verified descendant), affected Kustomizations consumed it, and affected HelmReleases observed current generation/are Ready. A stale Ready=True from before the merge is not sufficient.
- List what else merged since the wave began. An auto-merged PR in the same window is part of what you are verifying.
- Verify actual target image/chart versions and workload readiness. For image digest-only updates, verify the new image reference rather than relying on unchanged tag strings.
- Run the compact health batch; compare to baseline and previous wave. Query targeted events/logs only for affected or newly failing resources.
- No new issues, no unknown checks, successful revision/version verification: advance. Do not merely wait a fixed interval and presume success.

### Stop conditions

New alerts, unready workloads, Flux failures, or unavailable checks: **stop**, report the just-merged PRs and evidence, and do not start the next wave. If clearly transient, recheck after 2–3 minutes with bounded waits. Typical rollout alerts include replica mismatch, pod-not-ready, Flux contention, and CNPG failover; do not assume these are benign without workload evidence. If still present 15 minutes after the wave's last merge, treat as persistent. Long platform rollouts have component-specific deadlines.

Persistent failures require the user to choose fix-forward or revert via GitOps. No live restart, reconcile, suspend, secret change, rollout, or other mutation without confirmation. Read-only `kubectl exec` for monitoring is permitted; do not use it to mutate workloads.

Stopping a wave does not stop auto-merges. If the cluster is unhealthy and APPROVED PRs are still open, tell the operator: they can hold one with a "request changes" review.

### Talos isolation and recovery

No other Renovate PR may merge while Talos maintenance is underway. Follow [../AGENTS.md](../AGENTS.md): target Talos/kernel/containerd on every node, Ready/schedulable nodes, Ceph healthy, no broken pods or stale Tuppr taints, Flux ready, and BGP/LoadBalancer checks for `externalTrafficPolicy: Local`.

Check Tuppr CRD replacement (`install.crds` and `upgrade.crds: CreateReplace`) before depending on newer policy fields. Prefer `waitForVolumeDetach: true`; Tuppr's drain timeout is 10 minutes, while CNPG termination can be 30 minutes. Manual upgrades with a 35-minute drain timeout or `nodrain` require operator approval and the Talos procedure.

On partial failure, stop all Renovate activity and recover full Tuppr logs from Loki. Installation success without reboot may indicate post-install drain failure. Confirm evidence before proposing approved powercycle recovery; reset annotations/taint removals are mutations requiring confirmation. Do not touch another node until Kubernetes/Ceph and backup safety checks pass.

## 6. Finish

- Final health/revision checks, then one fresh Renovate-filtered inventory by Kritika state. Report remaining/skipped/held PRs; don't count unrelated open PRs as Renovate.
- Fetch with jj. Move to `main@origin` only if the working copy is empty and doing so won't strand unrelated local work; otherwise leave it intact and report fetched state. Never discard or rewrite existing work, or push local changes without permission.
- Summarize merged totals (by this rollout and on their own), skipped/failed PRs, unresolved alerts, intervention, and verified cluster health. Distinguish "merged" from "fully reconciled."
- Report where Kritika and your review disagreed: an approval you would have held, a hold that needed no thought, a miss. A repeated pattern belongs in a Kritika rule (`.kritika.yaml`) or a pinned path (`confidence.floors`); propose it, do not add it unasked.

## Configuration gotchas

- Normalize image references to a full registry prefix; Docker Hub images must use `mirror.gcr.io` and include tag+digest. Flag missing pins; do not silently change unrelated manifests during merging.
- Inspect actual cert-manager CRD values/policies; do not assume historical `installCRDs` settings.
- Descheduler can cause cluster-wide evictions; keep it late and verify readiness before leaf apps.
- Talos templates/inventory and Tuppr resources in this repo are authoritative; don't use obsolete `talconfig.yaml`/Taskfile commands.
- Kritika never approves a PR that changes `.kritika.yaml` or another file that configures it, such as a `flate` version bump. Those always need the operator.
- Renovate's schedule can run hours apart, so an APPROVED PR without the auto-merge flag may sit open for a long time. That is a backlog, not a hold.
