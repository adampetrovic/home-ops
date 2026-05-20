# Application Deployment Conventions

Read this before adding, removing, or modifying applications under `kubernetes/apps/`.

## Application Structure Pattern

Every application follows this structure:

```text
app-name/
├── ks.yaml                  # Flux Kustomization — entry point for Flux
└── app/
    ├── kustomization.yaml   # Kustomize resources list
    ├── helmrelease.yaml     # HelmRelease
    └── externalsecret.yaml  # ExternalSecret pulling from 1Password, if needed
```

## Flux Kustomization (`ks.yaml`)

Use this shape for app entrypoints:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app <app-name>
  namespace: &namespace <namespace>
spec:
  targetNamespace: *namespace
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn: []
  path: ./kubernetes/apps/<namespace>/<app-name>/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  wait: true
  interval: 30m
  retryInterval: 1m
  timeout: 5m
```

For apps with persistent storage, add the VolSync component and substitutions:

```yaml
spec:
  components:
    - ../../../../components/volsync
  postBuild:
    substitute:
      APP: *app
      VOLSYNC_CAPACITY: 10Gi
      VOLSYNC_KOPIA_SCHEDULE: "12 * * * *"
      VOLSYNC_R2_SCHEDULE: "30 3 * * *"
```

`VOLSYNC_KOPIA_SCHEDULE` and `VOLSYNC_R2_SCHEDULE` can be overridden per app. Most apps set a custom Kopia minute offset to spread load. A MutatingAdmissionPolicy injects additional jitter.

## HelmRelease Conventions

- All workloads must use HelmRelease, normally with the bjw-s `app-template` chart via the `app-template` OCIRepository.
- Never add raw Deployments, StatefulSets, DaemonSets, or CronJobs. For CronJobs, use `controllers.<name>.type: cronjob` in app-template.
- Never check application source code into this repository. Application code belongs in its own source repo and must be deployed here as a pre-built container image.
- Do not mount application source from ConfigMaps, build apps at container startup, or use generic language/runtime images as in-cluster build mechanisms.
- Use schema comment: `https://raw.githubusercontent.com/bjw-s/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json`.
- Always include `install.remediation.retries: -1` and `upgrade.remediation.strategy: rollback`.
- Use YAML anchors (`&app`, `&port`, `*envFrom`) to reduce duplication.
- Container images must include both tag and digest: `tag: v1.0.0@sha256:abc123...`.
- Never use `docker.io` directly. Use `mirror.gcr.io` as a pull-through mirror. Docker Official Images use `mirror.gcr.io/library/<image>`.
- Apply security contexts: `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities: {drop: ["ALL"]}`.
- Set `runAsNonRoot: true` in `defaultPodOptions` where possible.

## ExternalSecret Conventions

- Secrets come from 1Password via the `ClusterSecretStore` named `onepassword-connect`.
- ExternalSecrets extract fields from 1Password items and template Kubernetes Secrets.
- PostgreSQL apps typically use an `init-db` init container with `ghcr.io/home-operations/postgres-init`.
- Database connection strings follow `postgres://<user>:<pass>@postgres-rw.database.svc.cluster.local/<db>`.

## Namespace Kustomization

Each namespace directory has a `kustomization.yaml` that references `../../components/common` and lists app `ks.yaml` files:

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

## Adding a New Application

1. Create `kubernetes/apps/<namespace>/<app-name>/`.
2. Create `ks.yaml` with appropriate `dependsOn`.
3. Create `app/helmrelease.yaml` using app-template or an upstream chart.
4. Create `app/kustomization.yaml` listing all resources.
5. If the app has a web UI, add a Gateway API `route:` block in the HelmRelease.
6. If the app needs Authelia auth, add the `authelia-proxy` component to app-level `kustomization.yaml` and check ReferenceGrant needs.
7. If secrets are needed, create `app/externalsecret.yaml` referencing 1Password.
8. If persistent storage is needed, add the VolSync component to `ks.yaml`.
9. Add the app `ks.yaml` to the namespace `kustomization.yaml`.

## Modifying an Existing Application

- Edit `helmrelease.yaml` for app configuration changes.
- Edit `ks.yaml` for dependencies, wait behavior, pruning, or VolSync substitutions.
- Preserve app name consistency across directory, Flux Kustomization, HelmRelease, labels, service names, and route names.
- Flux applies committed changes automatically after the branch is merged or pushed to `main`.
