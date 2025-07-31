# Node Management Procedures

This document outlines procedures for managing Talos cluster nodes, including removing working nodes and replacing dead nodes.

## Overview

Node management in Talos clusters requires careful coordination between Kubernetes, etcd (for control plane), and storage systems like Rook/Ceph. This document covers both graceful removal of working nodes and emergency replacement of dead nodes.

# Working Node Removal Procedure

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
# Edit talconfig.yaml to remove the node entry
# Regenerate configurations
cd kubernetes/bootstrap/talos
talhelper genconfig

# Update Rook configuration if needed
# Edit kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml
# Remove the node from the storage.nodes list
```

---

# Dead Node Replacement Procedure

Use this procedure when a node has died and needs hardware replacement while maintaining the same node identity.

## Prerequisites

- New hardware ready for installation
- Access to existing node configuration files in `clusterconfig/`
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
3. **Storage**: Install compatible storage devices as specified in `talconfig.yaml`

### Step 5: Apply Existing Node Configuration

**IMPORTANT**: Use the existing node configuration - do NOT regenerate it.

```bash
# Apply the EXISTING node configuration to new hardware
talosctl apply-config --insecure --nodes <node-ip> --file clusterconfig/home-kubernetes-k8s-node-X.yaml
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

1. **Update `talconfig.yaml`** with new hardware specifications
2. **Regenerate configuration**:
   ```bash
   cd kubernetes/bootstrap/talos
   talhelper genconfig
   ```
3. **Apply updated configuration**:
   ```bash
   talosctl apply-config --nodes <node-ip> --file clusterconfig/home-kubernetes-k8s-node-X.yaml
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
- **Use existing node configuration** - regenerating changes the node identity
- **For etcd clusters** - maintain odd number of healthy control plane nodes

### Control Plane Considerations
- **Maintain quorum** - ensure sufficient healthy control plane nodes
- **etcd member limits** - odd numbers (3, 5, 7) are recommended
- **Never remove the last healthy control plane node**