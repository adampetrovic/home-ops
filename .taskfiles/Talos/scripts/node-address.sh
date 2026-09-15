#!/usr/bin/env bash
set -Eeuo pipefail

NODE="${1:-}"
if [[ -z "${NODE// }" ]]; then
    echo "Usage: $0 <node-name>" >&2
    exit 64
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INVENTORY="${ROOT_DIR}/talos/inventory.yaml"

if [[ ! -f "${INVENTORY}" ]]; then
    echo "Talos inventory not found: ${INVENTORY}" >&2
    exit 66
fi

ADDRESS="$(yq -r '.nodes["'"${NODE}"'"] // ""' "${INVENTORY}")"
if [[ -z "${ADDRESS}" || "${ADDRESS}" == "null" ]]; then
    echo "Node address not found in ${INVENTORY}: ${NODE}" >&2
    exit 66
fi

printf '%s\n' "${ADDRESS}"
