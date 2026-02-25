# AGENTS.md

> Instructions for AI coding agents working in this repository.

## Repository Overview

This is a **home-ops GitOps repository** managing a Kubernetes cluster running on Talos Linux. All infrastructure and applications are declaratively defined and automatically deployed by Flux CD. The cluster consists of 5 bare-metal nodes (3 control plane + 2 workers) running Talos Linux with Cilium CNI.

**Key technologies:** Talos Linux, Kubernetes, Flux CD, Helm, Kustomize, SOPS, 1Password (External Secrets), Rook-Ceph, VolSync, Renovate.

## Version Control

This repository uses **Jujutsu (jj)** as the version control system (with a Git backend). Use `jj` commands instead of `git` for all VCS operations. See the jj skill for details.

## Repository Structure

```
kubernetes/
├── apps/                    # Application deployments organized by namespace
│   ├── automation/          # Home Assistant, Frigate, Zigbee2MQTT, etc.
│   ├── cert-manager/        # TLS certificate management
│   ├── database/            # CloudNative-PG, Dragonfly, PgAdmin
│   ├── default/             # General apps (Atuin, Memos, Miniflux, Paperless, etc.)
│   ├── external-secrets/    # 1Password integration
│   ├── flux-system/         # Flux operator and instance
│   ├── kube-system/         # Cilium, Reloader, Descheduler, metrics, etc.
│   ├── media/               # Plex, Sonarr, Radarr, SABnzbd, etc.
│   ├── network/             # Envoy Gateway, AdGuard, Cloudflared, ExternalDNS
│   ├── observability/       # Prometheus, Grafana, Loki, Vector
│   ├── openebs-system/      # OpenEBS local storage
│   ├── rook-ceph/           # Distributed storage
│   ├── security/            # Authelia, LLDAP
│   ├── storage/             # Garage S3-compatible storage
│   └── volsync-system/      # VolSync operator, Kopia web UI, snapshot controller
├── components/              # Reusable Kustomize components
│   ├── common/              # Namespace, SOPS, cluster vars, Helm repos
│   └── volsync/             # VolSync backup/restore component
└── flux/
    └── cluster/             # Top-level Flux Kustomization

talos/                       # Talos Linux configuration
├── talconfig.yaml           # Node definitions (managed by talhelper)
├── talenv.yaml              # Talos environment vars
├── talsecret.yaml           # Talos secrets
├── clusterconfig/           # Generated node configs (do not edit directly)
└── patches/                 # Talos machine patches
    ├── controller/          # Control-plane-specific patches
    └── global/              # All-node patches

bootstrap/                   # Initial cluster bootstrap
├── helmfile.yaml            # Bootstrap Helm releases (Cilium → Spegel → cert-manager → ESO → Flux)
└── resources.yaml.j2        # Bootstrap resources template

scripts/                     # Helper scripts
├── bootstrap-cluster.sh     # Full cluster bootstrap automation
└── lib/                     # Script libraries

.taskfiles/                  # Taskfile automation
├── Kubernetes/              # k8s helper tasks
├── Talos/                   # Talos upgrade/management tasks
└── VolSync/                 # Backup/restore tasks
```

## Application Structure Pattern

Every application follows this consistent structure:

```
app-name/
├── ks.yaml                  # Flux Kustomization — entry point for Flux
└── app/
    ├── kustomization.yaml   # Kustomize resources list
    ├── helmrelease.yaml     # HelmRelease (most apps use bjw-s app-template or upstream charts)
    └── externalsecret.yaml  # ExternalSecret pulling from 1Password (if needed)
```

### Flux Kustomization (`ks.yaml`)

This is the Flux entry point for each app. Key conventions:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app <app-name>           # Use YAML anchors for DRY
  namespace: &namespace <namespace>
spec:
  targetNamespace: *namespace
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn: []                    # List upstream dependencies
  path: ./kubernetes/apps/<namespace>/<app-name>/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  wait: true                       # false if nothing depends on this app
  interval: 30m
  retryInterval: 1m
  timeout: 5m
```

**For apps with persistent storage (VolSync)**, add the volsync component and postBuild substitution variables:

```yaml
spec:
  components:
    - ../../../../components/volsync
  postBuild:
    substitute:
      APP: *app
      VOLSYNC_CAPACITY: 10Gi
      VOLSYNC_R2_SCHEDULE: "30 3 * * *"     # Cloudflare R2 backup schedule (optional override)
```

The Kopia (primary) backup schedule is fixed at `0 * * * *` for all apps — a `MutatingAdmissionPolicy` injects random 0-30s jitter to prevent thundering herd. Only `VOLSYNC_R2_SCHEDULE` can be overridden per-app.

### HelmRelease Conventions

- Most apps use the **bjw-s app-template** chart via `OCIRepository` named `app-template`
- Schema reference: `https://raw.githubusercontent.com/bjw-s/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json`
- Always include `install.remediation.retries: -1` and `upgrade.remediation.strategy: rollback`
- Use YAML anchors (`&app`, `&port`, `*envFrom`) to reduce duplication
- Container images should include both tag and digest: `tag: v1.0.0@sha256:abc123...`
- Apply security contexts: `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities: {drop: ["ALL"]}`
- Set `runAsNonRoot: true` in defaultPodOptions where possible

### ExternalSecret Conventions

- All secrets come from **1Password** via a `ClusterSecretStore` named `onepassword-connect`
- ExternalSecrets extract keys from 1Password items and template them into Kubernetes secrets
- PostgreSQL apps typically use an `init-db` init container with `ghcr.io/home-operations/postgres-init`
- Database connection strings follow the pattern: `postgres://<user>:<pass>@postgres-rw.database.svc.cluster.local/<db>`

### Namespace Kustomization

Each namespace directory has a `kustomization.yaml` that:
1. References the `../../components/common` component (provides namespace, SOPS, cluster vars, Helm repos)
2. Lists all `ks.yaml` files for apps in that namespace

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <namespace>
components:
  - ../../components/common
resources:
  - ./app-one/ks.yaml
  - ./app-two/ks.yaml
```

## Routing Conventions (Gateway API)

Ingress is handled by **Envoy Gateway** using the Kubernetes **Gateway API** — there are no legacy `Ingress` resources. Two `Gateway` resources are defined in the `network` namespace:

- **`envoy-internal`** (`10.0.80.200`): For apps accessible only within the local network. Uses `${SECRET_DOMAIN}`.
- **`envoy-external`** (`10.0.80.201`): For apps exposed to the internet via **Cloudflare Tunnel**. Uses `${SECRET_PUBLIC_DOMAIN}`.

Both Gateways terminate TLS on port 443 with a wildcard certificate and redirect HTTP→HTTPS automatically.

### App-Template Route Configuration

Most apps use the bjw-s app-template `route:` key, which renders `HTTPRoute` resources:

**Internal-only app** (most common):
```yaml
route:
  app:
    hostnames:
      - "app.${SECRET_DOMAIN}"
    parentRefs:
      - name: envoy-internal
        namespace: network
```

**Externally-exposed app** (via Cloudflare Tunnel):
```yaml
route:
  app:
    hostnames:
      - "app.${SECRET_PUBLIC_DOMAIN}"
    parentRefs:
      - name: envoy-external
        namespace: network
```

**Dual internal + external** (rare):
```yaml
route:
  internal:
    hostnames:
      - "app.${SECRET_DOMAIN}"
    parentRefs:
      - name: envoy-internal
        namespace: network
  external:
    hostnames:
      - "app.${SECRET_PUBLIC_DOMAIN}"
    parentRefs:
      - name: envoy-external
        namespace: network
```

When the default `backendRefs` (auto-wired from the `service:` block) aren't sufficient, explicit rules can be added:
```yaml
route:
  app:
    hostnames:
      - "app.${SECRET_DOMAIN}"
    parentRefs:
      - name: envoy-internal
        namespace: network
    rules:
      - backendRefs:
          - identifier: app
            port: http
```

### Authelia Authentication (authelia-proxy component)

Apps that need **Authelia SSO/ext-auth** include the `authelia-proxy` Kustomize component in their **app-level `kustomization.yaml`** (not `ks.yaml`):

```yaml
# app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./externalsecret.yaml
components:
  - ../../../../components/authelia-proxy
```

This creates an Envoy `SecurityPolicy` that targets the app's `HTTPRoute` by name (`${APP}`), forwarding auth checks to `authelia.security.svc.cluster.local`. A `ReferenceGrant` in the `security` namespace authorises cross-namespace access — if you add authelia-proxy to an app in a **new namespace**, that namespace must be added to the ReferenceGrant at `kubernetes/apps/security/authelia/app/referencegrant.yaml`.

### Cloudflare Tunnel

External traffic flows: **Internet → Cloudflare → cloudflared pod → `envoy-external` Gateway service → app**. The Cloudflare Tunnel is configured in `kubernetes/apps/network/cloudflared/app/configs/config.yaml` and forwards all `*.${SECRET_PUBLIC_DOMAIN}` traffic to the `envoy-external` service.

## Secrets Management

### SOPS Encryption

- Encrypted files match `*.sops.yaml` pattern
- Encryption uses **age** keys (key file at `~/.config/sops/age/keys.txt`)
- Kubernetes secrets encrypt only `data` and `stringData` fields (`encrypted_regex: "^(data|stringData)$"`)
- Talos secrets encrypt the entire file
- **Never** commit unencrypted secrets. If you need to create a secret, use an ExternalSecret referencing 1Password instead.

### Cluster Variables

- Cluster-wide variables are stored in `kubernetes/components/common/vars/cluster-secrets.sops.yaml` (encrypted)
- Variables like `${SECRET_DOMAIN}` are substituted into all Flux Kustomizations via `postBuild.substituteFrom`

## Coding Standards

### YAML Formatting

- **Indent:** 2 spaces (never tabs)
- **Line endings:** LF
- **Final newline:** Always include
- All YAML files should start with `---`
- Include yaml-language-server schema comments where applicable:
  ```yaml
  # yaml-language-server: $schema=https://json.schemastore.org/kustomization
  ```

### Shell Scripts

- **Indent:** 4 spaces
- Use `set -Eeuo pipefail` for strict error handling
- Use `#!/usr/bin/env bash` shebang

### Naming Conventions

- App names are lowercase, hyphen-separated: `home-assistant`, `paperless-ngx`
- Kubernetes labels follow: `app.kubernetes.io/name: <app-name>`
- Flux Kustomization names match app directory names
- HelmRelease names match app directory names

## Renovate (Automated Dependency Updates)

Renovate runs hourly and manages dependency updates automatically. Key conventions:

- **Container images** include digest pinning: `tag: v1.0.0@sha256:...`
- **Talos/Kubernetes versions** use annotated comments for Renovate detection:
  ```yaml
  # renovate: datasource=docker depName=ghcr.io/siderolabs/installer
  TALOS_VERSION: v1.11.3
  ```
- **CRD URLs** in bootstrap scripts use similar annotations
- Renovate config lives in `.renovaterc.json5` and `.renovate/` directory
- Semantic commits are enforced: `feat(container)!:`, `fix(helm):`, `chore(container):`

## Task Automation

Run tasks with `task <namespace>:<task>`. Key commands:

```bash
# Talos operations
task talos:generate              # Generate Talos node configs
task talos:apply                 # Apply configs to nodes
task talos:upgrade node=<ip>     # Upgrade Talos on a node
task talos:upgrade-rollout       # Rolling upgrade all nodes
task talos:upgrade-k8s node=<ip> to=<version>  # Upgrade Kubernetes
task talos:fetch-kubeconfig      # Fetch kubeconfig

# Kubernetes
task k8s:delete-failed-pods     # Clean up failed/evicted pods

# VolSync backup/restore
task volsync:list app=<name> ns=<namespace>      # List snapshots
task volsync:snapshot app=<name> ns=<namespace>   # Create snapshot
task volsync:restore app=<name> ns=<namespace>    # Restore from snapshot
task volsync:unlock app=<name> ns=<namespace>     # Unlock restic repo (R2)
```

## Storage

- **Rook-Ceph** (`ceph-block` StorageClass): Default for most persistent volumes (RWO)
- **Rook-CephFS**: For RWX volumes
- **OpenEBS** (`openebs-hostpath`): Local high-performance volumes, used for VolSync R2 cache
- **NFS**: Synology NAS mounts for media storage and Kopia backup repository (`/volume2/kopia`)
- **VolSync**: Dual-storage backup strategy:
  - **Kopia (primary)**: Hourly backups to NFS filesystem repository (uses perfectra1n VolSync fork with Kopia support)
  - **Restic (secondary)**: Daily backups to Cloudflare R2 for off-site disaster recovery
  - `MutatingAdmissionPolicy` resources inject NFS mounts and jitter into VolSync mover jobs automatically
  - `KopiaMaintenance` CRD runs repository maintenance every 12 hours
  - Kopia web UI available at `kopia.<domain>` for browsing backups

## Network

- **Pod CIDR:** `10.69.0.0/16`
- **Service CIDR:** `10.96.0.0/16`
- **LoadBalancer VIP:** `10.0.80.99`
- **Node IPs:** `10.0.80.10-14` (Management VLAN 80)
- **Trusted VLAN 10:** `10.0.10.0/24` (secondary interfaces for IoT access)
- CNI is **Cilium** (eBPF-based, deployed without kube-proxy)

## GitOps Reconciliation

Flux reconciles cluster state from Git automatically. A **GitHub webhook** notifies the Flux Notification Controller on every push to `main`, triggering an immediate reconciliation — there is no need to wait for the default polling interval. This means pushing a fix to a broken HelmRelease will be picked up within seconds, not minutes.

Combined with `install.remediation.retries: -1`, a newly introduced app that fails on first install will keep retrying indefinitely until the configuration is correct. Push a fix → GitHub webhook fires → Flux pulls immediately → Helm retries with the corrected spec.

You can still force a manual reconciliation if needed:

```bash
flux reconcile ks <app-name> -n flux-system --with-source
```

## Common Operations for Agents

### Adding a New Application

1. Create the directory structure under `kubernetes/apps/<namespace>/<app-name>/`
2. Create `ks.yaml` (Flux Kustomization) with appropriate `dependsOn`
3. Create `app/helmrelease.yaml` using app-template or upstream chart
4. Create `app/kustomization.yaml` listing all resources
5. If the app needs a web UI: add a `route:` block in the HelmRelease pointing to `envoy-internal` or `envoy-external`
6. If the app needs Authelia auth: add the `authelia-proxy` component to `app/kustomization.yaml`
7. If secrets needed: create `app/externalsecret.yaml` referencing 1Password
8. If persistent storage needed: add volsync component to `ks.yaml`
9. Add the `ks.yaml` reference to the namespace's `kustomization.yaml`

### Modifying an Existing Application

- Edit the `helmrelease.yaml` for configuration changes
- Edit `ks.yaml` for dependency or VolSync changes
- Flux will automatically detect and apply changes once committed and pushed

### Debugging Applications

```bash
kubectl get ks -A                          # Check Flux Kustomization status
kubectl get hr -A                          # Check HelmRelease status
flux get kustomization --all-namespaces    # Detailed Flux status
kubectl describe hr <name> -n <namespace>  # HelmRelease details
kubectl logs -n <namespace> <pod>          # Application logs
flux reconcile ks <name> --with-source     # Force reconciliation
```

### Suspending/Resuming Flux

```bash
flux suspend ks <name> -n flux-system      # Pause reconciliation
flux resume ks <name> -n flux-system       # Resume reconciliation
flux suspend hr <name> -n <namespace>      # Pause Helm release
flux resume hr <name> -n <namespace>       # Resume Helm release
```

## Important Warnings

- **Never edit files in `talos/clusterconfig/`** — these are generated by `task talos:generate`
- **Never commit plaintext secrets** — use ExternalSecrets (1Password) or SOPS encryption
- **Never modify Flux system resources directly** — changes are reconciled from Git
- **Be cautious with `prune: true`** — removing a resource from Git will delete it from the cluster
- **The `*.sops.yaml` files are encrypted** — you cannot read their contents without the age key
- **Container image tags should always include digests** for reproducibility
- **Respect `dependsOn` chains** — apps may fail if their dependencies aren't ready
