# Browser bookmark sync

Floccus synchronises desktop Helium's native bookmarks through a private WebDAV endpoint:

- URL: `https://browser-sync.petrovic.network/` (LAN/VPN only).
- Server: rclone WebDAV, one replica; Envoy terminates HTTPS.
- Authentication: HTTP Basic using the `browser-sync` item in the **k8s** 1Password vault.
- Storage: 1Gi Ceph PVC `browser-sync`, protected by hourly NFS and weekly R2 Kopiur policies.

No browser history, tabs, passwords, cookies, or settings are synced. Helium's service-provider setting stays unchanged. No interactive Authelia authentication is used because extension background requests cannot complete an SSO login.

## Credentials

The 1Password item contains:

| Field | Purpose |
|---|---|
| `username` | Floccus WebDAV username |
| `password` | Floccus WebDAV password |
| `htpasswd` | Matching bcrypt `username:hash` line, mounted into rclone via ExternalSecret |
| `floccus-passphrase` | Separate client-side encryption passphrase, never sent to the cluster |

Only `htpasswd` is materialised into Kubernetes. Never commit, print, or save resolved credentials to configuration files. For password rotation, update the password and matching bcrypt line together, let External Secrets/reloader update the server, and update every client. Changing the encryption passphrase is a separate client migration; retain the old passphrase until backups no longer need it.

## Initial setup

1. Export HTML bookmarks independently from **every** device and retain the exports somewhere safe outside this sync service.
2. Test the workflow using two disposable Helium profiles before enrolling real bookmark trees.
3. Install **Floccus** from the Chrome Web Store. Disable other bookmark-sync extensions for the selected folder.
4. Create a WebDAV sync profile using the URL above, the 1Password username/password, and a filename such as `bookmarks.xbel`.
5. Enable client-side encryption **before the first upload**, using `floccus-passphrase`. Use the same passphrase and remote filename on every client. Confirm the exact option names in your installed Floccus release.
6. Choose one authoritative device and one folder, for example Bookmarks Bar. Upload that folder first using Floccus's explicit overwrite-server/push strategy. Inspect its preview and deletion failsafe; do not bypass warnings blindly.
7. On a second device, select the corresponding folder and initially download the seeded data. If the device has unique bookmarks, preserve its export and merge those deliberately rather than overwriting them unnoticed.
8. Once the initial state is correct, switch to normal two-way merge sync. Test an add, rename, folder move, and deletion in both directions before enabling scheduled sync on all devices.

Bookmark-bar special/root folders differ between browsers: select a supported folder below the absolute browser root. If syncing another independent tree, use a separate profile and remote filename; never point unrelated folders at the same file. Do not configure tabs sync for this deployment.

## Validation and troubleshooting

- Confirm Flux Kustomization and HelmRelease readiness, ExternalSecret sync, and HTTPRoute `Accepted`/`ResolvedRefs`.
- Unauthenticated HTTPS requests must return **401**, not a login page or bookmark listing.
- Test authenticated WebDAV `MKCOL`, `PROPFIND` (207), `PUT`, `GET`, `MOVE`, and `DELETE` on a disposable collection. Use runtime credential injection, not shell command arguments or a plaintext `.netrc` file.
- Floccus host permission must allow the private hostname. Verify VPN DNS and trusted TLS if connection fails.
- On 401, verify the password matches the current bcrypt htpasswd line. On a decryption error, verify the separate Floccus passphrase; do not overwrite the remote file as a workaround.
- Test concurrent edits, repeated sync, and offline/reconnect using disposable profiles. A server outage should retry or report an error, not delete local bookmarks.
- Leave Floccus deletion failsafes enabled. A large-delete warning should trigger inspection and comparison with independent exports.
- Check backup status using `kubectl kopiur status -A --context=admin@home-kubernetes` and `kubectl kopiur doctor -A --context=admin@home-kubernetes`.
- Read `.pi/skills/kopiur/SKILL.md` before snapshot/restore operations. Restarts, manual snapshots, and restore rehearsals require operator approval.

## Recovery and removal

1. Pause Floccus on **all** clients before recovering old state.
2. Prefer an approved restore rehearsal into isolated storage; verify files and decryption using a disposable client before touching production.
3. Restore the desired WebDAV data through the approved Kopiur/GitOps workflow or re-seed from an independent bookmark export. Avoid reconnecting divergent clients without a deliberate initial direction.
4. Re-enable one client at a time, inspect previews/failsafes, then resume normal merge sync.

Disabling Floccus leaves native bookmarks intact. Keep the PVC/backups during rollback. If removing the application, explicitly decide whether to retain or delete Kopiur backups before pruning policies or persistent state.
