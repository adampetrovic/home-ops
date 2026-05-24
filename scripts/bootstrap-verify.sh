#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

export LOG_LEVEL="${LOG_LEVEL:-info}"
export ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

failures=0
mode="core"

function usage() {
    cat <<'EOF'
Usage: scripts/bootstrap-verify.sh [--core|--full]

  --core  Verify the bootstrap substrate: nodes, CNI, DNS, External Secrets, and Flux.
  --full  Also verify Flux convergence, storage, gateways, VolSync objects, and CNPG.
EOF
}

function fail_check() {
    log warn "$@"
    failures=$((failures + 1))
}

function run_check() {
    local description="${1}"
    shift

    if "$@"; then
        log info "Check passed" "check=${description}"
    else
        fail_check "Check failed" "check=${description}"
    fi
}

function wait_for_nodes() {
    kubectl wait nodes --for=condition=Ready=True --all --timeout="${NODE_READY_TIMEOUT:-15m}" >/dev/null
}

function wait_for_namespace_pods() {
    local namespace="${1}"
    local timeout="${2:-10m}"

    kubectl -n "${namespace}" wait pods --all --for=condition=Ready --timeout="${timeout}" >/dev/null
}

function wait_for_flux_object() {
    local namespace="${1}"
    local kind="${2}"
    local name="${3}"
    local timeout="${4:-10m}"

    kubectl -n "${namespace}" wait "${kind}/${name}" --for=condition=Ready --timeout="${timeout}" >/dev/null
}

function count_not_ready() {
    local resource="${1}"

    kubectl get "${resource}" --all-namespaces -o json \
        | jq '[.items[] | select(((.status.conditions // []) | map(select(.type == "Ready")) | .[0].status // "False") != "True")] | length'
}

function check_flux_convergence() {
    local ks_not_ready hr_not_ready

    ks_not_ready="$(count_not_ready kustomizations.kustomize.toolkit.fluxcd.io)"
    hr_not_ready="$(count_not_ready helmreleases.helm.toolkit.fluxcd.io)"

    if [[ "${ks_not_ready}" == "0" && "${hr_not_ready}" == "0" ]]; then
        return 0
    fi

    log warn "Flux objects are not fully ready" "kustomizations=${ks_not_ready}" "helmreleases=${hr_not_ready}"
    kubectl get kustomizations.kustomize.toolkit.fluxcd.io --all-namespaces || true
    kubectl get helmreleases.helm.toolkit.fluxcd.io --all-namespaces || true
    return 1
}

function check_full_convergence() {
    run_check "cluster-apps Kustomization ready" wait_for_flux_object flux-system kustomization cluster-apps "${CLUSTER_APPS_TIMEOUT:-30m}"
    run_check "Flux Kustomizations and HelmReleases ready" check_flux_convergence

    run_check "openebs-hostpath StorageClass exists" kubectl get storageclass openebs-hostpath
    run_check "ceph-block StorageClass exists" kubectl get storageclass ceph-block
    run_check "csi-ceph-blockpool VolumeSnapshotClass exists" kubectl get volumesnapshotclass csi-ceph-blockpool

    run_check "Rook Ceph cluster Kustomization ready" wait_for_flux_object rook-ceph kustomization rook-ceph-cluster "${ROOK_TIMEOUT:-30m}"
    run_check "VolSync Kustomization ready" wait_for_flux_object volsync-system kustomization volsync "${VOLSYNC_TIMEOUT:-15m}"
    run_check "Envoy internal Gateway programmed" kubectl -n network wait gateway/envoy-internal --for=condition=Programmed=True --timeout="${GATEWAY_TIMEOUT:-10m}"
    run_check "Envoy external Gateway programmed" kubectl -n network wait gateway/envoy-external --for=condition=Programmed=True --timeout="${GATEWAY_TIMEOUT:-10m}"

    if kubectl -n database get clusters.postgresql.cnpg.io postgres >/dev/null 2>&1; then
        run_check "CNPG postgres cluster ready" kubectl -n database wait clusters.postgresql.cnpg.io/postgres --for=condition=Ready --timeout="${CNPG_TIMEOUT:-30m}"
    else
        fail_check "CNPG postgres cluster is missing" "namespace=database" "name=postgres"
    fi

    run_check "VolSync ReplicationDestinations listable" kubectl get replicationdestinations.volsync.backube --all-namespaces
    run_check "VolSync ReplicationSources listable" kubectl get replicationsources.volsync.backube --all-namespaces
}

function main() {
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --core)
                mode="core"
                ;;
            --full)
                mode="full"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                exit 2
                ;;
        esac
        shift
    done

    check_env KUBECONFIG
    check_cli flux jq kubectl

    run_check "Kubernetes API reachable" kubectl version --request-timeout=10s
    run_check "all Kubernetes nodes Ready" wait_for_nodes
    run_check "Cilium DaemonSet rolled out" kubectl -n kube-system rollout status daemonset/cilium --timeout="${CILIUM_TIMEOUT:-10m}"
    run_check "CoreDNS Deployment rolled out" kubectl -n kube-system rollout status deployment/coredns --timeout="${COREDNS_TIMEOUT:-5m}"
    run_check "External Secrets pods Ready" wait_for_namespace_pods external-secrets "${EXTERNAL_SECRETS_TIMEOUT:-10m}"
    run_check "Flux pods Ready" wait_for_namespace_pods flux-system "${FLUX_TIMEOUT:-10m}"
    run_check "Flux source ready" wait_for_flux_object flux-system gitrepository flux-system "${FLUX_TIMEOUT:-10m}"

    if [[ "${mode}" == "full" ]]; then
        check_full_convergence
    else
        log info "Core bootstrap verification complete; run 'task bootstrap:verify-full' for full GitOps convergence"
    fi

    if ((failures > 0)); then
        log error "Bootstrap verification failed" "failures=${failures}" "mode=${mode}"
    fi

    log info "Bootstrap verification passed" "mode=${mode}"
}

main "$@"
