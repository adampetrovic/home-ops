#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

export LOG_LEVEL="${LOG_LEVEL:-info}"
export ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
export TALOSCONFIG="${TALOSCONFIG:-${ROOT_DIR}/talos/clusterconfig/talosconfig}"

failures=0

function fail_check() {
    log warn "$@"
    failures=$((failures + 1))
}

function check_file() {
    local file="${1}"

    if [[ -f "${file}" ]]; then
        log info "Required file exists" "file=${file}"
    else
        fail_check "Required file is missing" "file=${file}"
    fi
}

function check_op_refs() {
    local refs_file ref

    refs_file="$(mktemp)"
    grep -RhoE 'op://[^[:space:]}",]+' \
        "${ROOT_DIR}/talos/.env" \
        "${ROOT_DIR}/bootstrap/resources.yaml.j2" \
        | sort -u >"${refs_file}"

    while IFS= read -r ref; do
        [[ -z "${ref}" ]] && continue
        if op read "${ref}" >/dev/null 2>&1; then
            log info "1Password reference is readable" "ref=${ref}"
        else
            fail_check "1Password reference is not readable" "ref=${ref}"
        fi
    done <"${refs_file}"

    rm -f "${refs_file}"
}

function check_talos_nodes() {
    local ip

    if [[ "${BOOTSTRAP_PREFLIGHT_SKIP_NODES:-false}" == "true" ]]; then
        log warn "Skipping Talos node reachability checks" "BOOTSTRAP_PREFLIGHT_SKIP_NODES=true"
        return
    fi

    if [[ ! -f "${TALOSCONFIG}" ]]; then
        log info "Generating Talos config for node reachability checks" "file=${TALOSCONFIG}"
        if ! task --dir "${ROOT_DIR}" talos:generate; then
            fail_check "Failed to generate Talos config for node checks" "file=${TALOSCONFIG}"
            return
        fi
    fi

    while IFS= read -r ip; do
        [[ -z "${ip}" ]] && continue
        if talosctl --nodes "${ip}" version --insecure >/dev/null 2>&1; then
            log info "Talos node is reachable in maintenance mode" "node=${ip}"
        elif talosctl --talosconfig "${TALOSCONFIG}" --nodes "${ip}" version >/dev/null 2>&1; then
            log info "Talos node is reachable with generated config" "node=${ip}"
        else
            fail_check "Talos node is not reachable" "node=${ip}"
        fi
    done < <(yq '.nodes[].ipAddress' "${ROOT_DIR}/talos/talconfig.yaml")
}

function check_rendering() {
    if render_template "${ROOT_DIR}/bootstrap/resources.yaml.j2" >/dev/null; then
        log info "Bootstrap resources render with 1Password injection"
    else
        fail_check "Bootstrap resources failed to render"
    fi

    if helmfile --file "${ROOT_DIR}/bootstrap/helmfile.yaml" build >/dev/null; then
        log info "Bootstrap Helmfile renders with chart refs from bootstrap/helmfile.yaml"
    else
        fail_check "Bootstrap Helmfile failed to render"
    fi
}

function main() {
    check_env KUBECONFIG
    check_cli flux helm helmfile jq kubectl kustomize op sops talhelper talosctl task yq

    if ! op whoami --format=json >/dev/null 2>&1; then
        log error "Failed to authenticate with 1Password CLI"
    fi

    mkdir -p "$(dirname "${KUBECONFIG}")"
    if [[ ! -w "$(dirname "${KUBECONFIG}")" ]]; then
        fail_check "KUBECONFIG directory is not writable" "directory=$(dirname "${KUBECONFIG}")"
    fi

    check_file "${ROOT_DIR}/talos/.env"
    check_file "${ROOT_DIR}/talos/talconfig.yaml"
    check_file "${ROOT_DIR}/talos/talenv.yaml"
    check_file "${ROOT_DIR}/talos/talsecret.yaml"
    check_file "${ROOT_DIR}/bootstrap/helmfile.yaml"
    check_file "${ROOT_DIR}/bootstrap/resources.yaml.j2"
    check_file "${ROOT_DIR}/kubernetes/apps/external-secrets/external-secrets/stores/onepassword/clustersecretstore.yaml"

    check_op_refs
    check_rendering
    check_talos_nodes

    if ((failures > 0)); then
        log error "Bootstrap preflight failed" "failures=${failures}"
    fi

    log info "Bootstrap preflight passed"
}

main "$@"
