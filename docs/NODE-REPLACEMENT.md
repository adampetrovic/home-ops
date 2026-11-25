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

Use this procedure when replacing only the Talos system disk of a healthy node. The node is reinstalled onto the new disk and rejoins the cluster.

Do not use the working-node procedure for this. Removing the OSD rebalances the Ceph data disk away and back for no benefit, and `talosctl reset` wipes the old system disk, which is the fallback if the new disk fails.

## What to Expect

| Stays the same | Changes |
| --- | --- |
| Node name, IP address and role | etcd member ID |
| Node labels | Age of the Node object |
| Ceph data disk and its OSD ID | CloudNativePG replicas on the node are re-cloned |

The node is out of the cluster for about 20 minutes: about a minute to drain, the time the physical swap takes, and about three minutes from applying the config to `Ready`. The node needs no monitor or keyboard once it has booted from the USB stick; every later step can be followed remotely.

## What the System Disk Holds

Everything under `/var` goes with the old disk and is rebuilt from the rest of the cluster:

| Data | Recovery |
| --- | --- |
| Talos install and machine config | Reinstalled from the node template |
| etcd member (control-plane nodes) | The node leaves etcd before the swap and joins as a new member |
| Ceph monitor data in `/var/lib/rook` (control-plane nodes) | The monitor copies its store back from the other two |
| Ceph OSD directory in `/var/lib/rook` | Rebuilt from the data disk when the OSD pod starts |
| `openebs-hostpath` volumes in `/var/openebs/local` | CloudNativePG re-clones a replica from its primary; any other volume is lost |
| Container images | Pulled again |

## Prerequisites

- All nodes `Ready`, Ceph `HEALTH_OK`, every CloudNativePG cluster fully ready, and `just talos upgrade-check` passing. A backup pod that has only just started can show as `Pending`; re-run the check.
- A USB stick to boot the Talos installer from
- 1Password access for rendering the machine config
- No other node maintenance in progress: while a control-plane node is out, etcd and the Ceph monitors run on two of three

## Procedure

### Step 1: Build the Installer USB

```bash
# Schematic ID for the node
TALOS_SKIP_OP_INJECT=true talos/scripts/schematic-id.sh k8s-node-X

# It must match the "schematic" row the running nodes report
talosctl -n <any-node-ip> get extensions

# Talos version: the tag of installer.image in talos/nodes/**/k8s-node-X.yaml.j2
# The address redirects, so curl needs -L
curl -fLo talos.iso "https://factory.talos.dev/image/<schematic-id>/<version>/metal-amd64.iso"
```

`metal-amd64.iso` is the right image while `talosctl -n <any-node-ip> get securitystate` reports `secureBoot: false`.

Write the ISO to the USB stick. On macOS:

```bash
diskutil list external
diskutil unmountDisk /dev/diskN
sudo dd if=talos.iso of=/dev/rdiskN bs=4m
diskutil eject /dev/diskN
```

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

# Wait for running Kopiur backup pods (<app>-nfs-…, <app>-r2-…) on the node to finish
kubectl get pods -A --field-selector spec.nodeName=k8s-node-X

kubectl drain k8s-node-X --ignore-daemonsets --delete-emptydir-data --timeout=600s
```

The drain moves any CloudNativePG primary to another instance. Pods that tolerate a cordon, such as Tuppr, can be scheduled straight back onto the node.

Expected after the drain, until the node is back:

- The replicas from Step 2 and the node's `rook-ceph-osd` and `rook-ceph-mon` pods are `Pending`
- Ceph is `HEALTH_WARN` with one OSD and one monitor down, and `CephOSDDownHigh` fires

### Step 4: Leave etcd (Control Plane Nodes Only)

```bash
talosctl -n <node-ip> etcd forfeit-leadership
talosctl -n <node-ip> etcd leave

# Verify from another control-plane node: two members remain
talosctl -n <other-control-plane-node> etcd members
```

From here the old disk cannot simply be powered back on; see the fallback below.

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
# Answers only in maintenance mode
talosctl -n <node-ip> version --insecure

talosctl -n <node-ip> get disks --insecure
talosctl -n <node-ip> get discoveredvolumes --insecure
```

If the new disk's `MODEL` differs from the `diskSelector` in `talos/nodes/**/k8s-node-X.yaml.j2`, update the template with the exact string shown. Talos truncates SATA model names and reports no serial for SATA disks, so take the string from this output. Rendering reads the working copy, so the edit does not have to be committed before the install.

A used disk can carry partitions from a previous install. Wipe it so Talos sees a blank disk, naming the device from the output above. Never wipe the Ceph data disk, which shows as `bluestore`:

```bash
talosctl -n <node-ip> wipe disk <device> --insecure
```

### Step 7: Install

```bash
just talos validate k8s-node-X
just --yes talos apply-insecure-node k8s-node-X
```

Talos installs to the selected disk, reboots from it and joins the existing cluster by itself. Never run `just talos bootstrap` here: it creates a new etcd cluster.

Follow it remotely:

```bash
# Answers once the node runs its installed config
talosctl -n <node-ip> version

kubectl get nodes -w
talosctl -n <other-control-plane-node> etcd members
```

Remove the USB stick once the node is `Ready`. If it has not come back after a few minutes, remove the stick and power-cycle the node.

### Step 8: Rebuild Node-Local Data

The new Node object is schedulable as soon as it is `Ready`.

The replicas from Step 2 are scheduled onto the node and fail with `FailedMount … path "/var/openebs/local/pvc-…" does not exist`. Remove each one:

```bash
kubectl cnpg destroy -n <namespace> <cluster> <instance-number>
kubectl get clusters.postgresql.cnpg.io -A
```

CloudNativePG creates a replacement instance under the lowest free number and clones it from the primary. The scheduler picks its node.

The OSD starts by itself. Lift the rebalancing hold once it is up and every placement group is clean; this does not depend on the monitor:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd stat
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph pg stat
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout
```

On a control-plane node, check that the monitor rejoins quorum:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph get pods -l app=rook-ceph-mon -o wide
```

While the Node object is absent, Rook tries to replace the monitor. It cannot place one, because monitors use host networking and each control-plane node holds one, so the operator logs `failed to failover mon` and a `rook-ceph-mon-<letter>-canary` pod stays `Pending`. Both stop once the monitor is back in quorum.

If the monitor is still out of quorum a few minutes after the node is `Ready`, delete its pod. The new pod copies the store from the other monitors and rejoins:

```bash
kubectl -n rook-ceph delete pod -l app=rook-ceph-mon,ceph_daemon_id=<letter>
```

### Step 9: Verify

```bash
just talos upgrade-check
```

Ceph alerts take a few minutes to resolve after `HEALTH_OK`, so the check can fail on them at first.

Run the LoadBalancer/BGP check in `docs/agent/platform.md`, then commit the `diskSelector` change if there was one.

For a disk model that is new to the cluster, read its SMART data and confirm the wear alerts in `smart-rules.yaml` and the "Storage SMART Disk Data" dashboard match the wear attribute it reports:

```bash
kubectl -n observability get pods -o wide | grep smartctl-exporter
kubectl -n observability exec <smartctl-exporter-pod-on-the-node> -- smartctl -x /dev/<device>
```

The old disk can be wiped once every check passes.

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