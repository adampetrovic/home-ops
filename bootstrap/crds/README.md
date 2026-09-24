# Bootstrap CRDs

`standalone.yaml` lists CRD manifests that must exist before Flux reconciles
resources that reference them and that are not safely owned by one of the
bootstrap Helm charts.

Each standalone entry has a Renovate-managed `version` plus a `urlTemplate`.
Bootstrap derives the consumed URL by replacing `{version}`, so version bumps
change the CRD manifest that is actually applied.

Chart-owned CRDs are rendered from `bootstrap/helmfile/crds.yaml` using the
same OCIRepository chart URLs and tags that Flux uses. Gateway API CRDs are
owned by the Envoy Gateway chart, matching the upstream bootstrap pattern.

## Post-bootstrap ownership

| CRD group | Bootstrap source | Post-bootstrap owner/upgrader |
| --- | --- | --- |
| Gateway API | `bootstrap/helmfile/crds.yaml` via Envoy Gateway | `network/envoy-gateway` HelmRelease |
| Envoy Gateway | `bootstrap/helmfile/crds.yaml` | `network/envoy-gateway` HelmRelease |
| Prometheus Operator | `bootstrap/helmfile/crds.yaml` | `observability/kube-prometheus-stack` HelmRelease |
| Grafana Operator | `bootstrap/helmfile/crds.yaml` | `observability/grafana` HelmRelease |
| snapshot-controller | `bootstrap/helmfile/crds.yaml` | `kube-system/snapshot-controller` HelmRelease |
| External DNS `DNSEndpoint` | `standalone.yaml` | Manual/Renovate update of the standalone External DNS version |
| Multus `NetworkAttachmentDefinition` | `standalone.yaml` | Manual/Renovate update of the standalone Multus version |
| CNPG Barman `ObjectStore` | `standalone.yaml` | Manual/Renovate update of the standalone Barman plugin version |
| CloudNativePG | `bootstrap/helmfile/crds.yaml` | `database/cloudnative-pg` HelmRelease |

Bootstrap applies CRDs with server-side apply and `--force-conflicts`, but it
must never uninstall CRDs during Helm release handoff or cleanup. Flux-managed
operators own ongoing reconciliation and upgrades after bootstrap for
chart-owned CRDs. Standalone CRDs remain explicitly versioned in this directory
and are upgraded by changing their inventory versions.
