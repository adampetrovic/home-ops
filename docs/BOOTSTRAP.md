# Catastrophic Bootstrap Runbook

Use this procedure when rebuilding the cluster from scratch after a catastrophic incident. This is the **destructive rebuild** path: nodes are reset to Talos maintenance mode, Kubernetes state is recreated from Git, Ceph OSD disks are allowed to be wiped/recreated, and application PVCs restore primarily from the Kopia repository on the NAS.

Do **not** use this runbook if your goal is to preserve/adopt existing Ceph OSDs. This procedure assumes backups are the source of truth for application data.

## Recovery model

- **Infrastructure source of truth:** this Git repository on `main`.
- **Secrets source of truth:** 1Password vault `k8s` plus the SOPS age key.
- **Talos source of truth:** native templates under `talos/` (`cluster.yaml.j2`, role templates, `nodes/**`, `inventory.yaml`, `secrets.yaml.j2`, and `schematic.yaml.j2`).
- **Primary app PVC restore:** VolSync Kopia restore from the UNAS NFS repository at `/var/nfs/shared/kopia`.
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
- `minijinja-cli`
- `talosctl`
- `just`
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

- `talos/*.yaml.j2`
- `talos/nodes/**/*.yaml.j2`
- `bootstrap/resources.yaml.j2`

### Hardware and network

1. Boot each node into Talos maintenance mode, or reset an existing cluster with:

   ```bash
   just talos nuke destroy-cluster
   ```

2. Confirm DHCP reservations / static leases are in place for:

   - `k8s-node-1` — `10.0.80.10`
   - `k8s-node-2` — `10.0.80.11`
   - `k8s-node-3` — `10.0.80.12`
   - `k8s-node-4` — `10.0.80.13`
   - `k8s-node-5` — `10.0.80.14`
   - Kubernetes API VIP — `10.0.80.99`

3. Confirm the UNAS is online and serving NFS for at least:

   - `/var/nfs/shared/kopia` — primary VolSync restore repository
   - `/var/nfs/shared/media` and `/var/nfs/shared/photos` — application data
   - `/var/nfs/shared/garage/{data,meta}` — Garage object storage state

## Preflight

Run preflight before applying Talos configs:

```bash
just bootstrap preflight
```

This checks:

- required CLI tools
- `KUBECONFIG` parent directory writability
- required repo files
- 1Password references used by Talos/bootstrap resources
- native Talos render validation with `just talos validate-all`
- rendering of `bootstrap/helmfile.yaml`, using chart refs from that file
- rendering of `bootstrap/resources.yaml.j2`
- Talos node reachability in maintenance mode or with generated Talos client config

If node reachability must be skipped temporarily:

```bash
BOOTSTRAP_PREFLIGHT_SKIP_NODES=true just bootstrap preflight
```

## Bootstrap

Run the automated bootstrap:

```bash
./scripts/bootstrap-cluster.sh
```

The script performs these steps:

1. Generate a Talos client config with `just talos talosconfig`.
2. Render native Talos machine configs and apply them insecurely to maintenance-mode nodes.
3. Bootstrap etcd/Kubernetes on a controller node.
4. Fetch kubeconfig to the exact path in `$KUBECONFIG`.
5. Wait for all Kubernetes node objects to register.
6. Apply early CRDs required by Flux-managed resources.
7. Render and apply bootstrap secrets/namespaces from `bootstrap/resources.yaml.j2`.
8. Sync bootstrap Helm releases with `bootstrap/helmfile.yaml`:

   ```text
   Cilium → CoreDNS → Spegel → cert-manager → External Secrets → Flux Operator → Flux Instance
   ```

Flux then reconciles `kubernetes/flux/cluster/ks.yaml` from `main` and starts applying the full app graph.

## Verification

First verify the core bootstrap substrate:

```bash
just bootstrap verify
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
just bootstrap verify-full
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

Persistent apps using `kubernetes/components/volsync` create PVCs with a `dataSourceRef` to a VolSync `ReplicationDestination`. On a destructive rebuild, those PVCs should restore automatically from the latest Kopia snapshot in the UNAS repository.

Important details:

- The default GitOps-created PVC restore uses **Kopia/NFS**. Use the manual R2 procedure if the Kopia repository is unavailable or missing the desired snapshot.
- The UNAS and `/var/nfs/shared/kopia` must be available before VolSync mover jobs can restore.
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
just bootstrap verify-full
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

If the node was already configured, regenerate Talos client config and try authenticated access:

```bash
just talos talosconfig
talosctl --nodes 10.0.80.10 version
```

### Bootstrap interrupted

If interruption happened before Kubernetes was healthy, reset back to maintenance mode and rerun:

```bash
just talos nuke destroy-cluster
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
just bootstrap verify-full
```
