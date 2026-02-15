## Prerequisites

### Required Tools

The following CLI tools must be installed and accessible in your PATH:

- `helm` - Helm package manager
- `helmfile` - Helm chart deployment orchestration
- `jq` - JSON processor
- `kubectl` - Kubernetes command-line tool
- `kustomize` - Kubernetes configuration management
- `op` - 1Password CLI
- `talosctl` - Talos Linux control tool
- `yq` - YAML processor
- `task` - Task runner

### Environment Setup

1. **KUBECONFIG**: Set the `KUBECONFIG` environment variable to specify where the kubeconfig file should be saved:
   ```bash
   export KUBECONFIG=~/.kube/config
   ```

2. **SOPS Age Key**: Ensure the SOPS age key is saved to `~/.config/sops/age/keys.txt`. You can retrieve this from 1Password under the item 'sops-age-key'.

3. **1Password Authentication**: Authenticate with 1Password CLI:
   ```bash
   op signin
   ```

## Resetting Existing Cluster (Optional)

If you have an existing cluster that needs to be reset:

```bash
task talos:nuke
```

This will reset all nodes back to maintenance mode, wiping state and ephemeral data.

Alternatively, you can download `metal-amd64.iso` from the [Talos releases page](https://github.com/siderolabs/talos/releases) matching your current version and manually boot each node into maintenance mode. Nodes should have statically assigned IP addresses from the Unifi DHCP server (`10.0.80.x`).

## Bootstrap Process

The bootstrap process can be executed using the automated script:

```bash
./scripts/bootstrap-cluster.sh
```

This script performs the following steps:

### 1. Talos Configuration

The script will:

1. **Generate Talos configuration**: Creates node-specific configuration files using `talhelper`:
   ```bash
   task talos:generate
   ```
   This reads from `talos/talconfig.yaml`, `talos/talenv.yaml`, and `talos/talsecret.yaml` to generate configurations for each node.

2. **Apply configuration to nodes**: Applies the generated configuration to all Talos nodes:
   ```bash
   task talos:apply
   ```
   Note: If nodes are already configured, the script will skip this step to avoid certificate conflicts.

3. **Bootstrap the cluster**: Initializes the Kubernetes cluster on a controller node:
   ```bash
   task talos:bootstrap
   ```
   The script will retry this operation until successful, checking for "AlreadyExists" to detect completion.

4. **Fetch kubeconfig**: Downloads the kubeconfig file from a controller node:
   ```bash
   talosctl kubeconfig --nodes <controller> --force <kubeconfig-file>
   ```

### 2. Kubernetes Setup

Once Talos is bootstrapped, the script sets up core Kubernetes components:

1. **Wait for nodes**: The script waits for all nodes to be available before proceeding. It uses `talosctl health --server=false` to verify node health.

2. **Apply Custom Resource Definitions (CRDs)**:
   - External DNS CRDs
   - Gateway API experimental CRDs
   - Prometheus Operator CRDs
   - Network Attachment Definition CRDs (Multus)
   - Barman Cloud CRDs (CloudNative-PG)
   - Envoy Gateway CRDs (extracted from Helm chart)

3. **Apply bootstrap resources**: Renders and applies resources from `bootstrap/resources.yaml.j2` using 1Password (`op inject`) to inject secrets. This creates:
   - `external-secrets`, `flux-system`, and `network` namespaces
   - 1Password Connect credentials secret
   - SOPS age key secret for Flux decryption
   - TLS certificate secret for ingress

4. **Sync Helm releases**: Deploys core infrastructure components using Helmfile in order:
   ```
   Cilium → CoreDNS (built-in) → Spegel → cert-manager → External Secrets → Flux Operator → Flux Instance
   ```
   ```bash
   helmfile --file bootstrap/helmfile.yaml sync --hide-notes
   ```

## Verification

After the bootstrap completes, verify the cluster is healthy and starting:

1. **Check node status**:
   ```bash
   kubectl get nodes -o wide
   ```
   All nodes should show `Ready` status.

2. **Verify core resources**:
   ```bash
   kubectl get pods -A
   kubectl get kustomization -A
   kubectl get helmrelease -A
   ```

3. **Verify Flux components**:
   ```bash
   kubectl -n flux-system get pods -o wide
   ```

## Post-Bootstrap Notes

### Storage Considerations

Ensure OSDs are properly configured in `rook-ceph`. With `wipeDevicesFromOtherClusters: true` set, the setup should be seamless. However, avoid installing the Talos system partition on disks designated for Rook-Ceph, as this will cause OSD job failures.

### Certificate Generation

`cert-manager` may take some time to generate certificates. This is normal - be patient and monitor the certificate resources.

### Data Restoration

VolSync backups use a dual-storage strategy (Kopia to NFS + Restic to Cloudflare R2). On bootstrap, VolSync will automatically begin restoring volumes from the last available snapshot. Verify that your applications have their data restored after startup.

## Troubleshooting

- **Bootstrap interruption**: If the bootstrap process is interrupted (e.g., by Ctrl+C), you may need to reset the cluster using `task talos:nuke` before trying again.
- **Node connectivity**: Ensure all nodes are accessible and have their expected static IP addresses.
- **1Password authentication**: If you see authentication errors, ensure you're signed into 1Password CLI with `op signin`.

The bootstrap process typically takes 10+ minutes. During this time, you may see various error messages like "couldn't get current server API group list" or "error: no matching resources found" - these are normal as services come online.
