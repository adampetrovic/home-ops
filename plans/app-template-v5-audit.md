# app-template v5 Usage Audit Plan

## Context

This repository already points the shared `app-template` OCIRepository at bjw-s-labs app-template `5.1.0` in `kubernetes/components/common/repos/app-template/ocirepository.yaml`. The v4→v5 upgrade notes call out these relevant behaviour changes:

- `rawResources` must move Kubernetes manifests under `manifest`, with metadata nested under `manifest.metadata` and no `spec` wrapper.
- A per-release default ServiceAccount is now created unless disabled or explicitly configured.
- ServiceAccount token automount now defaults to `false`; workloads needing Kubernetes API access must opt in.
- ServiceMonitor/PodMonitor `jobLabel` now defaults to `app.kubernetes.io/name` instead of monitor `metadata.name`.
- NetworkPolicy `controller` and `podSelector` are mutually exclusive.

Audit findings so far:

- 70 HelmReleases in `kubernetes/apps` use `chartRef.name: app-template`.
- No app-template HelmRelease uses `rawResources`, so no rawResource v5 migration is needed.
- No app-template HelmRelease defines app-template `networkPolicy` or `podSelector`, so no controller/podSelector conflict exists.
- 13 app-template HelmReleases define `serviceMonitor`; no app-template HelmRelease defines `podMonitor`; none set `jobLabel` explicitly.
- 5 workloads explicitly set `automountServiceAccountToken: true`; each appears Kubernetes-API/RBAC related and should stay explicit:
  - `kubernetes/apps/observability/vector/app/agent/helmrelease.yaml`
  - `kubernetes/apps/observability/gatus/app/helmrelease.yaml`
  - `kubernetes/apps/database/dragonfly/app/helmrelease.yaml`
  - `kubernetes/apps/database/cloudnative-pg/barman-cloud/helmrelease.yaml`
  - `kubernetes/apps/network/multus/app/helmrelease.yaml`
- 2 workloads explicitly set `automountServiceAccountToken: false`; these are now redundant under v5 and should be removed per user preference:
  - `kubernetes/apps/network/unifi-os-backup/app/helmrelease.yaml`
  - `kubernetes/apps/observability/smartctl-exporter/app/helmrelease.yaml`
- 65 app-template HelmReleases still use the old `raw.githubusercontent.com/bjw-s/helm-charts` schema URL; 3 already use `bjw-s-labs`; `kubernetes/apps/network/multus/app/helmrelease.yaml` has no app-template schema comment.
- `kubernetes/apps/network/smtp-relay/app/helmrelease.yaml` has a duplicate YAML anchor name `&app`, which tripped parser-based audit tooling and should be fixed while normalizing schemas.

## Approach

Apply a full cleanup pass focused on v5 compatibility, security-default clarity, and schema consistency:

1. Make no chart-version change; app-template is already on v5.1.0.
2. Remove only redundant `automountServiceAccountToken: false`; keep all explicit `true` cases because they correspond to Kubernetes API access, RBAC, or controllers/operators.
3. Do not add `global.createDefaultServiceAccount: false` broadly. The v5 default per-app ServiceAccount is a beneficial security default for apps without explicit ServiceAccounts.
4. Do not change ServiceMonitor `jobLabel` unless validation or a concrete alert/dashboard dependency requires it. The new default aligns with app labels, and existing Prometheus rules only rely on custom relabeled jobs such as `talos-smart`.
5. Normalize app-template schema comments from `bjw-s` to `bjw-s-labs` across all app-template HelmReleases and add the missing app-template schema comment to `multus`.
6. Fix the duplicate YAML anchor in `smtp-relay` by reusing `*app` in the topology spread label instead of redefining `&app`.

## Files to modify

Specific functional cleanup:

- `kubernetes/apps/network/unifi-os-backup/app/helmrelease.yaml` — remove redundant `automountServiceAccountToken: false`; normalize schema URL.
- `kubernetes/apps/observability/smartctl-exporter/app/helmrelease.yaml` — remove redundant `automountServiceAccountToken: false`; normalize schema URL.
- `kubernetes/apps/network/smtp-relay/app/helmrelease.yaml` — fix duplicate `&app` anchor; normalize schema URL.
- `kubernetes/apps/network/multus/app/helmrelease.yaml` — add missing app-template schema comment.

Schema-only cleanup:

- All remaining app-template HelmReleases under `kubernetes/apps/**/helmrelease.yaml` with the old `raw.githubusercontent.com/bjw-s/helm-charts/.../app-template/...` schema URL should be updated to `raw.githubusercontent.com/bjw-s-labs/helm-charts/.../app-template/...`.

No app-template v5 changes needed for:

- `rawResources` (no usage found).
- app-template `networkPolicy` (no usage found).
- `podMonitor` (no app-template usage found).
- `serviceMonitor.jobLabel` (no repo evidence requiring old monitor-name-derived job labels).

## Reuse

- Repository app deployment conventions: `docs/agent/app-deployments.md`
- Repository YAML/schema conventions: `docs/agent/secrets-standards-renovate.md`
- Existing explicit-token patterns and comments in:
  - `kubernetes/apps/observability/vector/app/agent/helmrelease.yaml`
  - `kubernetes/apps/network/multus/app/helmrelease.yaml`
  - `kubernetes/apps/observability/gatus/app/helmrelease.yaml`
- Existing external ServiceAccount/RBAC pattern for barman-cloud:
  - `kubernetes/apps/database/cloudnative-pg/barman-cloud/rbac.yaml`
  - `kubernetes/apps/database/cloudnative-pg/barman-cloud/helmrelease.yaml`

## Steps

- [x] Normalize all app-template HelmRelease schema comments to the bjw-s-labs schema URL.
- [x] Add the missing app-template schema comment to `kubernetes/apps/network/multus/app/helmrelease.yaml`.
- [x] Remove redundant `automountServiceAccountToken: false` from `unifi-os-backup` and `smartctl-exporter`, preserving surrounding `defaultPodOptions`.
- [x] Fix the duplicate `&app` anchor in `smtp-relay` by changing the topology spread `app.kubernetes.io/name` value to `*app`.
- [x] Leave explicit `automountServiceAccountToken: true` in the five API/RBAC-dependent workloads.
- [x] Leave ServiceMonitor `jobLabel` unset unless validation exposes a schema issue; document that the v5 default is acceptable.
- [x] Re-run audit searches to confirm no `rawResources`, app-template `networkPolicy`, stale schema URLs, redundant false token automounts, or duplicate-anchor parser failures remain.

## Verification

- Run a parser-based YAML audit over all app-template HelmReleases to ensure they load cleanly after the `smtp-relay` anchor fix.
- Run schema validation for changed schema-backed HelmReleases, ideally with a loop equivalent to:
  - `uvx check-jsonschema --schemafile https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json <helmrelease.yaml>`
- Run targeted searches:
  - `rg 'rawResources:' kubernetes/apps -g 'helmrelease.yaml'`
  - `rg 'automountServiceAccountToken: false' kubernetes/apps -g 'helmrelease.yaml'`
  - `rg 'raw.githubusercontent.com/bjw-s/helm-charts' kubernetes/apps -g 'helmrelease.yaml'`
  - `rg 'podSelector:' kubernetes/apps -g 'helmrelease.yaml'`
- Review `jj diff` to confirm only intended YAML cleanup occurred.
