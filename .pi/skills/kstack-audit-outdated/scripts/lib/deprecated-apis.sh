# Copyright 2026 The Kubetail Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# shellcheck shell=bash

# deprecated-apis.sh — detects deprecated/removed API versions for /audit-outdated.
#
# Uses pluggable backends in priority order:
#   1. pluto  (if installed) — parsed in bash (structured JSON)
#   2. kubent (if installed) — parsed in bash (structured JSON)
#   3. kubernetes.io deprecation guide (web fetch) — raw page passed to agent
#
# When the web fallback is used, this script does NOT parse the HTML. Instead
# it sets DEPRECATED_APIS_AGENT_NEEDED=true and populates:
#   DEPRECATED_APIS_RAW_PAGE       — raw HTML/markdown from kubernetes.io
#   DEPRECATED_APIS_ACTIVE_VERSIONS — output of kubectl api-versions
# The caller (scripts/main) is responsible for emitting a render:agent envelope
# so the LLM can cross-reference the two.

_DEPRECATION_GUIDE_URL="https://kubernetes.io/docs/reference/using-api/deprecation-guide/"

# Caller-visible state for the web fallback path.
DEPRECATED_APIS_AGENT_NEEDED=""
DEPRECATED_APIS_RAW_PAGE=""
DEPRECATED_APIS_ACTIVE_VERSIONS=""

# _deprecated_apis::version_lt <a> <b>
#   True if version a < b (comparing as major.minor integers).
_deprecated_apis::version_lt() {
  local a_major="${1%%.*}" a_minor="${1#*.}"
  local b_major="${2%%.*}" b_minor="${2#*.}"
  if [ "$a_major" -lt "$b_major" ]; then return 0; fi
  if [ "$a_major" -gt "$b_major" ]; then return 1; fi
  [ "$a_minor" -lt "$b_minor" ]
}

# --- Backend: pluto ---

_deprecated_apis::pluto_available() {
  command -v pluto >/dev/null 2>&1
}

_deprecated_apis::pluto_scan() {
  local raw
  raw="$(pluto detect-all-in-cluster --context="${KSTACK_KUBE_CONTEXT:-}" -o json 2>/dev/null)" || return 1
  printf '%s' "$raw" | jq -r '.[] | "\(.api.version)|\(.removedIn)|\(.replaceWith)"' 2>/dev/null
}

# --- Backend: kubent ---

_deprecated_apis::kubent_available() {
  command -v kubent >/dev/null 2>&1
}

_deprecated_apis::kubent_scan() {
  local raw
  raw="$(kubent --context="${KSTACK_KUBE_CONTEXT:-}" -o json 2>/dev/null)" || return 1
  printf '%s' "$raw" | jq -r '.[] | "\(.ApiVersion)|\(.Since)|\(.ReplaceWith)"' 2>/dev/null
}

# --- Backend: web (kubernetes.io deprecation guide) ---
# This backend does NOT parse in bash. It fetches the raw page and signals
# the caller to delegate parsing to the agent.

_deprecated_apis::web_available() {
  command -v curl >/dev/null 2>&1
}

_deprecated_apis::web_fetch() {
  local page api_versions
  page="$(curl -sf --max-time 15 "$_DEPRECATION_GUIDE_URL" 2>/dev/null)" || return 1
  [ -n "$page" ] || return 1

  api_versions="$(kubectl --context="${KSTACK_KUBE_CONTEXT:-}" api-versions 2>/dev/null)" || {
    echo "Unable to query API versions from cluster." >&2
    return 1
  }

  DEPRECATED_APIS_AGENT_NEEDED="true"
  DEPRECATED_APIS_RAW_PAGE="$page"
  DEPRECATED_APIS_ACTIVE_VERSIONS="$api_versions"
}

# --- Backend availability (public) ---

# deprecated_apis::available_backends
#   Print one backend name per line for each tool installed, in priority order:
#   pluto, kubent, web. Empty output means no backend is usable.
deprecated_apis::available_backends() {
  _deprecated_apis::pluto_available  && printf 'pluto\n'
  _deprecated_apis::kubent_available && printf 'kubent\n'
  _deprecated_apis::web_available    && printf 'web\n'
  return 0
}

# --- Orchestrator ---

# deprecated_apis::render_backend <backend> <cluster_minor_version>
#   Run the named backend (pluto|kubent|web). For pluto/kubent, prints a
#   formatted findings block to stdout. For web, sets DEPRECATED_APIS_*
#   variables and prints nothing (caller handles the agent envelope).
#   Returns non-zero if the backend fails to produce output.
deprecated_apis::render_backend() {
  local backend="$1" cluster_minor="$2"
  local rows=""

  # shellcheck disable=SC2034  # read by callers (scripts/main, scripts/deprecated-apis)
  DEPRECATED_APIS_AGENT_NEEDED=""
  # shellcheck disable=SC2034
  DEPRECATED_APIS_RAW_PAGE=""
  # shellcheck disable=SC2034
  DEPRECATED_APIS_ACTIVE_VERSIONS=""

  case "$backend" in
    pluto)
      rows="$(_deprecated_apis::pluto_scan 2>/dev/null)" || rows="" ;;
    kubent)
      rows="$(_deprecated_apis::kubent_scan 2>/dev/null)" || rows="" ;;
    web)
      if _deprecated_apis::web_fetch 2>/dev/null; then
        return 0
      fi
      echo "Unable to fetch deprecation guide from kubernetes.io." >&2
      return 1 ;;
    *)
      echo "Unknown backend: $backend" >&2
      return 1 ;;
  esac

  # --- Structured backend (pluto/kubent): parse and render in bash ---

  # Deduplicate rows (pluto/kubent may report per-resource, not per-API version).
  if [ -n "$rows" ]; then
    rows="$(printf '%s' "$rows" | sort -t'|' -k1,1 -k2,2 -u)"
  fi

  local count=0
  local found=()
  while IFS='|' read -r gv removed_in replacement; do
    [ -z "$gv" ] && continue
    local status_label
    if _deprecated_apis::version_lt "$cluster_minor" "$removed_in"; then
      status_label="deprecated, removed in $removed_in"
    else
      status_label="removed in $removed_in"
    fi
    found+=("$(printf '%s|%s|%s|%s' "$gv" "$removed_in" "$status_label" "$replacement")")
    count=$(( count + 1 ))
  done <<< "$rows"

  if [ "$count" -eq 0 ]; then
    printf '  No deprecated APIs detected (via %s).\n' "$backend"
    return 0
  fi

  local sorted
  sorted="$(printf '%s\n' "${found[@]}" | sort -t'|' -k2,2)"

  printf '  Deprecated APIs (%d, via %s):\n' "$count" "$backend"
  while IFS='|' read -r gv removed_in status_label replacement; do
    if [ -n "$replacement" ]; then
      printf '    %-50s %s → %s\n' "$gv" "$status_label" "$replacement"
    else
      printf '    %-50s %s\n' "$gv" "$status_label"
    fi
  done <<< "$sorted"
}

# deprecated_apis::render <cluster_minor_version>
#   Legacy auto-select entrypoint: picks the best available backend and runs
#   it. For the new /audit-outdated orchestration, prefer render_backend with
#   an explicit backend chosen (or confirmed) at the main layer.
deprecated_apis::render() {
  local cluster_minor="$1"
  local backends
  backends="$(deprecated_apis::available_backends)"

  if [ -n "$backends" ]; then
    local backend
    backend="$(printf '%s\n' "$backends" | head -n1)"
    if deprecated_apis::render_backend "$backend" "$cluster_minor" 2>/dev/null; then
      return 0
    fi
    # Backend failed at runtime (e.g. curl exit 1) — fall through to the
    # "unable to detect" message so callers get a graceful response.
  fi

  printf '  Unable to detect deprecated APIs: no backend available.\n'
  printf '  Install pluto or kubent, or ensure curl can reach kubernetes.io.\n'
  return 0
}
