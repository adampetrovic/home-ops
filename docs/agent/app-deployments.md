# Application Deployment Conventions

Read this before adding, removing, or modifying applications under `kubernetes/apps/`.

## Application Structure Patterns

Most application directories follow this default shape:

```text
app-name/
├── ks.yaml                  # Flux Kustomization — entry point for Flux
└── app/
    ├── kustomization.yaml   # Kustomize resources list
    ├── helmrelease.yaml     # HelmRelease
    └── externalsecret.yaml  # ExternalSecret pulling from 1Password, if needed
```

Intentional exceptions exist for apps that need multiple Flux stages or supporting resources:

- Multi-stage apps may have one `ks.yaml` containing multiple Flux `Kustomization` documents, each pointing at a subdirectory, for example database-before-app flows such as Immich.
- Split controllers may have separate subdirectories under one app directory, for example `external-dns/external` and `external-dns/unifi`.
- Apps with several related HelmReleases may keep those releases under a nested `app/` layout, for example Vector's agent and aggregator.
- Certificate bundles, proxy routes, backup support resources, and operator-owned custom resources may omit the default `app/helmrelease.yaml` when no single app workload exists.

When adding a new exception, document why the default structure is not sufficient in the app's `ks.yaml` or a local README.

### Accepted Deviations

These are known and intentional. Do not "fix" them: renaming a Flux Kustomization or HelmRelease makes Flux prune and recreate everything the old name owned.

- HelmRelease names that differ from their directory: `grafana-operator` (`observability/grafana`), `rook-ceph-operator` (`rook-ceph/rook-ceph/app`), `unifi-poller` (`observability/unpoller`), `unifi-internal-dns` and `external-dns` (`network/external-dns`), `onepassword-connect` (`external-secrets/external-secrets/stores`), `barman-cloud` (`database/cloudnative-pg/barman-cloud`).
- Multi-stage Flux Kustomizations are named `<app>-<stage>`, for example `immich-db`, `rook-ceph-cluster`, and `grafana-instance`.
- `prune: false` on `cilium`, `coredns`, `ceph-csi-drivers`, `rook-ceph`, and `rook-ceph-cluster` protects core infrastructure.
- `network/envoy-gateway` pulls its chart from `oci://docker.io/envoyproxy/gateway-helm`. The `mirror.gcr.io` rule applies to container images, not chart sources.
- Immich, Bookorbit, Tracearr, and GDB run dedicated CloudNativePG clusters, so their connection strings use `<app>-postgres-rw.<namespace>.svc.cluster.local` instead of the shared `postgres-rw.database` cluster.
- Jellyseerr and Plexovic Gatus are published on `${SECRET_PLEX_DOMAIN}` rather than `${SECRET_PUBLIC_DOMAIN}`.
- `storage/garage/meta-bootstrap` is deliberately not registered with Flux; it is a recovery-only overlay, explained in its `kustomization.yaml` header.

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
  dependsOn:
    - name: external-secrets-stores
      namespace: external-secrets
  path: ./kubernetes/apps/<namespace>/<app-name>/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  wait: false
  interval: 30m
  retryInterval: 1m
  timeout: 5m
```

- `dependsOn` lists only what the app really needs, always with an explicit `namespace`. Omit it when there are no dependencies.
- `wait: false` is the default. Use `wait: true` only when another Flux Kustomization lists this one in `dependsOn`, so dependents start after its resources are ready.
- Flux Kustomizations live in the app's own namespace, not `flux-system`.
- Set `postBuild.substitute.APP` only when something in the path uses `${APP}`, such as the Kopiur backup or `authelia-proxy` components.

For apps with persistent storage, add the Kopiur backup component and substitutions:

```yaml
spec:
  components:
    - ../../../../components/kopiur/backup
  dependsOn:
    - name: kopiur-repositories
      namespace: kopiur-system
  postBuild:
    substitute:
      APP: *app
      KOPIUR_CAPACITY: 10Gi
```

R2 policies are suffixed `-r2` and run weekly; NFS policies are suffixed `-nfs` and run hourly. The backup component also creates the PVC and a passive Kopiur `Restore` named `${APP}` from `${APP}-nfs`; the PVC is wired to that restore with `dataSourceRef` and `onMissingSnapshot: Continue`, so first installs and disaster-recovery restores use the same manifests.

The backup component snapshots and restores a PVC named `${APP}`. Keep persistent app PVC names aligned with `APP`; for unusual workloads, create a separate Flux Kustomization whose `APP` value is the exact PVC name being protected.

Optional substitutions and their defaults:

| Variable | Default | Purpose |
|---|---|---|
| `KOPIUR_CAPACITY` | `5Gi` | Application PVC size; default mover cache capacity when not overridden |
| `KOPIUR_CACHE_CAPACITY` | `KOPIUR_CAPACITY` (or `5Gi`) | Mover cache PVC size, independently of the application PVC |
| `KOPIUR_ACCESSMODES` | `ReadWriteOnce` | PVC access mode |
| `KOPIUR_STORAGECLASS` | `ceph-block` | PVC storage class |
| `KOPIUR_SNAPSHOTCLASS` | `csi-ceph-blockpool` | VolumeSnapshotClass for snapshots and restores |
| `KOPIUR_CACHE_STORAGECLASS` | `ceph-block` | Mover cache storage class |
| `KOPIUR_PUID` / `KOPIUR_PGID` | `568` | UID/GID the mover runs as; match the app's data ownership |

### First Kopiur backup in a namespace

The backup component only works in namespaces that are already set up for Kopiur. Before adding it to an app, check the target namespace. This applies both to a brand-new namespace and to an existing namespace that has never had a backed-up app (for example `projects`, which only gained backups with `healthng`):

```sh
grep -n 'components/kopiur/secret' kubernetes/apps/<namespace>/kustomization.yaml
grep -n -- '- <namespace>$' kubernetes/apps/kopiur-system/kopiur/repository/app/clusterrepository.yaml   # expect 2 hits
```

If either check comes up short, make both changes in the same PR as the app:

1. Add `../../components/kopiur/secret` to the namespace `kubernetes/apps/<namespace>/kustomization.yaml`. Kopiur's mover Jobs run in the app's namespace and read the `kopiur-nfs-repository` and `kopiur-r2-repository` credential Secrets there. The component creates them as ExternalSecrets.
2. Add the namespace, in alphabetical order, to `allowedNamespaces` on **both** ClusterRepositories (`kopiur-r2` and `kopiur-nfs`) in `kubernetes/apps/kopiur-system/kopiur/repository/app/clusterrepository.yaml`.

Missing either one fails after merge, not in CI:

| Missing | Symptom |
| --- | --- |
| `allowedNamespaces` entry | The app's Flux Kustomization fails to apply: `SnapshotPolicy/<ns>/<app>-nfs dry-run failed: admission webhook "mutate.kopiur.home-operations.com" denied the request: namespace "<ns>" is not in the allowedNamespaces of ClusterRepository "kopiur-nfs"`. Nothing in the app is created. |
| `kopiur/secret` component | Everything applies, but the `Restore` stays `Pending` with condition `MissingCredentialsSecret` (`credentials Secret kopiur-nfs-repository does not exist in namespace <ns>`). The PVC never binds, the pod stays `Pending`, and the HelmRelease install times out. |

Once both are fixed, the restore runs (with `onMissingSnapshot: Continue` a first install has nothing to restore and completes immediately), the PVC binds, and the HelmRelease's install retries recover on their own.

The component PVC is not prune-protected: removing a persistent app from Git deletes its PVC and data, leaving only the Kopiur snapshots.

PVCs that are deliberately outside Kopiur:

- CloudNativePG clusters, which back up with barman-cloud (`objectstore.yaml` and `scheduledbackup.yaml` beside each `cluster.yaml`).
- Cache volumes such as `plex-cache` and `jellyseerr-cache`.
- Chart-managed observability storage for Prometheus, Alertmanager, Loki, and Grafana.
- `data-adguard-1`, the AdGuard replica that syncs from the backed-up `data-adguard-0`.

## HelmRelease Conventions

- All workloads must use HelmRelease. Application workloads normally use the bjw-s-labs `app-template` chart via the shared `app-template` OCIRepository.
- Platform components, operators, and upstream charts may use their own OCIRepository or HelmRepository, but should still keep Helm release settings, dependencies, and supporting resources explicit.
- Never add raw Deployments, StatefulSets, DaemonSets, or CronJobs. For CronJobs, use `controllers.<name>.type: cronjob` in app-template.
- Never check application source code into this repository. Application code belongs in its own source repo and must be deployed here as a pre-built container image.
- Do not mount application source from ConfigMaps, build apps at container startup, or use generic language/runtime images as in-cluster build mechanisms.
- For app-template HelmReleases, use schema comment: `https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json`.
- Always include `install.remediation.retries: -1` and `upgrade.remediation.strategy: rollback` unless the upstream chart has a documented reason not to.
- Use YAML anchors (`&app`, `&port`, `*envFrom`) to reduce duplication.
- Container images must include both tag and digest: `tag: v1.0.0@sha256:abc123...`.
- Never use `docker.io` directly. Use `mirror.gcr.io` as a pull-through mirror. Docker Official Images use `mirror.gcr.io/library/<image>`.
- Apply security contexts: `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities: {drop: ["ALL"]}`.
- Set `runAsNonRoot: true` in `defaultPodOptions` where possible.

## ExternalSecret Conventions

- Secrets come from 1Password via the `ClusterSecretStore` named `onepassword-connect`.
- ExternalSecrets extract fields from 1Password items and template Kubernetes Secrets.
- Database connection strings follow `postgres://<user>:<pass>@postgres-rw.database.svc.cluster.local/<db>`.

## PostgreSQL Roles and Databases

Postgres roles and databases are declared with CloudNativePG `DatabaseRole` and `Database` CRs, not the `postgres-init` init container. The CRs and the role's password Secret must live in the same namespace as the CNPG `Cluster`.

Apps on the shared `postgres` cluster add a `db/` directory, reconciled into the `database` namespace by a second Flux Kustomization named `<app>-db`:

```text
app-name/
├── ks.yaml                  # <app>-db (path ./db, targetNamespace: database, wait: true) + app
├── app/
└── db/
    ├── kustomization.yaml
    ├── externalsecret.yaml  # <app>-db -> <app>-db-credentials (kubernetes.io/basic-auth, cnpg.io/reload label)
    ├── databaserole.yaml    # login role, passwordSecret <app>-db-credentials
    └── database.yaml        # one Database per DB, owner = role
```

- The app Kustomization `dependsOn` `<app>-db` instead of `cloudnative-pg-cluster`. home-assistant deliberately doesn't, so it can start while Postgres is down.
- Use the same 1Password item as the app, so the app's connection string and the role password come from one source.
- Name CRs after the app (`<app>`, or `<app>-main`/`<app>-log` for multi-DB apps); `spec.name` is the real Postgres role/DB name.
- Always set `databaseRoleReclaimPolicy: retain` and `databaseReclaimPolicy: retain`, so removing a CR never drops the role or data.
- Declare required extensions in `Database.spec.extensions` without a `version`, so CNPG doesn't upgrade them.
- App namespaces must not receive the CNPG superuser password.

Apps with a dedicated cluster (Immich, Bookorbit, Tracearr, GDB) put `databaserole.yaml` and `database.yaml` in their existing `database/` directory beside `cluster.yaml`. Keep `bootstrap.initdb` on those clusters as-is: it only runs at cluster creation, and the CRs take over afterwards. Immich connects as its own role, not the superuser, so its `Database` pins `vector` and `vchord` versions. Bump them in `database/database.yaml` whenever the `cloudnative-vectorchord` image changes, so CNPG runs `ALTER EXTENSION ... UPDATE` as superuser.

### Example (`kubernetes/apps/default/miniflux/`)

`ks.yaml` gains a first document:

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app miniflux-db
  namespace: default
spec:
  targetNamespace: database
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: cloudnative-pg-cluster
      namespace: database
    - name: external-secrets-stores
      namespace: external-secrets
  path: ./kubernetes/apps/default/miniflux/db
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

`db/externalsecret.yaml`:

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: miniflux-db
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: miniflux-db-credentials
    creationPolicy: Owner
    template:
      engineVersion: v2
      type: kubernetes.io/basic-auth
      metadata:
        labels:
          cnpg.io/reload: "true"
      data:
        username: "{{ .POSTGRES_USER }}"
        password: "{{ .POSTGRES_PASS }}"
  dataFrom:
    - extract:
        key: miniflux
```

`db/databaserole.yaml` and `db/database.yaml`:

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/postgresql.cnpg.io/databaserole_v1.json
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: miniflux
spec:
  cluster:
    name: postgres
  name: miniflux
  ensure: present
  login: true
  passwordSecret:
    name: miniflux-db-credentials
  databaseRoleReclaimPolicy: retain
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/postgresql.cnpg.io/database_v1.json
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: miniflux
spec:
  cluster:
    name: postgres
  name: miniflux
  owner: miniflux
  ensure: present
  databaseReclaimPolicy: retain
```

The app's own ExternalSecret only templates its connection string, for example `postgres://{{ .POSTGRES_USER }}:{{ .POSTGRES_PASS }}@postgres-rw.database.svc.cluster.local/miniflux`. It has no `INIT_POSTGRES_*` keys and no `cloudnative-pg` extract.

### Operating Notes

- CNPG adopts an existing role or database with the same name, so adding CRs for an app that already has a database is non-destructive.
- A new `DatabaseRole` can briefly report `applied: false` with `secrets "<name>" is forbidden`. CNPG adds the password Secret to the cluster's RBAC Role when it sees the CR, and the next reconcile clears the error.
- Check status with `kubectl get databaserole,database -A`; both should show `APPLIED true`.
- Rotating a password in 1Password updates both the app Secret and `<app>-db-credentials`, and CNPG applies the new password to the role.

### Removing an App's Database

Removing `db/` (or the app) from Git deletes the CRs, but `retain` leaves the role and database in Postgres. When deleting a Postgres-backed app, ask whether its role and database should also be dropped. If yes, do it in two pushes:

1. Set `ensure: absent` on each `Database` and `databaseRoleReclaimPolicy: delete` on the `DatabaseRole`. CNPG rejects `ensure: absent` on a `DatabaseRole`. Wait until the `Database` CRs report `APPLIED true`, meaning the databases are dropped.
2. Remove the files from Git. Deleting the `DatabaseRole` CR with the `delete` policy drops the role. This only succeeds once the role owns nothing, which is why the databases go first.

Always run `kubectl apply --dry-run=server` on new CNPG CRs. The datreeio schemas don't catch CNPG's validation rules.

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
5. If the app has a simple app-owned web UI, add a Gateway API `route:` block in the HelmRelease. Use a standalone `HTTPRoute` for shared, cross-namespace, proxy, or non-app-template routing.
6. If the app needs Authelia auth, add the `authelia-proxy` component to app-level `kustomization.yaml` and check ReferenceGrant needs.
7. If secrets are needed, create `app/externalsecret.yaml` referencing 1Password.
8. If persistent storage is needed, add the Kopiur backup component to `ks.yaml`.
9. Add the app `ks.yaml` to the namespace `kustomization.yaml`.

## Modifying an Existing Application

- Edit `helmrelease.yaml` for app configuration changes.
- Edit `ks.yaml` for dependencies, wait behavior, pruning, or Kopiur substitutions.
- Preserve app name consistency across directory, Flux Kustomization, HelmRelease, labels, service names, and route names.
- Flux applies committed changes automatically after the branch is merged or pushed to `main`.
