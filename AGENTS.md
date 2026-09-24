# AGENTS.md

> Always-loaded instructions for AI coding agents working in this repository.

## How Pi Uses This File

Pi concatenates this file into the startup prompt. Keep it high-signal: critical rules live here, while detailed procedures live under `docs/agent/`. When a task matches one of the read gates below, read the linked doc before editing.

## Repository Snapshot

This is the `home-ops` GitOps repository for a 5-node bare-metal Talos Linux Kubernetes cluster. Flux CD reconciles everything from Git. Key technologies: Talos Linux, Kubernetes, Flux CD, Helm, Kustomize, SOPS, 1Password External Secrets, Rook-Ceph, Kopiur, Renovate, Cilium, Envoy Gateway.

## Operating Contract

- Use **Jujutsu (`jj`)** for all version-control operations. Do not use `git` directly in this repo.
- For `fix:` and `chore:` jj commits, add a concise one-line body explaining *why* where useful, for example `Why: avoid paging on brittle cause-based Talos log patterns`.
- Never commit plaintext secrets. Use ExternalSecrets backed by 1Password, or SOPS for files that are intentionally encrypted.
- Make all cluster changes via Git-tracked manifests and Flux reconciliation. Never mutate live cluster resources outside version control unless it is an explicit emergency/break-glass action confirmed by the operator.
- Talos machine configs are rendered natively from `talos/*.yaml.j2` and `talos/nodes/**`; do not commit rendered machine configs or talosconfig output.
- Never check application source code into this repository alongside deployments. Application code belongs in its own source repo and must be deployed here as a pre-built immutable container image.
- All workloads must be represented by HelmRelease resources, normally using the `app-template` OCIRepository. Do not add raw Deployments, StatefulSets, DaemonSets, or CronJobs.
- Container images must include both tag and digest, and Docker Hub images must use `mirror.gcr.io` rather than `docker.io`.
- Use Gateway API routes only. Do not add legacy `Ingress` resources.
- Validate changed YAML/JSON files that declare schemas before reporting completion.
- Preserve `dependsOn` chains and be cautious with `prune: true`; removing resources from Git deletes them from the cluster.
- Ask for confirmation before destructive or live-impacting operations such as cluster mutations, secret changes, production database work, node rollouts, or service restarts.

## Required Read Gates

Read the relevant doc before making non-trivial changes:

- Application deployment, HelmRelease, PVC, Kopiur, ExternalSecret, or app add/remove: `docs/agent/app-deployments.md`
- HTTPRoute, Envoy Gateway, Authelia, Cloudflare Tunnel, app exposure: `docs/agent/routing.md`
- SOPS, 1Password, formatting, schema validation, Renovate conventions: `docs/agent/secrets-standards-renovate.md`
- PRs, jj workflow, Flux reconciliation, debugging commands, post-merge cleanup: `docs/agent/operations.md`
- Talos, node upgrades, storage, networking, load balancers, Talos logs, observability platform: `docs/agent/platform.md`
- Unsure where to start: `docs/agent/README.md`

## Common Repository Layout

- `kubernetes/apps/<namespace>/<app>/` — Flux-managed applications
- `kubernetes/components/` — reusable Kustomize components, including Kopiur, persistence, and common vars
- `kubernetes/flux/cluster/` — top-level Flux Kustomization
- `talos/*.yaml.j2` and `talos/nodes/**` — native Talos machine config templates
- `talos/inventory.yaml` — node-to-management-IP mapping for Talos tasks
- `.justfile` plus module `mod.just` files — just automation recipes

## Quick App Rules

- App directories use `ks.yaml` plus `app/kustomization.yaml` and `app/helmrelease.yaml`.
- Persistent apps use the persistence and Kopiur backup components and set `APP`, `KOPIUR_SOURCE_PVC`, and `KOPIUR_CAPACITY` substitutions; new PVCs restore from `${APP}-nfs` by default via Kopiur `dataSourceRef`.
- Secrets come from the `onepassword-connect` ClusterSecretStore via ExternalSecret.
- PostgreSQL app connection strings use `postgres://<user>:<pass>@postgres-rw.database.svc.cluster.local/<db>`.
- App names are lowercase hyphenated and match Flux Kustomization and HelmRelease names.

## Quick Routing Rules

- Internal-only apps route through `network/envoy-internal` and `petrovic.network`.
- Public apps route through `network/envoy-external` and `${SECRET_PUBLIC_DOMAIN}` via Cloudflare Tunnel.
- Authelia-protected apps add the `components/authelia-proxy` component to the app-level `kustomization.yaml`.
- If adding Authelia in a new namespace, update `kubernetes/apps/security/authelia/app/referencegrant.yaml`.

## Quick Formatting and Validation

- YAML uses `---`, 2-space indentation, LF endings, and final newlines.
- Include schema comments where applicable.
- Shell scripts use `#!/usr/bin/env bash`, `set -Eeuo pipefail`, and 4-space indentation.
- For schema-backed YAML/JSON, run `uvx check-jsonschema --schemafile <schema-url> <file>` unless a project-specific validator is more appropriate.

## Quick Operational Notes

- Flux reconciles from `main`; a GitHub webhook triggers reconciliation shortly after pushes.
- CI checks are useful but not a default merge gate unless the user explicitly asks to wait.
- GitHub PRs in this repo only allow rebase merges; use `gh pr merge --rebase --delete-branch` and do not try squash or merge commits.
- After Talos or Kubernetes rollouts, verify LoadBalancer/BGP/L2 endpoint sanity for services using `externalTrafficPolicy: Local`.
- TODO state changes under `.pi/todos` are major coordination changes; commit and push them using jj.

## High-Priority Warnings

- Never commit unencrypted secrets or derived secret values.
- Never modify Flux-managed live resources as a substitute for GitOps changes; use Git-tracked changes and Flux instead, except for confirmed emergency break-glass operations.
- Never deploy app source from ConfigMaps or build application code at container startup.
- Never use `docker.io` directly; use `mirror.gcr.io` for Docker Hub images.
- Never commit rendered Talos machine configs or Talos client configs.
