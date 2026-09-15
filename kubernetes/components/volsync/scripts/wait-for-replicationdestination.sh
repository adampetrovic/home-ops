#!/usr/bin/env bash
set -Eeuo pipefail

RD=$1
NAMESPACE="${2:-default}"
TIMEOUT="${3:-7200}" # seconds, default 2h

[[ -z "${RD}" ]] && echo "ReplicationDestination name not specified" && exit 1

echo "Waiting for ReplicationDestination ${RD} in namespace ${NAMESPACE} (timeout: ${TIMEOUT}s)..."

deadline=$(( $(date +%s) + TIMEOUT ))
last_log=$(date +%s)
while true; do
    now=$(date +%s)
    result=$(kubectl -n "${NAMESPACE}" get replicationdestination "${RD}" \
        -o jsonpath='{.status.latestMoverStatus.result}' 2>/dev/null || true)

    if [[ "${result}" == "Successful" ]]; then
        echo "Restore completed successfully."
        exit 0
    fi

    if [[ "${result}" == "Failed" ]]; then
        echo "Restore failed. Logs:"
        kubectl -n "${NAMESPACE}" get replicationdestination "${RD}" \
            -o jsonpath='{.status.latestMoverStatus.logs}' 2>/dev/null || true
        exit 1
    fi

    if (( now > deadline )); then
        echo "Timed out waiting for ReplicationDestination ${RD}"
        exit 1
    fi

    # Log progress every 30 seconds
    if (( now - last_log >= 30 )); then
        elapsed=$(( now - (deadline - TIMEOUT) ))
        echo "Still waiting... (${elapsed}s elapsed, status: ${result:-pending})"
        last_log=$now
    fi

    sleep 5
done
