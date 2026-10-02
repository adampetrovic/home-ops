#!/usr/bin/env bash
set -Eeuo pipefail

namespace="${GDB_NAMESPACE:-gdb}"
context_args=()
if [[ -n "${KUBECONTEXT:-}" ]]; then
    context_args+=(--context "${KUBECONTEXT}")
fi

target_id="${USAG_TARGET_ID:-3000000}"

green=$'\033[32m'
yellow=$'\033[33m'
red=$'\033[31m'
blue=$'\033[34m'
reset=$'\033[0m'

function heading() {
    printf '\n%s== %s ==%s\n' "${blue}" "$1" "${reset}"
}

function warn() {
    printf '%sWARN:%s %s\n' "${yellow}" "${reset}" "$*" >&2
}

function kubectl_gdb() {
    if [[ ${#context_args[@]} -gt 0 ]]; then
        kubectl "${context_args[@]}" -n "${namespace}" "$@"
    else
        kubectl -n "${namespace}" "$@"
    fi
}

function has_resource() {
    kubectl_gdb get "$1" "$2" >/dev/null 2>&1
}

function print_or_none() {
    local label="${1}"
    local output="${2}"
    if [[ -n "${output}" ]]; then
        printf '%s\n' "${output}"
    else
        printf '%s: none\n' "${label}"
    fi
}

heading "GDB namespace"
printf 'namespace: %s\n' "${namespace}"

heading "Flux"
print_or_none "kustomizations" "$(kubectl_gdb get kustomizations.kustomize.toolkit.fluxcd.io 2>/dev/null || true)"
print_or_none "helmreleases" "$(kubectl_gdb get helmreleases.helm.toolkit.fluxcd.io 2>/dev/null || true)"

heading "Jobs / pods"
print_or_none "jobs" "$(kubectl_gdb get jobs 2>/dev/null || true)"
print_or_none "pods" "$(kubectl_gdb get pods 2>/dev/null || true)"

heading "Database counts"
if has_resource pod gdb-postgres-1; then
    if counts="$(kubectl_gdb exec gdb-postgres-1 -c postgres -- psql -U postgres -d gdb -Atqc "
select 'people=' || count(*) from people;
select 'rainbow=' || count(*) from usagnum_hash_lookup;
select 'results=' || count(*) from result;
select 'sanctions=' || count(*) from sanctions;
select 'coverage_rows=' || count(*) from source_coverage;
select 'schema=' || version || ',dirty=' || dirty from schema_migrations;
" 2>/dev/null)"; then
        printf '%s\n' "${counts}"
    else
        warn "failed to query gdb-postgres counts"
    fi
else
    warn "gdb-postgres-1 pod not found"
fi

heading "USAG bootstrap"
usag_job="${USAG_JOB:-gdb-usag-bootstrap-full}"
if has_resource job "${usag_job}"; then
    kubectl_gdb get job "${usag_job}"
    usag_pod="$(kubectl_gdb get pod -l "job-name=${usag_job}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${usag_pod}" ]]; then
        kubectl_gdb get pod "${usag_pod}"
        tmp_log="$(mktemp)"
        kubectl_gdb logs "${usag_pod}" --tail="${USAG_LOG_TAIL:-500}" >"${tmp_log}" 2>/dev/null || true
        python3 - "${tmp_log}" "${target_id}" <<'PY'
import datetime as dt
import pathlib
import re
import statistics
import sys

path = pathlib.Path(sys.argv[1])
target = int(sys.argv[2])
text = path.read_text(errors="replace")
progress_re = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*Checked: ([\d,]+).*Found: ([\d,]+).*ID: ([\d,]+)",
    re.M,
)
points = []
for match in progress_re.finditer(text):
    when = dt.datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=dt.timezone.utc)
    checked = int(match.group(2).replace(",", ""))
    found = int(match.group(3).replace(",", ""))
    member_id = int(match.group(4).replace(",", ""))
    points.append((when, checked, found, member_id))

if not points:
    print("progress: no 'Checked:' progress lines found in recent logs")
    sys.exit(0)

last = points[-1]
print(f"last_log_utc={last[0].isoformat(timespec='seconds')} checked={last[1]:,} found={last[2]:,} id={last[3]:,} target={target:,}")
remaining = max(target - last[3], 0)
print(f"remaining_ids={remaining:,} percent={last[3] / target * 100:.2f}%")

rates = []
for before, after in zip(points, points[1:]):
    seconds = (after[0] - before[0]).total_seconds()
    if seconds > 0 and after[3] >= before[3]:
        rates.append((after[3] - before[3]) / seconds * 60)

if rates:
    recent = rates[-5:]
    recent_rate = statistics.mean(recent)
    print(f"recent_rate_ids_per_min={recent_rate:,.0f} interval_rates={','.join(str(round(r)) for r in recent)}")
    if recent_rate > 0:
        eta_seconds = remaining / (recent_rate / 60)
        done = dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=eta_seconds)
        print(f"eta_hours={eta_seconds / 3600:.1f} eta_done_utc={done.isoformat(timespec='seconds')}")

if len(points) >= 2:
    first = points[0]
    elapsed = (last[0] - first[0]).total_seconds()
    if elapsed > 0:
        total_rate = (last[3] - first[3]) / elapsed * 60
        print(f"tail_average_rate_ids_per_min={total_rate:,.0f}")
PY
        rm -f "${tmp_log}"
        printf 'recent log:\n'
        kubectl_gdb logs "${usag_pod}" --tail=8 2>/dev/null || true
    fi
else
    printf 'job %s: not found\n' "${usag_job}"
fi

heading "MSO fetch-cache"
mso_job="${MSO_FETCH_JOB:-gdb-scrapers-mso-fetch-bootstrap}"
if has_resource job "${mso_job}"; then
    kubectl_gdb get job "${mso_job}"
    mso_pod="$(kubectl_gdb get pod -l "job-name=${mso_job}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${mso_pod}" ]]; then
        kubectl_gdb get pod "${mso_pod}"
        printf 'env_has_database_url='
        if kubectl_gdb get pod "${mso_pod}" -o json | jq -e '.spec.containers[0].env[]? | select(.name == "DATABASE_URL")' >/dev/null; then
            printf 'yes\n'
        else
            printf 'no\n'
        fi
        kubectl_gdb logs "${mso_pod}" --tail=40 2>/dev/null | grep -E 'MSO fetch plan|MSO fetch progress|validation passed|Incomplete|ERROR|Cached MSO|Wrote MSO' | tail -20 || true
    fi
else
    printf 'job %s: not found\n' "${mso_job}"
fi

heading "Scraper CronJobs"
print_or_none "cronjobs" "$(kubectl_gdb get cronjobs 2>/dev/null || true)"

heading "Useful commands"
cat <<EOF
USAG logs: kubectl -n ${namespace} logs -f job/${usag_job}
MSO logs:  kubectl -n ${namespace} logs -f job/${mso_job}
DB shell:  kubectl -n ${namespace} exec -it gdb-postgres-1 -c postgres -- psql -U postgres -d gdb
EOF
