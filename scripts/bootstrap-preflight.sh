#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

export LOG_LEVEL="${LOG_LEVEL:-info}"
export ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
export KUBECONFIG="${KUBECONFIG:-${ROOT_DIR}/kubeconfig}"
export TALOSCONFIG="${TALOSCONFIG:-${ROOT_DIR}/talosconfig}"

failures=0

function run_just() {
    (cd "${ROOT_DIR}" && just "$@")
}

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
        "${ROOT_DIR}/talos"/*.yaml.j2 \
        "${ROOT_DIR}/talos/nodes"/*/*.yaml.j2 \
        "${ROOT_DIR}/bootstrap/kustomize/home" |
        sort -u >"${refs_file}"

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
        log info "Generating Talos client config for node reachability checks" "file=${TALOSCONFIG}"
        if ! run_just talos talosconfig "${TALOSCONFIG}"; then
            fail_check "Failed to generate Talos client config for node checks" "file=${TALOSCONFIG}"
            return
        fi
    fi

    while IFS= read -r ip; do
        [[ -z "${ip}" ]] && continue
        if talosctl --nodes "${ip}" version --insecure >/dev/null 2>&1; then
            log info "Talos node is reachable in maintenance mode" "node=${ip}"
        elif talosctl --talosconfig "${TALOSCONFIG}" --nodes "${ip}" version >/dev/null 2>&1; then
            log info "Talos node is reachable with Talos client config" "node=${ip}"
        else
            fail_check "Talos node is not reachable" "node=${ip}"
        fi
    done < <(yq '.nodes[]' "${ROOT_DIR}/talos/inventory.yaml")
}

function check_crd_duplicates() {
    local chart_crds standalone_crds duplicates

    chart_crds="$(mktemp)"
    standalone_crds="$(mktemp)"
    trap 'rm -f "${chart_crds:-}" "${standalone_crds:-}"' RETURN

    (
        cd "${ROOT_DIR}/bootstrap/helmfile"
        helmfile --file crds.yaml template --quiet |
            yq ea -N -r 'select(.kind == "CustomResourceDefinition") | .metadata.name' -
    ) | sort -u >"${chart_crds}"

    while IFS=$'\t' read -r name version url_template; do
        [[ -z "${name}" || -z "${version}" || -z "${url_template}" ]] && continue
        url="${url_template//\{version\}/${version}}"
        curl --fail --silent --show-error --location "${url}"
    done < <(yq -r '.crds[] | [.name, .version, .urlTemplate] | @tsv' "${ROOT_DIR}/bootstrap/crds/standalone.yaml") |
        yq ea -N -r 'select(.kind == "CustomResourceDefinition") | .metadata.name' - |
        sort -u >"${standalone_crds}"

    duplicates="$(cat "${standalone_crds}" "${chart_crds}" | sort | uniq -d | tr '\n' ' ')"
    if [[ -n "${duplicates}" ]]; then
        fail_check "Bootstrap CRD sources contain duplicate CustomResourceDefinitions" "crds=${duplicates}"
    else
        log info "Bootstrap CRD sources have no duplicate CustomResourceDefinitions"
    fi
}

function check_rendering() {
    if run_just talos validate-all; then
        log info "Talos native renderer validates all node configs"
    else
        fail_check "Talos native renderer validation failed"
    fi

    if kustomize build "${ROOT_DIR}/bootstrap/kustomize/home" >/dev/null; then
        log info "Bootstrap Kustomize resources render"
    else
        fail_check "Bootstrap Kustomize resources failed to render"
    fi

    if kustomize build "${ROOT_DIR}/bootstrap/kustomize/home" | op inject | yq ea '.' - >/dev/null; then
        log info "Bootstrap Kustomize resources inject and parse without writing secrets"
    else
        fail_check "Bootstrap Kustomize resources failed op injection or YAML parsing"
    fi

    if (cd "${ROOT_DIR}/bootstrap/helmfile" && helmfile --file apps.yaml build >/dev/null); then
        log info "Bootstrap app Helmfile renders from canonical chart refs"
    else
        fail_check "Bootstrap app Helmfile failed to render"
    fi

    if (cd "${ROOT_DIR}/bootstrap/helmfile" && helmfile --file crds.yaml template --quiet | yq ea 'select(.kind == "CustomResourceDefinition")' - >/dev/null); then
        log info "Bootstrap CRD Helmfile renders chart-owned CustomResourceDefinitions"
    else
        fail_check "Bootstrap CRD Helmfile failed to render"
    fi

    check_crd_duplicates

    if "${ROOT_DIR}/scripts/bootstrap-helmfile-parity.sh" >/dev/null; then
        log info "Bootstrap Helmfile metadata and values match Flux sources"
    else
        fail_check "Bootstrap Helmfile parity check failed"
    fi
}

function main() {
    check_env KUBECONFIG
    check_cli curl flux helm helmfile jq just kubectl kustomize minijinja-cli op sops talosctl yq

    mkdir -p "$(dirname "${KUBECONFIG}")"
    if [[ ! -w "$(dirname "${KUBECONFIG}")" ]]; then
        fail_check "KUBECONFIG directory is not writable" "directory=$(dirname "${KUBECONFIG}")"
    fi

    check_file "${ROOT_DIR}/talos/cluster.yaml.j2"
    check_file "${ROOT_DIR}/talos/controlplane.yaml.j2"
    check_file "${ROOT_DIR}/talos/workers.yaml.j2"
    check_file "${ROOT_DIR}/talos/inventory.yaml"
    check_file "${ROOT_DIR}/talos/secrets.yaml.j2"
    check_file "${ROOT_DIR}/talos/schematic.yaml.j2"
    check_file "${ROOT_DIR}/bootstrap/helmfile/apps.yaml"
    check_file "${ROOT_DIR}/bootstrap/helmfile/crds.yaml"
    check_file "${ROOT_DIR}/bootstrap/kustomize/home/kustomization.yaml"
    check_file "${ROOT_DIR}/bootstrap/crds/standalone.yaml"
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
