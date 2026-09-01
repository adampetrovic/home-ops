#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONTEXT="admin@home-kubernetes"

APP="${1:-}"
NAMESPACE="${2:-default}"
MODE="${3:-exclusive}"
SOURCE="${APP}-r2"
SECRET="${APP}-volsync-r2-secret"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

print_items() {
    local item
    while IFS= read -r item; do
        echo "  - ${item}" >&2
    done <<<"$1"
}

validate_name() {
    local kind=$1
    local value=$2

    [[ ${#value} -le 63 ]] || fail "${kind} must be at most 63 characters"
    [[ ${value} =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
        fail "${kind} must be a lowercase DNS label: ${value}"
}

[[ -n ${APP} ]] || fail "Application name not specified"
[[ ${MODE} == "inspect" || ${MODE} == "exclusive" ]] || \
    fail "Mode must be inspect or exclusive"
validate_name "Application" "${APP}"
validate_name "Namespace" "${NAMESPACE}"
for job_prefix in volsync-r2-locks- volsync-r2-unlock- volsync-r2-check- volsync-r2-debug-; do
    (( ${#job_prefix} + ${#APP} <= 63 )) || \
        fail "Application name is too long for Taskfile operation Job names: ${APP}"
done

kubectl config get-contexts -o name | grep -Fxq "${CONTEXT}" || \
    fail "Kubernetes context ${CONTEXT} is not configured"
kubectl --context "${CONTEXT}" version --request-timeout=10s >/dev/null || \
    fail "Kubernetes API is not reachable through ${CONTEXT}"
kubectl --context "${CONTEXT}" get namespace "${NAMESPACE}" >/dev/null || \
    fail "Namespace ${NAMESPACE} does not exist"

source_json=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
    get replicationsource "${SOURCE}" -o json) || \
    fail "ReplicationSource ${NAMESPACE}/${SOURCE} does not exist"

jq -e --arg secret "${SECRET}" \
    '.spec.restic.repository == $secret and (.spec.restic | type == "object")' \
    <<<"${source_json}" >/dev/null || \
    fail "${NAMESPACE}/${SOURCE} is not a Restic source using ${SECRET}"

secret_json=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
    get secret "${SECRET}" -o json) || \
    fail "Secret ${NAMESPACE}/${SECRET} does not exist"

jq -e '.data
    | has("RESTIC_REPOSITORY")
    and has("RESTIC_PASSWORD")
    and has("AWS_ACCESS_KEY_ID")
    and has("AWS_SECRET_ACCESS_KEY")' \
    <<<"${secret_json}" >/dev/null || \
    fail "${NAMESPACE}/${SECRET} is missing required Restic or R2 keys"

echo "Target: ${NAMESPACE}/${SOURCE} via ${SECRET}"
echo "Context: ${CONTEXT}"

operation_jobs=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get jobs -o json | \
    jq -r --arg app "${APP}" '.items[]
        | select(.metadata.labels["home-ops.petrovic.io/volsync-app"] == $app)
        | .metadata.name')
if [[ -n ${operation_jobs} ]]; then
    echo "Existing Taskfile operation Jobs:" >&2
    print_items "${operation_jobs}"
    fail "Inspect or delete the existing Job before retrying"
fi

if [[ ${MODE} == "inspect" ]]; then
    echo "Preflight passed for read-only R2 lock inspection."
    exit 0
fi

sync_status=$(jq -r '[.status.conditions[]?
    | select(.type == "Synchronizing")
    | .status] | last // "Missing"' <<<"${source_json}")
[[ ${sync_status} == "False" ]] || \
    fail "${NAMESPACE}/${SOURCE} Synchronizing status is ${sync_status}; wait for it to become False"

active_jobs=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get jobs -o json | \
    jq -r --arg source "${SOURCE}" '.items[]
        | select((.status.active // 0) > 0)
        | select(any(.metadata.ownerReferences[]?;
            .kind == "ReplicationSource" and .name == $source))
        | .metadata.name')
if [[ -n ${active_jobs} ]]; then
    echo "Active mover Jobs owned by ${SOURCE}:" >&2
    print_items "${active_jobs}"
    fail "An active mover may own a legitimate Restic lock"
fi

active_sources=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
    get replicationsources -o json | \
    jq -r --arg source "${SOURCE}" --arg secret "${SECRET}" '.items[]
        | select(.metadata.name != $source)
        | select((.spec.restic.repository // "") == $secret)
        | select(any(.status.conditions[]?;
            .type == "Synchronizing" and .status == "True"))
        | .metadata.name')
active_destinations=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
    get replicationdestinations -o json | \
    jq -r --arg secret "${SECRET}" '.items[]
        | select((.spec.restic.repository // "") == $secret)
        | select(any(.status.conditions[]?;
            .type == "Synchronizing" and .status == "True"))
        | .metadata.name')
if [[ -n ${active_sources}${active_destinations} ]]; then
    [[ -z ${active_sources} ]] || {
        echo "Other active ReplicationSources using ${SECRET}:" >&2
        print_items "${active_sources}"
    }
    [[ -z ${active_destinations} ]] || {
        echo "Active ReplicationDestinations using ${SECRET}:" >&2
        print_items "${active_destinations}"
    }
    fail "Another replication may own a legitimate Restic lock"
fi

active_pods=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get pods -o json | \
    jq -r --arg secret "${SECRET}" '
        def all_containers: ((.spec.initContainers // []) + (.spec.containers // []));
        .items[]
        | select(.status.phase == "Pending" or .status.phase == "Running")
        | select(any(all_containers[]?;
            any(.envFrom[]?; .secretRef.name == $secret)
            or any(.env[]?; .valueFrom.secretKeyRef.name == $secret)))
        | .metadata.name')
if [[ -n ${active_pods} ]]; then
    echo "Pending or Running Pods using ${SECRET}:" >&2
    print_items "${active_pods}"
    fail "An active Pod may own a legitimate Restic lock"
fi

echo "Preflight passed: no active or ambiguous R2 repository owners found."
