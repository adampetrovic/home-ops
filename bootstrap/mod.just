set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

repo_root := source_directory() + '/..'
export KUBECONFIG := env_var_or_default('KUBECONFIG', repo_root + '/kubeconfig')
export TALOSCONFIG := env_var_or_default('TALOSCONFIG', repo_root + '/talosconfig')

[confirm('Bootstrap cluster? This does not reset or wipe nodes. [y/N]')]
[doc('Bootstrap the Talos and Kubernetes cluster end-to-end')]
cluster: preflight talosconfig nodes k8s kubeconfig base apps verify-core

[doc('Check local tools, credentials, rendering, and Talos node reachability before bootstrap')]
preflight:
    bash "{{ source_directory() }}/../scripts/bootstrap-preflight.sh"

[doc('Verify the core bootstrap substrate')]
verify:
    bash "{{ source_directory() }}/../scripts/bootstrap-verify.sh" --core

[doc('Verify full post-bootstrap GitOps convergence, storage, gateways, Kopiur, and CNPG')]
verify-full:
    bash "{{ source_directory() }}/../scripts/bootstrap-verify.sh" --full

[private]
talosconfig:
    just talos talosconfig "${TALOSCONFIG}"
    chmod 0600 "${TALOSCONFIG}"

[private]
nodes:
    while IFS= read -r node; do
        [[ -z "${node}" ]] && continue
        if ! output=$(just --yes talos apply-insecure-node "${node}" 2>&1); then
            if [[ "${output}" == *"certificate required"* ]]; then
                printf 'Talos node %s is already configured; skipping insecure apply\n' "${node}"
                continue
            fi
            printf 'Failed to apply Talos config to %s:\n%s\n' "${node}" "${output}" >&2
            exit 1
        fi
    done < <(yq -r '.nodes | keys | .[]' "{{ repo_root }}/talos/inventory.yaml")

[private]
k8s:
    start="$(date +%s)"
    timeout="${TALOS_BOOTSTRAP_TIMEOUT_SECONDS:-900}"
    while true; do
        if output=$(just talos bootstrap 2>&1); then
            exit 0
        fi
        if [[ "${output}" == *"AlreadyExists"* || "${output}" == *"already bootstrapped"* ]]; then
            exit 0
        fi
        now="$(date +%s)"
        if ((now - start >= timeout)); then
            printf 'Timed out waiting for Talos bootstrap after %ss:\n%s\n' "${timeout}" "${output}" >&2
            exit 1
        fi
        sleep 10
    done

[private]
kubeconfig:
    controller="$(yq -r '.nodes.k8s-node-1' "{{ repo_root }}/talos/inventory.yaml")"
    mkdir -p "$(dirname "${KUBECONFIG}")"
    talosctl --talosconfig "${TALOSCONFIG}" --endpoints "${controller}" kubeconfig --nodes "${controller}" --force "${KUBECONFIG}"
    chmod 0600 "${KUBECONFIG}"

[private]
base:
    timeout="${KUBERNETES_API_TIMEOUT_SECONDS:-600}"
    start="$(date +%s)"
    until kubectl version --request-timeout=5s >/dev/null 2>&1; do
        now="$(date +%s)"
        if ((now - start >= timeout)); then
            printf 'Timed out waiting for Kubernetes API after %ss\n' "${timeout}" >&2
            exit 1
        fi
        sleep 10
    done

    expected="$(yq '.nodes | length' "{{ repo_root }}/talos/inventory.yaml")"
    timeout="${NODE_DISCOVERY_TIMEOUT_SECONDS:-600}"
    start="$(date +%s)"
    until count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ') && [[ "${count}" =~ ^[0-9]+$ ]] && ((count >= expected)); do
        now="$(date +%s)"
        if ((now - start >= timeout)); then
            printf 'Timed out waiting for Kubernetes nodes: expected=%s seen=%s\n' "${expected}" "${count:-0}" >&2
            exit 1
        fi
        sleep 10
    done

    while IFS=$'\t' read -r name version url_template; do
        [[ -z "${name}" || -z "${version}" || -z "${url_template}" ]] && continue
        url="${url_template//\{version\}/${version}}"
        kubectl apply --server-side --force-conflicts --filename "${url}"
    done < <(yq -r '.crds[] | [.name, .version, .urlTemplate] | @tsv' "{{ repo_root }}/bootstrap/crds/standalone.yaml")

    helmfile --file "{{ repo_root }}/bootstrap/helmfile/crds.yaml" template --quiet \
        | yq ea 'select(.kind == "CustomResourceDefinition")' - \
        | kubectl apply --server-side --force-conflicts --filename -

    kustomize build "{{ repo_root }}/bootstrap/kustomize/home" \
        | op inject \
        | kubectl apply --server-side --force-conflicts --filename -

[private]
apps:
    helmfile --file "{{ repo_root }}/bootstrap/helmfile/apps.yaml" sync --hide-notes

[private]
verify-core:
    bash "{{ source_directory() }}/../scripts/bootstrap-verify.sh" --core
