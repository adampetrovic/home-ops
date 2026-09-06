# Paperless direct scanner inbox

The Brother MFC-L2750DW (`10.0.40.7`) writes PDFs to
`\\10.0.88.15\consume` using the dedicated `scanner` account. Samba runs beside
Paperless in the **same pod**, so the existing RWO Ceph-block PVC can be shared
without a second PVC attachment or an NFS mount.

## Storage and security boundaries

- Paperless keeps `/data/media`, `/data/data` and `/data/export` unchanged on PVC
  `paperless-ngx`. Consumption moves from `/library/consume` to `/data/scan-inbox`.
- Samba mounts **only** the `scan-inbox` subPath of that PVC at `/scan-inbox`.
  Its `/data` is a separate, size-limited `emptyDir` for Samba databases/cache.
  It cannot browse the document library, exports, or Paperless application data.
- A root init container rejects an inbox symlink, creates the inbox and sets
  **only that directory** to `568:100`, mode `0770`. There is no recursive chown
  of `/data` or new pod-wide `fsGroup` traversal. Samba's Unix account matches
  Paperless's existing `USERMAP_UID=568` / `USERMAP_GID=100`; files use `0660`.
- The workload has one replica and uses `Recreate` (brief UI/scanning downtime
  during upgrades). The existing HTTP Service name and Authelia route remain.
- The old NAS mount is removed from **all** containers, including Gotenberg and
  Tika. No NAS source data is copied, removed or migrated. The old inbox was
  approved as disposable; it will simply stop being watched. VolSync configuration
  is unchanged: the primary backup target still uses NAS, with R2 secondary.
- SMB2/3 only; NTLMv2 only; no guests, SMB1, NTLMv1, NetBIOS/139, discovery,
  host networking, recycling, wide links or followed symlinks. No public route.
  SMB encryption/signing negotiation uses Samba defaults; this is not a promise
  of mandatory transport encryption on this trusted routed LAN path.
- `paperless-ngx-scanner` exposes **TCP 445 only** at BGP VIP `10.0.88.15`.
  This address was unused in repository allocations and live Services when added.
  Current Cilium IPAM covers `10.0.88.0/24` and advertises all LoadBalancer IPs;
  this is **not** the old Envoy-only BGP configuration in the UniFi notes.
- `externalTrafficPolicy: Local` preserves the printer source address and restricts
  BGP advertisement to ready local endpoints. NodePort allocation is disabled.
  `loadBalancerSourceRanges`, a **Paperless-pod-only** NetworkPolicy and Samba's
  host ACL all restrict SMB to `10.0.40.7`. Loopback is allowed in Samba for local
  control; pod-local traffic shares a trust boundary with the other sidecars.
- The NetworkPolicy preserves HTTP/80 ingress, does not restrict egress or touch
  namespace-wide policies, and blocks remote access to internal Tika/Gotenberg
  ports (Paperless uses localhost). Kubelet health traffic and loopback are not
  blocked by this policy. Source IP ACLs are defence in depth, **not identity**:
  a compromised printer or host spoofing its address still needs the SMB password.
  Do not allow router/intermediary SNAT or widen ACLs to a node/router subnet to
  make a broken connection work. Confirm the observed source during acceptance.

### Image startup exception

`ghcr.io/crazy-max/samba:4.23.8` is pinned by OCI index digest. Its release source
is `crazy-max/docker-samba` tag `4.23.8-r0` (the container tag omits `-r0`).
This image starts as root: `/init` creates accounts in `/etc`, writes
`/etc/samba/smb.conf` and `/etc/services.d`, and replaces `/var/lib/samba` and
`/var/cache/samba` with links into its own `/data`. An immutable root filesystem
is **not compatible with its unmodified entrypoint**. We explicitly retain a
writable container root rather than masking the entire `/etc` with an emptyDir
or replacing upstream startup code.

The container drops all capabilities, then adds only account/file ownership,
UID/GID switching, chroot, low-port bind and process termination capabilities
(`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`, `SYS_CHROOT`,
`NET_BIND_SERVICE`, `KILL`). No privileged mode, `SYS_ADMIN`, `NET_ADMIN`, or
`NET_RAW`; privilege escalation is disabled and seccomp uses `RuntimeDefault`.
`smbd` switches to `scanner` for share I/O. Treat a root sidecar as part of the
Paperless pod's trust boundary, not as a sandbox for hostile code.

Startup/readiness/liveness use `smbcontrol smbd ping`, which checks the local
Samba daemon. Upstream's anonymous `smbclient` healthcheck is unsuitable after
turning off guest mapping. These checks do not prove an authenticated scanner
upload works. Runtime startup with this reduced capability set must be verified
before production acceptance; no container engine was available on the authoring
machine to run that test.

## Before merging / rollout prerequisites

This change is **PR-only**. Do not merge until the secret exists and the firewall
rule is ready. Do not manually apply the manifests to bypass Flux.

1. **1Password:** in vault **`k8s`**, edit the existing item **`paperless`** and add
   a top-level **concealed/password field** named exactly **`SCANNER_PASSWORD`**.
   Generate a unique 24-character alphanumeric password in 1Password (one line,
   no spaces/newlines; comfortably within common Brother firmware limits).
   Reference: `op://k8s/paperless/SCANNER_PASSWORD`.
   No username field or new item is needed; the SMB username is fixed as `scanner`.
   Do not reuse or change `ADMIN_PASS`, the NAS password or database credentials.
   ExternalSecret `paperless-scanner` creates `paperless-scanner-secret` with key
   `password`; it is mounted read-only, mode `0400`, only into Samba. Neither a
   plaintext password nor a real credential was generated/retrieved for this PR.
2. **UniFi UI, manual:** add an Allow rule named `printer-to-paperless-smb`:
   source zone **Cameras**, source IP **`10.0.40.7/32`**; destination zone
   **Internal**, destination IP **`10.0.88.15/32`**; **TCP destination port 445**;
   enable **Auto Allow Return Traffic**. Put it before the Cameras → Internal
   catch-all block. Ensure the routed `10.0.88.0/24` network is in Internal and
   that inter-VLAN traffic is not source-NATed. No 139/UDP/discovery or subnet-wide
   allow is required. This PR does not change the gateway.
3. Confirm printer DHCP reservation/address, unused VIP `10.0.88.15`, the current
   UCG BGP policy, PVC free space and healthy recent backups. The existing claim
   remains 20Gi; an unavailable consumer can fill it and affect the library.
4. Ensure no scan is in progress; review and merge separately when ready. Flux
   will recreate the pod. If the scanner secret is missing, the new pod cannot
   start, causing Paperless downtime. Check ExternalSecret Ready, init completion,
   Samba logs, pod readiness, Service endpoint and BGP next-hop before configuring
   the printer. Do not print the secret or dump all container environment values.

## Brother setup and acceptance

In Brother Web Based Management, create a **Scan to Network / CIFS** profile
(menu wording varies by firmware):

| Setting | Value |
|---|---|
| Profile name | Paperless |
| Network folder path | `\\10.0.88.15\consume` |
| Username | `scanner` (if a domain is required, `WORKGROUP\scanner`) |
| Password | Value of `k8s / paperless / SCANNER_PASSWORD` |
| Authentication | NTLMv2, or Auto if that is the only supported setting |
| Port, if shown | TCP 445 |
| File type | PDF (multi-page where desired); avoid encrypted/password PDF |
| File name | Unique date/time or sequential suffix for **every** scan |
| Resolution | 300 dpi to start |

Brother's listed CIFS capability does **not** prove the installed firmware's SMB
dialect. Run the profile connection test and scan a harmless single-page PDF,
then a slow/multi-page duplex job. Confirm the complete page count in Paperless,
correct `568:100` file ownership, and removal from the inbox after consumption.
If SMB negotiation/authentication fails, check firmware/profile/logs; **do not**
downgrade to SMB1/NTLMv1 or allow guests. Stop and reassess compatibility instead.

Also verify HTTP/Authelia still works and TCP 445/authenticated share access is
rejected from a non-printer host. Validate the actual source with packet capture
or Cilium observability (must be `10.0.40.7`, not a node or gateway IP). The Samba
pod should be the sole ready endpoint and UCG's next-hop should be that node.
No live deployment, printer upload or firewall mutation was performed for this PR.

## Completion, retries and recovery

Paperless **3.1.3** supports `PAPERLESS_CONSUMER_POLLING_INTERVAL=10` and
`PAPERLESS_CONSUMER_STABILITY_DELAY=120`: during normal watching, a file must have
unchanged size and mtime for 120 seconds before consumption. This increases the
five-second stability default for scanner uploads; expect a few minutes' delay.
Do not use the removed Paperless 2.x polling/retry variables.

A stability delay is **not an SMB close/atomic-commit guarantee**. A scanner
pausing longer than 120 seconds mid-file, or an interrupted upload left in the
inbox, can still look stable. Additionally, Paperless 3.1.3's startup scan queues
existing files immediately, before the stability watcher starts: a consumer
restart during an upload can bypass the delay. Stop scanning before planned
restarts and inspect interrupted jobs after crashes. Test the longest real job
before relying on direct scanning; increase the delay if appropriate. If the printer writes under a
fixed final filename for arbitrarily long pauses, this design cannot guarantee
completion without a separate staging/commit mechanism and should not be accepted
for unattended use. No custom ingestion daemon is introduced by this change.

- Always use unique filenames. Reusing a name can overwrite a still-pending scan;
  content duplicate detection does not prevent filename collisions.
- The existing `PAPERLESS_CONSUMER_DELETE_DUPLICATES=true` is retained: a successful
  duplicate detection removes the inbox copy, not the existing library document.
- A container/pod restart preserves pending scans on the Ceph PVC, but interrupts
  active SMB transfers. Samba credentials/runtime are recreated from the Secret.
  Review Paperless task failures, verify failed PDFs are complete, then rescan
  with a **new filename**. Do not blindly delete inbox contents or assume every
  failed upload is retried automatically.
- Inspect suspect/partial files before moving them out of the inbox for manual
  recovery; do not change library ownership or copy the old NAS inbox wholesale.
- Password rotation: update the 1Password field, wait for ExternalSecret refresh
  and Reloader to restart the pod (Samba loads passwords at startup), then update
  the printer. Avoid rotation during a scan.
- Rollback: stop new scans first and inventory pending `/data/scan-inbox` files.
  Reverting this change restores the old NFS consumption path but **does not
  delete or consume** the new inbox; recover those files deliberately. Do not
  delete/recreate the PVC or NAS source. Helm failure rollback has the same caveat.

## Validation and sources

Validated without deploying: app Kustomize build; Helm lint and render against
repository-pinned **app-template 5.1.0** (not the older v4 assumption); JSON schemas
for HelmRelease, ExternalSecret, Kustomization and NetworkPolicy; rendered core
resource schemas and targeted assertions for mounts, selectors, Service/route
names, source filters and secret isolation. Container startup, `testparm`, reduced
capabilities, SMB authentication and physical Brother compatibility remain runtime
acceptance checks because the local Docker daemon is unavailable.

Sources:
- [Pinned Samba release README](https://github.com/crazy-max/docker-samba/blob/4.23.8-r0/README.md)
- [Samba account/config startup](https://github.com/crazy-max/docker-samba/blob/4.23.8-r0/rootfs/etc/cont-init.d/01-config.sh)
- [Samba Dockerfile](https://github.com/crazy-max/docker-samba/blob/4.23.8-r0/Dockerfile)
- [Upstream healthcheck](https://github.com/crazy-max/docker-samba/blob/4.23.8-r0/rootfs/usr/local/bin/healthcheck)
- [Paperless 3.1.3 consumer configuration](https://github.com/paperless-ngx/paperless-ngx/blob/v3.1.3/docs/configuration.md#PAPERLESS_CONSUMER_STABILITY_DELAY)
- [Paperless 3.1.3 stability implementation](https://github.com/paperless-ngx/paperless-ngx/blob/v3.1.3/src/documents/management/commands/document_consumer.py)
