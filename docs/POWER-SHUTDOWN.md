ta Planned Power Shutdown & Startup

Runbook for gracefully shutting down and restarting the entire cluster during a planned power outage.

## Cluster Inventory

| Hostname   | IP          | Role          | Ceph OSD |
|------------|-------------|---------------|----------|
| k8s-node-1 | 10.0.80.10 | Control Plane | ✅       |
| k8s-node-2 | 10.0.80.11 | Control Plane | ✅       |
| k8s-node-3 | 10.0.80.12 | Control Plane | ✅       |
| k8s-node-4 | 10.0.80.13 | Worker        | ✅       |
| k8s-node-5 | 10.0.80.14 | Worker        | ✅       |

**VIP:** 10.0.80.99 · **CNPG:** 3-instance PostgreSQL on openebs-hostpath · **Ceph:** 3× replicated block pool across all 5 nodes

---

## Pre-Shutdown Checklist

Perform these steps **before** power is cut.

### 1. Verify cluster health

```bash
# All nodes Ready
kubectl get nodes -o wide

# All Flux Kustomizations reconciled
flux get kustomization --all-namespaces

# No failed HelmReleases
kubectl get hr -A | grep -v "True"

# Ceph is HEALTH_OK
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

# CNPG cluster healthy
kubectl -n database get cluster postgres
```

### 2. Trigger fresh VolSync backups (optional but recommended)

Kick off an ad-hoc Kopia snapshot for critical apps so the most recent data is backed up:

```bash
# Snapshot all apps in parallel (max 4 concurrent)
kubectl get replicationsources --all-namespaces --no-headers \
  | awk '{print $2, $1}' \
  | xargs --max-procs=4 -l bash -c 'task volsync:snapshot app=$0 ns=$1'
```

Or snapshot specific critical apps individually:

```bash
task volsync:snapshot app=home-assistant ns=automation
task volsync:snapshot app=paperless ns=default
task volsync:snapshot app=memos ns=default
```

### 3. Set Ceph OSD noout flag

Prevents Ceph from marking OSDs as `out` and triggering unnecessary data rebalancing while nodes are down:

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd set noout
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd set norebalance
```

Verify the flags are set:

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd dump | grep flags
# Should include: noout,norebalance
```

### 4. Set CNPG maintenance mode

Prevents the operator from performing failovers during shutdown:

```bash
kubectl cnpg maintenance set --reusePVC --all-namespaces
```

### 5. Suspend Flux

Prevents Flux from reconciling and fighting the shutdown process:

```bash
kubectl get ns -o jsonpath='{.items[*].metadata.name}' \
  | xargs -n1 -I {} flux suspend kustomization --all -n {}
```

### 6. Cordon all nodes

Mark every node `unschedulable` so that on startup the kube-scheduler cannot pile every
pending pod onto whichever node becomes `Ready` first. We've hit this before: the first node
back hits the kubelet `maxPods=110` ceiling and the rest of the workloads stay `Pending`
indefinitely until manually rescheduled.

```bash
kubectl cordon k8s-node-1 k8s-node-2 k8s-node-3 k8s-node-4 k8s-node-5
```

The cordon state lives on the `Node` object in etcd and persists across the shutdown. After
all five nodes are back `Ready` we'll uncordon them simultaneously (step 12) so the
scheduler distributes the backlog evenly in one shot.

> Cordon only blocks **new** pod assignments — DaemonSets (Cilium, Ceph OSD, etc.) and
> static pods (etcd, kube-apiserver) still come up normally on cordoned nodes, and pods
> that were already bound to a specific node before shutdown still resume on that node.
> What it stops is the eviction-driven cascade where pods that can't return to their
> original node all land on the same replacement.

---

## Shutdown Procedure

**Order matters.** Shut down workers first, then control plane nodes.

### 7. Shut down worker nodes

```bash
talosctl shutdown --nodes 10.0.80.13
talosctl shutdown --nodes 10.0.80.14
```

Wait for the nodes to disappear from `kubectl get nodes` (they will show `NotReady` then eventually drop):

```bash
kubectl get nodes -w
```

### 8. Shut down control plane nodes

Control plane nodes can hang during graceful shutdown because etcd blocks trying to transfer
leadership as quorum shrinks. Use `--force` to bypass the cordon/drain and set a timeout so the
command doesn't hang indefinitely. Shut down two non-leader nodes first, then the leader last.

Identify the current etcd leader:

```bash
talosctl -n 10.0.80.10 etcd members | grep -i "learner\|true"
# Or check which node responds fastest — the leader is usually the most responsive
```

Shut down the **non-leader** control plane nodes first with `--force` and a timeout.
After each, verify the node is actually unreachable before proceeding:

```bash
# First non-leader
talosctl shutdown --nodes 10.0.80.11 --force --timeout 3m
# Verify it's actually down
until ! ping -c 1 -W 2 10.0.80.11 &>/dev/null; do echo "Waiting for 10.0.80.11 to power off..."; sleep 5; done
echo "10.0.80.11 is down"

# Second non-leader
talosctl shutdown --nodes 10.0.80.12 --force --timeout 3m
until ! ping -c 1 -W 2 10.0.80.12 &>/dev/null; do echo "Waiting for 10.0.80.12 to power off..."; sleep 5; done
echo "10.0.80.12 is down"

# Last control plane node (leader) — after this, kubectl will stop working
talosctl shutdown --nodes 10.0.80.10 --force --timeout 3m
until ! ping -c 1 -W 2 10.0.80.10 &>/dev/null; do echo "Waiting for 10.0.80.10 to power off..."; sleep 5; done
echo "10.0.80.10 is down"
```

> **⚠️ If a node hangs past the shutdown timeout, do NOT re-run `talosctl shutdown` on it.**
> Talos holds an internal shutdown lock for the duration of the first attempt, and a second
> call will fail with `[talos] shutdown failed: failed to acquire lock: timeout` while
> potentially wedging the node further. The first shutdown is usually still running — it's
> stuck at `unmountPodMounts` (see [Why shutdown can hang](#why-shutdown-can-hang) below).
>
> **Preferred escalation: physical power-off.** Hold the power button on the stuck NUC for
> ~5 seconds until the power LED goes out, then confirm with ping. This is a safe and
> expected part of this runbook because:
>
> - Ceph's `noout`/`norebalance` flags are already set (no rebalance storm on restart).
> - Ceph OSDs replay their journals on boot and are designed to tolerate hard power loss.
> - Postgres (CNPG) handles crash recovery via WAL replay.
>
> **If you're off-site**, `talosctl reboot --nodes <ip> --mode powercycle` will hard-reset
> the stuck node, clearing the shutdown lock. Note that this causes the node to briefly boot
> back into the cluster before you can try `talosctl shutdown` again — it's slower than a
> physical power-off if you can reach the rack. Intel NUCs have no IPMI/BMC for remote power
> control, so there's no other remote option.

### Why shutdown can hang

This cluster is **converged** — every node is both a Ceph OSD (serving storage) and a Ceph
client (mounting RBD/CephFS PVCs on behalf of pods). During shutdown, Talos runs the
`unmountPodMounts` task to unmount all pod volumes before halting. When nodes shut down in
sequence, the Ceph daemons on the earlier nodes go away, and the kernel's Ceph client on the
later nodes hangs trying to contact the now-dead monitors/OSDs to cleanly close those
mounts.

Visible symptoms on the Talos dashboard of a hung node:

- `STAGE: Shutting down`, `KUBELET: Unhealthy`
- Kernel log full of `libceph: mon/osd ... socket closed (con state V2_BANNER_PREFIX)` warnings
- `block.MountController` stuck on `unmountPodMounts` / `/usr` / `/opt`
- The shutdown sequence never advances past `phase: umount`

`--force` skips cordon/drain but does **not** bypass the unmount phase, so it doesn't help
here. There is no clean remote recovery once the peer OSDs are gone — the only way forward
is to power-cycle the stuck node. **Expect this to happen on the last node or two of any
shutdown**; it is not a failure of the procedure, and physical power-off is the standard
escalation.

### 9. Shut down supporting infrastructure

Power off any other relevant infrastructure:

- **Synology NAS** (hosts NFS for Kopia backups and media) — shut down via DSM UI or SSH
- **Network switches / router** — if they're on the same circuit
- **UPS** — if the circuits need to be fully de-energised

---

## Startup Procedure

Bring up supporting infrastructure first, then wake all 5 nodes in parallel via WoL.
Parallel boot keeps the "first node `Ready`" window short and pairs with the pre-shutdown
cordon to avoid the scheduling cascade we hit previously.

### 10. Power on infrastructure

1. **Network switches / router** — wait for full convergence
2. **Synology NAS** — wait for NFS exports to be available
3. **UPS** — ensure it's online and charging

### 11. Wake all nodes via Wake-on-LAN

Wake every node simultaneously instead of staging control plane → workers. Bringing all
five up in parallel keeps the "first node `Ready`" window short, which (combined with the
pre-shutdown cordon from step 6) prevents the kube-scheduler from cascading every pending
pod onto whichever node won the boot race.

**One-time prerequisites:**

- WoL enabled in BIOS on every node (`Power → Wake on LAN`); disable any "Deep Sleep" /
  "ErP" / "EuP" power-saving option that cuts NIC standby power, otherwise the magic
  packet is silently dropped.
- `wakeonlan` installed locally: `brew install wakeonlan`.
- You must run this from a host on the same broadcast domain as the cluster
  (`10.0.80.0/21`). VPN/Tailscale **will not** carry WoL — you have to be on LAN.

Wake all 5 nodes:

```bash
./scripts/wake-cluster.sh
```

The script sends magic packets to every node MAC (sourced from `talos/talconfig.yaml`).
Talos boots automatically once power is applied — expect the nodes to be reachable within
60-90 seconds.

> **k8s-node-5 caveat:** it uses an Intel X710 NIC (`i40e` driver) which has limited WoL
> support compared to the Intel I225/I226 (`igc`) NICs in the other four NUCs. If
> `k8s-node-5` doesn't come up after a couple of minutes, power it on manually (physical
> button or smart plug). Everything else should wake reliably.

Wait for the API to become reachable:

```bash
# Control plane usually responds first; the API needs etcd quorum (2 of 3 CP nodes)
until talosctl health --nodes 10.0.80.10 --wait-timeout=10m --server=false 2>/dev/null; do
    echo "Waiting for control plane..."
    sleep 15
done

# Verify etcd membership
talosctl -n 10.0.80.10 etcd members
```

Wait for **all 5 nodes** to be `Ready` before moving on — do not skip this step or the
cordon-release in step 12 will only spread pods across whichever nodes happen to be back:

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl get nodes -o wide
```

If any node is still `NotReady` after 10 minutes, debug it before continuing
([troubleshooting](#etcd-wont-form-quorum)).

---

## Post-Startup Recovery

### 12. Uncordon all nodes

With every node back `Ready`, release the pre-shutdown cordon so the kube-scheduler can
distribute the pending workload across all 5 nodes in one shot:

```bash
kubectl uncordon k8s-node-1 k8s-node-2 k8s-node-3 k8s-node-4 k8s-node-5
```

Watch pods start landing on every node (you should see roughly even counts):

```bash
kubectl get pods -A -o wide --field-selector=status.phase!=Succeeded \
  | awk 'NR>1 {print $8}' | sort | uniq -c | sort -rn
```

If one node is dramatically heavier than the others, something tolerated the cordon (look
for pods with `tolerations: node.kubernetes.io/unschedulable`) — usually fine, but worth a
glance.

### 13. Verify Ceph health

Ceph should recover automatically once all OSD nodes are back. This can take a few minutes:

```bash
# Watch Ceph recover
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph -w
```

Wait for `HEALTH_OK` (or `HEALTH_WARN` with only the `noout` and `norebalance` flags):

```bash
until kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph health 2>/dev/null | grep -q "HEALTH_OK\|HEALTH_WARN"; do
    echo "Waiting for Ceph..."
    sleep 15
done
```

### 14. Unset Ceph flags

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd unset noout
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd unset norebalance
```

Verify Ceph returns to `HEALTH_OK`:

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

### 15. Unset CNPG maintenance mode

```bash
kubectl cnpg maintenance unset --reusePVC --all-namespaces
```

Verify the PostgreSQL cluster is healthy:

```bash
kubectl -n database get cluster postgres
kubectl -n database get pods -l cnpg.io/cluster=postgres
```

### 16. Resume Flux

```bash
kubectl get ns -o jsonpath='{.items[*].metadata.name}' \
  | xargs -n1 -I {} flux resume kustomization --all -n {}
```

Flux will begin reconciling all resources. Monitor progress:

```bash
flux get kustomization --all-namespaces -w
```

### 17. Clean up failed pods

Some pods may have failed during the shutdown/startup cycle:

```bash
task k8s:delete-failed-pods
```

### 18. Final verification

```bash
# All nodes Ready
kubectl get nodes -o wide

# All HelmReleases reconciled
kubectl get hr -A

# All Kustomizations reconciled
flux get kustomization --all-namespaces

# Ceph healthy
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

# CNPG cluster healthy with all 3 replicas
kubectl -n database get cluster postgres
kubectl -n database get pods -l cnpg.io/cluster=postgres -o wide

# Ingress working (quick smoke test)
curl -sk https://home-assistant.${SECRET_DOMAIN} -o /dev/null -w "%{http_code}"
```

---

## Troubleshooting

### etcd won't form quorum

If the API server doesn't come up after all 3 control plane nodes are running:

```bash
# Check etcd logs on each control plane node
talosctl -n 10.0.80.10 logs etcd
talosctl -n 10.0.80.11 logs etcd
talosctl -n 10.0.80.12 logs etcd

# Check etcd member list
talosctl -n 10.0.80.10 etcd members
```

If a member is stuck, try restarting the etcd service:

```bash
talosctl -n <problem-node> service etcd restart
```

### `talosctl shutdown` fails with "failed to acquire lock: timeout"

This error appears on the Talos dashboard (or in `talosctl dmesg`) as:

```
[talos] shutdown failed: failed to acquire lock: timeout
```

**Cause:** `talosctl shutdown --force` has been called a second time on a node that is still
in the middle of its first shutdown attempt. Talos holds a single shutdown lock per boot,
and the second call times out waiting for the first to release it. The `talosctl` client
may have appeared to "fail" on the first attempt (timeout, connection reset, etc.) but the
actual shutdown sequence on the node is still running — almost certainly stuck at
`unmountPodMounts` because of the Ceph unmount hang described in [Why shutdown can
hang](#why-shutdown-can-hang).

**Fix:** Do not retry `talosctl shutdown`. Either wait longer for the first attempt to
finish, or go directly to **physical power-off** (hold the power button on the NUC for ~5
seconds). Ceph, etcd, and Postgres all tolerate hard power loss from this state because
`noout`/`norebalance` are set and no writes are in flight.

If you need the node recovered remotely without power-off, `talosctl reboot --nodes <ip>
--mode powercycle` will hard-reset it and clear the lock — at the cost of a brief reboot
into the cluster before you can try shutting down again.

### Ceph stuck in HEALTH_WARN / HEALTH_ERR

```bash
# Check OSD status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd status

# Check for down OSDs
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph health detail

# Check OSD pods are running on all nodes
kubectl -n rook-ceph get pods -l app=rook-ceph-osd -o wide
```

If an OSD pod is crashlooping, check its logs:

```bash
kubectl -n rook-ceph logs -l app=rook-ceph-osd --prefix --tail=50
```

### CNPG cluster not recovering

```bash
# Check cluster status in detail
kubectl -n database describe cluster postgres

# Check pod logs
kubectl -n database logs -l cnpg.io/cluster=postgres --prefix --tail=50

# Force a restart if stuck
kubectl cnpg restart postgres -n database
```

### Pods stuck in Pending/ContainerCreating

Usually caused by Ceph PVCs not being mountable yet. Wait for Ceph `HEALTH_OK` first:

```bash
# Check which PVCs are stuck
kubectl get pvc -A | grep -v Bound

# Check events for stuck pods
kubectl describe pod <pod-name> -n <namespace> | tail -20
```

### NFS mounts failing (VolSync / media)

If the Synology NAS isn't back online yet, VolSync mover jobs and media pods will fail:

```bash
# Verify NAS is reachable
ping <nas-ip>
showmount -e <nas-ip>
```

Wait for the NAS to fully boot before expecting VolSync and media pods to recover.

---

## Notes

- **NUT client**: All nodes have `nut-client` configured. For _unplanned_ outages, the UPS will signal a graceful shutdown automatically via NUT. This runbook is for _planned_ shutdowns where you want a cleaner process.
- **Estimated downtime**: Shutdown takes ~5 minutes. Startup and full recovery typically takes 10-15 minutes once power is restored.
- **Synology NAS**: The NAS is external to the cluster but critical for NFS-backed storage (Kopia backups, media). Ensure it's powered on before the cluster nodes.

