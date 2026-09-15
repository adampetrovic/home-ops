set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

alias render := render-config
alias apply := apply-node

nodes := 'k8s-node-1 k8s-node-2 k8s-node-3 k8s-node-4 k8s-node-5'
scripts_dir := source_directory() + '/scripts'

[doc('Render native Talos machine config for one node to stdout')]
render-config node:
    test -f "{{ source_directory() }}/cluster.yaml.j2"
    test -f "{{ source_directory() }}/inventory.yaml"
    command -v talosctl >/dev/null
    command -v op >/dev/null
    "{{ scripts_dir }}/render-config.sh" "{{ node }}"

[doc('Render all native Talos machine configs to /dev/null')]
render-all:
    test -f "{{ source_directory() }}/cluster.yaml.j2"
    for node in {{ nodes }}; do
        "{{ scripts_dir }}/render-config.sh" "${node}" >/dev/null
    done

[doc('Generate a Talos client config from 1Password-backed secrets')]
talosconfig talosconfig="":
    output="{{ talosconfig }}"
    if [[ -z "${output}" ]]; then
        output="${HOME}/.talos/config"
    fi
    mkdir -p "$(dirname "${output}")"
    tmp_secrets="$(mktemp)"
    trap 'rm -f "${tmp_secrets}"' EXIT
    "{{ scripts_dir }}/template.sh" "{{ source_directory() }}/secrets.yaml.j2" > "${tmp_secrets}"
    talosctl gen config home-kubernetes https://10.0.80.99:6443 \
        --with-secrets "${tmp_secrets}" \
        --output "${output}" \
        --output-types talosconfig \
        --with-docs=false \
        --with-examples=false \
        --force >/dev/null
    talosctl --talosconfig "${output}" config endpoint 10.0.80.99
    talosctl --talosconfig "${output}" config node 10.0.80.10 10.0.80.11 10.0.80.12 10.0.80.13 10.0.80.14

[doc('Resolve Talos Image Factory schematic ID')]
schematic-id node="":
    "{{ scripts_dir }}/schematic-id.sh" "{{ node }}"

[doc('Render and print a node UnattendedInstall installer image')]
machine-image node:
    "{{ scripts_dir }}/machine-image.sh" "{{ node }}"

[doc('Print a node Talos management address from talos/inventory.yaml')]
node-address node:
    "{{ scripts_dir }}/node-address.sh" "{{ node }}"

[doc('Validate rendered native Talos config for one node')]
validate node:
    command -v talosctl >/dev/null
    "{{ scripts_dir }}/render-config.sh" "{{ node }}" \
        | talosctl validate --mode=metal --strict --config /dev/stdin

[doc('Validate rendered native Talos configs for every node')]
validate-all:
    for node in {{ nodes }}; do
        just talos validate "${node}"
    done

[doc('Render and dry-run apply native Talos config against one live node')]
dry-run node:
    talosctl config info >/dev/null 2>&1
    node_address="$({{ scripts_dir }}/node-address.sh "{{ node }}")"
    "{{ scripts_dir }}/render-config.sh" "{{ node }}" \
        | talosctl --nodes "${node_address}" apply-config --dry-run -f /dev/stdin

[doc('Dry-run rendered native Talos config against every live node')]
dry-run-all:
    for node in {{ nodes }}; do
        just talos dry-run "${node}"
    done

[confirm('Apply rendered Talos config to ' + node + ' with mode=' + mode + ' [y/N]?')]
[doc('Apply rendered native Talos config to one live node')]
apply-node node mode="try":
    talosctl config info >/dev/null 2>&1
    talosctl --nodes "$({{ scripts_dir }}/node-address.sh "{{ node }}")" get machineconfig >/dev/null 2>&1
    node_address="$({{ scripts_dir }}/node-address.sh "{{ node }}")"
    "{{ scripts_dir }}/render-config.sh" "{{ node }}" \
        | talosctl --nodes "${node_address}" apply-config --mode={{ mode }} -f /dev/stdin

[confirm('Apply rendered Talos config insecurely to ' + node + ' [y/N]?')]
[doc('Apply rendered Talos config to one node in maintenance mode')]
apply-insecure-node node:
    command -v talosctl >/dev/null
    node_address="$({{ scripts_dir }}/node-address.sh "{{ node }}")"
    "{{ scripts_dir }}/render-config.sh" "{{ node }}" \
        | talosctl --nodes "${node_address}" apply-config --insecure -f /dev/stdin

[confirm('Apply rendered Talos configs insecurely to all nodes [y/N]?')]
[doc('Apply rendered Talos configs insecurely to all nodes')]
apply-insecure-all confirm:
    if [[ "{{ confirm }}" != "bootstrap" ]]; then
        echo "Refusing insecure all-node apply unless confirm argument is 'bootstrap'" >&2
        exit 64
    fi
    for node in {{ nodes }}; do
        just --yes talos apply-insecure-node "${node}"
    done

[doc('Validate all native Talos configs; native rendering writes no generated machine configs')]
generate:
    just talos validate-all

[confirm('Upgrade Talos on ' + node + ' [y/N]?')]
[doc('Break-glass Talos upgrade on a single node using rendered installer image')]
upgrade node rollout="false":
    talosctl config info >/dev/null 2>&1
    talosctl --nodes "$({{ scripts_dir }}/node-address.sh "{{ node }}")" get machineconfig >/dev/null 2>&1
    node_address="$({{ scripts_dir }}/node-address.sh "{{ node }}")"
    talos_image="$({{ scripts_dir }}/machine-image.sh "{{ node }}")"
    bash "{{ scripts_dir }}/upgrade.sh" "${node_address}" "${talos_image}" "{{ rollout }}"

[confirm('Run break-glass Talos rollout for supplied nodes [y/N]?')]
[doc('Break-glass Talos rollout on supplied comma-separated node names')]
upgrade-rollout nodes confirm:
    if [[ "{{ confirm }}" != "all-nodes" ]]; then
        echo "Refusing all-node Talos rollout unless confirm argument is 'all-nodes'" >&2
        exit 64
    fi
    talosctl config info >/dev/null 2>&1
    kubectl get ns -o jsonpath='{.items[*].metadata.name}' | xargs -n1 -I {} flux suspend kustomization --all -n {}
    kubectl cnpg maintenance set --reusePVC --all-namespaces
    IFS=',' read -ra rollout_nodes <<< "{{ nodes }}"
    for node in "${rollout_nodes[@]}"; do
        just --yes talos upgrade "${node}" true
    done
    kubectl cnpg maintenance unset --reusePVC --all-namespaces
    kubectl get ns -o jsonpath='{.items[*].metadata.name}' | xargs -n1 -I {} flux resume kustomization --all -n {}
    just kube delete-failed-pods

[confirm('Upgrade Kubernetes to ' + to + ' from ' + node + ' [y/N]?')]
[doc('Upgrade Kubernetes from a control-plane node')]
upgrade-k8s to node="k8s-node-1":
    talosctl --nodes "$({{ scripts_dir }}/node-address.sh "{{ node }}")" get machineconfig >/dev/null 2>&1
    node_address="$({{ scripts_dir }}/node-address.sh "{{ node }}")"
    talosctl --nodes "${node_address}" upgrade-k8s --to {{ to }}

[confirm('Reboot node ' + node + ' with mode=' + mode + ' [y/N]?')]
[doc('Reboot Talos on a single node')]
reboot-node node mode="powercycle":
    talosctl --nodes "$({{ scripts_dir }}/node-address.sh "{{ node }}")" get machineconfig >/dev/null 2>&1
    command -v talosctl >/dev/null
    node_address="$({{ scripts_dir }}/node-address.sh "{{ node }}")"
    talosctl --nodes "${node_address}" reboot --mode={{ mode }}

[doc('Fetch kubeconfig from a Talos node')]
fetch-kubeconfig node="k8s-node-1":
    talosctl config info >/dev/null 2>&1
    node_address="$({{ scripts_dir }}/node-address.sh "{{ node }}")"
    talosctl --nodes "${node_address}" kubeconfig --force

[doc('Bootstrap etcd from a rendered control-plane node')]
bootstrap node="k8s-node-1":
    talosctl config info >/dev/null 2>&1
    node_address="$({{ scripts_dir }}/node-address.sh "{{ node }}")"
    talosctl --nodes "${node_address}" bootstrap

[confirm('DESTROY the cluster and reset all nodes to maintenance mode [y/N]?')]
[doc('Reset all Talos nodes back to maintenance mode')]
nuke confirm:
    if [[ "{{ confirm }}" != "destroy-cluster" ]]; then
        echo "Refusing cluster reset unless confirm argument is 'destroy-cluster'" >&2
        exit 64
    fi
    talosctl config info >/dev/null 2>&1
    for node in {{ nodes }}; do
        node_address="$({{ scripts_dir }}/node-address.sh "${node}")"
        talosctl --nodes "${node_address}" reset \
            --reboot \
            --system-labels-to-wipe STATE \
            --system-labels-to-wipe EPHEMERAL \
            --graceful=false \
            --wait=false
    done
