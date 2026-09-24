#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo "Usage: $0 <single-node-ip-or-name> <talos-installer-image> [rollout=false]" >&2
}

NODE="${1:-}"
TALOS_IMAGE="${2:-}"
ROLLOUT="${3:-false}"

if [[ -z "${NODE// /}" ]]; then
    usage
    echo "Refusing to run Talos upgrade without an explicit node." >&2
    exit 64
fi

if [[ "${NODE}" == *","* ]]; then
    usage
    echo "Refusing to run single-node Talos upgrade with multiple nodes: ${NODE}" >&2
    exit 64
fi

if [[ -z "${TALOS_IMAGE// /}" ]]; then
    usage
    echo "Refusing to run Talos upgrade without an explicit installer image." >&2
    exit 64
fi

if [[ "${TALOS_IMAGE}" != factory.talos.dev/metal-installer/* ]]; then
    usage
    echo "Refusing unexpected Talos installer image: ${TALOS_IMAGE}" >&2
    exit 64
fi

node_name="$(kubectl get nodes -o json | jq -r --arg ip "${NODE}" \
    '.items[] | select(any(.status.addresses[]; .type == "InternalIP" and .address == $ip)) | .metadata.name')"
if [[ -z "${node_name}" || "${node_name}" == *$'\n'* ]]; then
    echo "Could not resolve exactly one Kubernetes node for ${NODE}." >&2
    exit 1
fi

echo "Waiting for active Job pods on ${node_name} before upgrading Talos ..."
for attempt in {1..30}; do
    active_jobs="$(kubectl get pods --all-namespaces --field-selector "spec.nodeName=${node_name}" -o json |
        jq -r '[.items[] | select(.status.phase == "Running" or .status.phase == "Pending")
            | select(any(.metadata.ownerReferences[]?; .kind == "Job"))
            | "\(.metadata.namespace)/\(.metadata.name)"] | join(", ")')"
    if [[ -z "${active_jobs}" ]]; then
        break
    fi
    if ((attempt == 30)); then
        echo "Active Job pods did not finish on ${node_name}: ${active_jobs}" >&2
        exit 1
    fi
    echo "Waiting for Job pods on ${node_name}: ${active_jobs}"
    sleep 10
done

active_backups="$(kubectl get snapshots,restores,snapshotreplications,repositoryreplications --all-namespaces -o json |
    jq -r '[.items[]
        | select(.status.phase? as $phase | $phase | IN("Pending", "Running", "Resolving", "Restoring", "Replicating", "Deleting"))
        | "\(.metadata.namespace)/\(.kind)/\(.metadata.name):\(.status.phase)"] | join(", ")')"
active_maintenance="$(kubectl get maintenance.kopiur.home-operations.com --all-namespaces -o json |
    jq -r '[.items[]
        | select(.status.manualRun.phase? == "Running")
        | "\(.metadata.namespace)/Maintenance/\(.metadata.name):Running"] | join(", ")')"
ceph_health="$(kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health}')"
if [[ -n "${active_backups}${active_maintenance}" || "${ceph_health}" != "HEALTH_OK" ]]; then
    echo "Upgrade blocked: active Kopiur work: ${active_backups:-none}${active_maintenance:+, ${active_maintenance}}; Ceph: ${ceph_health}" >&2
    exit 1
fi

suspended_kustomizations=""
resume_kustomizations() {
    result=$?
    trap - EXIT
    if [[ -n "${suspended_kustomizations}" ]]; then
        echo "Resuming Flux Kustomizations ..."
        while IFS=$'\t' read -r namespace name; do
            [[ -z "${namespace}" ]] && continue
            flux resume kustomization "${name}" -n "${namespace}" || result=1
        done <<<"${suspended_kustomizations}"
    fi
    exit "${result}"
}
trap resume_kustomizations EXIT

if [[ "${ROLLOUT}" != "true" ]]; then
    echo "Suspending Flux Kustomizations ..."
    active_kustomizations="$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io --all-namespaces -o json |
        jq -r '.items[] | select(.spec.suspend != true) | [.metadata.namespace, .metadata.name] | @tsv')"
    while IFS=$'\t' read -r namespace name; do
        [[ -z "${namespace}" ]] && continue
        suspended_kustomizations+="${namespace}"$'\t'"${name}"$'\n'
        flux suspend kustomization "${name}" -n "${namespace}"
    done <<<"${active_kustomizations}"
fi

echo "Upgrading Talos on node ${NODE} with ${TALOS_IMAGE} ..."
talosctl --nodes "${NODE}" upgrade \
    --image="${TALOS_IMAGE}" \
    --wait=true --timeout=10m --preserve=true

# talosctl health needs a control-plane node for its Kubernetes API checks.
health_node="$(kubectl get nodes -o json | jq -r \
    '[.items[] | select(.metadata.labels | has("node-role.kubernetes.io/control-plane"))
        | .status.addresses[] | select(.type == "InternalIP") | .address] | first // empty')"
if [[ -z "${health_node}" ]]; then
    echo "Could not resolve a control-plane node for the Talos health check." >&2
    exit 1
fi
echo "Waiting for Talos cluster health via ${health_node} ..."
talosctl --nodes "${health_node}" health \
    --wait-timeout=10m --server=false

echo "Waiting for Ceph health to be OK ..."
until kubectl wait --timeout=5m \
    --for=jsonpath=.status.ceph.health=HEALTH_OK cephcluster \
    --all --all-namespaces; do
    echo "Waiting for Ceph health to be OK ..."
    sleep 10
done

# The EXIT trap resumes only Kustomizations that this invocation suspended.
