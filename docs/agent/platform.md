# Platform Reference

Read this before changing Talos, storage, networking, load balancers, observability, or upgrade-related behavior.

## Repository Structure

```text
kubernetes/
├── apps/                    # Application deployments organized by namespace
├── components/              # Reusable Kustomize components
│   ├── common/              # Namespace, SOPS, cluster vars, Helm repos
│   └── volsync/             # VolSync backup/restore component
└── flux/cluster/            # Top-level Flux Kustomization

talos/
├── talconfig.yaml           # Node definitions managed by talhelper
├── talenv.yaml              # Talos environment vars
├── talsecret.yaml           # Talos secrets
├── clusterconfig/           # Generated node configs; do not edit directly
└── patches/                 # Editable Talos machine patches

bootstrap/                   # Initial cluster bootstrap
scripts/                     # Helper scripts
.taskfiles/                  # Taskfile automation
```

## Storage

- Rook-Ceph `ceph-block` is the default StorageClass for most RWO volumes.
- Rook-CephFS is used for RWX volumes.
- OpenEBS `openebs-hostpath` provides local high-performance volumes, including VolSync R2 cache.
- NFS on the Synology NAS is used for media storage and the Kopia repository at `/volume2/kopia`.
- VolSync uses a dual-storage backup strategy:
  - Kopia primary backups to NFS.
  - Restic secondary backups to Cloudflare R2.
  - MutatingAdmissionPolicies inject NFS mounts and backup jitter into mover jobs.
  - KopiaMaintenance runs repository maintenance every 12 hours.
  - Kopia web UI is available at `kopia.<domain>`.

## Network

- Pod CIDR: `10.69.0.0/16`
- Service CIDR: `10.96.0.0/16`
- LoadBalancer VIP: `10.0.80.99`
- Routed Kubernetes LoadBalancer prefix: `10.0.88.0/24` (BGP-advertised; Envoy VIPs live here)
- Node IPs: `10.0.80.10-14` on Management VLAN 80
- Trusted VLAN 10: `10.0.10.0/24` for secondary IoT access
- CNI is Cilium, eBPF-based, without kube-proxy

## Post-Upgrade LoadBalancer/L2 Sanity Check

After any Talos or Kubernetes rollout, especially Tuppr upgrades, explicitly check north/south LoadBalancer services using `externalTrafficPolicy: Local`.

For BGP-advertised services such as `network/envoy-internal` (`10.0.88.200`) and `network/envoy-external` (`10.0.88.201`), ensure UCG BGP next-hops only include nodes with ready local endpoints. A stale next-hop can cause `connection refused` even when pods, Services, HTTPRoutes, and Envoy look healthy.

For Cilium L2 announcements, ensure the `cilium-l2announce-<namespace>-<service>` lease holder has at least one ready local endpoint for Services with `externalTrafficPolicy: Local`.

Read-only checks:

```bash
kubectl get svc -A --field-selector spec.type=LoadBalancer
kubectl get leases -n kube-system | grep cilium-l2announce
kubectl get endpointslice -n <namespace> -l kubernetes.io/service-name=<service> -o wide
kubectl get pods -n <namespace> -o wide
```

If a lease holder has no ready local endpoint, a targeted lease delete can force re-election, but confirm before running `kubectl delete lease ...` because it mutates cluster state.

## Talos Node Logging

Talos service and kernel logs flow to Loki through Vector:

```text
Talos machine.logging / KmsgLogConfig
  -> tcp://127.0.0.1:6050/ on each node
  -> hostNetwork vector-agent socket source
  -> vector-aggregator-talos.observability.svc.cluster.local:6030
  -> Loki {source="talos"}
```

Key files:

- `talos/patches/global/machine-logging.yaml`
- `kubernetes/apps/observability/vector/app/agent/resources/vector.yaml`
- `kubernetes/apps/observability/vector/app/aggregator/resources/vector.yaml`
- `kubernetes/apps/observability/loki/app/helmrelease.yaml`
- `kubernetes/apps/observability/vector/app/aggregator/talos-logs-dashboard.json`
- `kubernetes/apps/observability/vector/app/aggregator/lokirule.yaml`

Operational notes:

- `vector-agent` uses `hostNetwork: true` and listens only on host loopback `127.0.0.1:6050` for Talos TCP JSON-lines logs.
- Keep Talos log labels low-cardinality: `source`, `cluster`, `node`, `stream`, `service`, `level`.
- Do not add labels for message text, sequence numbers, kernel clock, or raw source address.
- Debug-level Talos logs are filtered before reaching Loki unless explicitly troubleshooting.
- The per-node Talos Vector throttle is intentionally conservative at 500 events/sec/node.
- Logs emitted before host-network `vector-agent` is listening can be dropped; this is accepted.
- Do not edit `talos/clusterconfig/` directly. Change Talos patches, run `task talos:generate`, then inspect/apply generated node configs.

Useful LogQL:

```logql
{source="talos", node="k8s-node-1"}
{source="talos", stream="service", service="kubelet"}
{source="talos", stream="kernel", level=~"warn|err|error|crit|alert|emerg"}
sum by (node, stream) (count_over_time({source="talos"}[5m]))
```
