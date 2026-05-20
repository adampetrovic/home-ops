# Agent Documentation Index

This directory holds detailed agent procedures that are intentionally kept out of the always-loaded `AGENTS.md` prompt. Pi loads `AGENTS.md` at startup, but it does not automatically load these files. Read the relevant file before doing matching work.

## Read Gates

- `app-deployments.md` — adding, removing, or modifying Kubernetes applications; HelmRelease/app-template conventions; VolSync; ExternalSecrets.
- `routing.md` — Gateway API, Envoy internal/external routes, Authelia proxy, Cloudflare Tunnel.
- `secrets-standards-renovate.md` — SOPS, 1Password, YAML/schema validation, Renovate conventions.
- `operations.md` — jj workflow, Taskfile commands, Flux reconciliation, PR checks, debugging, post-merge cleanup.
- `platform.md` — repository map, storage, network, post-upgrade LoadBalancer checks, Talos logging/observability.

## Why This Is Split

Pi concatenates `AGENTS.md` into the prompt. Long examples and rarely used procedures compete with critical rules for model attention. Keep `AGENTS.md` concise and imperative; keep detailed workflows here for progressive disclosure.
