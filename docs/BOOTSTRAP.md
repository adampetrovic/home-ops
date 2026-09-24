# Catastrophic Bootstrap Runbook

Use this procedure when rebuilding the cluster from scratch after a catastrophic incident. This is the **destructive rebuild** path: nodes are reset to Talos maintenance mode, Kubernetes state is recreated from Git, Ceph OSD disks are allowed to be wiped/recreated, and application PVCs restore primarily from the Kopia repository on the NAS.

Do **not** use this runbook if your goal is to preserve/adopt existing Ceph OSDs. This procedure assumes backups are the source of truth for application data.

## Recovery model

- **Infrastructure source of truth:** this Git repository on `main`.
- **Secrets source of truth:** 1Password vault `k8s` plus the SOPS age key.
- **Talos source of truth:** native templates under `talos/` (`cluster.yaml.j2`, role templates, `nodes/**`, `inventory.yaml`, `secrets.yaml.j2`, and `schematic.yaml.j2`).
- **Primary app PVC restore:** Kopiur Kopia restore from the UNAS NFS repository at `/var/nfs/shared/kopiur`.
- **Secondary app backup:** Cloudflare R2 Kopia backups. R2 is a fallback/manual restore path, not the default automatic bootstrap restore.
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

Bootstrap defaults to repository-local generated config files:

```bash
export KUBECONFIG="${PWD}/kubeconfig"
export TALOSCONFIG="${PWD}/talosconfig"
```

Authenticate to 1Password:

```bash
op signin
op whoami
```

The SOPS age private key is resolved at runtime from 1Password via
`SOPS_AGE_KEY=op://k8s/sops/SOPS_PRIVATE_KEY` in `.mise.toml`. Activate or enter
the pinned mise environment first, then run bootstrap commands through `op run`
so SOPS can decrypt without a workstation-local age key file:

```bash
op run -- just bootstrap preflight
op run -- just bootstrap cluster
```

The bootstrap process also reads Talos secrets and initial Kubernetes secrets
from 1Password references in:

- `talos/*.yaml.j2`
- `talos/nodes/**/*.yaml.j2`
- `bootstrap/kustomize/home/**`

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

   - `/var/nfs/shared/kopiur` — primary Kopiur restore repository
   - `/var/nfs/shared/media` and `/var/nfs/shared/photos` — application data
   - `/var/nfs/shared/garage/{data,meta}` — Garage object storage state

## Preflight

Run preflight before applying Talos configs:

```bash
op run -- just bootstrap preflight
```

This checks:

- required CLI tools
- `KUBECONFIG` parent directory writability
- required repo files
- 1Password references used by Talos/bootstrap resources
- native Talos render validation with `just talos validate-all`
- rendering of `bootstrap/helmfile/apps.yaml` and `bootstrap/helmfile/crds.yaml`
- rendering and in-memory 1Password injection of `bootstrap/kustomize/home` without writing resolved Secrets
- duplicate checks across standalone and chart-rendered bootstrap CRD sources
- Talos node reachability in maintenance mode or with generated Talos client config

If node reachability must be skipped temporarily:

```bash
BOOTSTRAP_PREFLIGHT_SKIP_NODES=true op run -- just bootstrap preflight
```

## Bootstrap

Run the staged automated bootstrap:

```bash
op run -- just bootstrap cluster
```

The recipe performs these stages:

1. `preflight` — check local tools, 1Password references, renders, and node reachability.
2. `talosconfig` — generate `${TALOSCONFIG}` from 1Password-backed Talos secrets.
3. `nodes` — render native Talos machine configs and apply them insecurely to maintenance-mode nodes, skipping nodes that are already configured.
4. `k8s` — bootstrap etcd/Kubernetes on `k8s-node-1` and treat an existing etcd cluster as a successful rerun.
5. `kubeconfig` — fetch kubeconfig to `${KUBECONFIG}`.
6. `base` — wait for the API and node registration, apply prerequisite CRDs, then apply bootstrap namespaces and seed Secrets from `bootstrap/kustomize/home` via `op inject`.
7. `apps` — sync bootstrap Helm releases with `bootstrap/helmfile/apps.yaml`:

   ```text
   Cilium → CoreDNS → Spegel → cert-manager → External Secrets → 1Password Connect → Flux Operator → Flux Instance
   ```

8. `verify-core` — run core post-bootstrap verification before reporting success.

Flux then reconciles `kubernetes/flux/cluster/ks.yaml` from `main` and starts applying the full app graph.

## Static validation

Before relying on the workflow for a recovery, run the non-destructive checks:

```bash
BOOTSTRAP_PREFLIGHT_SKIP_NODES=true op run -- just bootstrap preflight
just talos validate-all
kustomize build bootstrap/kustomize/home >/dev/null
helmfile --file bootstrap/helmfile/apps.yaml build >/dev/null
helmfile --file bootstrap/helmfile/crds.yaml template --quiet \
  | yq ea 'select(.kind == "CustomResourceDefinition" and ((.spec.group | test("^gateway\\.networking\\.(x-)?k8s\\.io$")) | not))' - >/dev/null
scripts/bootstrap-helmfile-parity.sh
```

A live disaster-recovery or disposable-cluster drill is intentionally outside
this implementation scope and should be scheduled separately.

## Verification

First verify the core bootstrap substrate:

```bash
op run -- just bootstrap verify
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
op run -- just bootstrap verify-full
```

This additionally checks:

- `cluster-apps` readiness
- all Flux Kustomizations and HelmReleases ready
- `openebs-hostpath`, `ceph-block`, and `csi-ceph-blockpool`
- Rook Ceph Kustomization readiness
- Kopiur Kustomization and repository readiness
- Envoy Gateway programming
- main CNPG `postgres` cluster readiness
- Kopiur SnapshotPolicy/SnapshotSchedule API availability

## Data restoration expectations

### Kopiur PVCs

Persistent apps using `kubernetes/components/kopiur/backup` create Kopiur `SnapshotPolicy`, `SnapshotSchedule`, and passive `Restore` resources. PVCs created by `kubernetes/components/persistence` have a `dataSourceRef` to that `Restore`, so a destructive rebuild provisions the PVC from the latest **NFS** Kopia snapshot automatically. New apps still work because the restore uses `onMissingSnapshot: Continue`.

Important details:

- The default GitOps-created PVC restore uses `${APP}-nfs` from the Kopiur NFS repository. Use the manual R2 procedure if the NFS repository is unavailable or missing the desired snapshot.
- The UNAS and `/var/nfs/shared/kopiur` must be available before Kopiur mover jobs can restore from the primary repository.
- Cloudflare R2 Kopia backups are retained as a secondary disaster copy. Use `kubectl kopiur restore` against the `*-r2` policy snapshots if the NFS repository is unavailable.
- App-specific exceptions must keep `KOPIUR_RESTORE_NAME` and `KOPIUR_RESTORE_POLICY` aligned with the PVC that should be populated. For example, AdGuard restores the seed PVC `adguard` from policy `adguard-0-nfs`; StatefulSet ordinal `data-adguard-1` is then repopulated by sync.
- After bootstrap, inspect Kopiur objects and PVCs:

  ```bash
  kubectl kopiur status -A
  kubectl get restores,snapshotpolicies,snapshotschedules,snapshots.kopiur.home-operations.com -A
  kubectl get pvc -A
  ```

### PostgreSQL / CNPG

CNPG clusters use their declarative manifests and backup configuration in Git. During a full rebuild, database readiness can lag behind Flux readiness while operators, object storage, DNS/routing, and backup recovery settle.

Use the full verifier and CNPG checks:

```bash
op run -- just bootstrap verify-full
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
op run -- just talos talosconfig
talosctl --endpoints 10.0.80.10 --nodes 10.0.80.10 version
```

### Bootstrap interrupted

If bootstrap is interrupted, rerun the same staged command. Stages are designed to tolerate already-configured nodes, existing etcd bootstrap state, and already-applied Kubernetes resources:

```bash
op run -- just bootstrap cluster
```

Do not reset nodes unless you intentionally want to restart the destructive rebuild from maintenance mode.

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
op run -- just bootstrap verify-full
```
