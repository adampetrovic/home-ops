set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

kubernetes_api_endpoint := '10.0.80.99'
bootstrap_controller := 'k8s-node-1'
nodes := `yq -r '.nodes | keys | join(" ")' inventory.yaml`
node_addresses := `yq -r '.nodes | to_entries | map(.value) | join(" ")' inventory.yaml`
scripts_dir := source_directory() + '/scripts'

[doc('Render native Talos machine config for one node to stdout')]
render-config node:
    test -f "{{ source_directory() }}/cluster.yaml.j2"
    test -f "{{ source_directory() }}/inventory.yaml"
    command -v talosctl >/dev/null
    command -v op >/dev/null
    "{{ scripts_dir }}/render-config.sh" "{{ node }}"

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
    talosctl gen config home-kubernetes https://{{ kubernetes_api_endpoint }}:6443 \
        --with-secrets "${tmp_secrets}" \
        --output "${output}" \
        --output-types talosconfig \
        --with-docs=false \
        --with-examples=false \
        --force >/dev/null
    chmod 0600 "${output}"
    talosctl --talosconfig "${output}" config endpoint {{ node_addresses }}
    talosctl --talosconfig "${output}" config node {{ node_addresses }}

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

[confirm('Upgrade Talos on ' + node + ' [y/N]?')]
[doc('Break-glass Talos upgrade on a single node using rendered installer image')]
upgrade node rollout="false":
    talosctl config info >/dev/null 2>&1
    talosctl --nodes "$({{ scripts_dir }}/node-address.sh "{{ node }}")" get machineconfig >/dev/null 2>&1
    node_address="$({{ scripts_dir }}/node-address.sh "{{ node }}")"
    talos_image="$({{ scripts_dir }}/machine-image.sh "{{ node }}")"
    bash "{{ scripts_dir }}/upgrade.sh" "${node_address}" "${talos_image}" "{{ rollout }}"

[doc('Fetch kubeconfig from a Talos node')]
fetch-kubeconfig node=bootstrap_controller:
    talosctl config info >/dev/null 2>&1
    node_address="$({{ scripts_dir }}/node-address.sh "{{ node }}")"
    talosctl --endpoints "${node_address}" --nodes "${node_address}" kubeconfig --force

[doc('Bootstrap etcd from a rendered control-plane node')]
bootstrap node=bootstrap_controller:
    talosctl config info >/dev/null 2>&1
    node_address="$({{ scripts_dir }}/node-address.sh "{{ node }}")"
    talosctl --endpoints "${node_address}" --nodes "${node_address}" bootstrap

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
