# Upgrading Talos and Kubernetes

Talos and Kubernetes upgrades are GitOps-driven. Renovate opens a PR that bumps the version in a Tuppr resource, and merging it starts the rollout. Tuppr then upgrades one node at a time without further input.

- Talos: `kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml`
- Kubernetes: `kubernetes/apps/system-upgrade/tuppr/upgrades/kubernetesupgrade.yaml`

A Talos upgrade does not upgrade Kubernetes, and the reverse is also true. Merge them as separate PRs, never in the same wave as other updates. A Talos run across the 5 nodes takes about 30 minutes.

## How a Talos upgrade runs

When Flux applies a new `talos.version`, Tuppr's admission webhook first checks the upgrade path. It rejects a version that the nodes can't move to directly, or one that doesn't support the running Kubernetes version. Nothing is touched if it fails.

The run then moves through these phases. `kubectl get talosupgrade talos -w` shows each one.

1. **Pre-pull.** Each node pulls its installer image before anything is cordoned. A bad tag or unreachable registry parks the run here, with no disruption.
2. **Initial health check.** Every `healthChecks` entry must pass, along with Tuppr's built-in gate: all nodes Ready, Talos `MachineStatus` running, one healthy etcd member per control-plane node.
3. **Pre-hooks.** `suspend-backups` suspends every Kopiur `SnapshotSchedule`, so no backup starts on a node that is about to drain and the health checks between nodes don't wait on new snapshots.
4. **Per node, in turn.** The node running the Tuppr leader goes first, then the rest in name order.
   - Health checks run again. Kopiur snapshots already in flight finish, and every CNPG cluster must have all instances ready. Ceph must have no monitor or OSD down and no degraded, unavailable or damaged PGs, and CephFS must have a standby MDS. Other Ceph warnings, such as a crash report, don't block.
   - Tuppr cordons and drains the node, respecting PDBs. Its drain has a fixed 10 minute timeout. On timeout it uncordons and retries a minute later. Envoy pods hold the drain for up to 60 seconds while long-lived connections close.
   - If the node hosts a CNPG primary, the CNPG PDB blocks its eviction until CNPG has switched the primary over to a replica on another node.
   - Rook sees its OSDs going down and sets `noout` for that host for up to 30 minutes, so Ceph does not start rebalancing.
   - Tuppr waits up to 2 minutes for the node's CSI volumes to detach, then runs `talosctl upgrade` with powercycle.
   - The node boots the new version and must return Ready within the 45 minute per-node timeout.
5. **Post-hooks.** `resume-backups` releases the suspend. Each schedule fires one catch-up snapshot if its slot was missed. Post-hooks run even if the upgrade failed.
6. **Completed.** The Alertmanager silence lapses about 5 minutes later.

Tuppr holds an Alertmanager silence for the alerts a reboot is expected to cause: node NotReady, TargetDown, Ceph mon and OSD down, Ceph slow ops, etcd member down, CNPG replication lag and similar. The silence is a lease that Tuppr extends on each reconcile while a node is draining, upgrading or rebooting. While the run waits in `Pending` between nodes, Tuppr lets the silence run down a 5 minute tail. It holds a new one once the next node's drain has finished, because the drain runs inside a single reconcile. A wait plus drain longer than about 5 minutes therefore lets alerts through. The lease also lapses if Tuppr stops, and stops being extended once a run has been held for 2 hours, so a stuck upgrade still pages. Alerts that mean real damage stay live, for example `CephHealthError`, `etcdInsufficientMembers`, `CephPGsInactive`, `LoadBalancerProbeFailed` and Gatus endpoint alerts. So do alerts like `KubeletDown` and `KubeAPIDown`, which only fire when every instance is gone.

Tuppr's own alerts (`TalosUpgradeFailed`, `TalosUpgradeNodeFailed`, `TalosUpgradeStuck`, `TupprUpgradeBlocked`) come from the chart's PrometheusRule. The Tuppr dashboard is in Grafana.

### A Kubernetes upgrade

A `KubernetesUpgrade` updates the control-plane static pods and the kubelets in place, without reboots. It uses the same health checks but has no hooks or silences. Talos and Kubernetes runs queue behind each other rather than overlapping.

## Expected disruption

- **Prometheus** keeps its TSDB on `openebs-hostpath` on k8s-node-5, so it is down while that node reboots, and metrics have a gap of a few minutes.
- **CNPG instances** on hostpath are pinned to their node. A replica on a rebooting node is down until the node returns, and the primary switches over before its node drains. CNPG promotes the most up to date replica regardless of which nodes are still to be upgraded, so a primary can switch over twice in one run. Connections drop briefly during each switchover.
- **bookorbit-postgres** has a single instance on Ceph, so it restarts on another node and is unavailable for a few minutes.
- **Home Assistant** uses the `Recreate` strategy, so it is unavailable while it reschedules.
- **Backups** are paused for the length of the run.

## Before merging

```sh
just talos upgrade-check
```

It must pass. It checks nodes, Tuppr state, Ceph, CNPG, Kopiur schedules, pods, Flux, LoadBalancer endpoints and unsilenced alerts. Also read the Talos release notes for anything affecting `talos/*.yaml.j2`. An OS-only upgrade never needs `just talos apply-node`.

## Watching a run

```sh
kubectl get talosupgrade talos -w
kubectl describe talosupgrade talos        # HealthChecksFailed events explain a wait
kubectl -n system-upgrade logs deploy/tuppr -f
kubectl -n system-upgrade get jobs         # hook and per-node upgrade jobs
talosctl -n <node-ip> dmesg -f             # node console during boot
```

A run that sits in `HealthChecking` is waiting on a check. The event message names it.

## After it completes

```sh
just talos upgrade-check
```

This confirms every node runs the target version and is schedulable with no outdated taint. It also confirms Ceph is `HEALTH_OK` with no OSD flags left set, every CNPG cluster is fully ready, and no Kopiur schedule is still suspended or still carries the `tuppr-upgrade` field manager. LoadBalancer services with `externalTrafficPolicy: Local` must have ready endpoints, and nothing may be firing unsilenced. For BGP next-hop problems on the UCG, see "Post-Upgrade LoadBalancer/BGP Sanity Check" in `docs/agent/platform.md`.

## When something goes wrong

- **A pre-hook failed.** The run is marked `Failed` before any node is touched, and the post-hook still resumes backups. Check the hook Job logs in `system-upgrade`. Jobs are kept for 5 minutes.
- **Backups still suspended after a run.** The post-hook failed after its retries. `just talos upgrade-check` flags it. Run the `resume-backups` script from `talosupgrade.yaml` by hand. It only releases the `tuppr-upgrade` field manager, so it is safe to repeat.
- **The drain keeps timing out.** Look for a pod that can't be evicted, usually a PDB that can't be satisfied. `kubectl get pdb -A` shows which one allows 0 disruptions.
- **Talos installed but the node didn't reboot.** Logs show `installation of <target> complete` but the node is on the old version. Recover the full job logs from Loki before acting, confirm the install, then power-cycle the node with Talos and watch Kubernetes and Ceph recover. Reset Tuppr with its reset annotation only once every node is healthy or deliberately halted.
- **Break-glass.** `just talos upgrade <node>` upgrades a single node outside Tuppr.

## Version paths

Upgrade through the latest patch of each intermediate minor release, for example `v1.12.x` then the latest `v1.13.y` then `v1.14.z`. Tuppr's webhook rejects an unsupported jump. Image Factory metal installs use `factory.talos.dev/metal-installer/<schematic>:<version>`. Tuppr keeps each node's schematic when it resolves the installer.
