#!/usr/bin/env bash
# Send Wake-on-LAN magic packets to every cluster node in parallel.
#
# Bringing all nodes up at the same time keeps the "first node Ready" window
# small, which (combined with the pre-shutdown cordon in docs/POWER-SHUTDOWN.md)
# stops the kube-scheduler from piling every pending pod onto a single node and
# hitting the kubelet maxPods=110 limit.
#
# Prerequisites:
#   - WoL enabled in BIOS on every node ("Power → Wake on LAN", and disable any
#     "Deep Sleep" / "ErP" / "EuP" power-saving option that cuts NIC power)
#   - `wakeonlan` installed (`brew install wakeonlan`)
#   - Run from a host on the same broadcast domain as the cluster
#     (10.0.80.0/21) — VPN/Tailscale won't carry the magic packet
#
# k8s-node-5 caveat: it uses an Intel X710 (i40e driver) which has limited WoL
# support. If it doesn't come up via WoL, power it on manually (physical button
# or smart plug). The other four NUCs use Intel I225/I226 (igc) which works.
set -Eeuo pipefail

# hostname / IP / MAC (from talos/talconfig.yaml deviceSelectors)
# Parallel arrays for bash 3.2 compatibility (macOS system bash).
HOSTNAMES=(
    k8s-node-1
    k8s-node-2
    k8s-node-3
    k8s-node-4
    k8s-node-5
)
IPS=(
    10.0.80.10
    10.0.80.11
    10.0.80.12
    10.0.80.13
    10.0.80.14
)
MACS=(
    "48:21:0b:58:8d:f8"
    "1c:69:7a:a7:68:82"
    "48:21:0b:59:26:b7"
    "1c:69:7a:a7:b4:7f"
    "58:47:ca:7e:e5:28"
)

if ! command -v wakeonlan &>/dev/null; then
    echo "error: wakeonlan not found. Install with: brew install wakeonlan" >&2
    exit 1
fi

echo "Sending WoL packets to ${#HOSTNAMES[@]} cluster nodes..."
for i in "${!HOSTNAMES[@]}"; do
    printf "  waking %-12s mac=%s ip=%s\n" "${HOSTNAMES[$i]}" "${MACS[$i]}" "${IPS[$i]}"
    wakeonlan "${MACS[$i]}" >/dev/null
done

cat <<'EOF'

Wake packets sent. Talos boots automatically (~60-90s per node).

Next steps (see docs/POWER-SHUTDOWN.md step 11+):
  1. Wait for the API:
     until talosctl health --nodes 10.0.80.10 --wait-timeout=10m --server=false; do sleep 15; done
  2. Wait for all nodes Ready:
     kubectl wait --for=condition=Ready nodes --all --timeout=10m
  3. Uncordon every node:
     kubectl uncordon k8s-node-1 k8s-node-2 k8s-node-3 k8s-node-4 k8s-node-5
EOF
