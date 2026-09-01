#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONTEXT="admin@home-kubernetes"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

APP="${1:-}"
NAMESPACE="${2:-default}"
TYPE="${3:-kopia}"
TIMEOUT="${4:-7200}"
cleanup_source=""
cleanup_token=""

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup_manual_trigger() {
    [[ -n ${cleanup_source} && -n ${cleanup_token} ]] || return 0

    local attempt current_manual
    for attempt in 1 2 3 4 5; do
        if kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
            patch replicationsource "${cleanup_source}" --type json \
            -p "[{\"op\":\"test\",\"path\":\"/spec/trigger/manual\",\"value\":\"${cleanup_token}\"},{\"op\":\"remove\",\"path\":\"/spec/trigger/manual\"}]" \
            >/dev/null 2>&1; then
            echo "Restored the scheduled trigger on ${cleanup_source}."
            cleanup_source=""
            cleanup_token=""
            return 0
        fi

        if current_manual=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
            get replicationsource "${cleanup_source}" \
            -o jsonpath='{.spec.trigger.manual}' 2>/dev/null); then
            if [[ ${current_manual} != "${cleanup_token}" ]]; then
                echo "Manual trigger on ${cleanup_source} no longer belongs to this task; leaving it unchanged."
                cleanup_source=""
                cleanup_token=""
                return 0
            fi
        fi

        (( attempt == 5 )) || sleep 2
    done

    echo "ERROR: could not remove manual trigger ${cleanup_token} from ${cleanup_source}." >&2
    echo "Scheduled backups may remain paused; rerun cleanup after restoring API access:" >&2
    echo "  kubectl --context ${CONTEXT} -n ${NAMESPACE} patch replicationsource ${cleanup_source} --type json -p '[{\"op\":\"test\",\"path\":\"/spec/trigger/manual\",\"value\":\"${cleanup_token}\"},{\"op\":\"remove\",\"path\":\"/spec/trigger/manual\"}]'" >&2
    return 1
}

on_exit() {
    local rc=$?
    trap - EXIT
    cleanup_manual_trigger || rc=1
    exit "${rc}"
}

run_backup() {
    local source=$1
    local label=$2
    local existing_manual patch resource_version source_json status token rc

    token="task-$(date -u +%Y%m%dT%H%M%S)-$$"
    source_json=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
        get replicationsource "${source}" -o json)
    status=$(jq -r '[.status.conditions[]?
        | select(.type == "Synchronizing")
        | .status] | last // "Missing"' <<<"${source_json}")
    [[ ${status} == "False" ]] || \
        fail "${source} Synchronizing status is ${status}; refusing to overlap backups"

    existing_manual=$(jq -r '.spec.trigger.manual // ""' <<<"${source_json}")
    [[ -z ${existing_manual} ]] || \
        fail "${source} already has manual trigger ${existing_manual}; refusing to overwrite it"
    resource_version=$(jq -r '.metadata.resourceVersion' <<<"${source_json}")
    patch=$(jq -cn --arg rv "${resource_version}" --arg token "${token}" '[
        {"op":"test","path":"/metadata/resourceVersion","value":$rv},
        {"op":"add","path":"/spec/trigger/manual","value":$token}
    ]')

    echo "Triggering ${label} backup for ${APP} in ${NAMESPACE} with token ${token}..."
    cleanup_source=${source}
    cleanup_token=${token}
    if ! kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
        patch replicationsource "${source}" --type json -p "${patch}"; then
        cleanup_manual_trigger || \
            fail "${source} trigger patch failed ambiguously and cleanup did not complete"
        fail "${source} changed concurrently; no manual trigger was created"
    fi

    rc=0
    bash "${SCRIPT_DIR}/wait-for-replicationsource.sh" \
        "${source}" "${NAMESPACE}" "${token}" "${TIMEOUT}" || rc=$?
    cleanup_manual_trigger || return 1
    return "${rc}"
}

[[ -n ${APP} ]] || fail "Application name not specified"
[[ ${TYPE} =~ ^(kopia|r2|all)$ ]] || fail "Type must be kopia, r2, or all"
[[ ${TIMEOUT} =~ ^[1-9][0-9]*$ ]] || fail "Timeout must be a positive integer"

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ${TYPE} == "kopia" || ${TYPE} == "all" ]]; then
    run_backup "${APP}" Kopia
fi
if [[ ${TYPE} == "r2" || ${TYPE} == "all" ]]; then
    bash "${SCRIPT_DIR}/preflight-r2-operation.sh" "${APP}" "${NAMESPACE}" exclusive
    run_backup "${APP}-r2" R2
fi
