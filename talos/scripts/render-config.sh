#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo "Usage: $0 <node-name>" >&2
}

NODE="${1:-}"
if [[ -z "${NODE// }" ]]; then
    usage
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TALOS_DIR="${ROOT_DIR}/talos"

ROLE=""
NODE_FILE=""
for candidate_role in controlplane workers; do
    candidate_file="${TALOS_DIR}/nodes/${candidate_role}/${NODE}.yaml.j2"
    if [[ -f "${candidate_file}" ]]; then
        ROLE="${candidate_role}"
        NODE_FILE="${candidate_file}"
        break
    fi
done

if [[ -z "${ROLE}" ]]; then
    echo "Node template not found for ${NODE} under ${TALOS_DIR}/nodes/{controlplane,workers}" >&2
    exit 66
fi

ROLE_FILE="${TALOS_DIR}/${ROLE}.yaml.j2"
if [[ ! -f "${ROLE_FILE}" ]]; then
    echo "Role template not found: ${ROLE_FILE}" >&2
    exit 66
fi

SCHEMATIC="$(${SCRIPT_DIR}/schematic-id.sh "${NODE}")"

if [[ "${ROLE}" == "controlplane" ]]; then
    if ! command -v op >/dev/null 2>&1; then
        echo "1Password CLI 'op' is required for service-account key decoding" >&2
        exit 69
    fi

    TALOS_K8S_SERVICE_ACCOUNT_KEY="$(op read op://k8s/talsecret/CERTS_K8SSERVICEACCOUNT_KEY | base64 --decode)"
    if [[ -z "${TALOS_K8S_SERVICE_ACCOUNT_KEY// }" ]]; then
        echo "Decoded Kubernetes service-account key is empty" >&2
        exit 65
    fi
    export TALOS_K8S_SERVICE_ACCOUNT_KEY
fi

# Layer order mirrors onedr0p/home-ops: cluster-wide baseline, role patch, node patch.
talosctl machineconfig patch <("${SCRIPT_DIR}/template.sh" "${TALOS_DIR}/cluster.yaml.j2" -D "schematic=${SCHEMATIC}") \
    -p @<("${SCRIPT_DIR}/template.sh" "${ROLE_FILE}" -D "schematic=${SCHEMATIC}") \
    -p @<("${SCRIPT_DIR}/template.sh" "${NODE_FILE}" -D "schematic=${SCHEMATIC}")
