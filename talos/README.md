# Talos

Declarative Talos Linux machine configuration for the home Kubernetes cluster,
built from composable native Talos multi-document templates. Nothing in this
directory is applied automatically; configs are rendered on demand and pushed to
nodes with `talosctl`.

## Layout

| Path | Purpose |
| --- | --- |
| `cluster.yaml.j2` | Cluster-wide baseline and global multi-document Talos configs |
| `controlplane.yaml.j2` | Control-plane-only patch, including `machine.type` and control-plane secrets |
| `workers.yaml.j2` | Worker-only patch, including `machine.type` |
| `nodes/controlplane/<node>.yaml.j2` | Per-control-plane node networking, hostname, install config |
| `nodes/workers/<node>.yaml.j2` | Per-worker node networking, hostname, install config |
| `nodes/*/<node>.schematic.yaml.j2` | Optional complete per-node schematic override |
| `schematic.yaml.j2` | Shared Talos Image Factory schematic |
| `secrets.yaml.j2` | 1Password-backed Talos secrets bundle for generating talosconfig |
| `inventory.yaml` | Node name to Talos management address mapping for recipes |

Role is derived from directory placement under `nodes/`; node files should not
claim a different role in their content.

## Rendering

`just talos render-config k8s-node-1` builds the final machine config in
three layers:

```bash
talosctl machineconfig patch <(template cluster.yaml.j2) \
  -p @<(template controlplane.yaml.j2) \
  -p @<(template nodes/controlplane/k8s-node-1.yaml.j2)
```

Each layer is rendered with `minijinja-cli --env` and then passed through
`op inject` so `op://k8s/talsecret/...` references are resolved only at
render/apply time. Rendered configs contain secrets and must not be committed.
For individual static template checks that must not touch 1Password,
`template.sh` supports `TALOS_SKIP_OP_INJECT=true`; the control-plane template
also expects `TALOS_K8S_SERVICE_ACCOUNT_KEY` to contain the decoded Kubernetes
service-account private key. Full machine-config rendering still needs real or
synthetic secrets because `talosctl machineconfig patch` decodes certificate
fields.

## Common recipes

```bash
just talos render-config k8s-node-1      # render to stdout
just talos validate k8s-node-1           # talosctl validate --strict
just talos validate-all                  # validate every rendered node
just talos dry-run k8s-node-1            # live apply-config --dry-run
just talos apply-node k8s-node-1         # explicit live mutation; defaults mode=try
just talos talosconfig                   # regenerate ~/.talos/config from 1Password
```

## Schematics and Tuppr

The rendered `UnattendedInstallConfig` owns the installer image:

```yaml
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/<schematic>:v1.14.1
```

Tuppr resolves future OS upgrade images from node runtime state and the current
install image, so keeping this document accurate is important. GitOps-managed
Tuppr remains the preferred OS rollout path; manual `just talos upgrade` is a
break-glass fallback and derives the installer image from the rendered config.

## Deferred modernization

- Kubelet remains in the legacy `machine.kubelet` block for now because the
  v1.14 `KubeletConfig` document does not represent the existing
  `/var/openebs/local` `extraMounts` requirement.
- Etcd remains in the legacy `cluster.etcd` block because Talos v1.14 does not
  register a standalone typed `EtcdConfig` document.
- Kubernetes CA material remains in legacy `cluster.*` fields until the
  renderer can safely emit typed PEM block scalars from 1Password-backed secret
  values without committing rendered secrets. The service-account key is already
  migrated to `KubeServiceAccountConfig`; `render-config.sh` decodes the
  1Password-backed base64 key into the environment at render time.
## Workload isolation rollout

`SecurityProfileConfig.workloadIsolation: true` is enabled in every node template.
It was rolled out in stages: worker canaries `k8s-node-4` and `k8s-node-5`,
control-plane canary `k8s-node-2`, then `k8s-node-3` and `k8s-node-1` after the
previous nodes recovered. The config must be applied and the node rebooted to
activate `sandboxd`; a successful `apply-config --mode=try` does not persist.

No pod security-context or runtime changes were needed for the observed workload
classes. Validation covered Talos/Kubernetes node health, `sandboxd`, etcd/API,
Flux, Ceph monitors and OSDs, OpenEBS hostpath PVs, NFS-mounted media and Kopiur
movers, GPU/device plugins, privileged Cilium/Multus, and Envoy Local-policy
endpoints. See [issue #3406](https://github.com/adampetrovic/home-ops/issues/3406)
for the staged validation and follow-up observations. Continue monitoring
storage, NFS, and device workloads after future Talos or runtime upgrades.
