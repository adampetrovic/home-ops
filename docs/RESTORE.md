# Restore / Bootstrap

Make sure sops key is saved to `~/.config/sops/age/keys.txt`. You can get this from 1password under the item 'sops-age-key'
### Nuking Existing Cluster

1. Reset the cluster
   ```
   task talos:hard-nuke
   ```

*Alternatively*, download the latest `metal-amd64.iso` from the [Talos releases page](https://github.com/siderolabs/talos/releases/tag/v1.8.0) and boot each of the nodes into maintenance mode. Each of the nodes should have statically assigned IP addresses from the Unifi DHCP server (`10.0.80.10-13`)

### Bootstrapping New Cluster

At this point the cluster should be in maintenance mode with everything reset to defaults. Now we need to bootstrap the cluster to get it ready for workloads.

1.  Deploy your cluster and bootstrap it.  This generates secrets, generates the config files for your nodes and applies them. It bootstraps the cluster afterwards, fetches the kubeconfig file and installs Cilium and kubelet-csr-approver. It finishes with some health checks.

    ```
      task talos:bootstrap
    ```

2. ⚠️ It might take a while for the cluster to be setup (10+ minutes is normal), during which time you will see a variety of error messages like: "couldn't get current server API group list," "error: no matching resources found", etc. This is a normal. If this step gets interrupted, e.g. by pressing `Ctrl + C`, you likely will need to nuke the cluster before trying again.

3. Move the kubeconfig file that's generated to the global directory
    ```
    mv kubeconfig ~/.kube/config
    ```

4. Verify the nodes are online

    ```sh
    kubectl get nodes -o wide
    # NAME           STATUS   ROLES                       AGE     VERSION
    # k8s-0          Ready    control-plane,etcd,master   1h      v1.29.1
    # k8s-1          Ready    worker                      1h      v1.29.1
    ```

### Install Flux in the cluster

1. Verify Flux can be installed

    ```sh
    flux check --pre
    # ► checking prerequisites
    # ✔ kubectl 1.27.3 >=1.18.0-0
    # ✔ Kubernetes 1.27.3+k3s1 >=1.16.0-0
    # ✔ prerequisites checks passed
    ```

1. Install Github Deploy Key & Flux and sync the cluster to the Git repository

    ```sh
    task flux:github-deploy-key
    task flux:bootstrap
    # namespace/flux-system configured
    # customresourcedefinition.apiextensions.k8s.io/alerts.notification.toolkit.fluxcd.io created
    # ...
    ```

1. Verify Flux components are running in the cluster

    ```sh
    kubectl -n flux-system get pods -o wide
    # NAME                                       READY   STATUS    RESTARTS   AGE
    # helm-controller-5bbd94c75-89sb4            1/1     Running   0          1h
    # kustomize-controller-7b67b6b77d-nqc67      1/1     Running   0          1h
    # notification-controller-7c46575844-k4bvr   1/1     Running   0          1h
    # source-controller-7d6875bcb4-zqw9f         1/1     Running   0          1h
    ```

### Verification Steps

In a few moments applications should be lighting up like Christmas in July 🎄

1. Output all the common resources in your cluster.

    📍 _Feel free to use the provided [kubernetes tasks](.taskfiles/Kubernetes/Taskfile.yaml) for validation of cluster resources or continue to get familiar with the `kubectl` and `flux` CLI tools._

    ```sh
    # look for errors or warnings from the following
    kubectl get kustomization -A
    kubectl get helmrelease -A

    ```

2. ⚠️ It might take `cert-manager` awhile to generate certificates, this is normal so be patient.

### Final Step

1. If there are volsync backups already configured at the locations your PVCs specify, then they should start being hydrated from the last snapshot. Confirm your apps have their data restored after they start!
