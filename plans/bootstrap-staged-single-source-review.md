# Review: staged single-source bootstrap (issue 3413)

## Scope and verdict

Reviewed the implementation against `plans/bootstrap-staged-single-source.md`, including Just orchestration, Talos configuration, runtime secrets, Kustomize seeds, Helmfile values and paths, CRD handling, verification, and documentation.

**Verdict: not ready to merge.** Three bootstrap blockers and four correctness gaps need attention. Two blockers are introduced by the refactor; the Talos VIP issue is inherited and also embedded in the plan.

The review performed no repository edits or cluster mutations. This report was written afterward. Validation used dry-runs, renders, and in-memory secret checks. Recovery/disaster drills and interruption testing remain out of scope. Line references describe the implementation at review time.

## Blocking findings

### F1 — P1: Kustomize output breaks 1Password injection

**Locations:** `bootstrap/mod.just:106–108`; `bootstrap/kustomize/home/network/secret.yaml:8–15`.

Kustomize wraps the TLS annotation's `{{ op://… }}` references across lines. The problematic source is valid YAML before Kustomize:

```yaml
# bootstrap/kustomize/home/network/secret.yaml
metadata:
  annotations:
    cert-manager.io/alt-names: "*.{{ op://k8s/cluster-secrets/SECRET_PUBLIC_DOMAIN }},\
      *.{{ op://k8s/cluster-secrets/SECRET_PUBLIC_ANON_DOMAIN }},\
      *.petrovic.network"
```

But the bootstrap stage feeds Kustomize's reserialized output directly to `op inject`:

```just
# bootstrap/mod.just
kustomize build "{{ repo_root }}/bootstrap/kustomize/home" \
    | op inject \
    | kubectl apply --server-side --force-conflicts --filename -
```

After Kustomize, a secret reference can be split across physical lines, so `op inject` sees an incomplete `{{ ... }}` token:

```yaml
cert-manager.io/alt-names: '*.{{ op://k8s/cluster-secrets/SECRET_PUBLIC_DOMAIN
  }},*.{{ op://k8s/cluster-secrets/SECRET_PUBLIC_ANON_DOMAIN }}'
```

The actual `kustomize build | op inject` pipeline fails with:

```text
parsing error at 52:83: no corresponding }} found for {{
```

Bootstrap cannot finish the base stage or reach app installation. Rendering the Kustomize resources alone does not detect this failure.

**Evidence:** Executed the injection pipeline without piping to kubectl. After removing wrapping in-memory, injected YAML parsed, all Secret fields were strings, and no unresolved references remained. The TLS fields were valid base64-encoded PEM; using `data` for those particular stored values is not itself a defect.

**Recommended correction:** Preserve reference tokens through serialization, or restructure the annotation so Kustomize cannot split them. Add a non-mutating build → inject → parse validation that discards resolved output and never writes it to disk.

### F2 — P1: Talos bootstrap depends on a VIP that does not exist yet

**Locations:** `talos/mod.just:39`; `bootstrap/mod.just:47–63`.

The generated talosconfig uses `10.0.80.99` as its endpoint:

```just
# talos/mod.just
talosctl gen config home-kubernetes https://{{ api_endpoint }}:6443 \
    --with-secrets "${tmp_secrets}" \
    --output "${output}" \
    --output-types talosconfig \
    --force >/dev/null

talosctl --talosconfig "${output}" config endpoint {{ api_endpoint }}
```

`just talos bootstrap` overrides only `--nodes`, so it still connects through that VIP endpoint:

```just
# talos/mod.just
bootstrap node=bootstrap_controller:
    node_address="$({{ scripts_dir }}/node-address.sh "{{ node }}")"
    talosctl --nodes "${node_address}" bootstrap
```

Talos VIP ownership requires etcd, which this command is supposed to bootstrap.

A healthy existing cluster can conceal this circular dependency. It blocks the clean recovery path.

**Classification:** Inherited defect and incorrect plan assumption, not a new regression. The plan explicitly preserves this Talos client endpoint and needs correction too.

**Evidence:** The Just dry-run shows no physical `--endpoints` override. Talos documentation states that the VIP does not come alive until after bootstrap and must not be the talosconfig endpoint because it depends on etcd and kube-apiserver health.

Reference: https://docs.siderolabs.com/talos/v1.13/networking/advanced/vip

**Recommended correction:** Use physical control-plane addresses for Talos API endpoints, including bootstrap and reachability checks. Retain `10.0.80.99` as the Kubernetes API VIP; this does not require changing the cluster's VIP architecture.

### F3 — P1: 1Password Connect renders an invalid HTTPRoute hostname

**Locations:** `bootstrap/helmfile/templates/values.yaml.gotmpl:3–5,15–16`; canonical value at `kubernetes/apps/external-secrets/external-secrets/stores/onepassword/helmrelease.yaml:128–134`.

Copying HelmRelease values does not reproduce Flux's variable substitution. The template copies the canonical inline values as-is:

```gotmpl
# bootstrap/helmfile/templates/values.yaml.gotmpl
{{- if eq .Release.Name "onepassword-connect" -}}
  {{- $valuesPath = "" -}}
  {{- $helmReleasePath = "../../../kubernetes/apps/external-secrets/external-secrets/stores/onepassword/helmrelease.yaml" -}}
{{- end -}}
...
{{ (fromYaml (readFile $helmReleasePath)).spec.values | toYaml }}
```

The source HelmRelease expects Flux post-build substitution later:

```yaml
# kubernetes/apps/external-secrets/external-secrets/stores/onepassword/helmrelease.yaml
route:
  app:
    hostnames:
      - "{{ .Release.Name }}.petrovic.network"
```

Actual app rendering therefore produces an unsubstituted HTTPRoute:

```yaml
hostnames:
  - "onepassword-connect.petrovic.network"
```

This is not a valid HTTPRoute hostname. Kubernetes rejects it, preventing successful Connect installation and blocking the dependent Flux Operator and Flux Instance releases.

**Evidence:** Rendered the app Helmfile and inspected the generated HTTPRoute. No substitution step exists in the values template. The existing parity check accepts the same unresolved source value and therefore does not catch the problem.

**Recommended correction:** Resolve required substitutions securely, or explicitly disable this nonessential route during bootstrap. If using a bootstrap-only override, document it and make the parity test recognize the intentional difference.

## Other actionable findings

### F4 — P2: mise can undo runtime age-key injection

**Location:** `.mise.toml:1–3`.

With mise shims, the documented `op run -- just …` sequence can replace the resolved age key with the configured `op://k8s/sops/SOPS_PRIVATE_KEY` reference:

```toml
# .mise.toml
[env]
SOPS_AGE_KEY = "op://k8s/sops/SOPS_PRIVATE_KEY"
```

The intended mental model is:

```text
op run resolves SOPS_AGE_KEY -> child tools see AGE-SECRET-KEY-...
```

What I reproduced through the shimmed entry point is instead:

```text
op run resolves SOPS_AGE_KEY -> mise env setup reassigns SOPS_AGE_KEY=op://k8s/sops/SOPS_PRIVATE_KEY
```

**Evidence:** Reproduced all of the following without printing or persisting the key:

- `op run` resolves the age key.
- Calling the actual SOPS binary directly decrypts successfully.
- Calling the mise SOPS shim under the same resolved environment fails.
- `op run → just shim → child` receives the unresolved reference rather than the resolved key.

**Impact boundary:** Current Helmfile app/CRD paths do not invoke SOPS or consume encrypted values. This is a workstation runtime-secrets correctness issue, not another immediate app-stage blocker. Flux's in-cluster decryption uses its seeded Kubernetes Secret.

**Recommended correction:** Ensure mise environment setup occurs before secret resolution, or preserve an already-resolved environment value. Validate the documented entry point through the actual supported shim/activation setup, rather than only testing a directly invoked binary.

### F5 — P2: CoreDNS is not single-source, and the parity test falsely passes

**Locations:** `bootstrap/helmfile/templates/values.yaml.gotmpl:13–16`; `scripts/bootstrap-helmfile-parity.sh:50–54`.

Both implementations prefer `app/helm/values.yaml` merely because it exists:

```gotmpl
# bootstrap/helmfile/templates/values.yaml.gotmpl
{{- if and (ne $valuesPath "") (isFile $valuesPath) -}}
{{ readFile $valuesPath }}
{{- else -}}
{{ (fromYaml (readFile $helmReleasePath)).spec.values | toYaml }}
{{- end -}}
```

The parity script repeats the same assumption:

```bash
# scripts/bootstrap-helmfile-parity.sh
if [[ -n "${values_path}" && -f "${values_path}" ]]; then
    yq -o=json '.' "${values_path}" | jq --sort-keys . >"${expected_file}"
else
    yq -o=json '.spec.values' "${helmrelease_path}" | jq --sort-keys . >"${expected_file}"
fi
```

CoreDNS's actual HelmRelease uses inline `spec.values`; its Kustomization does not reference the old values file:

```yaml
# kubernetes/apps/kube-system/coredns/app/kustomization.yaml
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
```

Canonical CoreDNS values include private-domain forwarding to `10.0.0.1`:

```yaml
# kubernetes/apps/kube-system/coredns/app/helmrelease.yaml
servers:
  - zones:
      - zone: petrovic.network
        scheme: dns://
    plugins:
      - name: forward
        parameters: . 10.0.0.1
```

The old values file, and bootstrap's rendered Corefile, omit that private-domain server.

**Classification:** Existing bootstrap drift retained by the refactor. The newly added parity check incorrectly claims to prove equivalence because it repeats the implementation's selection assumption.

**Evidence:** Inspected the canonical HelmRelease and Kustomization, compared the old values file, and observed that app rendering omits the private-domain server while the parity script reports success.

**Recommended correction:** Derive effective values from the HelmRelease's actual references and overrides. Test against independently calculated effective Flux values, including required substitutions and explicitly documented bootstrap exceptions.

### F6 — P2: Gateway API CRDs have competing sources and are downgraded during bootstrap

**Locations:** `bootstrap/crds/standalone.yaml:11–15`; `bootstrap/helmfile/crds.yaml:17–18`; `bootstrap/mod.just:97–104`.

The standalone inventory selects Gateway API **v1.6.2**:

```yaml
# bootstrap/crds/standalone.yaml
- name: gateway-api-experimental
  owner: gateway-api
  version: v1.6.2
  url: https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/experimental-install.yaml
```

The base stage then applies standalone CRDs first and chart-rendered CRDs second:

```just
# bootstrap/mod.just
kubectl apply --server-side --force-conflicts --filename "${url}"

helmfile --file "{{ repo_root }}/bootstrap/helmfile/crds.yaml" template --quiet \
    | yq ea 'select(.kind == "CustomResourceDefinition")' - \
    | kubectl apply --server-side --force-conflicts --filename -
```

Rendering Envoy Gateway also emits overlapping Gateway API CRDs marked **v1.6.1**:

```text
httproutes.gateway.networking.k8s.io    bundle-version=v1.6.1    channel=experimental
referencegrants.gateway.networking.k8s.io bundle-version=v1.6.1  channel=experimental
```

Consequently, the later source overwrites the selected definitions, including on reruns. This contradicts the intended single-source CRD ownership model.

**Classification:** Inherited ordering/overlap problem retained by the refactor.

**Evidence:** Actual CRD rendering emitted Gateway API resources, including `httproutes.gateway.networking.k8s.io`, with `gateway.networking.k8s.io/bundle-version: v1.6.1` and the experimental channel.

**Recommended correction:** Choose one authoritative source for Gateway API CRDs. Exclude overlapping definitions from other sources and validate uniqueness of CRD names across the combined inventory before applying anything. Do not uninstall existing CRDs during the correction or handoff.

### F7 — P2: Renovate updates an unused CRD version field

**Location:** `bootstrap/crds/standalone.yaml:8–25`.

Renovate annotations target the following `version` field, but each URL independently hardcodes that version:

```yaml
# bootstrap/crds/standalone.yaml
# renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api
version: v1.6.2
url: https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/experimental-install.yaml
```

Bootstrap reads only `.name` and `.url`, not `.version`:

```just
# bootstrap/mod.just
while IFS=$'\t' read -r name url; do
    [[ -z "${name}" || -z "${url}" ]] && continue
    kubectl apply --server-side --force-conflicts --filename "${url}"
done < <(yq -r '.crds[] | [.name, .url] | @tsv' "{{ repo_root }}/bootstrap/crds/standalone.yaml")
```

An automated version bump therefore leaves the installed CRD definitions unchanged while making the inventory appear updated.

**Evidence:** The annotated dependency regex in `.renovate/customManagers.json5` matches the following version field. The base-stage inventory reader consumes `.url` verbatim.

**Recommended correction:** Derive URLs from the declared version, or make the consumed URL itself the Renovate update target. Avoid maintaining two independent version literals for one dependency.

## Documentation gaps

- `README.md:359–360` still lists the deleted `bootstrap/helmfile.yaml` and `bootstrap/resources.yaml.j2`.
- `README.md:312,414` still promotes the script entry point. The wrapper remains functional, but the primary documented interface should be `just bootstrap cluster`.
- `docs/agent/secrets-standards-renovate.md:8` still describes workstation-local age keys.
- `docs/BOOTSTRAP.md:102–104` shows an unwrapped preflight command despite the earlier runtime-injection guidance. Clarify that current preflight does not itself use SOPS, or consistently document the intended environment setup.
- `bootstrap/crds/README.md` names standalone URLs as post-bootstrap “upgraders”, without identifying an ongoing reconciliation mechanism or an explicit manual upgrade procedure.

## Checks that passed

- The legacy script is a thin handoff to Just, not a retained fallback implementation.
- Just exposes the intended public commands and planned stage order.
- Helmfile metadata and values-template paths resolve when rendering with absolute state-file paths from the repository root.
- App and CRD Helmfile rendering succeeds; successful rendering alone does not establish API validity.
- The dependency graph has the intended eight-release chain.
- CRD rendering produces 64 CRDs and covers the required chart-owned groups; the Gateway API duplication remains a separate correctness problem.
- The parity script runs successfully, subject to F5's false-positive behavior.
- Generated config names are ignored, and kubeconfig/talosconfig generation paths apply `0600` permissions.
- Verification failures propagate through `log error`, which calls `exit 1` in `scripts/lib/common.sh`. A preliminary subagent claim that verification always succeeds was rejected after inspection.
- Shell syntax checks passed. ShellCheck could not be rerun because its mise shim lacked a configured version.

## Validation boundaries

- No apply, sync, reconcile, delete, patch, restart, destructive Talos operation, or other cluster mutation was executed.
- No resolved secrets were printed or written to disk by the review's validation probes.
- Helm hooks, live adoption, API admission, and interruption recovery were not exercised.
- Fresh-node, configured-node, mixed-node, and disaster-recovery drills remain deferred to the user as agreed.
- Existing uncommitted work was left unchanged; only this requested report was added after the review.
