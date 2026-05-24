# Catastrophic Bootstrap Runbook

Use this procedure when rebuilding the cluster from scratch after a catastrophic incident. This is the **destructive rebuild** path: nodes are reset to Talos maintenance mode, Kubernetes state is recreated from Git, Ceph OSD disks are allowed to be wiped/recreated, and application PVCs restore primarily from the Kopia repository on the NAS.

Do **not** use this runbook if your goal is to preserve/adopt existing Ceph OSDs. This procedure assumes backups are the source of truth for application data.

## Recovery model

- **Infrastructure source of truth:** this Git repository on `main`.
- **Secrets source of truth:** 1Password vault `k8s` plus the SOPS age key.
- **Talos source of truth:** `talos/talconfig.yaml`, `talos/talenv.yaml`, `talos/talsecret.yaml`, and patches under `talos/patches/`.
- **Primary app PVC restore:** VolSync Kopia restore from the NAS NFS repository at `/volume2/kopia`.
- **Secondary app backup:** Cloudflare R2 Restic backups. R2 is a fallback/manual restore path, not the default automatic bootstrap restore.
- **Ceph stance:** always rebuild in this runbook. `wipeDevicesFromOtherClusters: true` is expected for this destructive path.

## Prerequisites

### Workstation tools

Install the pinned toolchain from `.mise.toml`:

```bash
mise install
mise trust
```

The bootstrap scripts expect these tools in `PATH`:

- `age`
- `flux`
- `helm`
- `helmfile`
- `jq`
- `kubectl`
- `kustomize`
- `op`
- `sops`
- `talhelper`
- `talosctl`
- `task`
- `yq`

### Environment

```bash
export KUBECONFIG=~/.kube/config
```

Authenticate to 1Password:

```bash
op signin
op whoami
```

Ensure the SOPS age key exists locally:

```bash
test -f ~/.config/sops/age/keys.txt
```

The bootstrap process also reads Talos secrets and initial Kubernetes secrets from 1Password references in:

- `talos/.env`
- `bootstrap/resources.yaml.j2`

### Hardware and network

1. Boot each node into Talos maintenance mode, or reset an existing cluster with:

   ```bash
   task talos:nuke
   ```

2. Confirm DHCP reservations / static leases are in place for:

   - `k8s-node-1` — `10.0.80.10`
   - `k8s-node-2` — `10.0.80.11`
   - `k8s-node-3` — `10.0.80.12`
   - `k8s-node-4` — `10.0.80.13`
   - `k8s-node-5` — `10.0.80.14`
   - Kubernetes API VIP — `10.0.80.99`

3. Confirm the NAS is online and serving NFS for at least:

   - `/volume2/kopia` — primary VolSync restore repository
   - any app-specific NFS paths used by media/home-automation workloads
   - `/volume2/garage/*` if Garage object storage is being restored from NAS-backed state

## Preflight

Run preflight before applying Talos configs:

```bash
task bootstrap:preflight
```

This checks:

- required CLI tools
- `KUBECONFIG` parent directory writability
- required repo files
- 1Password references used by Talos/bootstrap resources
- rendering of `bootstrap/helmfile.yaml`, using chart refs from that file
- rendering of `bootstrap/resources.yaml.j2`
- rendering of `bootstrap/helmfile.yaml`
- Talos node reachability in maintenance mode or with generated Talos config

If node reachability must be skipped temporarily:

```bash
BOOTSTRAP_PREFLIGHT_SKIP_NODES=true task bootstrap:preflight
```

## Bootstrap

Run the automated bootstrap:

```bash
./scripts/bootstrap-cluster.sh
```

The script performs these steps:

1. Generate Talos configuration with `task talos:generate`.
2. Export and use the generated Talos client config at `talos/clusterconfig/talosconfig`.
3. Apply Talos machine configs to nodes.
4. Bootstrap etcd/Kubernetes on a controller node.
5. Fetch kubeconfig to the exact path in `$KUBECONFIG`.
6. Wait for all Kubernetes node objects to register.
7. Apply early CRDs required by Flux-managed resources.
8. Render and apply bootstrap secrets/namespaces from `bootstrap/resources.yaml.j2`.
9. Sync bootstrap Helm releases with `bootstrap/helmfile.yaml`:

   ```text
   Cilium → CoreDNS → Spegel → cert-manager → External Secrets → Flux Operator → Flux Instance
   ```

Flux then reconciles `kubernetes/flux/cluster/ks.yaml` from `main` and starts applying the full app graph.

## Verification

First verify the core bootstrap substrate:

```bash
task bootstrap:verify
```

This checks:

- Kubernetes API reachability
- all nodes `Ready=True`
- Cilium rollout
- CoreDNS rollout
- External Secrets pods
- Flux pods
- Flux source readiness

After Flux has had time to reconcile the full repository, verify full convergence:

```bash
task bootstrap:verify-full
```

This additionally checks:

- `cluster-apps` readiness
- all Flux Kustomizations and HelmReleases ready
- `openebs-hostpath`, `ceph-block`, and `csi-ceph-blockpool`
- Rook Ceph Kustomization readiness
- VolSync Kustomization readiness
- Envoy Gateway programming
- main CNPG `postgres` cluster readiness
- VolSync ReplicationSource/ReplicationDestination API availability

## Data restoration expectations

### VolSync PVCs

Persistent apps using `kubernetes/components/volsync` create PVCs with a `dataSourceRef` to a VolSync `ReplicationDestination`. On a destructive rebuild, those PVCs should restore automatically from the latest Kopia snapshot in the NAS repository.

Important details:

- The default GitOps-created PVC restore uses **Kopia/NFS**. Use the manual R2 procedure if the Kopia repository is unavailable or missing the desired snapshot.
- The NAS and `/volume2/kopia` must be available before VolSync mover jobs can restore.
- Cloudflare R2 Restic backups are retained as a secondary disaster copy. Manual R2 restore steps are documented in `kubernetes/components/volsync/README.md`.
- After bootstrap, inspect VolSync objects and PVCs:

  ```bash
  kubectl get replicationdestinations,replicationsources -A
  kubectl get pvc -A
  ```

### PostgreSQL / CNPG

CNPG clusters use their declarative manifests and backup configuration in Git. During a full rebuild, database readiness can lag behind Flux readiness while operators, object storage, DNS/routing, and backup recovery settle.

Use the full verifier and CNPG checks:

```bash
task bootstrap:verify-full
kubectl -n database get cluster postgres
kubectl -n database describe cluster postgres
```

### Ceph / Rook

This runbook assumes Ceph is rebuilt, not adopted. Rook is configured with `wipeDevicesFromOtherClusters: true`, so make sure the selected OSD disks in `kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml` are the disks you intend to wipe/reuse.

## Troubleshooting

### Preflight cannot read 1Password refs

Re-authenticate and check vault access:

```bash
op signin
op whoami
op read op://k8s/sops/SOPS_PRIVATE_KEY >/dev/null
```

### Talos node not reachable

Confirm the node is booted into Talos maintenance mode and has the expected IP:

```bash
talosctl --nodes 10.0.80.10 version --insecure
```

If the node was already configured, regenerate Talos config and try authenticated access:

```bash
task talos:generate
TALOSCONFIG=talos/clusterconfig/talosconfig talosctl --nodes 10.0.80.10 version
```

### Bootstrap interrupted

If interruption happened before Kubernetes was healthy, reset back to maintenance mode and rerun:

```bash
task talos:nuke
./scripts/bootstrap-cluster.sh
```

### Flux is installed but apps are still reconciling

Check Flux state:

```bash
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A
kubectl get helmreleases.helm.toolkit.fluxcd.io -A
flux get kustomizations -A
flux get helmreleases -A
```

Then rerun:

```bash
task bootstrap:verify-full
```
