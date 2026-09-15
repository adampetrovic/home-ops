#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo "Usage: $0 <template-file> [minijinja-args...]" >&2
}

TEMPLATE_FILE="${1:-}"
if [[ -z "${TEMPLATE_FILE// }" ]]; then
    usage
    exit 64
fi
shift

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
    echo "Template file not found: ${TEMPLATE_FILE}" >&2
    exit 66
fi

if ! command -v minijinja-cli >/dev/null 2>&1; then
    echo "minijinja-cli is required; run 'mise install' after syncing .mise.toml" >&2
    exit 69
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export MINIJINJA_CONFIG_FILE="${MINIJINJA_CONFIG_FILE:-${ROOT_DIR}/.minijinja.toml}"

if [[ "${TALOS_SKIP_OP_INJECT:-false}" == "true" ]]; then
    minijinja-cli "${TEMPLATE_FILE}" "$@"
    exit 0
fi

if ! command -v op >/dev/null 2>&1; then
    echo "1Password CLI 'op' is required for op:// secret injection" >&2
    exit 69
fi

minijinja-cli "${TEMPLATE_FILE}" "$@" | op inject
