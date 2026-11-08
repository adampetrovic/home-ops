# Secrets, Standards, and Renovate

Read this before touching secrets, encrypted files, schema-backed YAML/JSON, formatting-sensitive files, or Renovate-managed dependencies.

## Secret Management

- All secrets live in the 1Password vault `k8s` and reach the cluster through ExternalSecrets on the `onepassword-connect` ClusterSecretStore. Don't add SOPS-encrypted files.
- Never commit unencrypted secrets or derived secret values.
- Cluster-wide Flux substitution variables come from the 1Password item `cluster-secrets` via the `cluster-vars` ExternalSecret in `kubernetes/components/common/vars/externalsecret.yaml`. `cluster-apps` substitutes them into every Kustomization via `postBuild.substituteFrom`.
- Internal hostnames, LAN IPs and `TZ` are written literally. Keep private public domains and Cloudflare IDs in `${SECRET_*}` variables.
- Bootstrap seeds the secrets the cluster needs before External Secrets runs (`bootstrap/kustomize/home`, rendered with `op inject`): the Connect credentials, `flux-system/cluster-vars` and the wildcard TLS certificate. `just bootstrap secrets` re-runs only that step, for example to recover from a revoked Connect token.
- Connect's own credentials are kept in sync after bootstrap by the `onepassword-connect-credentials` ExternalSecret. When rotating them, update the `1password` item and revoke the old token only after the new one has synced.

## YAML Formatting

- Indent with 2 spaces, never tabs.
- Use LF line endings and final newlines.
- Start YAML files with `---`.
- Include schema comments where applicable:

```yaml
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
```

## Schema Validation

When changing YAML/JSON files that declare a schema, validate the changed file before reporting completion.

Use direct schema checks when no project validator is available:

```bash
uvx check-jsonschema --schemafile <schema-url> <file>
```

If validation fails, fix the manifest and re-run validation.

## Shell Scripts

- Use `#!/usr/bin/env bash`.
- Use `set -Eeuo pipefail`.
- Indent with 4 spaces.

## Naming Conventions

- App names are lowercase and hyphen-separated, for example `home-assistant`.
- Kubernetes labels follow `app.kubernetes.io/name: <app-name>`.
- Flux Kustomization names match app directory names.
- HelmRelease names match app directory names.

## Renovate

Renovate runs hourly and manages dependency updates.

Key conventions:

- Container images include digest pinning: `tag: v1.0.0@sha256:...`.
- Talos/Kubernetes upgrade versions use annotated comments for Renovate detection, as in `kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` (and `kubernetesupgrade.yaml` with `ghcr.io/siderolabs/kubelet`):

```yaml
spec:
  talos:
    # renovate: datasource=docker depName=ghcr.io/siderolabs/talos
    version: v1.14.2
```

- The Talos installer image in `talos/nodes/**` (`factory.talos.dev/metal-installer/{{ schematic }}:vX.Y.Z`) has no annotation; the "Process Talos Image Factory installer tags" custom manager in `.renovate/customManagers.json5` tracks it as `ghcr.io/siderolabs/talos`. Kubernetes component images in `talos/*.yaml.j2` are tracked by the "Process Kubernetes image tags" custom manager.

- Standalone bootstrap CRD inventories use Renovate-managed `version` fields plus `urlTemplate`; bootstrap derives the consumed URL from the version.
- Renovate config lives in `.renovaterc.json5` and `.renovate/`.
- Semantic commits are enforced, for example `feat(container)!:`, `fix(helm):`, `chore(container):`.
