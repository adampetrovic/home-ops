# Logseq DB Sync

Private sync-only Node adapter for existing Logseq DB graphs. Clients use
`https://logseq-sync.petrovic.network` in Settings → Advanced → Sync server URL.
Remote clients need private-network access; this app has no public route.

## Authentication and storage

- Clients still sign in through Logseq's Cognito service. The server validates
  those tokens and checks graph access. No independent user allowlist is configured.
- Do not add Authelia proxy authentication: browser redirects can interfere with
  native-client HTTP and WebSocket requests.
- SQLite databases and filesystem assets are stored together in the `logseq-sync`
  Ceph PVC at `/app/data`. One replica and `Recreate` prevent overlapping writers.
- Kopiur protects the PVC with hourly NFS and weekly R2 snapshots. Live volume
  snapshots are crash-consistent; application consistency must be tested.

## Pinned image limitations

The image tracks Logseq revision `f3beb333dbd4e9209425dc9ed5b94620b789f6c0`.

- The Node adapter does not forward `DB_SYNC_ADMIN_TOKEN`; configuring the
  variable has no effect. Admin access fails closed, so no admin secret is supplied.
- `DB_SYNC_ALLOW_UNVERIFIED_JWT_CLAIMS` is explicitly disabled.
- The entrypoint has no graceful SIGTERM handler. Do not assume restarts drain
  in-flight sync or WebSocket connections.
- `/health` is a shallow process check, not a database integrity check.
- Renovate upgrades are disabled during initial client compatibility and restore
  verification. Review client/server compatibility and backups before upgrading;
  rolling back an image alone may not reverse database changes.
- The sibling Worker image has incompatible storage. Do not swap images on this PVC.

## Acceptance testing

Use a disposable DB graph before changing the primary graph's sync destination.

1. Verify HTTPS `/health` returns `200` with `{"ok":true}`; unauthenticated
   `/graphs`, `/sync/<graph-id>/pull?since=0`, and WebSocket sync access are rejected.
2. Set the server URL independently on two clients. Create a disposable graph and
   confirm it is discoverable on the second client after signing in.
3. Test bidirectional edits, offline edits and reconnect, and attachment uploads
   and downloads. Leave the clients connected long enough to detect idle timeouts.
4. With operator approval, test a GitOps-managed restart and confirm persistence
   and reconnection. Avoid edits while restarting.
5. After approval, snapshot and restore the test data into an isolated test PVC
   and app via Git-tracked manifests. Verify graph contents, attachments, and sync
   before calling the backup application-consistent.
6. Preserve an export and the original sync configuration before switching the
   primary graph. Follow the client's supported migration workflow.
