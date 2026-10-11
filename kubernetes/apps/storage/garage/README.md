# Garage metadata on Ceph

Garage v2.4.1 is one node (replication factor 1). `/meta` uses the protected
`garage-meta` Ceph PVC; `/data` remains the original NFS export. Do not recreate
or add `dataSourceRef` to the existing Bound metadata claim.

## Metadata backups (not object-data backups)

`garage-meta-nfs` runs hourly and `garage-meta-r2` weekly. Both require a successful
native `/garage meta snapshot` workload hook and archive the completed native
LMDB snapshots under `snapshots/<UTC timestamp>/db.lmdb`, plus node identity,
cluster/data layout and other metadata files. **The running `/db.lmdb` tree is
excluded.** Native snapshots are consistent database copies; a raw running-LMDB
filesystem copy is not substituted. Both policies verify 100% of archived files
on a daily schedule.

Current Kopiur stages its CSI volume before the workload hook. Consequently the
archive contains previously completed native snapshots, not necessarily the
snapshot produced by that run's hook. The hook refreshes native snapshots for
subsequent CSI captures. Determine the actual recovery point from the latest
native timestamp **inside the archive**, not the Snapshot CR creation time.
Hourly NAS runs refresh these; Garage also auto-snapshots every six hours. RPO
therefore includes native snapshot age and schedule delays. Failures must be
investigated rather than assumed to have produced a current backup.

Pinned backup records are retained in Git. The first R2 capture contains older
native snapshots and is historical, **not** the preferred migration recovery
point. Use `garage-meta-verified-r2-20261011`, Kopia ID
`397fe6fec529945c25847c7df5553b6d`: its independently restored native point is
2026-10-11 12:31:25 AEDT (01:31:25 UTC), SHA-256
`e6192f90a650c683b5f3ab7236e2dafaa6c03373344d7ee5447d2d7168542f6a`.
The archive contains 9 files / 108,760,257 bytes. Isolated restore verified the
original identity/layout, raw running-LMDB exclusion, normalized writable
568:568 ownership and successful full Garage v2.4.1 LMDB-to-SQLite validation.
NAS and R2 100%-file verification both succeeded. This does not start another
Garage node or imply full object-data recovery.

Kopiur R2 is independent of the local NFS/Ceph failure domains; the NAS repository
is a separate export, but shares the NAS failure domain with object data.

Metadata backups **do not back up `/data`**. Recovery requires the appropriate
surviving/matching object data. Older metadata can reference blocks subsequently
deleted, and newer objects can be absent from its catalog. Do not pair a weekly
metadata snapshot with the abandoned partial whole-data migration copy.

## Explicit bootstrap recovery

The `meta-bootstrap/` overlay is intentionally **not registered in Flux** during
normal operation. It uses supported Kopiur `Restore`/PVC-populator APIs to fill a
**new** `garage-meta-recovered` claim from `garage-meta-r2`'s `/pvc/garage-meta`
identity. `onMissingSnapshot: Fail` prevents silently starting with empty metadata.
Recorded backup identity works without a running Garage pod. Existing claims and
NFS exports are never deleted by this overlay.

For disaster recovery, make every change in Git and obtain outage approval:

1. Fence writers and stop any surviving Garage instance through Flux; never run
   two instances with the same node identity.
2. Reestablish the repositories/policies, then register a dedicated Flux
   Kustomization for `meta-bootstrap/` (depends on Ceph and Kopiur repositories).
   Select a suitable exact Snapshot or `fromPolicy.asOf` when necessary.
3. Wait for Restore Ready and the bootstrap Job Complete. The Job chooses the
   latest native LMDB snapshot, copies it into `db.lmdb/data.mdb`, verifies its
   bytes, checks identity/layout presence and writable ownership 568:568, and
   validates all database entries with Garage's supported LMDB-to-SQLite
   conversion into disposable scratch space. SQLite is **only a validator**;
   Garage remains configured for LMDB.
4. Review the native recovery timestamp and object-data availability. Through
   Git change only the Garage metadata existingClaim to `garage-meta-recovered`,
   start one instance, verify original node/layout/partition and object health,
   then reopen clients. Keep the prior claim/source intact.
5. Remove temporary bootstrap Job/Restore registration through Git after recovery;
   retain the recovered PVC and final backup protection for the active claim.

The isolated R2 restore proof uses the same normalization and native database
validation, without stopping or starting the production Garage service.

## Migration safety sources

Old NFS metadata is intentionally retained and unchanged. It became an unsafe
ordinary rollback as soon as Garage restarted on Ceph: housekeeping and client
writes can mutate metadata. An approved rollback requires a fresh offline reverse
copy or an appropriate restore; simply switching back to old NFS metadata is not
safe. The 200Gi migration recovery PVC is temporary, contained verified offline
metadata but incomplete object-data recovery, and was removed through GitOps after an
independent post-cutover metadata backup and isolated restore validation succeeded.
Its PVC/PV and active RBD image are gone; Ceph asynchronously reclaims the trashed
image. Temporary migration/inspection/copy/diagnostic/stop/S3/restore/test workloads,
RBAC, projected test credentials and cleanup helpers have been removed. The two
persistent Kopiur cache claims are intentionally retained for ongoing backups.
