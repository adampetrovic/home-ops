# Planned Power Shutdown & Startup

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

---

## Shutdown Procedure

**Order matters.** Shut down workers first, then control plane nodes.

### 6. Shut down worker nodes

```bash
talosctl shutdown --nodes 10.0.80.13
talosctl shutdown --nodes 10.0.80.14
```

Wait for the nodes to disappear from `kubectl get nodes` (they will show `NotReady` then eventually drop):

```bash
kubectl get nodes -w
```

### 7. Shut down control plane nodes

Shut down one at a time, leaving one node up until the end to maintain API access:

```bash
talosctl shutdown --nodes 10.0.80.11
talosctl shutdown --nodes 10.0.80.12

# Last control plane node — after this, kubectl will stop working
talosctl shutdown --nodes 10.0.80.10
```

### 8. Shut down supporting infrastructure

Power off any other relevant infrastructure:

- **Synology NAS** (hosts NFS for Kopia backups and media) — shut down via DSM UI or SSH
- **Network switches / router** — if they're on the same circuit
- **UPS** — if the circuits need to be fully de-energised

---

## Startup Procedure

**Reverse order.** Network infrastructure first, then control plane, then workers.

### 9. Power on infrastructure

1. **Network switches / router** — wait for full convergence
2. **Synology NAS** — wait for NFS exports to be available
3. **UPS** — ensure it's online and charging

### 10. Power on control plane nodes

Power on all 3 control plane nodes. Talos nodes boot automatically when power is applied (no manual intervention needed beyond powering on the hardware).

Wait for the API to become reachable:

```bash
# Retry until the API responds (may take 2-5 minutes)
until talosctl health --nodes 10.0.80.10 --wait-timeout=10m --server=false 2>/dev/null; do
    echo "Waiting for control plane..."
    sleep 15
done
```

Once etcd has quorum (2 of 3 nodes), the Kubernetes API will become available:

```bash
# Verify etcd membership
talosctl -n 10.0.80.10 etcd members

# Verify API access
kubectl get nodes
```

### 11. Power on worker nodes

Power on both worker nodes. They will automatically join the cluster once the API server is reachable.

```bash
# Watch nodes come back
kubectl get nodes -w
```

Wait for all 5 nodes to show `Ready`:

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=10m
```

---

## Post-Startup Recovery

### 12. Verify Ceph health

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

### 13. Unset Ceph flags

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd unset noout
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd unset norebalance
```

Verify Ceph returns to `HEALTH_OK`:

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

### 14. Unset CNPG maintenance mode

```bash
kubectl cnpg maintenance unset --reusePVC --all-namespaces
```

Verify the PostgreSQL cluster is healthy:

```bash
kubectl -n database get cluster postgres
kubectl -n database get pods -l cnpg.io/cluster=postgres
```

### 15. Resume Flux

```bash
kubectl get ns -o jsonpath='{.items[*].metadata.name}' \
  | xargs -n1 -I {} flux resume kustomization --all -n {}
```

Flux will begin reconciling all resources. Monitor progress:

```bash
flux get kustomization --all-namespaces -w
```

### 16. Clean up failed pods

Some pods may have failed during the shutdown/startup cycle:

```bash
task k8s:delete-failed-pods
```

### 17. Final verification

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
