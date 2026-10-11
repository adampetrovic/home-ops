# Optional upload details rollout

These manifests prepare configuration only. Both existing image digests are unchanged;
`STASH_UPLOADER_DETAILS_ENABLED` stays `"false"`. Do not enable new clients against
the old pinned uploader image. Application builds and rollout require separate approval.

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
`STASH_PATH=/data`. `METADATA_QUEUE_DIR=/data/.stash-uploader-metadata` is a hidden,
persistent directory on the existing writable shared NFS mount, not an emptyDir.
Verify UID/GID 568 can create/write it and the Stash scan does not ingest queue files.
Do not delete queued work during rollout or rollback.

The uploader holds an exclusive process-lifetime `flock` on the durable queue;
a second process refuses startup. Keep `replicas: 1` and `strategy: Recreate`
for cold replacement: the old pod must terminate and release its lock before the
replacement starts. Expect a brief upload outage; RollingUpdate can deadlock
waiting for a replacement that cannot acquire the old process's lock.
Before rollout, verify the NFS server and client mounts enforce `flock` across
hosts (not merely local locks), including lock release and reacquisition after
termination. Replica count alone cannot protect against a stale process on
another node; treat missing cross-host lock enforcement as a rollout blocker.

`stash-uploader-secret` extracts the existing 1Password item mapping `stash` through
`onepassword-connect`, templating only the established `STASH_API_KEY` field (same
mapping as `web/externalsecret.yaml`). No resolved secrets are stored here.

The uploader NetworkPolicy isolates ingress only, so outbound TCP and DNS are not
restricted by it. The repository contains no namespace-wide or Cilium egress deny
for these pods. Stash ingress now permits same-namespace uploader pods on TCP 9999;
no external exposure or broad new egress allowance is needed. This is a manifest
review, not a live connectivity test.

To stop GDB sending details, set its flag back to `"false"`. Revert userscript
clients before reverting the uploader to a legacy image; disabling the GDB flag
does not disable independently deployed userscript clients.
