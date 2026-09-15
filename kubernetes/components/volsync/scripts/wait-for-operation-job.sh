#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONTEXT="admin@home-kubernetes"

JOB="${1:-}"
NAMESPACE="${2:-default}"
TIMEOUT="${3:-600}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

kubectl_cmd() {
    kubectl --context "${CONTEXT}" "$@"
}

show_diagnostics() {
    echo "--- Job logs ---" >&2
    kubectl_cmd -n "${NAMESPACE}" logs "job/${JOB}" \
        --all-containers=true --prefix=true >&2 2>/dev/null || true
    echo "--- Job description ---" >&2
    kubectl_cmd -n "${NAMESPACE}" describe job "${JOB}" >&2 2>/dev/null || true
    echo "--- Recent Job events ---" >&2
    kubectl_cmd -n "${NAMESPACE}" get events \
        --field-selector "involvedObject.kind=Job,involvedObject.name=${JOB}" \
        --sort-by='.lastTimestamp' >&2 2>/dev/null || true
}

[[ -n ${JOB} ]] || fail "Job name not specified"
[[ ${TIMEOUT} =~ ^[1-9][0-9]*$ ]] || fail "Timeout must be a positive integer"

start=$(date +%s)
deadline=$((start + TIMEOUT))
last_progress=${start}

echo "Waiting for Job ${NAMESPACE}/${JOB} via ${CONTEXT} (timeout: ${TIMEOUT}s)..."

while true; do
    now=$(date +%s)
    if (( now >= deadline )); then
        echo "Timed out waiting for Job ${NAMESPACE}/${JOB}" >&2
        show_diagnostics
        exit 1
    fi

    if ! kubectl_cmd -n "${NAMESPACE}" get job "${JOB}" >/dev/null 2>&1; then
        if (( now - last_progress >= 30 )); then
            echo "Still waiting for Job creation ($((now - start))s elapsed)..."
            last_progress=${now}
        fi
        sleep 2
        continue
    fi

    complete=$(kubectl_cmd -n "${NAMESPACE}" get job "${JOB}" \
        -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
    failed=$(kubectl_cmd -n "${NAMESPACE}" get job "${JOB}" \
        -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)

    if [[ ${complete} == "True" ]]; then
        echo "Job ${NAMESPACE}/${JOB} completed successfully."
        kubectl_cmd -n "${NAMESPACE}" logs "job/${JOB}" \
            --all-containers=true --prefix=true
        exit 0
    fi

    if [[ ${failed} == "True" ]]; then
        echo "Job ${NAMESPACE}/${JOB} failed." >&2
        show_diagnostics
        exit 1
    fi

    if (( now - last_progress >= 30 )); then
        active=$(kubectl_cmd -n "${NAMESPACE}" get job "${JOB}" \
            -o jsonpath='{.status.active}' 2>/dev/null || true)
        succeeded=$(kubectl_cmd -n "${NAMESPACE}" get job "${JOB}" \
            -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
        failures=$(kubectl_cmd -n "${NAMESPACE}" get job "${JOB}" \
            -o jsonpath='{.status.failed}' 2>/dev/null || true)
        echo "Still waiting ($((now - start))s elapsed; active=${active:-0}, succeeded=${succeeded:-0}, failed=${failures:-0})..."
        last_progress=${now}
    fi

    sleep 2
done
