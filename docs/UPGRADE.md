# Upgrading Talos

This document is a reminder for upgrading your Talos Linux cluster, reflecting custom pre/post actions.

## Overview

Talos Linux OS upgrades are API-driven, typically via `task` files wrapping `talosctl` commands and custom scripts. Upgrades use an A-B image scheme for rollbacks.
**Note:** Talos OS upgrade does not upgrade Kubernetes.

## Supported Upgrade Paths

Upgrade to the latest patch release of all intermediate minor releases.
Example: `v1.0.x` -> latest `v1.0.y` -> latest `v1.1.z` -> `v1.2.x`.
Check official release pages for installer images. Your tasks likely use `factory.talos.dev/installer/`.

## Upgrade Procedure

1.  **Generate latest configuration:**
    Ensure your Talos machine configurations are up-to-date before upgrading any node. Run the following command:
    ```sh
    task talos:generate
    ```

2.  **Perform the upgrade via Taskfile:**
    Use your `Taskfile` to upgrade the node. The node IP is the primary parameter:
    ```sh
    task talos:upgrade node=<NODE_IP>
    ```
    Replace `<NODE_IP>` with the IP address of the node you wish to upgrade.

### Control Plane Nodes

-   Upgrade sequentially.

### Worker Nodes

-   Upgrade after control plane nodes are stable.
-   Consider upgrading a small batch first if not using a rollout strategy via your task.

## Monitoring

Kernel messages directly from the node:
```sh
talosctl dmesg -f --nodes <NODE_IP>
```
The upgrade task uses `--wait=true`, so it will block until completion or timeout. The script also has explicit health checks.

## Key Considerations

-   **Workload Disruption:** Node reboots are expected. The script attempts to manage service states (Flux, CNPG).
-   **Kubernetes Compatibility:** Verify Talos & K8s version compatibility.
-   **Machine Config Changes:** Review release notes for any impact on your `talhelper` configs.

## Upgrading Kubernetes

Talos OS upgrades do not upgrade Kubernetes. See the official [Upgrading Kubernetes](https://www.talos.dev/v1.10/kubernetes-guides/upgrading-kubernetes/) guide.

---

This guide summarizes your scripted upgrade. Always refer to the [official Talos documentation](https://www.talos.dev/latest/talos-guides/upgrading-talos/) for base `talosctl` behavior.
