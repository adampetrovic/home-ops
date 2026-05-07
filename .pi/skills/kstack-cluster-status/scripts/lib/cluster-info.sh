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

# cluster-info.sh — render the one-line cluster identity header for
# /cluster-status. Sourced, not executed. On failure writes a diagnostic to
# stderr and returns non-zero.

cluster_info::render() {
  local context="$1" file="$2"

  local k8s_version server_platform
  IFS=$'\t' read -r k8s_version server_platform <<EOF
$(jq -r '[.serverVersion.gitVersion // "", .serverVersion.platform // "unknown"] | @tsv' "$file" 2>/dev/null)
EOF

  if [ -z "$k8s_version" ]; then
    printf 'Server version missing from cached cluster.json.\n' >&2
    return 1
  fi

  local platform
  case "$k8s_version" in
    *-eks-*) platform="EKS" ;;
    *-gke.*) platform="GKE" ;;
    *+k3s*)  platform="k3s" ;;
    *+rke2*) platform="RKE2" ;;
    *)
      case "$context" in
        gke_*)         platform="GKE" ;;
        kind-*)        platform="kind" ;;
        arn:aws:eks:*) platform="EKS" ;;
        *-aks-*)       platform="AKS" ;;
        *)             platform="$server_platform" ;;
      esac
      ;;
  esac

  printf 'Cluster: %s · Kubernetes %s · %s\n' \
    "$context" "$k8s_version" "${platform:-unknown}"
}
