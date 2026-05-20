# Secrets, Standards, and Renovate

Read this before touching secrets, encrypted files, schema-backed YAML/JSON, formatting-sensitive files, or Renovate-managed dependencies.

## SOPS and Secret Management

- Encrypted files match `*.sops.yaml`.
- Encryption uses age keys from `~/.config/sops/age/keys.txt`.
- Kubernetes secrets encrypt only `data` and `stringData` fields via `encrypted_regex: "^(data|stringData)$"`.
- Talos secrets encrypt the entire file.
- Never commit unencrypted secrets or derived secret values.
- Prefer ExternalSecrets referencing 1Password for application secrets.
- Cluster-wide variables live in `kubernetes/components/common/vars/cluster-secrets.sops.yaml`.
- Variables such as `${SECRET_DOMAIN}` are substituted into Flux Kustomizations via `postBuild.substituteFrom`.

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
- Talos/Kubernetes versions use annotated comments for Renovate detection:

```yaml
# renovate: datasource=docker depName=ghcr.io/siderolabs/installer
TALOS_VERSION: v1.11.3
```

- CRD URLs in bootstrap scripts use similar annotations.
- Renovate config lives in `.renovaterc.json5` and `.renovate/`.
- Semantic commits are enforced, for example `feat(container)!:`, `fix(helm):`, `chore(container):`.
