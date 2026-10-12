# Optional upload details rollout

The rollout is staged: stash-uploader 0.1.5 was deployed first and production
image/video smoke tests passed on 2026-10-12 (Australia/Sydney), including legacy
uploads, automatic scans, Details updates and synthetic-item cleanup. GDB 1.10.85
is pinned in the follow-up deployment with `STASH_UPLOADER_DETAILS_ENABLED: "true"`.
Do not enable details-sending clients against a legacy uploader image.

1. Build/publish the details-capable stash-uploader in its source repository, then
   update `stash-uploader/app/helmrelease.yaml` to its real immutable tag+digest first.
   Verify readiness, a legacy upload without `details`, and an upload with `details`
   that completes the background Stash scan and Details update before proceeding.
   Requests without `details` must retain the legacy behavior.
2. Build/publish gdb-web with the default-false feature flag, pin its real new
   tag+digest in `web/helmrelease.yaml` (and align `APP_VERSION`), then enable
   `STASH_UPLOADER_DETAILS_ENABLED: "true"` only after uploader verification.
3. Roll out the details-sending userscript last, after verifying GDB uploads.

Uploader configuration uses `http://stash.gdb.svc.cluster.local:9999/graphql` and
`STASH_PATH=/data`. The existing `/data` NFS media mount remains unchanged; its actual
runtime options include `vers=3,nolock,local_lock=all`. This is acceptable for media,
but cannot provide cross-host `flock` exclusion for the metadata queue.

`METADATA_QUEUE_DIR=/metadata` uses the dedicated `stash-uploader` 1Gi Ceph RWO PVC
(`ceph-block`), created by the Kopiur backup component with `APP=stash-uploader`.
The component supplies hourly NFS and weekly R2 backups and the standard passive
restore; a missing snapshot is allowed on first install. The old deployed uploader
has no metadata support and there are no existing queue jobs, so no queue migration
from `/data` is needed. The pod runs as UID/GID 568 with `fsGroup: 568`; verify it can
create/write queue files on `/metadata`. Queue files are outside Stash's media scan.
Do not delete queued work or the PVC during rollout or rollback.

The uploader holds an exclusive process-lifetime `flock` on the durable queue;
a second process refuses startup. Keep `replicas: 1` and `strategy: Recreate`
for cold replacement: the old pod must terminate and release its lock before the
replacement starts. Expect a brief upload outage; RollingUpdate can deadlock
waiting for a replacement that cannot acquire the old process's lock.
Cross-node exclusion relies on Ceph RBD/CSI exclusive attachment and fencing for
the RWO queue volume, not cross-host NFS locks. RWO does not prevent multiple pods
on the same node, so retain both cold replacement and the process lock. Verify
queue persistence and lock release/reacquisition after a normal restart. During
node failover, confirm the old writer is terminated or fenced before the volume
is attached on another node; do not force-detach around an unfenced stale writer.
There is no cross-host NFS locking requirement for the media mount.

`stash-uploader-secret` extracts the existing 1Password item mapping `stash` through
`onepassword-connect`, templating only the established `STASH_API_KEY` field (same
mapping as `web/externalsecret.yaml`). No resolved secrets are stored here.

The uploader NetworkPolicy isolates ingress only, so outbound TCP and DNS are not
restricted by it. The repository contains no namespace-wide or Cilium egress deny
for these pods. Stash ingress now permits same-namespace uploader pods on TCP 9999;
no external exposure or broad new egress allowance is needed. Production image/video Details smoke tests verified uploader-to-Stash connectivity.

To stop GDB sending details, set its flag back to `"false"`. Revert userscript
clients before reverting the uploader to a legacy image; disabling the GDB flag
does not disable independently deployed userscript clients.
