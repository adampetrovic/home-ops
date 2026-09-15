# Talos

Declarative Talos Linux machine configuration for the home Kubernetes cluster.
This directory is migrating away from talhelper toward the same native rendering
pattern used by onedr0p/home-ops: composable multi-document templates rendered
on demand and applied with `talosctl`.

Nothing here is applied automatically. Live node changes require an explicit
`task talos:apply-node ...` or Tuppr OS upgrade.

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
| `inventory.yaml` | Node name to Talos management address mapping for tasks |
| `patches/` | Legacy talhelper-era patches kept during migration |

Role is derived from directory placement under `nodes/`; node files should not
claim a different role in their content.

## Rendering

`task talos:render-config node=k8s-node-1` builds the final machine config in
three layers:

```bash
talosctl machineconfig patch <(template cluster.yaml.j2) \
  -p @<(template controlplane.yaml.j2) \
  -p @<(template nodes/controlplane/k8s-node-1.yaml.j2)
```

Each layer is rendered with `minijinja-cli` and then passed through `op inject`
so `op://k8s/talsecret/...` references are resolved only at render/apply time.
Rendered configs contain secrets and must not be committed. For individual
static template checks that must not touch 1Password, `template.sh` supports
`TALOS_SKIP_OP_INJECT=true`; full machine-config rendering still needs real or
synthetic secrets because `talosctl machineconfig patch` decodes certificate
fields.

## Common tasks

```bash
task talos:render-config node=k8s-node-1      # render to stdout
task talos:validate node=k8s-node-1           # talosctl validate --strict
task talos:validate-all                       # validate every rendered node
task talos:dry-run node=k8s-node-1            # live apply-config --dry-run
task talos:apply-node node=k8s-node-1         # explicit live mutation; defaults mode=try
task talos:machine-image node=k8s-node-1      # image from UnattendedInstallConfig
task talos:schematic-id                       # shared Image Factory schematic ID
```

## Schematics and Tuppr

The rendered `UnattendedInstallConfig` owns the installer image:

```yaml
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/<schematic>:v1.14.0
```

Tuppr resolves future OS upgrade images from node runtime state and the current
install image, so keeping this document accurate is important. GitOps-managed
Tuppr remains the preferred OS rollout path; manual `task talos:upgrade` is a
break-glass fallback and derives the installer image from the rendered config.

## Migration notes

- `talconfig.yaml`, `talenv.yaml`, `talsecret.yaml`, `talos/clusterconfig/`, and
  `talos/patches/` are retained temporarily for comparison and rollback.
- Kubelet remains in the legacy `machine.kubelet` block for now because the
  v1.14 `KubeletConfig` document does not represent the existing
  `/var/openebs/local` `extraMounts` requirement.
- Workload isolation / `SecurityProfileConfig` is intentionally deferred due to
  storage and NFS risk.
- Do not edit `talos/clusterconfig/`; it is generated/ignored legacy output.
