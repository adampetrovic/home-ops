{
  "id": "d8efebc0",
  "title": "Migrate tracearr from embedded TimescaleDB to CNPG with barman backup to Garage",
  "tags": [
    "home-ops",
    "tracearr",
    "cnpg",
    "backup"
  ],
  "status": "open",
  "created_at": "2026-04-05T22:46:19.286Z"
}

## Context
tracearr currently runs an embedded TimescaleDB container (`timescale/timescaledb-ha`) with data on `openebs-hostpath` PVC (10Gi). This data is **not backed up** — no VolSync, no CNPG, no barman.

## Extension Image ✅
Built and published: `ghcr.io/adampetrovic/timescaledb-cnpg:2.26.1-18-trixie`
- Repo: https://github.com/adampetrovic/timescaledb-cnpg
- 2.6 MB FROM scratch image with just .so + .control + .sql files
- Renovate tracks PGDG apt repo for auto-updates
- Uses CNPG ImageVolume approach (k8s 1.35 + CNPG 1.29 + PG18 — all met)

## Remaining Work
1. Create `media/tracearr/database/` with:
   - `cluster.yaml` — CNPG Cluster using minimal PG18 image + timescaledb extension via ImageVolume
   - `objectstore.yaml` — barman ObjectStore backing up to Garage S3
   - `scheduledbackup.yaml` — daily barman backup
   - `externalsecret.yaml` — credentials from 1Password
   - `kustomization.yaml`
2. Add `tracearr-db` Kustomization to `media/tracearr/ks.yaml` with `dependsOn: cloudnative-pg`
3. Update tracearr HelmRelease:
   - Remove the `db` controller and `db-data` PVC
   - Point `DATABASE_URL` at the CNPG cluster service (`tracearr-postgres-rw.media.svc.cluster.local`)
   - Remove the `db` service
4. Data migration: either pg_dump from embedded container or accept fresh start
