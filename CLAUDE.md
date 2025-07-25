# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a GitOps-based home infrastructure repository managing a Kubernetes cluster using Flux CD. The cluster runs on Talos Linux across Intel NUCs and hosts various home automation, media, and self-hosted services.

## Common Development Commands

### Environment Setup
```bash
# Install required tools
task workstation:brew  # macOS

# Configure SOPS (required for secrets)
# Ensure age key from 1Password 'sops-age-key' is saved to:
# ~/.config/sops/age/keys.txt
```

### Daily Development Tasks

#### Checking Cluster Status
```bash
flux get all -A                    # Check all Flux resources
kubectl get kustomization -A       # Check Kustomizations
kubectl get helmrelease -A         # Check Helm releases
kubectl get pods -A               # Check all pods
task kubernetes:resources         # Overview of cluster resources
```

#### Applying Changes
```bash
# After editing manifests, commit and push:
git add . && git commit -m "feat: description" && git push

# Force Flux to reconcile immediately
task flux:reconcile

# Apply specific app directly (for testing)
task flux:apply path=<app-path> ns=<namespace>
# Example: task flux:apply path=networking/nginx ns=networking
```

#### Working with Secrets
```bash
# View encrypted secret
sops --decrypt path/to/secret.sops.yaml

# Edit encrypted secret
sops path/to/secret.sops.yaml

# Encrypt all secrets before committing
task sops:encrypt
```

#### Debugging Issues
```bash
# Check Flux events for a resource
flux events --for Kustomization/<name>
flux events --for HelmRelease/<name>

# View pod logs
kubectl logs -n <namespace> <pod-name>

# Describe resources
kubectl describe helmrelease -n <namespace> <name>

# Delete failed pods
task kubernetes:delete-failed-pods
```

#### Backup Operations (VolSync)
```bash
# Create snapshot
task volsync:snapshot app=<app> ns=<namespace>

# List snapshots
task volsync:list app=<app> ns=<namespace>

# Restore from backup
task volsync:restore app=<app> ns=<namespace> previous=<number>
```

### Running Tests/Validation
```bash
# Validate Kubernetes manifests
task kubernetes:kubeconform

# Check what Flux would apply
flux diff kustomization <name> --path <path>
```

## Architecture & Structure

### Directory Layout
- `kubernetes/apps/` - Application deployments organized by category:
  - `ai/` - AI tools (Ollama, Open WebUI)
  - `automation/` - Home automation (Home Assistant, ESPHome, Frigate)
  - `database/` - Databases (CloudNative-PG, Redis)
  - `media/` - Media services (Plex, Sonarr, Radarr)
  - `network/` - Network services (AdGuard, Cloudflare)
  - `observability/` - Monitoring (Grafana, Prometheus, Loki)
  - `security/` - Auth services (Authelia, LLDAP)
  - `storage/` - Storage services (MinIO, Rook-Ceph)
- `kubernetes/bootstrap/` - Cluster bootstrapping
- `kubernetes/flux/` - Core Flux GitOps configuration
- `kubernetes/templates/` - Reusable Kubernetes templates
- `.taskfiles/` - Task automation scripts

### Key Architectural Patterns

1. **GitOps Flow**: All changes go through Git → Flux auto-applies from main branch
2. **Kustomization Structure**: Each app has a `ks.yaml` defining the Flux Kustomization
3. **HelmRelease Pattern**: Most apps deployed via Helm with `app.yaml` containing HelmRelease
4. **Secret Management**: All secrets encrypted with SOPS using age encryption
5. **Dependency Management**: Flux Kustomizations use `dependsOn` for ordered deployment
6. **Namespace Organization**: Apps organized by function (networking, media, etc.)

### Application Deployment Pattern
Each application typically follows this structure:
```
kubernetes/apps/<category>/<app-name>/
├── ks.yaml              # Flux Kustomization
├── app.yaml             # HelmRelease or Deployment
└── secrets.sops.yaml    # Encrypted secrets (if needed)
```

### Networking & Ingress
- Currently transitioning from ingress-nginx to Cilium Gateway API
- Services exposed via Gateway/HTTPRoute resources
- External-DNS manages DNS records automatically
- Cloudflare for DNS and tunnel services

### Storage Architecture
- Rook-Ceph provides distributed block storage
- VolSync handles PVC backups to MinIO
- NFS from Synology NAS for media storage
- PersistentVolumeClaims defined in app configurations

### Important Conventions
- All YAML files use 2-space indentation
- Secrets must be encrypted before committing
- Use existing patterns when adding new services
- Renovate handles dependency updates automatically
- Check existing similar apps for configuration patterns