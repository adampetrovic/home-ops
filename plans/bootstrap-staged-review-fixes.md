# Plan: fix staged bootstrap review findings

## Context

The staged bootstrap refactor is close, but review found several blockers and drift points that must be fixed before merge. The requested implementation should happen in a **new jj changeset** and address the Plannotator annotations:

- `petrovic.network` does come from cluster secrets during normal Flux reconciliation, but bootstrap Helmfile runs before Flux post-build substitution has applied those values. Bootstrap must either perform an equivalent non-secret substitution for required values or avoid rendering resources that need it.
- mise environment setup is assumed to be active before bootstrap. Therefore the implementation should not try to work around mise being absent; instead it should document and validate the supported order: enter/activate mise first, then resolve 1Password refs for commands that need `SOPS_AGE_KEY`.

## Approach

Create a new jj changeset for the fixes. Keep the staged bootstrap shape intact, but make the bootstrap path self-consistent and statically verifiable:

1. Fix Talos client endpoints so Talos API operations use physical control-plane addresses, while Kubernetes still uses the API VIP.
2. Fix Kustomize seed injection by preventing `op://` template tokens from being line-wrapped before `op inject`, and add a non-mutating preflight check for the exact `kustomize build | op inject` path.
3. Fix bootstrap Helmfile values to use effective canonical Flux values, not stale values files selected by existence. For values needing Flux substitutions, add a small bootstrap substitution mechanism or bootstrap-specific override.
4. Fix 1Password Connect bootstrap rendering by resolving `petrovic.network` from cluster secrets or disabling the route during bootstrap. Prefer resolving the non-secret domain value so the release remains closest to Flux state.
5. Fix CRD source ownership so Gateway API has a single authoritative source and chart-rendered CRDs cannot downgrade/overwrite it.
6. Fix standalone CRD Renovate handling so version bumps update the URL actually consumed.
7. Update docs to match the fixed behavior and remove stale legacy references.

## Files to modify

Likely files:

- `talos/mod.just`
- `bootstrap/mod.just`
- `scripts/bootstrap-preflight.sh`
- `bootstrap/kustomize/home/network/secret.yaml`
- `bootstrap/helmfile/templates/values.yaml.gotmpl`
- `bootstrap/helmfile/apps.yaml`
- `bootstrap/helmfile/crds.yaml`
- `bootstrap/crds/standalone.yaml`
- `bootstrap/crds/README.md`
- `scripts/bootstrap-helmfile-parity.sh`
- `docs/BOOTSTRAP.md`
- `README.md`
- `docs/agent/secrets-standards-renovate.md`

Possibly add a small helper script if templating/substitution cannot stay readable in Helmfile templates:

- `scripts/bootstrap-render-values.sh` or similar

## Reuse

- Reuse `talos/inventory.yaml` as the single source for physical Talos node addresses.
- Reuse `talos/scripts/node-address.sh` for node-name to IP lookup where a recipe operates on one node.
- Reuse existing bootstrap stages in `bootstrap/mod.just`; do not reintroduce the deleted monolithic script.
- Reuse `op inject` and the existing 1Password references; do not write resolved secrets to disk.
- Reuse the existing parity script, but correct it so expected values come from effective HelmRelease configuration instead of duplicating the template's existence check.
- Reuse Flux substitution sources for non-secret domains where possible. `petrovic.network` is sourced from cluster secrets in normal Flux flow, so bootstrap needs an equivalent one-time substitution for rendered Helm values that are installed before Flux takes over.

## Steps

- [x] Start a new jj changeset, for example `jj start "fix bootstrap staged review findings"` or equivalent project-preferred jj flow.
- [x] Update `talos/mod.just` so generated talosconfig endpoints are physical control-plane IPs from `talos/inventory.yaml`, not the Kubernetes API VIP. Keep the generated cluster endpoint in Talos machine config as `https://10.0.80.99:6443`.
- [x] Ensure `bootstrap/mod.just` bootstrap/kubeconfig calls target the bootstrap controller physical IP and do not depend on the VIP before etcd exists.
- [x] Adjust `bootstrap/kustomize/home/network/secret.yaml` so Kustomize output cannot split `{{ op://... }}` references before `op inject`. Avoid writing resolved TLS material to disk.
- [x] Add a preflight check that runs the exact Kustomize seed pipeline through `op inject` and parses the result without printing or persisting secrets. It should fail before any apply if injection is broken.
- [x] Update Helmfile values rendering so it follows the HelmRelease's actual source of values. If a HelmRelease has inline `spec.values`, use those even when an old `app/helm/values.yaml` exists.
- [x] Fix CoreDNS bootstrap values to include the canonical inline private-domain forwarding configuration from its HelmRelease.
- [x] Handle `petrovic.network` for bootstrap values. Recommended approach: perform bootstrap-time substitution for known non-secret cluster vars needed by the initial release chain, sourced through 1Password/op injection or an already-decrypted/generated safe values map. Confirm this does not print or persist secrets.
- [x] Specifically verify the rendered 1Password Connect HTTPRoute hostname is concrete, for example `onepassword-connect.<domain>`, not `onepassword-connect.petrovic.network`.
- [x] Update `scripts/bootstrap-helmfile-parity.sh` so it independently computes expected effective values and catches CoreDNS/`petrovic.network` drift instead of mirroring the template selection logic.
- [x] Resolve Gateway API CRD ownership. Prefer applying Gateway API only from `bootstrap/crds/standalone.yaml` and filtering overlapping Gateway API CRDs out of chart-rendered CRDs before apply.
- [x] Add a duplicate-CRD-name check across standalone and chart-rendered CRDs, or at least across the final applied stream, so future overlaps fail preflight.
- [x] Fix standalone CRD Renovate handling by deriving URLs from `version` or by moving the Renovate-managed token to the consumed URL. Keep URL/version literals from drifting.
- [x] Update `bootstrap/crds/README.md` to describe the real post-bootstrap owner/upgrader for each CRD group, including manual standalone updates.
- [x] Update docs: `docs/BOOTSTRAP.md`, `README.md`, and `docs/agent/secrets-standards-renovate.md`. Remove stale `bootstrap/helmfile.yaml` / `resources.yaml.j2` references and clarify the supported mise/op ordering.
- [x] Keep `scripts/bootstrap-cluster.sh` as only a thin wrapper; do not reintroduce a fallback path.

## Verification

Run only static/render/read-only checks unless the user separately approves live mutations.

- [x] `jj status` confirms the work is isolated in the new changeset and includes only intended files.
- [x] `BOOTSTRAP_PREFLIGHT_SKIP_NODES=true op run -- just bootstrap preflight` using the supported environment setup.
- [x] `op run -- just talos validate-all`.
- [x] Dry-run/show Just commands to confirm Talos bootstrap uses physical endpoints, not the VIP.
- [x] Kustomize seed validation: `kustomize build bootstrap/kustomize/home | op inject | <parse-without-printing-secrets>`.
- [x] Helmfile app render confirms no `petrovic.network` remains in bootstrap-installed manifests.
- [x] Helmfile app render confirms CoreDNS includes the private-domain forwarding server from the canonical HelmRelease.
- [x] Helmfile CRD render confirms Gateway API CRDs are not force-applied from Envoy Gateway after standalone Gateway API CRDs.
- [x] CRD filter still emits only `CustomResourceDefinition` documents for the chart-owned CRD stage.
- [x] `scripts/bootstrap-helmfile-parity.sh` fails on intentionally reproduced old CoreDNS/value-selection drift, then passes after the fix.
- [x] Schema validation for changed schema-backed YAML/JSON.
- [x] Shell syntax and ShellCheck for changed shell scripts, using the available project tooling or direct binary if mise lacks a shellcheck version.
- [x] Read-only live checks may be used only for inspection; no `apply`, `sync`, `reconcile`, `delete`, `patch`, `edit`, `scale`, destructive Talos commands, or Helm operations that change state.
