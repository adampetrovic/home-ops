{
  "id": "f3dd63bb",
  "title": "Make AdGuard DNS/DoH highly available",
  "tags": [
    "home-ops",
    "network",
    "adguard",
    "dns",
    "doh",
    "ha",
    "reliability"
  ],
  "status": "open",
  "created_at": "2026-05-14T21:52:41.081Z",
  "assigned_to_session": "019e2887-5eb9-708d-921f-e0943f302116"
}

# Make AdGuard DNS/DoH highly available

## Context

During the `k8s-node-3` hard hang on 2026-05-15 AEST, AdGuard could not fail over cleanly. Kubernetes created a replacement pod on another node, but the single `network/adguard` RWO Ceph block PVC remained attached to the unreachable node, causing `Multi-Attach` and leaving DNS/DoH unavailable until the node was power-cycled.

MacBooks using the DNSSettings profile were pinned to `https://dns.${SECRET_DOMAIN}/dns-query/adam-laptop` via `10.0.88.53`; `AllowFailover=true` did not fail over quickly enough because the managed DoH resolver remained sticky. Disabling the profile made DHCP DNS work immediately.

## Goal

Keep the existing stable DNS/DoH endpoint (`dns.${SECRET_DOMAIN}`, `10.0.88.53`) but remove AdGuard's single-PVC single-pod failure mode so DNS and native macOS DoH survive a hard node failure.

## Proposed design

Adopt the Gabe-style active/active AdGuard pattern:

1. Convert AdGuard from a single-replica Deployment with one shared PVC to a StatefulSet with `replicas: 2`.
2. Give each AdGuard pod its own RWO PVC via StatefulSet `volumeClaimTemplates`.
3. Add pod anti-affinity/topology spread so the two replicas land on different nodes.
4. Run `ghcr.io/bakito/adguardhome-sync` as a separate controller to sync configuration from origin (`adguard-0`) to replica (`adguard-1`).
5. Keep a shared `adguard-dns` LoadBalancer at `10.0.88.53` selecting both AdGuard pods for DNS/DoH/DoT.
6. Expose the admin UI primarily to the origin pod, with an optional replica UI route for troubleshooting.
7. Keep both pods serving the same TLS certificate/hostname for `dns.${SECRET_DOMAIN}` so the existing macOS DoH profile can continue using one `ServerURL` and `ServerAddresses: [10.0.88.53]`.

## Implementation notes

- Current manifest: `kubernetes/apps/network/adguard/app/helmrelease.yaml`
- Current PVC: `network/adguard`, `ceph-block`, RWO, 5Gi
- Current service IP: `10.0.88.53`
- Reference patterns:
  - Stateless/config-in-Git approach: `ahinko/home-ops` AdGuard Home
  - Stateful origin/replica + `adguardhome-sync`: `gabe565/home-ops` AdGuard Home
- `adguardhome-sync` needs credentials for both AdGuard instances. Store them via ExternalSecret/1Password; do not commit plaintext.
- Decide whether to preserve current query logs/stats or treat them as per-replica/non-critical.
- Consider whether AdGuard config should remain UI-managed + synced, or move toward Git-declared config later.

## Migration plan

1. Export/backup current AdGuard config from the existing PVC/UI.
2. Put the operator MacBook into a safe test posture before changing cluster DNS:
   - Disable the DNSSettings/DoH profile temporarily.
   - Pin the MacBook's active network DNS to the gateway (`10.0.0.1`) so day-to-day connectivity does not depend on AdGuard during rollout.
   - Use explicit test commands against AdGuard (`@10.0.88.53`) instead of relying on the system resolver while validating failover.
3. Baseline current behaviour before changing manifests:
   - `dig @10.0.0.1 example.com` — confirm gateway DNS works independently.
   - `dig @10.0.88.53 example.com` — confirm AdGuard UDP DNS works.
   - `dig +tcp @10.0.88.53 example.com` — confirm AdGuard TCP DNS works.
   - DoH transport smoke test against the VIP, e.g. `curl --resolve 'dns.${SECRET_DOMAIN}:443:10.0.88.53' -sS -o /dev/null -w '%{http_code}\n' 'https://dns.${SECRET_DOMAIN}/dns-query/adam-laptop'`; a non-timeout HTTP response proves TLS/HTTP reaches the service, but this is not a full DNS answer test.
   - If a DoH-capable CLI is available (`kdig`, `dnslookup`, `doggo`, etc.), use it to perform a real DoH query through `10.0.88.53` with SNI/Host `dns.${SECRET_DOMAIN}`.
4. Create new StatefulSet-backed configuration with two PVCs while preserving the existing `10.0.88.53` service name/IP.
5. Bootstrap origin from the current config.
6. Enable `adguardhome-sync` and verify replica auto-setup + sync.
7. Verify both pods answer:
   - UDP/TCP 53
   - DoH on `https://dns.${SECRET_DOMAIN}/dns-query/...`
   - DoT on 853 if still required
8. Verify the shared `adguard-dns` Service has two ready endpoints and no endpoint points at a NotReady pod.
9. Failover test with the MacBook still pinned to gateway DNS:
   - Identify which node hosts each AdGuard pod.
   - Run a loop from the MacBook such as `while true; do date; dig +time=1 +tries=1 @10.0.88.53 example.com; sleep 1; done`.
   - In a controlled maintenance window, remove one AdGuard backend at a time (pod-level first, then node-level if needed) and confirm `10.0.88.53` continues resolving through the surviving backend.
   - Repeat for UDP and TCP DNS.
   - Separately smoke-test DoH transport during each backend failure.
10. Only after explicit service-level failover passes, re-enable the macOS DNSSettings/DoH profile and validate with macOS system resolver paths, not only `dig`:
    - `scutil --dns` — confirm the managed resolver is active.
    - `dscacheutil -q host -a name example.com` — exercises the macOS resolver stack.
    - Browser/curl test to normal websites.
    - Then repeat a controlled single-pod AdGuard failure and confirm the MacBook does not require manually disabling the profile.
11. Remove or archive the old single shared PVC only after the new setup is stable and backups exist.

## Acceptance criteria

- Two AdGuard pods are Running on different nodes.
- Each pod has an independent PVC.
- `adguardhome-sync` reports successful sync from origin to replica.
- `adguard-dns` LoadBalancer remains `10.0.88.53` and has two ready endpoints.
- DNS/DoH resolution continues when either AdGuard pod is unavailable.
- A hard failure of one node does not block the surviving AdGuard pod on RWO multi-attach.
- During rollout, the operator MacBook remains pinned to gateway DNS (`10.0.0.1`) until explicit `dig`/DoH tests against AdGuard pass.
- `dig @10.0.88.53` and `dig +tcp @10.0.88.53` continue succeeding during single-AdGuard-pod failure.
- MacBook DNSSettings profile continues to work without manual disablement during single-AdGuard-pod failure.

## Rollback

- Keep current AdGuard PVC and manifests recoverable until validation completes.
- If sync/StatefulSet migration fails, revert to the current single-replica HelmRelease and reattach the original `network/adguard` PVC.
