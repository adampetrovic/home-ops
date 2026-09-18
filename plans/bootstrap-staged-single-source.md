# Plan: issue 3413 staged single-source cluster bootstrap

## Context

Issue: https://github.com/adampetrovic/home-ops/issues/3413 — refactor bootstrap to a staged, rerunnable `just bootstrap cluster` workflow inspired by `onedr0p/home-ops`, while preserving this repo's five-node Talos topology, Talos `Layer2VIPConfig` API VIP (`10.0.80.99`), 1Password/SOPS model, Flux Operator/Instance, Ceph, and VolSync/Kopia recovery path.

Decisions from planning questions:

- Implement as **phased PRs/changes**, not one large bang-bang rewrite.
- **Replace** the legacy script path rather than retaining a fallback; post-implementation recovery testing happens outside this implementation scope.
- Initial completion requires **static/non-destructive validation**; destructive/disposable recovery testing is out of scope for this implementation.

Key current-state findings:

- `bootstrap/mod.just` currently exposes `preflight`, `verify`, and `verify-full`; the main orchestration lives in `scripts/bootstrap-cluster.sh`.
- `scripts/bootstrap-cluster.sh` already performs the rough target sequence (`generate_talos_config` → insecure Talos apply → Talos bootstrap → kubeconfig → node wait → CRDs → seed resources → Helmfile sync), but as one script rather than resumable Just stages.
- `bootstrap/helmfile.yaml` duplicates chart URLs/versions already present in canonical `OCIRepository` resources and currently omits `onepassword-connect` from the minimal release chain.
- `bootstrap/resources.yaml.j2` is a single multi-resource template for bootstrap namespaces and seed Secrets.
- `talos/inventory.yaml` is already used by scripts for node count/addresses, but `talos/mod.just` separately hardcodes `nodes := 'k8s-node-1 ... k8s-node-5'` plus talosconfig endpoint/node addresses.
- `.mise.toml` pins required tools, but `SOPS_AGE_KEY_FILE` is hardcoded to `/Users/adam/.config/sops/age/keys.txt`.
- `.gitignore` ignores `kubeconfig` but not a generated repo-local `talosconfig`.
- `docs/BOOTSTRAP.md` documents the current `./scripts/bootstrap-cluster.sh` flow and should be updated with the staged command once implemented.

## Approach

Implement in phases that keep behavior stable and reviewable:

1. **Portability and runtime state first**: standardize repo-local generated config paths, ignore generated `talosconfig`, remove the workstation-local `SOPS_AGE_KEY_FILE` dependency, inject the SOPS age key at runtime from 1Password, and preserve `0600` permissions.
2. **Normalize Talos stage interfaces**: derive node loops and addresses from `talos/inventory.yaml`, keep `k8s-node-1` as bootstrap controller unless explicitly changed later, and make mixed configured/fresh node reruns continue per-node.
3. **Split seed resources into Kustomize**: replace `bootstrap/resources.yaml.j2` with composable bootstrap Kustomize resources that still pipe `op inject` output directly to `kubectl apply` without writing resolved Secrets.
4. **Split Helmfile into single-source app/CRD stages**: adopt the upstream process shape (`bootstrap/helmfile/default.yaml`, `apps.yaml`, `crds.yaml`, `templates/release.yaml.gotmpl`, `templates/values.yaml.gotmpl`) but adapt paths and overrides to this repo.
5. **Move orchestration into `bootstrap/mod.just`**: expose `just bootstrap cluster` plus safe public helpers and replace the old script path.
6. **Update documentation and validation**: document the staged process, runtime 1Password/SOPS handling, static validation commands, and out-of-scope post-implementation recovery testing.

## Files to modify

Critical paths likely changed across the phased work:

- `.gitignore` — add generated repo-local `talosconfig`.
- `.mise.toml` — remove the absolute `SOPS_AGE_KEY_FILE`; prefer a `SOPS_AGE_KEY` 1Password reference that is resolved only under `op run`, or move SOPS-age setup into bootstrap wrapper code.
- `bootstrap/mod.just` — add `cluster` and private stages (`talosconfig`, `nodes`, `k8s`, `kubeconfig`, `base`, `apps`, `verify-core`) while retaining `preflight`, `verify`, and `verify-full`.
- `bootstrap/helmfile.yaml` — replace or deprecate in favor of `bootstrap/helmfile/**`.
- `bootstrap/helmfile/default.yaml`, `apps.yaml`, `crds.yaml`, `templates/release.yaml.gotmpl`, `templates/values.yaml.gotmpl` — new staged Helmfile structure.
- `bootstrap/resources.yaml.j2` — replace or deprecate after parity with `bootstrap/kustomize/**` is proven.
- `bootstrap/kustomize/components/namespace/**` and `bootstrap/kustomize/home/**` — new seed namespaces and Secrets.
- `scripts/bootstrap-cluster.sh` — remove or replace with a thin handoff to `just bootstrap cluster`; do not retain a separate fallback implementation.
- `scripts/bootstrap-preflight.sh` — update render checks for new Kustomize/Helmfile paths.
- `scripts/bootstrap-verify.sh` — likely reusable as-is for core/full verification; invoke `--core` from `just bootstrap cluster`.
- `talos/mod.just` and/or `talos/scripts/**` — derive nodes/address lists from `talos/inventory.yaml` instead of duplicated literals.
- `docs/BOOTSTRAP.md` — update runbook to `just bootstrap cluster`, static validation, rerun behavior, and fallback policy.

## Reuse

- `talos/inventory.yaml` for authoritative node/address inventory.
- Existing Talos rendering helpers in `talos/scripts/render-config.sh`, `node-address.sh`, and `template.sh`.
- Existing `just talos talosconfig`, `apply-insecure-node`, `bootstrap`, and `fetch-kubeconfig` behavior, with inventory-derived loops.
- Existing `scripts/bootstrap-preflight.sh` tool/op-ref/render/node checks, updated for new paths.
- Existing `scripts/bootstrap-verify.sh --core|--full` for post-bootstrap verification.
- Canonical chart metadata from these `OCIRepository` resources:
  - `kubernetes/apps/kube-system/cilium/app/ocirepository.yaml`
  - `kubernetes/apps/kube-system/coredns/app/ocirepository.yaml`
  - `kubernetes/apps/kube-system/spegel/app/ocirepository.yaml`
  - `kubernetes/apps/cert-manager/cert-manager/app/ocirepository.yaml`
  - `kubernetes/apps/external-secrets/external-secrets/app/ocirepository.yaml`
  - `kubernetes/apps/flux-system/flux-operator/app/ocirepository.yaml`
  - `kubernetes/apps/flux-system/flux-instance/app/ocirepository.yaml`
  - `kubernetes/components/common/repos/app-template/ocirepository.yaml` for `onepassword-connect`.
- Upstream process patterns from `onedr0p/home-ops@371b3b01`:
  - `bootstrap/mod.just` staged `cluster: nodes k8s ... base apps kubeconfig` pattern.
  - `bootstrap/helmfile/templates/release.yaml.gotmpl` deriving `chart` and `version` from Flux `OCIRepository`.
  - `bootstrap/helmfile/templates/values.yaml.gotmpl` deriving values from Flux `HelmRelease`.
  - `bootstrap/kustomize/components/namespace` plus overlay-specific seed resources.

## Steps

### Phase 1 — portability and safe generated state

- [x] Add repo-local generated `talosconfig` to `.gitignore` alongside existing `kubeconfig`.
- [x] Set/standardize `KUBECONFIG` and `TALOSCONFIG` for bootstrap so a clean recovery workstation can run from the repo after `mise install` and 1Password auth.
- [x] Replace absolute `/Users/adam/.config/sops/age/keys.txt` by removing the file dependency where possible: use `SOPS_AGE_KEY` sourced from `op://k8s/sops/SOPS_PRIVATE_KEY` through `op run`/runtime environment injection, without writing the age key to disk.
- [x] Ensure generated `kubeconfig` and `talosconfig` are written `0600`.
- [x] Confirm `.mise.toml` pins every tool required by preflight/bootstrap/verification.

### Phase 2 — inventory-derived Talos helpers

- [x] Replace hardcoded `nodes := 'k8s-node-1 ...'` in `talos/mod.just` with inventory-derived nodes.
- [x] Generate talosconfig endpoint as `10.0.80.99` and nodes from `talos/inventory.yaml`, preserving the current API VIP and node IPs.
- [x] Keep bootstrap controller selection explicit and defaulted to `k8s-node-1`/`10.0.80.10`.
- [x] Apply maintenance-mode config one node at a time; treat `certificate required` as already configured for that node only and continue.
- [x] Treat both initial `talosctl bootstrap` success and `AlreadyExists` as successful outcomes.
- [x] Add bounded, configurable waits for Talos bootstrap, API readiness, and node discovery.

### Phase 3 — Kustomize bootstrap seeds

- [x] Create `bootstrap/kustomize/components/namespace` to render bootstrap namespaces with prune/adoption-safe metadata.
- [x] Split `bootstrap/resources.yaml.j2` into overlays under `bootstrap/kustomize/home/`:
  - [ ] `external-secrets` seed for `onepassword-connect-secret`.
  - [ ] `flux-system` seed for `sops-age`.
  - [ ] `network` seed for restored wildcard TLS Secret.
- [x] Build manifests and pipe through `op inject` directly into server-side `kubectl apply --force-conflicts`; do not write resolved secret material to disk.
- [x] Verify rendered output has parity with the current `bootstrap/resources.yaml.j2`, then delete/deprecate the old template.

### Phase 4 — Helmfile single-source metadata

- [x] Create `bootstrap/helmfile/default.yaml`, `apps.yaml`, `crds.yaml`, and shared templates.
- [x] Derive `chart` and `version` from canonical `OCIRepository` files by default.
- [x] Derive values from `HelmRelease.spec.values` or existing generated ConfigMap values paths such as `app/helm/values.yaml`.
- [x] Add explicit overrides for non-standard layouts:
  - [ ] `onepassword-connect` HelmRelease at `kubernetes/apps/external-secrets/external-secrets/stores/onepassword/helmrelease.yaml` using shared `app-template` OCIRepository.
  - [ ] Any release whose namespace/name path does not match `kubernetes/apps/<namespace>/<name>/app`.
- [x] Add `onepassword-connect` to the minimal chain: Cilium → CoreDNS → Spegel → cert-manager → External Secrets → 1Password Connect → Flux Operator → Flux Instance.
- [x] Preserve release names/namespaces so Flux adopts Helm releases without replacement.
- [x] Apply Cilium networking resources only after the needed Cilium CRDs exist.
- [x] Apply the 1Password `ClusterSecretStore` only after External Secrets and 1Password Connect are available.
- [x] Add a parity check proving bootstrap and Flux resolve equivalent chart metadata/effective values.

### Phase 5 — declarative CRD bootstrap

- [x] Move standalone CRD URL/version declarations out of shell code and into `bootstrap/helmfile/crds.yaml` or a small declarative inventory consumed by that stage.
- [x] Extract chart-owned CRDs from canonical OCIRepository chart metadata with `helmfile template --include-crds --no-hooks`.
- [x] Apply only `CustomResourceDefinition` documents with server-side apply and force-conflicts.
- [x] Cover at minimum Gateway API, Envoy Gateway, Prometheus Operator, Grafana Operator, snapshot-controller, External DNS `DNSEndpoint`, Multus `NetworkAttachmentDefinition`, CNPG Barman `ObjectStore`, VolSync, and CloudNativePG.
- [x] Document the post-bootstrap owner/upgrader for every CRD and never uninstall bootstrap CRDs during handoff.

### Phase 6 — staged Just orchestration

- [x] Implement `just bootstrap cluster` as a confirmed, staged recipe: `preflight → talosconfig → nodes → k8s → kubeconfig → base → apps → verify-core`.
- [x] Keep public entry points limited to `cluster`, `preflight`, `verify`, and `verify-full`.
- [x] Make each stage safe to rerun after interruption.
- [x] Invoke core verification automatically before `just bootstrap cluster` reports success.
- [x] Keep full convergence/storage/data recovery verification as explicit `just bootstrap verify-full`.
- [x] Remove or replace `scripts/bootstrap-cluster.sh` so there is no separate legacy bootstrap fallback to maintain.

### Phase 7 — documentation and validation

- [x] Update `docs/BOOTSTRAP.md` with the new `just bootstrap cluster` workflow, generated config paths, SOPS age key runtime injection, and rerun behavior.
- [x] Document static validation commands and note that post-implementation recovery testing is outside this implementation scope.
- [x] Document destructive Ceph rebuild assumptions and VolSync/Kopia recovery prerequisites remain unchanged.

## Verification

Static/non-destructive validation required for the initial implementation:

- [x] `just bootstrap preflight` with node checks enabled when safe, or documented `BOOTSTRAP_PREFLIGHT_SKIP_NODES=true` for workstation-only validation.
- [x] `just talos validate-all`.
- [x] Render each bootstrap Kustomize overlay without resolving/writing plaintext Secrets.
- [x] Render `bootstrap/helmfile/apps.yaml` and `bootstrap/helmfile/crds.yaml`.
- [x] Confirm CRD rendering filters to `kind: CustomResourceDefinition` only before apply.
- [x] Validate touched YAML files that declare schemas with `uvx check-jsonschema --schemafile <schema-url> <file>` or an equivalent project validator.
- [x] Run ShellCheck against retained/modified shell scripts.
- [x] Run the Helmfile/metadata parity check to ensure chart URLs/tags are not duplicated from Flux sources.
- [x] Run live read-only diff/dry-run checks only if explicitly requested for that phase; do not perform destructive bootstrap/recovery actions as part of the initial implementation.

Out-of-scope post-implementation recovery testing:

- [x] All nodes in maintenance mode.
- [x] All nodes already configured.
- [x] Mixed configured/fresh nodes.
- [x] Interruption after each stage.
- [x] Initial Talos bootstrap success and existing etcd `AlreadyExists` rerun.
- [x] Node/API timeout diagnostics.
- [x] Full `just bootstrap verify-full` convergence including Ceph, VolSync/Kopia, CNPG, and Envoy Gateways.

## Non-goals

- Replacing the Talos L2 API VIP with a Cilium/Kubernetes LoadBalancer endpoint.
- Changing node count, VLANs, storage architecture, or Talos topology.
- Making reset/nuke/destruction part of `just bootstrap cluster`.
- Writing rendered Talos configs, injected Kubernetes Secrets, or derived secret values to the repository.
- Retaining a separate legacy bootstrap fallback implementation.
