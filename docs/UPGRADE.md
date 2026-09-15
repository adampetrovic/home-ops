# Upgrading Talos

This document is a reminder for upgrading your Talos Linux cluster, reflecting custom pre/post actions.

## Overview

Talos Linux OS upgrades are API-driven, typically via `task` files wrapping `talosctl` commands and custom scripts. Upgrades use an A-B image scheme for rollbacks.
**Note:** Talos OS upgrade does not upgrade Kubernetes.

## Supported Upgrade Paths

Upgrade to the latest patch release of all intermediate minor releases.
Example: `v1.0.x` -> latest `v1.0.y` -> latest `v1.1.z` -> `v1.2.x`.
Check official release pages for installer images. Talos v1.14+ Image Factory metal installs use `factory.talos.dev/metal-installer/<schematic>:<version>`.

## Upgrade Procedure

1.  **Decide whether this is OS-only or machine-config-changing:**
    For OS-only upgrades, keep Talos machine-config modernization separate. Do not run `task talos:apply-node` or `task talos:apply-node-all` unless the approved plan includes applying rendered machine config.

2.  **Perform a one-node rollout:**
    Prefer the GitOps-managed Tuppr `TalosUpgrade` with a temporary `nodeSelector` and `parallelism: 1`. For manual fallback only, use the Taskfile with an explicit node:
    ```sh
    task talos:upgrade node=<node-name>
    ```
    Replace `<node-name>` with a node from `talos/inventory.yaml`, for example `k8s-node-4`.

### Worker Nodes

-   Prefer a worker canary first.
-   Upgrade remaining workers only after the canary is stable.

### Control Plane Nodes

-   Upgrade one control-plane node at a time after workers are stable.

## Monitoring

Kernel messages directly from the node:
```sh
talosctl dmesg -f --nodes <NODE_IP>
```
The upgrade task uses `--wait=true`, so it will block until completion or timeout. The script also has explicit health checks.

## Key Considerations

-   **Workload Disruption:** Node reboots are expected. The script attempts to manage service states (Flux, CNPG).
-   **Kubernetes Compatibility:** Verify Talos & K8s version compatibility.
-   **Machine Config Changes:** Review release notes for any impact on the native Talos templates under `talos/`; validate with `task talos:validate-all` and dry-run with `task talos:dry-run-all` before applying.

## Upgrading Kubernetes

Talos OS upgrades do not upgrade Kubernetes. See the official [Upgrading Kubernetes](https://www.talos.dev/v1.10/kubernetes-guides/upgrading-kubernetes/) guide.

---

This guide summarizes your scripted upgrade. Always refer to the [official Talos documentation](https://www.talos.dev/latest/talos-guides/upgrading-talos/) for base `talosctl` behavior.
