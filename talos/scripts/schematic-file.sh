#!/usr/bin/env bash
set -Eeuo pipefail

NODE="${1:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TALOS_DIR="${ROOT_DIR}/talos"
SCHEMATIC_FILE="${TALOS_DIR}/schematic.yaml.j2"

if [[ -n "${NODE// }" ]]; then
    while IFS= read -r -d '' candidate; do
        SCHEMATIC_FILE="${candidate}"
        break
    done < <(find "${TALOS_DIR}/nodes" -path "*/${NODE}.schematic.yaml.j2" -print0 2>/dev/null | sort -z)
fi

if [[ ! -f "${SCHEMATIC_FILE}" ]]; then
    echo "Schematic template not found: ${SCHEMATIC_FILE}" >&2
    exit 66
fi

printf '%s\n' "${SCHEMATIC_FILE}"
