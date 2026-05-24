#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

export LOG_LEVEL="${LOG_LEVEL:-debug}"
export ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
export TALOSCONFIG="${TALOSCONFIG:-${ROOT_DIR}/talos/clusterconfig/talosconfig}"

# Generate the Talos configuration before reading talosctl config state. This makes
# the bootstrap path work from a clean workstation that has no ~/.talos/config yet.
function generate_talos_config() {
    log debug "Generating Talos node configuration"

    task --dir "${ROOT_DIR}" talos:generate

    if [[ ! -f "${TALOSCONFIG}" ]]; then
        log error "Generated Talos config does not exist" "file=${TALOSCONFIG}"
    fi

    log info "Talos client configuration is available" "file=${TALOSCONFIG}"
}

function talos_controller() {
    local controller

    if ! controller=$(talosctl --talosconfig "${TALOSCONFIG}" config info --output json | jq --exit-status --raw-output '.endpoints[0] // empty') || [[ -z "${controller}" ]]; then
        log error "No Talos controller endpoint found" "talosconfig=${TALOSCONFIG}"
    fi

    echo "${controller}"
}

function expected_node_count() {
    yq '.nodes | length' "${ROOT_DIR}/talos/talconfig.yaml"
}

# Apply the Talos configuration to all the nodes.
function apply_talos_config() {
    log debug "Applying Talos configuration"

    log debug "Applying Talos node configuration"
    if ! output=$(task --dir "${ROOT_DIR}" talos:apply 2>&1); then
        if [[ "${output}" == *"certificate required"* ]]; then
            log warn "At least one Talos node is already configured; skipping insecure apply for configured nodes"
            return
        fi
        log error "Failed to apply Talos node configuration" "output=${output}"
    fi

    log info "Talos node configuration applied successfully"
}

# Bootstrap Talos on a controller node.
function bootstrap_talos() {
    local controller output start now timeout

    log debug "Bootstrapping Talos"

    controller="$(talos_controller)"
    timeout="${TALOS_BOOTSTRAP_TIMEOUT_SECONDS:-900}"
    start="$(date +%s)"

    log debug "Talos controller discovered" "controller=${controller}"

    while true; do
        if output=$(task --dir "${ROOT_DIR}" talos:bootstrap 2>&1); then
            log info "Talos bootstrap command completed" "controller=${controller}"
            return
        fi

        if [[ "${output}" == *"AlreadyExists"* || "${output}" == *"already bootstrapped"* ]]; then
            log info "Talos is already bootstrapped" "controller=${controller}"
            return
        fi

        now="$(date +%s)"
        if ((now - start >= timeout)); then
            log error "Timed out waiting for Talos bootstrap" "controller=${controller}" "timeout=${timeout}s" "output=${output}"
        fi

        log info "Talos bootstrap in progress, waiting 10 seconds..." "controller=${controller}"
        sleep 10
    done
}

# Fetch the kubeconfig from a controller node.
function fetch_kubeconfig() {
    local controller kubeconfig_dir

    log debug "Fetching kubeconfig"

    controller="$(talos_controller)"
    kubeconfig_dir="$(dirname "${KUBECONFIG}")"
    mkdir -p "${kubeconfig_dir}"

    if ! talosctl --talosconfig "${TALOSCONFIG}" kubeconfig --nodes "${controller}" --force "${KUBECONFIG}" &>/dev/null; then
        log error "Failed to fetch kubeconfig" "controller=${controller}" "kubeconfig=${KUBECONFIG}"
    fi

    log info "Kubeconfig fetched successfully" "file=${KUBECONFIG}"
}

# Wait for Kubernetes node objects to exist before applying API resources. On a
# fresh cluster with no CNI yet, nodes are expected to appear as Ready=False.
function wait_for_nodes() {
    local expected count start now timeout

    log debug "Waiting for Kubernetes node objects"

    expected="$(expected_node_count)"
    timeout="${NODE_DISCOVERY_TIMEOUT_SECONDS:-600}"
    start="$(date +%s)"

    until count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ') && [[ "${count}" =~ ^[0-9]+$ ]] && ((count >= expected)); do
        now="$(date +%s)"
        if ((now - start >= timeout)); then
            log error "Timed out waiting for Kubernetes nodes to register" "expected=${expected}" "seen=${count:-0}" "timeout=${timeout}s"
        fi
        log info "Waiting for Kubernetes nodes to register" "expected=${expected}" "seen=${count:-0}"
        sleep 10
    done

    if kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
        log info "Nodes are already Ready; continuing"
        return
    fi

    until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
        log info "Nodes are registered but not all have Ready=False yet; retrying in 10 seconds..."
        sleep 10
    done

    talosctl --talosconfig "${TALOSCONFIG}" health --server=false --wait-timeout=20m
}

# CRDs to be applied before the helmfile charts are installed.
function apply_crds() {
    log debug "Applying CRDs"

    local -r crds=(
        # renovate: datasource=github-releases depName=kubernetes-sigs/external-dns
        https://raw.githubusercontent.com/kubernetes-sigs/external-dns/refs/tags/v0.21.0/config/crd/standard/dnsendpoints.externaldns.k8s.io.yaml
        # renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api
        https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml
        # renovate: datasource=github-releases depName=prometheus-operator/prometheus-operator
        https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.91.0/stripped-down-crds.yaml
        # renovate: datasource=github-releases depName=k8snetworkplumbingwg/network-attachment-definition-client
        https://raw.githubusercontent.com/k8snetworkplumbingwg/network-attachment-definition-client/refs/tags/v1.7.7/artifacts/networks-crd.yaml
        # renovate: datasource=github-releases depName=cloudnative-pg/plugin-barman-cloud
        https://raw.githubusercontent.com/cloudnative-pg/plugin-barman-cloud/refs/tags/v0.12.0/config/crd/bases/barmancloud.cnpg.io_objectstores.yaml
    )

    for crd in "${crds[@]}"; do
        if kubectl diff --filename "${crd}" &>/dev/null; then
            log info "CRDs are up-to-date" "crd=${crd}"
            continue
        fi
        if kubectl apply --server-side --filename "${crd}" &>/dev/null; then
            log info "CRDs applied" "crd=${crd}"
        else
            log error "Failed to apply CRDs" "crd=${crd}"
        fi
    done

    # Extract and apply CRDs from Helm charts (matching onedr0p/home-ops pattern).
    local -r helm_crds=(
        # renovate: datasource=docker depName=docker.io/envoyproxy/gateway-helm
        "oci://docker.io/envoyproxy/gateway-helm 1.8.0"
    )

    for entry in "${helm_crds[@]}"; do
        local chart="${entry% *}"
        local version="${entry#* }"
        local tmpdir crds_dir

        tmpdir="$(mktemp -d)"
        if helm pull "${chart}" --version "${version}" --untar --untardir "${tmpdir}" &>/dev/null; then
            crds_dir="$(find "${tmpdir}" -type d -name crds | head -1)"
            if [[ -n "${crds_dir}" ]]; then
                if kubectl apply --server-side --force-conflicts -f "${crds_dir}" --recursive &>/dev/null; then
                    log info "Helm chart CRDs applied" "chart=${chart}" "version=${version}"
                else
                    log error "Failed to apply Helm chart CRDs" "chart=${chart}" "version=${version}"
                fi
            fi
        else
            log error "Failed to pull Helm chart" "chart=${chart}" "version=${version}"
        fi
        rm -rf "${tmpdir}"
    done
}

# Resources to be applied before the helmfile charts are installed.
function apply_resources() {
    log debug "Applying resources"

    local -r resources_file="${ROOT_DIR}/bootstrap/resources.yaml.j2"

    if ! output=$(render_template "${resources_file}") || [[ -z "${output}" ]]; then
        exit 1
    fi

    if echo "${output}" | kubectl diff --filename - &>/dev/null; then
        log info "Resources are up-to-date"
        return
    fi

    if echo "${output}" | kubectl apply --server-side --filename - &>/dev/null; then
        log info "Resources applied"
    else
        log error "Failed to apply resources"
    fi
}

# Sync Helm releases.
function sync_helm_releases() {
    log debug "Syncing Helm releases"

    local -r helmfile_file="${ROOT_DIR}/bootstrap/helmfile.yaml"

    if [[ ! -f "${helmfile_file}" ]]; then
        log error "File does not exist" "file=${helmfile_file}"
    fi

    if ! helmfile --file "${helmfile_file}" sync --hide-notes; then
        log error "Failed to sync Helm releases"
    fi

    log info "Helm releases synced successfully"
}

function main() {
    check_env KUBECONFIG
    check_cli helm helmfile jq kubectl kustomize op sops talhelper talosctl task yq

    if ! op whoami --format=json &>/dev/null; then
        log error "Failed to authenticate with 1Password CLI"
    fi

    # Bootstrap the Talos node configuration.
    generate_talos_config
    apply_talos_config
    bootstrap_talos
    fetch_kubeconfig

    # Apply resources and Helm releases.
    wait_for_nodes
    apply_crds
    apply_resources
    sync_helm_releases

    log info "Congrats! The cluster is bootstrapped and Flux is syncing the Git repository"
    log info "Run post-bootstrap verification with: task bootstrap:verify"
}

main "$@"
