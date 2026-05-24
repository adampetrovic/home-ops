VolSync is a Kubernetes operator that provides automated backup and restore capabilities for persistent volumes using Kopia and CSI snapshots. This document explains how our VolSync implementation works and how to integrate it with applications.

## Architecture Overview

This VolSync setup uses a dual-storage strategy:

- **Kopia (Primary)**: Frequent backups (hourly) stored in a Kopia filesystem repository on NFS (`/volume2/kopia`)
- **Cloudflare R2 (Secondary)**: Daily backups stored in Cloudflare R2 via restic for disaster recovery

### Thundering Herd Prevention

All Kopia backups share a single cron schedule (`0 * * * *`). A `MutatingAdmissionPolicy` (`volsync-mover-jitter`) automatically injects a random 0-30 second sleep as an init container into every VolSync source job, spreading out the actual backup starts across a 30-second window.

A second `MutatingAdmissionPolicy` (`volsync-mover-nfs`) dynamically injects the NFS volume mount for the Kopia repository into every VolSync mover job, keeping the component configuration clean.

### Core Components

The VolSync system consists of these main CRDs:

1. **ReplicationSource**: Handles backup operations from a PVC to a repository (Kopia for primary, restic for R2)
2. **ReplicationDestination**: Handles restore operations from a Kopia repository to a PVC
3. **KopiaMaintenance**: Runs scheduled Kopia repository maintenance (every 12 hours)
4. **ExternalSecret**: Manages repository credentials securely via 1Password

### Component Architecture

The reusable Kustomize component at `kubernetes/components/volsync/`:

```
volsync/
├── kustomization.yaml          # Component definition
├── claim.yaml                  # PVC template with restore capability
├── externalsecret.yaml         # Kopia repository secret
├── replicationsource.yaml      # Kopia backup configuration (hourly)
├── replicationdestination.yaml # Kopia restore configuration
└── r2.yaml                     # Cloudflare R2 restic backup (daily)
```

### Infrastructure (volsync-system namespace)

```
volsync-system/
├── volsync/           # VolSync operator (perfectra1n fork with Kopia support)
│   ├── app/           # HelmRelease + MutatingAdmissionPolicies (jitter + NFS)
│   └── maintenance/   # KopiaMaintenance CRD + NFS admission policy
├── kopia/             # Kopia web UI server (NFS-backed repository browser)
└── snapshot-controller/
```

## Integration Guide: Adding VolSync to Applications

### Step 1: Add the VolSync Component

In your application's `ks.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app your-app
spec:
  components:
    - ../../../../components/volsync
  postBuild:
    substitute:
      APP: *app
      VOLSYNC_CAPACITY: 10Gi
```

That's it for Kopia backups — no schedule configuration needed. The hourly schedule and jitter are handled automatically.

### Step 2: Optional R2 Schedule Override

R2 daily backups default to `30 2 * * *`. To customize:

```yaml
  postBuild:
    substitute:
      APP: *app
      VOLSYNC_CAPACITY: 10Gi
      VOLSYNC_R2_SCHEDULE: "45 3 * * *"
```

### Required Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `APP` | Yes | - | Application name, used for PVC and backup naming |
| `VOLSYNC_CAPACITY` | Yes | 5Gi | Size of the PVC to create/backup |
| `VOLSYNC_ACCESSMODES` | No | ReadWriteOnce | PVC access modes |
| `VOLSYNC_STORAGECLASS` | No | ceph-block | StorageClass for PVC |
| `VOLSYNC_SNAPSHOTCLASS` | No | csi-ceph-blockpool | VolumeSnapshotClass for snapshots |
| `VOLSYNC_R2_SCHEDULE` | No | 30 2 * * * | Cron schedule for R2 backups |

### Secret Management

The VolSync component automatically creates ExternalSecrets that pull credentials from 1Password:

- **Kopia**: Uses `volsync-template` secret (contains `KOPIA_PASSWORD`)
- **R2**: Uses `cloudflare-r2-volsync` and `volsync-r2-template` secrets

### 1Password Setup

Create a `volsync-template` item in 1Password with:
- `KOPIA_PASSWORD`: Password for the Kopia repository

## Monitoring and Troubleshooting

### Checking Backup Status

```bash
# List ReplicationSources
kubectl get replicationsource -A

# Check Kopia maintenance status
kubectl get kopiamaintenance -A

# View Kopia web UI
# Navigate to kopia.<your-domain>
```

### Kopia Web UI

The Kopia server provides a web interface for browsing and managing backups. It connects to the same NFS-backed repository that the VolSync movers use.

## Manual R2 Restore

Taskfile shortcuts cover the two common R2 restore flows:

```bash
# Restore R2 into an existing bound PVC. The task suspends the app, scales it down,
# restores with a temporary Restic ReplicationDestination, then resumes the app.
task volsync:restore-r2 app=actual-budget ns=default

# Restore an older R2 snapshot.
task volsync:restore-r2 app=actual-budget ns=default previous=2
task volsync:restore-r2 app=actual-budget ns=default restoreAsOf="2026-03-18T08:53:01+11:00"

# Fresh rebuild fallback when the normal Kopia/NFS populator cannot restore.
# Capacity must match the app PVC size.
task volsync:restore-r2-fallback app=actual-budget ns=default capacity=2Gi
```

The detailed manual procedure below documents what those tasks do and is useful for troubleshooting.

The component creates two independent backup paths:

- `${APP}-volsync-secret` + `${APP}-dst` use Kopia on the NAS and drive the automatic PVC restore path in `claim.yaml`.
- `${APP}-volsync-r2-secret` + `${APP}-r2` use Restic on Cloudflare R2 and create secondary backups only.

VolSync does **not** automatically fall back from Kopia/NFS to R2. If the NAS Kopia repository is unavailable or missing the desired snapshot, restore from R2 by creating a temporary Restic `ReplicationDestination` that references `${APP}-volsync-r2-secret`.

### Prerequisites

Set the app, namespace, capacity, and restore identity. Most apps use UID/GID `568`; check the app's `ReplicationSource` if unsure.

```bash
export app=actual-budget
export ns=default
export capacity=2Gi
export storageClass=ceph-block
export snapshotClass=csi-ceph-blockpool
export puid=568
export pgid=568
```

Confirm the R2 repository secret exists:

```bash
kubectl -n "${ns}" get secret "${app}-volsync-r2-secret"
```

Optionally inspect R2 snapshots directly with Restic:

```bash
kubectl -n "${ns}" run "restic-list-${app}" \
  --rm -it --restart=Never \
  --image=docker.io/restic/restic:0.16.4 \
  --env-from="secretRef/name=${app}-volsync-r2-secret" \
  -- snapshots
```

### Fresh rebuild fallback before the PVC is populated

Use this when the GitOps-created PVC is still pending because the default Kopia/NFS `ReplicationDestination` cannot produce a snapshot.

#### 1. Suspend the app Kustomization

Suspend the app Kustomization so Flux does not replace the temporary R2 restore object while it is running:

```bash
flux -n flux-system suspend kustomization "${app}"
```

#### 2. Replace the Kopia destination with a Restic/R2 destination

The PVC already points its `dataSourceRef` at `${app}-dst`, so use the same `ReplicationDestination` name and switch the mover to Restic. Volume-populator restores require `copyMethod: Snapshot`.

```bash
kubectl -n "${ns}" delete replicationdestination "${app}-dst" --ignore-not-found

cat <<EOF | kubectl apply -f -
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: ${app}-dst
  namespace: ${ns}
  labels:
    kustomize.toolkit.fluxcd.io/ssa: IfNotPresent
spec:
  trigger:
    manual: restore-once
  restic:
    repository: ${app}-volsync-r2-secret
    copyMethod: Snapshot
    accessModes: [ReadWriteOnce]
    capacity: ${capacity}
    storageClassName: ${storageClass}
    volumeSnapshotClassName: ${snapshotClass}
    cacheCapacity: 4Gi
    cacheStorageClassName: openebs-hostpath
    cacheAccessModes: [ReadWriteOnce]
    enableFileDeletion: true
    moverSecurityContext:
      runAsUser: ${puid}
      runAsGroup: ${pgid}
      fsGroup: ${pgid}
      fsGroupChangePolicy: OnRootMismatch
EOF
```

#### 3. Recreate the PVC if needed

If the PVC was deleted or never created, recreate it with the same `dataSourceRef` used by the component:

```bash
kubectl -n "${ns}" get pvc "${app}" >/dev/null 2>&1 || cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${app}
  namespace: ${ns}
spec:
  accessModes: [ReadWriteOnce]
  dataSourceRef:
    kind: ReplicationDestination
    apiGroup: volsync.backube
    name: ${app}-dst
  resources:
    requests:
      storage: ${capacity}
  storageClassName: ${storageClass}
EOF
```

#### 4. Wait for restore and PVC binding

```bash
bash .taskfiles/VolSync/scripts/wait-for-replicationdestination.sh "${app}-dst" "${ns}" 7200
kubectl -n "${ns}" wait pvc/"${app}" --for=jsonpath='{.status.phase}'=Bound --timeout=10m
```

#### 5. Clean up and resume Flux

Delete the temporary R2 destination and resume Flux. Flux will recreate the normal Kopia destination for future restores/backups.

```bash
kubectl -n "${ns}" delete replicationdestination "${app}-dst"
flux -n flux-system resume kustomization "${app}"
```

### Restore R2 into an existing bound PVC

Use this when the PVC already exists and you want to overwrite its contents from R2.

#### 1. Suspend Flux and stop the workload

No process should write to the PVC during restore:

```bash
flux -n flux-system suspend kustomization "${app}"
flux -n "${ns}" suspend helmrelease "${app}" || true
kubectl -n "${ns}" scale deploy,statefulset -l "app.kubernetes.io/name=${app}" --replicas=0
```

#### 2. Restore directly into the existing PVC

Apply a temporary Restic `ReplicationDestination` that writes directly into the existing PVC:

```bash
cat <<EOF | kubectl apply -f -
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: ${app}-r2-restore
  namespace: ${ns}
spec:
  trigger:
    manual: restore-once
  restic:
    repository: ${app}-volsync-r2-secret
    destinationPVC: ${app}
    copyMethod: Direct
    cacheCapacity: 4Gi
    cacheStorageClassName: openebs-hostpath
    cacheAccessModes: [ReadWriteOnce]
    enableFileDeletion: true
    moverSecurityContext:
      runAsUser: ${puid}
      runAsGroup: ${pgid}
      fsGroup: ${pgid}
      fsGroupChangePolicy: OnRootMismatch
EOF
```

To restore an older snapshot, add either `previous: <n>` or `restoreAsOf: "<RFC3339 timestamp>"` under `spec.restic` before applying.

#### 3. Wait, clean up, and resume the app

```bash
bash .taskfiles/VolSync/scripts/wait-for-replicationdestination.sh "${app}-r2-restore" "${ns}" 7200
kubectl -n "${ns}" delete replicationdestination "${app}-r2-restore"
flux -n "${ns}" resume helmrelease "${app}" || true
flux -n flux-system resume kustomization "${app}"
```

### Common Issues

1. **Backup Pod Fails**: Check storage class availability and CSI snapshot support
2. **NFS Mount Issues**: Verify the NFS admission policy is working (`kubectl get mutatingadmissionpolicybinding`)
3. **Restore Hangs**: Verify repository credentials and NFS connectivity
4. **PVC Not Created**: Ensure ReplicationDestination is in Ready state before PVC creation
5. **R2 Restore Fails**: Verify `${APP}-volsync-r2-secret`, R2 credentials, cache PVC capacity, and the Restic snapshot selection (`previous` / `restoreAsOf`)
