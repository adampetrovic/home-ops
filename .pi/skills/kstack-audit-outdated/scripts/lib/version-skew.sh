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

# version-skew.sh — renders the Kubernetes version skew block for /audit-outdated.
#
# Compares control-plane server version against node kubelet versions and
# reports skew + end-of-life status. EOL dates are fetched from the
# endoflife.date API rather than a hardcoded table.

_ENDOFLIFE_API_URL="https://endoflife.date/api/v1/products/kubernetes"

# _version_skew::parse_major_minor <gitVersion>
#   Extract "major.minor" from a version string like "v1.31.2" → "1.31"
_version_skew::parse_major_minor() {
  local v="${1#v}"
  printf '%s' "${v%.*}"
}

# _version_skew::fetch_eol <minor_version>
#   Fetch EOL data from endoflife.date API. Prints "eolFrom|isEol|latest"
#   to stdout (latest may be empty when the API doesn't expose it).
#   Returns 1 if the API is unreachable or the version is not found.
_version_skew::fetch_eol() {
  local minor="$1"
  local api_response

  # Query the per-cycle endpoint directly instead of fetching the full product
  # catalog — smaller payload and avoids scanning the entire array with jq.
  api_response="$(curl -sf --max-time 10 "$_ENDOFLIFE_API_URL/$minor/" 2>/dev/null)" || return 1

  local result
  result="$(printf '%s' "$api_response" \
    | jq -r '"\(.eolFrom)|\(.isEol)|\(.latest // "")"' 2>/dev/null)" || return 1

  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

# _version_skew::format_support <eol_from> <is_eol>
#   Print the "Support …" line. Truncates the date to YYYY-MM.
_version_skew::format_support() {
  local eol_from="${1:0:7}" is_eol="$2"
  if [ "$is_eol" = "true" ]; then
    printf '  Support        End-of-life since %s\n' "$eol_from"
  else
    printf '  Support        Supported until %s\n' "$eol_from"
  fi
}

# _version_skew::patches_behind <current_full> <latest_full>
#   Print the integer number of patches the current version is behind
#   `latest`, or print nothing when current >= latest, when either input
#   is empty, or when the patch components don't parse as integers.
_version_skew::patches_behind() {
  local current_patch="${1##*.}" latest_patch="${2##*.}"
  case "$current_patch" in ''|*[!0-9]*) return 0 ;; esac
  case "$latest_patch"  in ''|*[!0-9]*) return 0 ;; esac
  if [ "$latest_patch" -gt "$current_patch" ]; then
    printf '%d' "$(( latest_patch - current_patch ))"
  fi
}

# version_skew::render <cluster.json> <nodes.json>
#   Render the version skew block to stdout. Returns non-zero on read errors.
version_skew::render() {
  local cluster_file="$1" nodes_file="$2"

  if [ ! -f "$cluster_file" ]; then
    echo "Cannot read cluster version file: $cluster_file" >&2
    return 1
  fi
  if [ ! -f "$nodes_file" ]; then
    echo "Cannot read nodes file: $nodes_file" >&2
    return 1
  fi

  # Extract server version
  local server_version
  server_version="$(jq -r '.serverVersion.gitVersion' "$cluster_file")" || return 1
  local server_minor
  server_minor="$(_version_skew::parse_major_minor "$server_version")"

  # Extract node kubelet versions
  local node_count=0 match_count=0 behind_count=0 node_minor=""
  local node_versions
  node_versions="$(jq -r '.items[].status.nodeInfo.kubeletVersion' "$nodes_file")" || return 1

  while IFS= read -r nv; do
    [ -z "$nv" ] && continue
    node_count=$(( node_count + 1 ))
    # Inline parse_major_minor to avoid a subshell fork per node.
    local _tmp="${nv#v}"; node_minor="${_tmp%.*}"
    if [ "$node_minor" = "$server_minor" ]; then
      match_count=$(( match_count + 1 ))
    else
      behind_count=$(( behind_count + 1 ))
    fi
  done <<< "$node_versions"

  # Build output
  printf '  Control plane  %s\n' "$server_version"

  if [ "$behind_count" -eq 0 ]; then
    printf '  Nodes          %s (%d/%d match)\n' "$server_version" "$match_count" "$node_count"
  else
    printf '  Nodes          %d/%d match, %d behind\n' "$match_count" "$node_count" "$behind_count"
  fi

  local eol_data
  if ! eol_data="$(_version_skew::fetch_eol "$server_minor")"; then
    printf '  Support        Unable to fetch EOL data from endoflife.date\n'
    return 0
  fi

  local eol_from is_eol latest behind
  IFS='|' read -r eol_from is_eol latest <<< "$eol_data"

  behind="$(_version_skew::patches_behind "$server_version" "$latest")"
  if [ -n "$behind" ]; then
    printf '  Latest patch   v%s (%d patches behind)\n' "$latest" "$behind"
  fi

  _version_skew::format_support "$eol_from" "$is_eol"
}
