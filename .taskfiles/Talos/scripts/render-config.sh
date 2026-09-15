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
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
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

# Layer order mirrors onedr0p/home-ops: cluster-wide baseline, role patch, node patch.
talosctl machineconfig patch <("${SCRIPT_DIR}/template.sh" "${TALOS_DIR}/cluster.yaml.j2" -D "schematic=${SCHEMATIC}") \
    -p @<("${SCRIPT_DIR}/template.sh" "${ROLE_FILE}" -D "schematic=${SCHEMATIC}") \
    -p @<("${SCRIPT_DIR}/template.sh" "${NODE_FILE}" -D "schematic=${SCHEMATIC}")
