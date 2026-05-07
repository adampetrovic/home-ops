#!/usr/bin/env bash

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

# node-info.sh — render a bounded one-line node summary for /cluster-status.
# Sourced, not executed. Outputs: "Nodes  X/Y Ready · N pressure · M
# unschedulable · roles: A cp, B worker". Full per-node details are
# available on demand from the cached nodes.json.

node_info::render() {
  local file="$1"

  local summary
  summary="$(jq -r '
    def is_ready:
      (.status.conditions // [])
      | any(.[]; .type == "Ready" and .status == "True");

    def has_pressure:
      (.status.conditions // [])
      | any(.[];
          (.type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure")
          and .status == "True");

    def role:
      (.metadata.labels // {})
      | keys_unsorted
      | map(select(startswith("node-role.kubernetes.io/")))
      | map(sub("node-role.kubernetes.io/"; ""))
      | if length == 0 then "worker" else .[0] end;

    (.items | length) as $total
    | ([.items[] | select(is_ready)] | length) as $ready
    | ([.items[] | select(has_pressure)] | length) as $pressure
    | ([.items[] | select(.spec.unschedulable // false)] | length) as $unsched
    | ([.items[] | select(role | startswith("control-plane") or . == "master")] | length) as $cp
    | ([.items[] | select(role | (startswith("control-plane") or . == "master") | not)] | length) as $worker
    | "\($ready)/\($total) Ready · \($pressure) pressure · \($unsched) unschedulable · \($cp) control-plane, \($worker) worker"
  ' "$file" 2>/dev/null)"

  if [ -z "$summary" ]; then
    printf 'No nodes found.\n' >&2
    return 1
  fi

  printf 'Nodes  %s\n' "$summary"
}
