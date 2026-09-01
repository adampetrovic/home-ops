#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONTEXT="admin@home-kubernetes"

SOURCE="${1:-}"
NAMESPACE="${2:-default}"
TOKEN="${3:-}"
TIMEOUT="${4:-7200}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

kubectl_cmd() {
    kubectl --context "${CONTEXT}" "$@"
}

[[ -n ${SOURCE} ]] || fail "ReplicationSource name not specified"
[[ -n ${TOKEN} ]] || fail "Manual trigger token not specified"
[[ ${TIMEOUT} =~ ^[1-9][0-9]*$ ]] || fail "Timeout must be a positive integer"

start=$(date +%s)
deadline=$((start + TIMEOUT))
last_progress=${start}

echo "Waiting for ReplicationSource ${NAMESPACE}/${SOURCE} token ${TOKEN} (timeout: ${TIMEOUT}s)..."

while true; do
    now=$(date +%s)
    if (( now >= deadline )); then
        echo "Timed out waiting for ReplicationSource ${NAMESPACE}/${SOURCE}" >&2
        kubectl_cmd -n "${NAMESPACE}" get replicationsource "${SOURCE}" -o yaml >&2 || true
        exit 1
    fi

    source_json=$(kubectl_cmd -n "${NAMESPACE}" get replicationsource "${SOURCE}" -o json)
    last_manual=$(jq -r '.status.lastManualSync // ""' <<<"${source_json}")
    result=$(jq -r '.status.latestMoverStatus.result // ""' <<<"${source_json}")

    if [[ ${last_manual} == "${TOKEN}" ]]; then
        logs=$(jq -r '.status.latestMoverStatus.logs // ""' <<<"${source_json}")
        if [[ ${result} == "Successful" ]]; then
            echo "ReplicationSource ${NAMESPACE}/${SOURCE} completed successfully."
            [[ -z ${logs} ]] || printf '%s\n' "${logs}"
            exit 0
        fi

        if [[ ${result} == "Failed" ]]; then
            echo "ReplicationSource ${NAMESPACE}/${SOURCE} failed." >&2
            [[ -z ${logs} ]] || printf '%s\n' "${logs}" >&2
            exit 1
        fi
    fi

    if (( now - last_progress >= 30 )); then
        echo "Still waiting ($((now - start))s elapsed; last token=${last_manual:-none}, result=${result:-pending})..."
        last_progress=${now}
    fi

    sleep 5
done
