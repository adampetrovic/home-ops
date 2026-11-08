#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only checks to run before and after a Talos or Kubernetes upgrade.
# Exits non-zero when anything needs a look.

ALERTMANAGER="/api/v1/namespaces/observability/services/kube-prometheus-stack-alertmanager:9093/proxy"
problems=0

section() {
    printf '\n== %s\n' "$1"
}

fail() {
    printf '  FAIL %s\n' "$1"
    problems=$((problems + 1))
}

section "Nodes"
nodes="$(kubectl get nodes -o json)"
jq -r '.items[] | "  \(.metadata.name)  \(.status.nodeInfo.osImage)  kernel \(.status.nodeInfo.kernelVersion)  \(.status.nodeInfo.containerRuntimeVersion)"' <<<"${nodes}"
while read -r line; do
    [[ -n "${line}" ]] && fail "${line}"
done < <(jq -r '.items[] | select(([.status.conditions[] | select(.type == "Ready" and .status == "True")] | length) == 0) | "\(.metadata.name) is not Ready"' <<<"${nodes}")
while read -r line; do
    [[ -n "${line}" ]] && fail "${line}"
done < <(jq -r '.items[] | select(.spec.unschedulable == true) | "\(.metadata.name) is cordoned"' <<<"${nodes}")
while read -r line; do
    [[ -n "${line}" ]] && fail "${line}"
done < <(jq -r '.items[] | select([.spec.taints[]?.key] | index("tuppr.home-operations.com/outdated")) | "\(.metadata.name) still has the tuppr outdated taint"' <<<"${nodes}")
if [[ "$(jq -r '[.items[].status.nodeInfo.osImage] | unique | length' <<<"${nodes}")" != "1" ]]; then
    fail "nodes run different Talos versions"
fi

section "Tuppr"
kubectl get talosupgrades,kubernetesupgrades -o json \
    | jq -r '.items[] | "  \(.kind)/\(.metadata.name)  \(.status.phase // "-")  \(.status.message // "")"'
while read -r line; do
    [[ -n "${line}" ]] && fail "${line}"
done < <(kubectl get talosupgrades,kubernetesupgrades -o json \
    | jq -r '.items[] | select(.status.phase == "Failed" or ((.status.failedNodes // []) | length) > 0) | "\(.kind)/\(.metadata.name) failed: \(.status.failedNodes // [] | join(","))"')

section "Ceph"
ceph_health="$(kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health}')"
echo "  ${ceph_health}"
[[ "${ceph_health}" == "HEALTH_OK" ]] || fail "Ceph is ${ceph_health}"
osd_flags="$(kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd dump --format json | jq -r '.flags')"
if grep -qE 'noout|norebalance|nodown' <<<"${osd_flags}"; then
    fail "OSD flags left set: ${osd_flags}"
fi

section "CloudNativePG"
clusters="$(kubectl get clusters.postgresql.cnpg.io -A -o json)"
jq -r '.items[] | "  \(.metadata.namespace)/\(.metadata.name)  \(.status.readyInstances // 0)/\(.spec.instances) ready  primary \(.status.currentPrimary)"' <<<"${clusters}"
while read -r line; do
    [[ -n "${line}" ]] && fail "${line}"
done < <(jq -r '.items[] | select((.status.readyInstances // 0) != .spec.instances) | "\(.metadata.namespace)/\(.metadata.name) has unready instances"' <<<"${clusters}")

section "Kopiur schedules"
schedules="$(kubectl get snapshotschedules.kopiur.home-operations.com -A -o json --show-managed-fields)"
suspended="$(jq '[.items[] | select(.spec.schedule.suspend == true)] | length' <<<"${schedules}")"
residue="$(jq '[.items[] | select([.metadata.managedFields[]?.manager] | index("tuppr-upgrade"))] | length' <<<"${schedules}")"
echo "  $(jq '.items | length' <<<"${schedules}") schedules, ${suspended} suspended"
[[ "${suspended}" == "0" ]] || fail "${suspended} Kopiur schedules are still suspended"
[[ "${residue}" == "0" ]] || fail "${residue} Kopiur schedules still carry the tuppr-upgrade field manager"

section "Pods"
while read -r line; do
    [[ -n "${line}" ]] && fail "${line}"
done < <(kubectl get pods -A -o json \
    | jq -r '.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | "\(.metadata.namespace)/\(.metadata.name) is \(.status.phase)"')

section "Flux"
while read -r line; do
    [[ -n "${line}" ]] && fail "${line}"
done < <(kubectl get kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io -A -o json \
    | jq -r '.items[] | select(.spec.suspend != true) | select(([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) == 0) | "\(.kind) \(.metadata.namespace)/\(.metadata.name) is not Ready"')

section "LoadBalancers with externalTrafficPolicy Local"
while read -r namespace name address; do
    endpoint_nodes="$(kubectl -n "${namespace}" get endpointslices -l "kubernetes.io/service-name=${name}" -o json \
        | jq -r '[.items[].endpoints[]? | select(.conditions.ready == true) | .nodeName] | unique | join(",")')"
    echo "  ${namespace}/${name}  ${address}  ready on ${endpoint_nodes:-nothing}"
    [[ -n "${endpoint_nodes}" ]] || fail "${namespace}/${name} has no ready endpoints"
done < <(kubectl get svc -A -o json \
    | jq -r '.items[] | select(.spec.type == "LoadBalancer" and .spec.externalTrafficPolicy == "Local") | "\(.metadata.namespace) \(.metadata.name) \(.status.loadBalancer.ingress[0].ip // "-")"')

# Tuppr's silence lapses a few minutes after a run, so anything it hid shows here again
section "Firing alerts"
while read -r line; do
    [[ -n "${line}" ]] && fail "${line}"
done < <(kubectl get --raw "${ALERTMANAGER}/api/v2/alerts?active=true&silenced=false&inhibited=false" \
    | jq -r '.[].labels | select(.alertname != "Watchdog" and .alertname != "InfoInhibitor") | "\(.alertname) \(.namespace // "") \(.service // .instance // "")"' \
    | sort -u)

printf '\n'
if ((problems > 0)); then
    echo "${problems} problem(s) found"
    exit 1
fi
echo "All checks passed"
