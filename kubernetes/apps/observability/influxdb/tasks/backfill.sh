#!/usr/bin/env bash
set -Eeuo pipefail

# Runs homeassistant-hourly.flux over [START, STOP) one week at a time, so each
# query stays well inside InfluxDB's memory limits. Writes are idempotent, so a
# failed or repeated chunk can simply be re-run.
#
# Usage: INFLUX_HOST=... INFLUX_ORG=... INFLUX_TOKEN=... ./backfill.sh START STOP
#   e.g. ./backfill.sh 2024-03-04T00:00:00Z 2026-10-16T00:00:00Z

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
task_file="${script_dir}/homeassistant-hourly.flux"

start="${1:?start time (RFC3339) required}"
stop="${2:?stop time (RFC3339) required}"

: "${INFLUX_HOST:?}" "${INFLUX_ORG:?}" "${INFLUX_TOKEN:?}"

to_epoch() {
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s
}

to_rfc3339() {
    date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

chunk_start=$(to_epoch "${start}")
end=$(to_epoch "${stop}")
week=$((7 * 24 * 3600))

while ((chunk_start < end)); do
    chunk_stop=$((chunk_start + week))
    ((chunk_stop > end)) && chunk_stop=${end}
    from_ts=$(to_rfc3339 "${chunk_start}")
    to_ts=$(to_rfc3339 "${chunk_stop}")

    query=$(sed \
        -e '/^option task/d' \
        -e "s|^stop = .*|stop = ${to_ts}|" \
        -e "s|^start = .*|start = ${from_ts}|" \
        "${task_file}")

    printf '%s → %s ... ' "${from_ts}" "${to_ts}"
    influx query --raw "${query}" > /dev/null
    echo "ok"

    chunk_start=${chunk_stop}
done
