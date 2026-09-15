#!/usr/bin/env bash
set -Eeuo pipefail

NODE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMATIC_FILE="$(${SCRIPT_DIR}/schematic-file.sh "${NODE}")"

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required" >&2
    exit 69
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required" >&2
    exit 69
fi

"${SCRIPT_DIR}/template.sh" "${SCHEMATIC_FILE}" \
    | curl -fsS -X POST --data-binary @- "https://factory.talos.dev/schematics" \
    | jq -r '.id'
