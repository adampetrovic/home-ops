# Renovate Merge Skill Agent Instructions

These rules are mandatory for agents using the `renovate-merge` skill in `home-ops`.

## Talos Renovate PRs are isolated maintenance

Do **not** include Talos Linux Renovate PRs in a bulk merge wave. Treat every Talos installer update as a single-purpose maintenance rollout because it reboots nodes and can affect Ceph, CNPG/Postgres, Cilium, Envoy/Gateway API, LoadBalancer routing, and Tuppr state.

For Talos PRs:

1. Merge only the Talos PR, after explicit user approval.
2. Do not merge Cilium, cert-manager, Flux Operator, Rook-Ceph, Kubernetes, or leaf-app PRs in the same wave.
3. Before merge/rollout, verify:
   - all nodes are `Ready` and schedulable
   - Ceph is `HEALTH_OK`
   - no pods are non-running/non-succeeded
   - no VolSync `ReplicationSource` is actively `Synchronizing=True`
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
