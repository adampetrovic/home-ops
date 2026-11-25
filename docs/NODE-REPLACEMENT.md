# Working Node

Use this procedure when removing a healthy, working node from the cluster.

## Prerequisites

- Node to be removed is healthy and accessible
- Sufficient remaining nodes to maintain cluster quorum (especially for control plane)
- For Rook storage nodes: verify sufficient replicas exist on remaining nodes

## Procedure

### Step 1: Drain the Node

Gracefully move workloads off the node:

```bash
# Cordon the node to prevent new pods
kubectl cordon k8s-node-X

# Drain the node (move pods to other nodes)
kubectl drain k8s-node-X --ignore-daemonsets --delete-emptydir-data --force

# Verify no user workloads remain
kubectl get pods --all-namespaces --field-selector spec.nodeName=k8s-node-X
```

### Step 2: Clean Up Rook/Ceph Storage (If Applicable)

If the node participates in Rook storage, clean up OSDs before removal:

```bash
# Check which OSDs are on the node
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree

# For each OSD on the node, gracefully remove it
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd out osd.X

# Wait for data migration to complete
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph -s

# Once data is migrated, stop the OSD
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd down osd.X

# Remove the OSD from the cluster
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd rm osd.X

# Remove from CRUSH map
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd crush remove k8s-node-X

# Clean up authentication
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph auth del osd.X
```

### Step 3: Remove from etcd (Control Plane Nodes Only)

For control plane nodes, remove from etcd cluster:

```bash
# List etcd members
talosctl -n <other-control-plane-node> etcd members

# Remove the member
talosctl -n <other-control-plane-node> etcd remove-member <member-id>

# Verify removal
talosctl -n <other-control-plane-node> etcd members
```

### Step 4: Reset the Node

Perform a clean reset on the working node:

```bash
# Reset the node (this will wipe it clean)
talosctl reset --nodes k8s-node-X --graceful=true --wait=true

# The node will shut down after reset
```

### Step 5: Remove from Kubernetes

```bash
# Remove the node from Kubernetes
kubectl delete node k8s-node-X

# Verify removal
kubectl get nodes
```

### Step 6: Update Configuration (Optional)

If permanently removing the node, update your configuration:

```bash
# Edit talos/inventory.yaml and remove the matching talos/nodes/** template
# Validate remaining rendered configs
just talos validate-all

# Update Rook configuration if needed
# Edit kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml
# Remove the node from the storage.nodes list
```

---

# System Disk Replacement

Use this procedure when replacing only the Talos system disk of a healthy node. The node keeps its name, IP address and Ceph data disk, and is reinstalled onto the new disk.

Do not use the working-node procedure for this. Removing the OSD rebalances the Ceph data disk away and back for no benefit, and `talosctl reset` wipes the old system disk, which is the fallback if the new disk fails.

## What the System Disk Holds

Everything under `/var` goes with the old disk and is rebuilt from the rest of the cluster:

| Data | Recovery |
| --- | --- |
| Talos install and machine config | Reinstalled from the node template |
| etcd member (control-plane nodes) | The node leaves etcd before the swap and joins as a new member |
| Ceph monitor data in `/var/lib/rook` (control-plane nodes) | Rook restores the monitor once the node is back |
| Ceph OSD directory in `/var/lib/rook` | Rebuilt from the data disk when the OSD pod starts |
| `openebs-hostpath` volumes in `/var/openebs/local` | CloudNativePG re-clones a replica from its primary; any other volume is lost |
| Container images | Pulled again |

## Prerequisites

- All nodes `Ready`, Ceph `HEALTH_OK`, every CloudNativePG cluster fully ready, and `just talos upgrade-check` passing
- A USB stick to boot the Talos installer from
- 1Password access for rendering the machine config
- No other node maintenance in progress: while a control-plane node is out, etcd and the Ceph monitors run on two of three

## Procedure

### Step 1: Build the Installer USB

```bash
# Schematic ID for the node
TALOS_SKIP_OP_INJECT=true talos/scripts/schematic-id.sh k8s-node-X

# Talos version: the tag of installer.image in talos/nodes/**/k8s-node-X.yaml.j2
curl -fLO "https://factory.talos.dev/image/<schematic-id>/<version>/metal-amd64.iso"
```

Write the ISO to the USB stick.

### Step 2: List the Node-Local Volumes

```bash
# openebs-hostpath claims pinned to the node
kubectl get pv -o json | jq -r '.items[]
  | select(.spec.storageClassName == "openebs-hostpath")
  | select(.spec.nodeAffinity.required.nodeSelectorTerms[].matchExpressions[].values[] == "k8s-node-X")
  | "\(.spec.claimRef.namespace)/\(.spec.claimRef.name)"'

# Instance counts and current primaries
kubectl get clusters.postgresql.cnpg.io -A
```

Each claim must belong to a CloudNativePG cluster that has another instance on a different node. Any other claim on the list loses its data, so move it or accept the loss before continuing. Keep the list for Step 8.

### Step 3: Drain the Node

```bash
kubectl cordon k8s-node-X
kubectl drain k8s-node-X --ignore-daemonsets --delete-emptydir-data --timeout=600s
```

The drain moves any CloudNativePG primary to another instance. Replicas pinned to the node stay `Pending`. Pods that tolerate a cordon, such as Tuppr, can be scheduled straight back onto the node.

### Step 4: Leave etcd (Control Plane Nodes Only)

```bash
talosctl -n <node-ip> etcd forfeit-leadership
talosctl -n <node-ip> etcd leave

# Verify from another control-plane node: two members remain
talosctl -n <other-control-plane-node> etcd members
```

### Step 5: Hold Ceph Rebalancing and Shut Down

Rook holds off rebalancing for only 30 minutes after a drain, so set the flag for the whole swap:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set noout

talosctl -n <node-ip> shutdown
kubectl delete node k8s-node-X
```

### Step 6: Swap the Disk and Boot the Installer

Replace the system disk and keep the old one untouched until the node has rejoined. Boot from the USB stick into Talos maintenance mode, then check the node and its disks:

```bash
talosctl -n <node-ip> version --insecure
talosctl -n <node-ip> get disks --insecure
```

If the new disk's `MODEL` differs from the `diskSelector` in `talos/nodes/**/k8s-node-X.yaml.j2`, update the template with the exact string shown. Talos truncates SATA model names and reports no serial for SATA disks, so take the string from this output.

### Step 7: Install

```bash
just talos validate k8s-node-X
just talos apply-insecure-node k8s-node-X
```

Talos installs to the selected disk and reboots; remove the USB stick when it does. The node joins the existing cluster by itself. Never run `just talos bootstrap` here: it creates a new etcd cluster.

### Step 8: Rebuild Node-Local Data

```bash
# Node Ready, and three etcd members again on control-plane nodes
kubectl get nodes -w
talosctl -n <other-control-plane-node> etcd members

# For each claim from Step 2: remove the instance whose data is gone
kubectl cnpg destroy -n <namespace> <cluster> <instance-number>
kubectl get clusters.postgresql.cnpg.io -A
```

CloudNativePG creates a replacement instance under a new number and clones it from the primary. The scheduler picks its node.

```bash
# OSD and monitor pods on the node
kubectl -n rook-ceph get pods -o wide | grep k8s-node-X
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status

# Once all OSDs are up and three monitors are in quorum
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout
```

### Step 9: Verify

```bash
just talos upgrade-check
```

Run the LoadBalancer/BGP check in `docs/agent/platform.md`, then commit the `diskSelector` change if there was one. The old disk can be wiped once every check passes.

## Fallback to the Old Disk

If the new disk fails to install, put the old disk back. It boots with its existing machine config, but on a control-plane node its etcd data belongs to a member that has left the cluster. Wipe `/var` so the node rejoins as a new member, then continue from Step 8:

```bash
talosctl -n <node-ip> reset --system-labels-to-wipe EPHEMERAL --reboot --graceful=false
```

---

# Dead Node

Use this procedure when a node has died and needs hardware replacement while maintaining the same node identity.

## Prerequisites

- New hardware ready for installation
- Access to the repository's native Talos templates and 1Password-backed Talos secrets
- Access to healthy cluster nodes for cleanup operations

## Procedure

### Step 1: Clean Up Kubernetes Resources

Remove the dead node from Kubernetes cluster:

```bash
# Remove the dead node from Kubernetes
kubectl delete node k8s-node-X

# Check for stuck pods on the dead node
kubectl get pods --all-namespaces --field-selector spec.nodeName=k8s-node-X

# Force delete any stuck pods
kubectl delete pod <stuck-pod> --grace-period=0 --force -n <namespace>
```

### Step 2: Clean Up etcd (Control Plane Nodes Only)

If replacing a control plane node, remove it from etcd cluster:

```bash
# List current etcd members
talosctl -n <healthy-control-plane-node> etcd members

# Remove the dead member by ID
talosctl -n <healthy-control-plane-node> etcd remove-member <member-id>

# Verify removal
talosctl -n <healthy-control-plane-node> etcd members
```

### Step 3: Clean Up Rook/Ceph Storage (If Applicable)

If the dead node participated in Rook storage:

```bash
# Check which OSDs were on the dead node
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree

# Mark OSDs as out and remove them
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd out osd.X
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd purge osd.X --yes-i-really-mean-it

# Remove the node from CRUSH map
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd crush remove k8s-node-X

# Verify cleanup
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

### Step 4: Prepare New Hardware

1. **Physical Setup**: Install and configure new hardware
2. **Network Configuration**: Ensure same IP address (static or DHCP reservation)
3. **Storage**: Install compatible storage devices as specified in the matching `talos/nodes/**/<node>.yaml.j2` template

### Step 5: Apply Existing Node Configuration

**IMPORTANT**: Preserve the same node identity and secrets. Render/apply the existing node template for that node name.

```bash
# Validate and apply the existing node template to new hardware in maintenance mode
just talos validate k8s-node-X
just --yes talos apply-insecure-node k8s-node-X
```

The node will:
- Boot with the same certificates and identity
- Automatically rejoin the cluster
- Inherit the same role (control plane or worker)

### Step 6: Verify Node Recovery

Monitor the node joining process:

```bash
# Watch node status
kubectl get nodes -w

# Check node details once Ready
kubectl describe node k8s-node-X

# For control plane nodes, verify etcd cluster
talosctl -n <any-control-plane> etcd members
talosctl -n <any-control-plane> etcd status
```

### Step 7: Verify Storage Recovery (Rook Nodes)

For nodes that participate in Rook storage:

```bash
# Check OSD pods starting
kubectl get pods -n rook-ceph -o wide | grep k8s-node-X

# Monitor Ceph cluster health
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree

# Wait for data rebalancing to complete
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph -s
```

## Hardware Changes

If the new hardware requires different configuration (disk model, network interface, etc.):

1. **Update the matching `talos/nodes/**/<node>.yaml.j2`** with new hardware selectors/specifications.
2. **Validate rendered configuration**:
   ```bash
   just talos validate k8s-node-X
   ```
3. **Apply updated configuration**:
   ```bash
   just --yes talos apply-insecure-node k8s-node-X
   ```

## Troubleshooting

### Node Won't Join Cluster
- Verify network connectivity to control plane
- Check certificates match existing cluster
- Ensure correct talosconfig context

### etcd Issues (Control Plane)
- Verify etcd member was properly removed before replacement
- Check etcd logs: `talosctl -n <node> logs etcd`
- Ensure sufficient healthy etcd members during replacement

### Rook/Ceph Issues
- Monitor OSD startup: `kubectl logs -n rook-ceph -l app=rook-ceph-osd`
- Check device availability and permissions
- Verify data replication before removing additional nodes

## Important Notes

### General Guidelines
- **One node at a time** - don't remove/replace multiple nodes simultaneously
- **Monitor cluster health** throughout any procedure
- **Verify sufficient resources** remain for workloads after node removal

### Working Node Removal
- **Always drain first** - prevents workload disruption
- **For Rook storage** - wait for data migration to complete before proceeding
- **Configuration updates** are optional unless permanently removing the node

### Dead Node Replacement
- **Never skip cleanup steps** - leftover cluster state can cause conflicts
- **Use the existing node template and secrets** - changing the node name or Talos secrets changes identity
- **For etcd clusters** - maintain odd number of healthy control plane nodes

### Control Plane Considerations
- **Maintain quorum** - ensure sufficient healthy control plane nodes
- **etcd member limits** - odd numbers (3, 5, 7) are recommended
- **Never remove the last healthy control plane node**