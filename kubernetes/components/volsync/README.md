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

### Common Issues

1. **Backup Pod Fails**: Check storage class availability and CSI snapshot support
2. **NFS Mount Issues**: Verify the NFS admission policy is working (`kubectl get mutatingadmissionpolicybinding`)
3. **Restore Hangs**: Verify repository credentials and NFS connectivity
4. **PVC Not Created**: Ensure ReplicationDestination is in Ready state before PVC creation
