# Renovate Merge Skill Agent Instructions

These rules are mandatory for agents using the `renovate-merge` skill in `home-ops`.

## Kritika's review never replaces the operator's approval

Kritika reviews every Renovate PR and approves the low-risk ones, which then merge without this skill. Everything it holds needs the operator.

- Merge a held PR only after the operator approved the presented plan for that PR and head SHA. Kritika's score, risk rating, or approval is evidence for the plan, never permission.
- Do not merge a PR whose `Kritika / Review` status is failing, pending, or missing on its head commit. Get it reviewed, or hand it to the operator.
- Stay inside the `main` ruleset: no `--admin`, and no auto-merge on a held PR.
- Talos, Kubernetes, and the other pinned paths are always rated high and never approved by Kritika. A 5/5 score on one of them means the review found nothing; the isolation and approval rules below still apply in full.

## Talos Renovate PRs are isolated maintenance

Do **not** include Talos Linux Renovate PRs in a bulk merge wave. Treat every Talos installer update as a single-purpose maintenance rollout because it reboots nodes and can affect Ceph, CNPG/Postgres, Cilium, Envoy/Gateway API, LoadBalancer routing, and Tuppr state.

For Talos PRs:

1. Merge only the Talos PR, after explicit user approval.
2. Do not merge Cilium, cert-manager, Flux Operator, Rook-Ceph, Kubernetes, or leaf-app PRs in the same wave.
3. Before merge/rollout, verify:
   - all nodes are `Ready` and schedulable
   - Ceph is `HEALTH_OK`
   - no pods are non-running/non-succeeded
   - no Kopiur snapshot or restore is actively running (`kubectl kopiur status -A`)
   - `TalosUpgrade/talos` is not already `Failed`
4. After rollout, verify:
   - every node reports the target Talos version, kernel, and containerd version
   - all nodes are Ready and schedulable
   - Ceph is `HEALTH_OK`
   - no non-running pods remain
   - no stale `tuppr.home-operations.com/outdated` taints remain
   - Flux Kustomizations and HelmReleases are Ready
   - BGP/LoadBalancer sanity for services with `externalTrafficPolicy: Local`
5. Only after this is clean may remaining Renovate PRs be considered.

## Tuppr-specific guidance

Before relying on newer Tuppr policy fields, verify the CRD is current. Flux HelmRelease must use CRD replacement on install and upgrade:

```yaml
spec:
  install:
    crds: CreateReplace
  upgrade:
    crds: CreateReplace
```

Without this, Helm may leave old CRDs installed; the controller can run a newer version while Kubernetes prunes/rejects newer spec/status fields.

Preferred Tuppr policy for automated Talos rollouts:

```yaml
spec:
  policy:
    rebootMode: powercycle
    waitForVolumeDetach: true
```

`waitForVolumeDetach` makes Tuppr drain first, wait for CSI `VolumeAttachment`s to clear, then run `talosctl upgrade --drain=false`. This avoids the failure mode where Talos installs successfully but `talosctl` drain times out before reboot.

Caveat: Tuppr currently hardcodes its own drain timeout at 10 minutes and has no configurable `drainTimeout` field. CNPG/Postgres pods in this cluster may have `terminationGracePeriodSeconds: 1800`, so control-plane/CNPG-heavy nodes can still exceed Tuppr's drain window. For those rollouts, prefer manual `talosctl upgrade --drain-timeout=35m --reboot-mode=powercycle`, or ask the user before using `policy.nodrain: true`.

## If Tuppr fails mid-Talos rollout

If logs show `installation of <target> complete` / `Exit code: 0` but the node stays on the old Talos version:

1. Recover full Tuppr job logs from Loki before taking more action.
2. Verify whether the node installed the target but failed before reboot.
3. If confirmed, manually reboot the node with Talos (`powercycle`), then monitor Kubernetes and Ceph.
4. Reset Tuppr with its documented reset annotation only after all nodes are healthy or intentionally halted.
5. Remove/verify stale `tuppr.home-operations.com/outdated` taints only after the controller has had a chance to reconcile.
