#!/usr/bin/env bash
set -Eeuo pipefail

NODE="${1:-}"
if [[ -z "${NODE// }" ]]; then
    echo "Usage: $0 <node-name>" >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/render-config.sh" "${NODE}" \
    | yq -r 'select(.kind == "UnattendedInstallConfig") | .installer.image'
