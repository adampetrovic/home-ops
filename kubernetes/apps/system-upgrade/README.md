# system-upgrade

Automated Talos Linux and Kubernetes upgrades via [tuppr](https://github.com/home-operations/tuppr).

## How It Works

tuppr is a Kubernetes controller that watches two custom resources — `TalosUpgrade` and `KubernetesUpgrade` — and performs rolling upgrades when the target version changes.

### Upgrade Flow

1. **Renovate** detects a new Talos or Kubernetes version and opens a PR bumping the version in `talosupgrade.yaml` or `kubernetesupgrade.yaml`
2. **PR is merged** → GitHub webhook fires → Flux reconciles the new version into the cluster
3. **tuppr detects version drift** between the CR and the running cluster
4. **Health checks run** — VolSync must not be mid-sync, Ceph must be `HEALTH_OK`
5. **Talos upgrades** proceed node-by-node: drain → upgrade → reboot → verify → uncordon → health check → next node
6. **Kubernetes upgrades** run as a single operation against a control plane node via the Talos API

Talos and Kubernetes upgrades are **mutually exclusive** — if both CRs have pending upgrades, one waits for the other to complete.

### Health Checks

Before each node upgrade (Talos) or before starting (Kubernetes), tuppr evaluates:

| Check | Expression | Purpose |
|-------|-----------|---------|
| VolSync | `ReplicationSource` status `Synchronizing == False` | Don't upgrade while backups are running |
| Rook-Ceph | `CephCluster` health `in ['HEALTH_OK']` | Don't upgrade while Ceph is degraded |

After a Talos node reboots, Ceph OSDs restart and health temporarily goes to `HEALTH_WARN`. tuppr waits for recovery before proceeding to the next node.

### Upgrade Order for Minor Versions

When upgrading both Talos and Kubernetes minor versions, **order matters**:

1. **Upgrade Talos first** — each Talos version has a maximum supported Kubernetes version
2. **Then upgrade Kubernetes** — only after all nodes are on the new Talos version

For example, Talos v1.11.x supports Kubernetes up to v1.34.x. To get to Kubernetes v1.35.x, you must first upgrade Talos to v1.12.x.

## Architecture

```
kubernetes/apps/system-upgrade/
├── kustomization.yaml                    # Namespace entry point
└── tuppr/
    ├── ks.yaml                           # Flux Kustomizations (controller + upgrades)
    ├── app/
    │   ├── kustomization.yaml
    │   ├── helmrelease.yaml              # tuppr controller (2 replicas, HA)
    │   └── ocirepository.yaml            # OCI chart source
    └── upgrades/
        ├── kustomization.yaml
        ├── talosupgrade.yaml             # TalosUpgrade CR — target Talos version
        └── kubernetesupgrade.yaml        # KubernetesUpgrade CR — target K8s version
```

Flux deploys in two phases via `ks.yaml`:
- **tuppr** — the controller and CRDs (`wait: true`)
- **tuppr-upgrades** — the upgrade CRs (`dependsOn: tuppr`)

### Prerequisites

Talos API access for the `system-upgrade` namespace is configured in `talos/patches/controller/machine-features.yaml`:

```yaml
machine:
  features:
    kubernetesTalosAPIAccess:
      enabled: true
      allowedRoles:
        - os:admin
      allowedKubernetesNamespaces:
        - system-upgrade
```

## Monitoring a Rollout

### Quick status

```bash
kubectl get talosupgrade,kubernetesupgrade -n system-upgrade
```

Output shows phase (`Pending` → `InProgress` → `Completed` / `Failed`) and current node.

### Watch the upgrade

```bash
# Pane 1: upgrade progress
kubectl get talosupgrade,kubernetesupgrade -n system-upgrade -w

# Pane 2: controller logs
kubectl logs -n system-upgrade deployment/tuppr -f

# Pane 3: node health
kubectl get nodes -w
```

### Check health gates

If an upgrade is stuck in `Pending` between nodes:

```bash
# Is Ceph healthy?
kubectl get cephcluster -n rook-ceph -o jsonpath='{.items[0].status.ceph.health}'

# Is VolSync syncing?
kubectl get replicationsource -A -o custom-columns=NAME:.metadata.name,SYNCING:.status.conditions[0].status
```

### Watch upgrade jobs

tuppr creates a Job per node (Talos) or a single Job (Kubernetes):

```bash
kubectl get jobs -n system-upgrade -w
kubectl logs -n system-upgrade -l app.kubernetes.io/name=talos-upgrade -f
```

### Prometheus metrics

```bash
kubectl port-forward -n system-upgrade deployment/tuppr 8080:8080
curl -s http://localhost:8080/metrics | grep tuppr_
```

Key metrics:
- `tuppr_talos_upgrade_phase` — 0=Pending, 1=InProgress, 2=Completed, 3=Failed
- `tuppr_talos_upgrade_nodes_total` / `tuppr_talos_upgrade_nodes_completed`
- `tuppr_upgrade_job_duration_seconds`

## Troubleshooting

### Reset a failed upgrade

```bash
kubectl annotate talosupgrade talos -n system-upgrade tuppr.home-operations.com/reset="$(date)"
kubectl annotate kubernetesupgrade kubernetes -n system-upgrade tuppr.home-operations.com/reset="$(date)"
```

### Suspend upgrades

```bash
# Prevent tuppr from acting (e.g. for manual maintenance)
kubectl annotate talosupgrade talos -n system-upgrade tuppr.home-operations.com/suspend="true"
kubectl annotate kubernetesupgrade kubernetes -n system-upgrade tuppr.home-operations.com/suspend="true"

# Resume
kubectl annotate talosupgrade talos -n system-upgrade tuppr.home-operations.com/suspend-
kubectl annotate kubernetesupgrade kubernetes -n system-upgrade tuppr.home-operations.com/suspend-
```

### Emergency stop

```bash
kubectl scale deployment tuppr --replicas=0 -n system-upgrade
```

### Detailed status

```bash
kubectl describe talosupgrade talos -n system-upgrade
kubectl describe kubernetesupgrade kubernetes -n system-upgrade
```
