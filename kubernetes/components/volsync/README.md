VolSync is a Kubernetes operator that provides automated backup and restore capabilities for persistent volumes using Restic and CSI snapshots. This document explains how my VolSync implementation works and how to integrate it with applications.

## Architecture Overview

This VolSync setup uses a dual-storage strategy:

- **Garage (Primary)**: Frequent backups (hourly by default) stored in local Garage S3-compatible storage
- **Cloudflare R2 (Secondary)**: Daily backups stored in Cloudflare R2 for long-term retention and disaster recovery

### Core Components

The VolSync system consists of three main CRDs (Custom Resource Definitions):

1. **ReplicationSource**: Handles backup operations from a PVC to a repository
2. **ReplicationDestination**: Handles restore operations from a repository to a PVC
3. **ExternalSecret**: Manages repository credentials securely via 1Password

### Component Architecture

Our implementation uses a Kustomize component approach located in `kubernetes/components/volsync/`:

```
volsync/
├── kustomization.yaml    # Component definition
├── claim.yaml           # PVC template with restore capability
├── garage.yaml          # Garage backup configuration
└── r2.yaml              # Cloudflare R2 backup configuration
```

## Detailed Workflows

### 1. First-Time PVC Provisioning

When an application with VolSync support is deployed for the first time, the following process occurs:

#### Step 1: ReplicationDestination Creation
```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: "${APP}-dst"
spec:
  trigger:
    manual: restore-once  # Manual trigger for initial setup
  restic:
    repository: "${APP}-volsync-secret"
    copyMethod: Snapshot
```

#### Step 2: PVC Creation with DataSource Reference
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: "${APP}"
spec:
  dataSourceRef:
    kind: ReplicationDestination
    apiGroup: volsync.backube
    name: "${APP}-dst"  # References the ReplicationDestination
```

#### Step 3: Pod Creation Process

1. **Initial Check**: VolSync controller checks if backup data exists in the repository
2. **No Existing Backup**: If no backup exists, the PVC is provisioned normally as an empty volume
3. **Existing Backup Found**: If backup data exists, the restore process begins:

   a. **Cache Volume Creation**: A temporary cache PVC is created:
   ```
   Name: volsync-dst-cache-{random}
   Size: ${VOLSYNC_CACHE_CAPACITY} (default: 8Gi)
   StorageClass: ${VOLSYNC_CACHE_SNAPSHOTCLASS} (default: openebs-hostpath)
   ```

   b. **Restore Mover Pod**: VolSync creates a restore pod:
   ```
   Name: volsync-dst-{app}-{random}
   Image: quay.io/backube/volsync:latest
   SecurityContext:
     runAsUser: 568
     runAsGroup: 568
     fsGroup: 568
   ```

   c. **Data Restoration**: The mover pod:
   - Mounts both the cache volume and target PVC
   - Downloads and decrypts backup data from the repository
   - Restores files to the target PVC
   - Verifies data integrity

   d. **Cleanup**: Cache volume and mover pod are removed after successful restoration

#### Step 4: Application Pod Startup
Once the PVC is ready (either empty or restored), the application pod can start and mount the volume.

### 2. Scheduled Backup Process

Automated backups are configured via ReplicationSource with two separate schedules:

#### Garage Backup (Frequent)
- **Schedule**: `${VOLSYNC_SCHEDULE}` (default: hourly at minute 0)
- **Retention**: 24 hourly, 7 daily, 5 weekly, 6 monthly

#### R2 Backup (Long-term)
- **Schedule**: `${VOLSYNC_R2_SCHEDULE}` (default: daily at 00:30)
- **Retention**: 7 daily, 1 weekly, 1 monthly

#### Backup Pod Creation Process

When a backup is triggered:

1. **Snapshot Creation**: CSI creates a volume snapshot:
   ```
   Name: volsync-src-{app}-{timestamp}
   SnapshotClass: ${VOLSYNC_SNAPSHOTCLASS} (default: csi-ceph-blockpool)
   ```

2. **Cache Volume Provisioning**: Temporary cache volume created:
   ```
   Size: ${VOLSYNC_CACHE_CAPACITY} (default: 4Gi)
   StorageClass: ${VOLSYNC_CACHE_SNAPSHOTCLASS} (default: openebs-hostpath)
   ```

3. **Backup Mover Pod Creation**:
   ```
   Name: volsync-src-{app}-{random}
   Image: quay.io/backube/volsync:latest
   Volumes:
   - snapshot-data (from CSI snapshot)
   - cache-volume (temporary cache)
   Environment:
   - RESTIC_REPOSITORY
   - RESTIC_PASSWORD
   - AWS_ACCESS_KEY_ID
   - AWS_SECRET_ACCESS_KEY
   ```

4. **Backup Execution**:
   - Pod mounts the snapshot as read-only
   - Restic creates encrypted, deduplicated backup
   - Data is uploaded to the target repository (Garage or R2)
   - Backup metadata is updated

5. **Cleanup Process**:
   - Snapshot is deleted (after successful backup)
   - Cache volume is removed
   - Mover pod is terminated
   - Old backups are pruned according to retention policy

### 3. Restore from Existing Backup

When provisioning a PVC where backups already exist:

#### Step 1: Repository Discovery
VolSync controller queries the Restic repository to find available snapshots:
```bash
restic snapshots --json
```

#### Step 2: ReplicationDestination Activation
The ReplicationDestination is triggered with the manual restore:
```yaml
spec:
  trigger:
    manual: restore-once
```

#### Step 3: Restore Pod Lifecycle

1. **Pod Creation**: Restore mover pod is created:
   ```
   Name: volsync-dst-{app}-{random}
   Image: quay.io/backube/volsync:latest
   InitContainers: []  # No init containers needed
   Containers:
   - name: restic
     securityContext:
       runAsUser: 568
       runAsGroup: 568
       fsGroup: 568
   ```

2. **Volume Mounting**:
   - Target PVC mounted at `/data`
   - Cache volume mounted at `/tmp/cache`

3. **Backup Selection**: Pod automatically selects the latest snapshot unless specified otherwise

4. **Data Restoration Process**:
   ```bash
   # Inside the mover pod
   restic restore latest --target /data
   restic check --read-data  # Verify integrity
   ```

5. **Ownership and Permissions**: Files are restored with proper ownership (UID 568, GID 568)

6. **Completion**: Pod completes successfully, PVC is ready for application use

## Integration Guide: Adding VolSync to Applications

### Step 1: Include the VolSync Component

In your application's `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
components:
  - ../../../../components/volsync  # Path to volsync component
resources:
  - ./your-app-resources.yaml
```

### Step 2: Configure Environment Variables

In your Flux Kustomization (`ks.yaml`), define the required variables:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: your-app
spec:
  postBuild:
    substitute:
      APP: your-app                                    # Required: Application name
      VOLSYNC_CAPACITY: 10Gi                          # Required: PVC size
      VOLSYNC_ACCESSMODES: ReadWriteOnce              # Optional: default ReadWriteOnce
      VOLSYNC_STORAGECLASS: ceph-block                # Optional: default ceph-block
      VOLSYNC_SNAPSHOTCLASS: csi-ceph-blockpool       # Optional: default csi-ceph-blockpool
      VOLSYNC_COPYMETHOD: Snapshot                    # Optional: default Snapshot
      VOLSYNC_SCHEDULE: "0 */6 * * *"                # Optional: Garage backup schedule (default hourly)
      VOLSYNC_R2_SCHEDULE: "30 2 * * *"              # Optional: R2 backup schedule (default daily at 00:30)
      VOLSYNC_CACHE_CAPACITY: 4Gi                     # Optional: default 4Gi
      VOLSYNC_CACHE_SNAPSHOTCLASS: openebs-hostpath   # Optional: default openebs-hostpath
      VOLSYNC_CACHE_ACCESSMODES: ReadWriteOnce        # Optional: default ReadWriteOnce
```

### Step 3: Application Configuration

Ensure your application's PVC uses the same name as the `APP` variable:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: your-app  # Must match ${APP} variable
spec:
  # ... rest of PVC spec
```

### Required Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `APP` | Yes | - | Application name, used for PVC and backup naming |
| `VOLSYNC_CAPACITY` | Yes | - | Size of the PVC to create/backup |
| `VOLSYNC_ACCESSMODES` | No | ReadWriteOnce | PVC access modes |
| `VOLSYNC_STORAGECLASS` | No | ceph-block | StorageClass for PVC |
| `VOLSYNC_SNAPSHOTCLASS` | No | csi-ceph-blockpool | VolumeSnapshotClass for snapshots |
| `VOLSYNC_SCHEDULE` | No | 0 * * * * | Cron schedule for Garage backups |
| `VOLSYNC_R2_SCHEDULE` | No | 30 0 * * * | Cron schedule for R2 backups |

### Step 4: Secret Management

The VolSync component automatically creates ExternalSecrets that pull credentials from 1Password:

- **Garage**: Uses `garage` and `volsync-garage-template` secrets
- **R2**: Uses `cloudflare-r2-volsync` and `volsync-r2-template` secrets

No additional secret configuration is required in your application.

## Storage Classes and Compatibility

### Supported Storage Classes

- **ceph-block** (default): RBD-based block storage with ReadWriteOnce
- **ceph-filesystem**: CephFS-based storage with ReadWriteMany support
- **openebs-hostpath**: Local storage for cache volumes

### Special Configurations

For applications requiring ReadWriteMany access:

```yaml
VOLSYNC_ACCESSMODES: ReadWriteMany
VOLSYNC_STORAGECLASS: ceph-filesystem
VOLSYNC_SNAPSHOTCLASS: csi-ceph-filesystem
```

## Monitoring and Troubleshooting

### Checking Backup Status

```bash
# List ReplicationSources
kubectl get replicationsource -A

# Check backup history
kubectl logs -n <namespace> <replicationsource-pod-name>

# View backup repository info
kubectl exec -n <namespace> <pod-name> -- restic snapshots
```

### Clearing PVC Data

When switching applications or resetting state, you may need to wipe the contents of a VolSync-managed PVC without deleting the PVC itself. Deleting the PVC would cause VolSync to restore from the existing backup on recreation, bringing back the old data.

```bash
# 1. Suspend the Flux kustomization to prevent reconciliation
flux suspend ks <app> -n flux-system

# 2. Scale down the application so it releases the PVC
kubectl scale deployment <app> -n <namespace> --replicas=0

# 3. Run a temporary pod to wipe the PVC contents
kubectl run pvc-cleanup -n <namespace> --rm -it --restart=Never \
  --image=alpine \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "pvc-cleanup",
        "image": "alpine",
        "command": ["sh", "-c", "rm -rf /data/* /data/.*; echo done"],
        "volumeMounts": [{"name": "data", "mountPath": "/data"}]
      }],
      "volumes": [{
        "name": "data",
        "persistentVolumeClaim": {"claimName": "<app>"}
      }],
      "securityContext": {"runAsUser": 568, "runAsGroup": 568, "fsGroup": 568}
    }
  }'

# 4. Resume the kustomization to deploy the updated application
flux resume ks <app> -n flux-system
```

The next scheduled backup will snapshot the fresh state, replacing old data in the backup chain over time according to the retention policy.

### Common Issues

1. **Backup Pod Fails**: Check storage class availability and CSI snapshot support
2. **Restore Hangs**: Verify repository credentials and network connectivity
3. **PVC Not Created**: Ensure ReplicationDestination is in Ready state before PVC creation

### Pod Naming Conventions

- **Backup pods**: `volsync-src-{app}-{random-string}`
- **Restore pods**: `volsync-dst-{app}-{random-string}`
- **Cache volumes**: `volsync-{src|dst}-cache-{random-string}`

This naming scheme helps identify pods and their purposes during troubleshooting.
