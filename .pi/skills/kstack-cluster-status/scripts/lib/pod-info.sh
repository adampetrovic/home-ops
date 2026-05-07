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

# pod-info.sh — render a bounded one-line pod summary for /cluster-status.
# Sourced, not executed. Outputs:
#
#   Pods   X/Y Ready · N pod(s) with restarts
#
# Issue analysis is left to the agent, which reads pods.json from cache_dir.

pod_info::render() {
  local file="$1"

  local summary
  summary="$(jq -r '
    def is_terminal_success: .status.phase == "Succeeded";

    def is_ready:
      (.status.containerStatuses // []) as $cs
      | (.spec.containers // []) as $spec
      | ($cs | length) > 0
        and ($cs | length) == ($spec | length)
        and all($cs[]; .ready == true);

    def total_restarts:
      (.status.containerStatuses // []) | map(.restartCount // 0) | add // 0;

    ([.items[] | select(is_terminal_success | not)]) as $active
    | ($active | length) as $total
    | ([$active[] | select(is_ready)] | length) as $ready
    | ([$active[] | select(total_restarts > 0)] | length) as $with_restarts
    | "\($ready)/\($total) Ready · \($with_restarts) pod(s) with restarts"
  ' "$file" 2>/dev/null)"

  if [ -z "$summary" ]; then
    printf 'No pods found.\n' >&2
    return 1
  fi

  printf 'Pods   %s\n' "$summary"
}
