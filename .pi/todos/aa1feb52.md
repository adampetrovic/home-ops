{
  "id": "aa1feb52",
  "title": "Migrate all LoadBalancer Services to Cilium BGP",
  "tags": [
    "home-ops",
    "network",
    "cilium",
    "bgp",
    "unifi",
    "loadbalancer",
    "reliability"
  ],
  "status": "closed",
  "created_at": "2026-05-11T20:58:50.866Z"
}

# Migrate all LoadBalancer Services to Cilium BGP

Created: 2026-05-12 06:57 AEST

## Context

The Envoy Gateway VIP migration is complete and healthy:

- `network/envoy-internal` → `10.0.88.200/32`
- `network/envoy-external` → `10.0.88.201/32`
- Envoy is excluded from Cilium L2 announcements.
- UCG accepts only those exact `/32`s today via `K8S_CILIUM_VIPS` and `neighbor K8S_CILIUM maximum-prefix 2`.
- Cilium BGP is scoped to the two Envoy Services via `CiliumBGPAdvertisement/envoy-loadbalancers`.

This TODO tracks the follow-up migration from the current mixed model:

- Envoy: BGP-only on routed prefix `10.0.88.0/24`
- non-Envoy LoadBalancer Services: still Cilium L2-backed in the old `10.0.81.x` space

## Primary goal

Move all Kubernetes `LoadBalancer` Services to a controlled Cilium BGP model, ideally using only `/32` host routes from the routed Kubernetes LoadBalancer prefix `10.0.88.0/24`, then retire Cilium L2 announcements for LoadBalancers.

## Current LoadBalancer inventory

Snapshot from 2026-05-12:

| Namespace | Service | Current VIP | externalTrafficPolicy | Current path |
|---|---|---:|---|---|
| automation | mosquitto | `10.0.81.1` | Cluster | L2 |
| media | plex | `10.0.81.3` | Cluster | L2 |
| automation | home-assistant | `10.0.81.4` | Cluster | L2 |
| network | ntpd | `10.0.81.5` | Cluster | L2 |
| network | smtp-relay | `10.0.81.6` | Cluster | L2 |
| media | qbittorrent | `10.0.81.7` | Cluster | L2 |
| observability | vector-aggregator | `10.0.81.8` | Cluster | L2 |
| observability | influxdb | `10.0.81.9` | Cluster | L2 |
| network | adguard-dns | `10.0.81.10` | Cluster | L2 |
| database | postgres | `10.0.81.12` | Cluster | L2 |
| automation | go2rtc-streams | `10.0.81.14` | Cluster | L2 |
| removed-db-namespace | removed-db-cluster | `10.0.81.15` | Cluster | L2 |
| network | envoy-internal | `10.0.88.200` | Local | BGP |
| network | envoy-external | `10.0.88.201` | Local | BGP |

Current total: **14** LoadBalancer Services. Re-inventory before implementation; this list will drift.

Suggested draft target VIP map, preserving current final octets where practical:

| Service | Draft target VIP |
|---|---:|
| mosquitto | `10.0.88.1` |
| plex | `10.0.88.3` |
| home-assistant | `10.0.88.4` |
| ntpd | `10.0.88.5` |
| smtp-relay | `10.0.88.6` |
| qbittorrent | `10.0.88.7` |
| vector-aggregator | `10.0.88.8` |
| influxdb | `10.0.88.9` |
| adguard-dns | `10.0.88.10` |
| postgres | `10.0.88.12` |
| go2rtc-streams | `10.0.88.14` |
| removed-db-cluster | `10.0.88.15` |
| envoy-internal | `10.0.88.200` |
| envoy-external | `10.0.88.201` |

Confirm these before applying. Avoid `.0` and `.255`; keep `.200/.201` reserved for Envoy.

## Hard gates before starting

- [ ] Cilium release contains the BGP active-backend fix:
  - issue: https://github.com/cilium/cilium/issues/45276
  - main PR: https://github.com/cilium/cilium/pull/45286
  - v1.19 backport PR: https://github.com/cilium/cilium/pull/45673
  - v1.19 backport commit: `3d890fa25132c7ea72eda58df1b8b5ff4529c2ab`
- [ ] Cilium is upgraded to a release containing that fix.
- [ ] Controlled Envoy failover test is re-run after the Cilium upgrade and shows no brief `connection refused` window.
- [ ] UCG/UniFi access is confirmed independent of Envoy.
- [ ] UniFi Network backup is taken before changing BGP config.
- [ ] Current LoadBalancer inventory is refreshed.
- [ ] Current service consumers are identified, especially for DNS, MQTT, Postgres, Plex, NTP, SMTP, and InfluxDB.

## Design decisions to make

### 1. UCG route safety model

Choose one before expanding beyond Envoy.

#### Option A — exact `/32` allow-list per VIP

Pros: strongest guardrail; every advertised VIP must be pre-approved.

Cons: every future BGP-backed LoadBalancer requires UCG config changes.

Example:

```frr
ip prefix-list K8S_CILIUM_VIPS seq 10 permit 10.0.88.1/32
ip prefix-list K8S_CILIUM_VIPS seq 20 permit 10.0.88.3/32
...
ip prefix-list K8S_CILIUM_VIPS seq 200 permit 10.0.88.200/32
ip prefix-list K8S_CILIUM_VIPS seq 210 permit 10.0.88.201/32
neighbor K8S_CILIUM maximum-prefix 14
```

#### Option B — `10.0.88.0/24` host routes with capacity budget

Pros: future LoadBalancers inside the routed LB prefix do not need UCG edits until the budget is reached.

Cons: less strict than exact `/32`s, so Cilium selectors and monitoring become more important.

Example:

```frr
ip prefix-list K8S_CILIUM_VIPS seq 10 permit 10.0.88.0/24 ge 32 le 32
neighbor K8S_CILIUM maximum-prefix 20
```

Recommendation: use Option B with a small budget like `20` or `32`, not `254`, once the migration intentionally moves all LB VIPs into `10.0.88.0/24`. This still blocks broad prefixes, PodCIDRs, ClusterIPs, and anything outside the routed LB prefix.

### 2. Cilium advertisement selector

Avoid a blind "advertise every Service" selector. Prefer one of:

- explicit Service-name match list per migration wave; or
- label-based opt-in, e.g. `bgp.cilium.io/advertise=true`, applied only to migrated Services.

A label-based opt-in is better for future operations if paired with the UCG `10.0.88.0/24 ge 32 le 32` prefix-list and a maximum-prefix budget.

### 3. Cilium L2 policy steady state

Current policy is "announce all LoadBalancer IPs except Envoy". For migration, either:

- change L2 to an opt-in label such as `l2.cilium.io/announce=true`, then remove that label wave by wave; or
- keep adding exclusions for migrated Services until the final cutover, then disable L2 announcements entirely.

Prefer the opt-in label model if many Services remain L2 during a staged rollout.

### 4. Monitoring thresholds

Current alert assumes exactly two BGP routes. Update it with each wave or convert it to a budget model:

- expected route count: all currently migrated BGP VIPs
- hard maximum: UCG `maximum-prefix` budget
- alert on route count exceeding the approved count/budget
- retain blackbox/TCP probes for critical VIPs

## Rollout plan

### Phase 0 — refresh baseline

- [ ] Re-run inventory:
  ```bash
  kubectl get svc -A --field-selector spec.type=LoadBalancer -o wide
  kubectl get leases -n kube-system | grep cilium-l2announce
  kubectl get ciliumbgpnodeconfigs -o wide
  ssh root@10.0.0.1 'vtysh -c "show bgp ipv4 unicast summary" -c "show bgp ipv4 unicast" -c "show ip route bgp"'
  ```
- [ ] Record current DNS answers for all affected hostnames/VIPs.
- [ ] Record UCG firewall/address-group references for old `10.0.81.x` VIPs.
- [ ] Confirm all non-Envoy LoadBalancers still use `externalTrafficPolicy: Cluster`, unless intentionally changed.

### Phase 1 — prepare guardrails

- [ ] Update `kubernetes/apps/kube-system/cilium/ucg-cilium-bgp.conf` with the selected prefix-list model and new `maximum-prefix`.
- [ ] Upload the BGP config through UniFi UI, not only via transient `vtysh`.
- [ ] Verify live FRR and persisted UniFi config contain the intended prefix-list, route-map, and maximum-prefix.
- [ ] Update Prometheus alert threshold(s) for the intended wave.
- [ ] Add blackbox/TCP probes for any critical non-HTTP services before moving them.

### Phase 2 — migrate a low-risk pilot service

Pick one low-risk non-critical Service first, e.g. `network/smtp-relay` or `observability/vector-aggregator` if client impact is understood.

For each service in the wave:

- [ ] Assign a stable `10.0.88.x` VIP using the appropriate manifest/annotation for that app.
- [ ] Add/apply the BGP opt-in selector or add the Service to the explicit Cilium BGP advertisement list.
- [ ] Exclude the Service from Cilium L2 or remove its L2 opt-in label.
- [ ] Update DNS/firewall/client references from old `10.0.81.x` to new `10.0.88.x` where applicable.
- [ ] Let Flux reconcile.
- [ ] Verify UCG learns only the intended new `/32` route(s).
- [ ] Verify old L2 lease for the migrated Service is gone.
- [ ] Verify service reachability from local host, UCG, and a representative client VLAN.
- [ ] Observe for at least one normal usage cycle.

### Phase 3 — migrate remaining services in waves

Suggested order, subject to updated risk assessment:

1. low-risk internal infra: `smtp-relay`, `ntpd`, `vector-aggregator`
2. media/user-facing but less core: `qbittorrent`, `plex`, `go2rtc-streams`
3. observability/data: `influxdb`
4. automation/control plane dependencies: `mosquitto`, `home-assistant`
5. DNS: `adguard-dns` only after client resolver paths and fallback are clearly understood
6. databases: `postgres`, `removed-db-cluster` only after consumers and firewall paths are confirmed

Do not batch DNS, MQTT/Home Assistant, and databases in the same wave.

### Phase 4 — retire Cilium L2 for LoadBalancers

After every intended LoadBalancer is BGP-backed and stable:

- [ ] Confirm no required LoadBalancer remains on the old `10.0.81.x` range.
- [ ] Confirm no `cilium-l2announce-*` leases are required.
- [ ] Disable or narrow `CiliumL2AnnouncementPolicy` so it no longer announces LoadBalancer IPs by default.
- [ ] Remove old `10.0.81.x` DNS/firewall references.
- [ ] Update `unifi-config` documentation with final BGP prefix-list/max-prefix policy.
- [ ] Update `home-ops` AGENTS/docs with the steady-state LoadBalancer policy for future apps.

## Validation checklist per wave

- [ ] Flux Kustomizations and HelmReleases ready:
  ```bash
  flux get kustomizations --all-namespaces --status-selector ready=false
  flux get helmreleases --all-namespaces --status-selector ready=false
  ```
- [ ] Services show expected VIPs:
  ```bash
  kubectl get svc -A --field-selector spec.type=LoadBalancer -o wide
  ```
- [ ] BGP peers established and expected route count:
  ```bash
  kubectl get ciliumbgpnodeconfigs -o wide
  ssh root@10.0.0.1 'vtysh -c "show bgp ipv4 unicast summary"'
  ```
- [ ] UCG BGP table contains only approved `10.0.88.x/32` routes:
  ```bash
  ssh root@10.0.0.1 'vtysh -c "show bgp ipv4 unicast"'
  ssh root@10.0.0.1 'ip route | grep -E "10\.0\.88\.|10\.69\.|10\.96\." || true'
  ```
- [ ] No old L2 lease for migrated Services:
  ```bash
  kubectl get leases -n kube-system | grep cilium-l2announce
  ```
- [ ] TCP/UDP checks pass from the agent host, UCG, and representative client VLANs.
- [ ] Prometheus has no firing `Envoy|Cilium|TargetDown|Endpoint|Gateway` alerts and new service-specific probes are healthy.

## Rollback principles

- Keep changes small enough that each wave can be reverted independently.
- If a migrated service fails, prefer reverting that service's VIP/selector/L2 change rather than disabling all BGP.
- If unexpected routes appear, immediately remove or disable the expanded UniFi BGP config and narrow Cilium advertisement back to Envoy-only.
- If L2 is still enabled for the service, restore its old VIP/L2 selector and verify the L2 lease holder has a usable endpoint.
- Do not delete leases or mutate live resources without explicit operator confirmation.

## Completion criteria

- [ ] All intended LoadBalancer Services use stable VIPs in `10.0.88.0/24`.
- [ ] UCG accepts only host routes from the approved routed LB prefix and has a deliberate `maximum-prefix` budget.
- [ ] Cilium advertises only approved LoadBalancer VIPs.
- [ ] No LoadBalancer depends on Cilium L2 announcements.
- [ ] Monitoring and docs reflect the final route count/budget and future app workflow.

### 2026-05-12 — Closed as completed/superseded

This older migration TODO was left open after the work moved to TODO-c7ae6934 / GitHub issue #2625.

Final outcome is complete and healthy:

- All Kubernetes LoadBalancer Services now use routed Cilium BGP VIPs in `10.0.88.0/24`.
- No legacy `10.0.81.x` LoadBalancer VIPs remain.
- BGP advertisement remains opt-in via `lb-transport=bgp` for non-Envoy Services.
- UCG inbound filtering allows only `10.0.88.0/24` host routes (`ge 32 le 32`).
- Cilium advertises 15 routes per node; sessions are established on all five nodes.
- No Cilium L2 leases exist for BGP-labelled Services.
- Configured blackbox probes are healthy and no relevant BGP/Envoy/Cilium/TargetDown alerts are firing.
- GitHub issue #2625 was closed; final notes are in TODO-c7ae6934.
