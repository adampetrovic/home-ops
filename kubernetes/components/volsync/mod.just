set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

scripts_dir := source_directory() + '/scripts'
templates_dir := source_directory() + '/templates'
context := 'admin@home-kubernetes'

[doc('Create an interactive Restic debug Pod for an R2 repository')]
debug-r2 app ns="default":
    bash "{{ scripts_dir }}/preflight-r2-operation.sh" "{{ app }}" "{{ ns }}" inspect
    export app="{{ app }}" ns="{{ ns }}" job="volsync-r2-debug-{{ app }}"
    envsubst '$app $ns $job' < "{{ templates_dir }}/debug.tmpl.yaml" \
        | kubectl --context "{{ context }}" create -f -
    echo "Debug Pod {{ ns }}/volsync-r2-debug-{{ app }} created; use container r2 and delete it when finished."

[doc('Deprecated alias for debug-r2')]
debug app ns="default":
    echo "DEPRECATED - use 'just volsync debug-r2 {{ app }} {{ ns }}'."
    just volsync debug-r2 "{{ app }}" "{{ ns }}"

[doc('Check an R2 Restic repository')]
check-r2 app ns="default" timeout="3600":
    [[ "{{ timeout }}" =~ ^[1-9][0-9]*$ ]] || { echo "timeout must be a positive integer" >&2; exit 64; }
    bash "{{ scripts_dir }}/preflight-r2-operation.sh" "{{ app }}" "{{ ns }}" exclusive
    export app="{{ app }}" ns="{{ ns }}" job="volsync-r2-check-{{ app }}" timeout="{{ timeout }}"
    envsubst '$app $ns $job $timeout' < "{{ templates_dir }}/check.tmpl.yaml" \
        | kubectl --context "{{ context }}" create -f -
    bash "{{ scripts_dir }}/wait-for-operation-job.sh" "${job}" "${ns}" "${timeout}"
    kubectl --context "{{ context }}" -n "${ns}" delete job "${job}"

[doc('Deprecated alias for check-r2')]
check app ns="default" timeout="3600":
    echo "DEPRECATED - use 'just volsync check-r2 {{ app }} {{ ns }}'."
    just volsync check-r2 "{{ app }}" "{{ ns }}" "{{ timeout }}"

[doc('List Kopia snapshots for an application')]
list app ns="default" timeout="300":
    [[ "{{ timeout }}" =~ ^[1-9][0-9]*$ ]] || { echo "timeout must be a positive integer" >&2; exit 64; }
    export app="{{ app }}" ns="{{ ns }}" job="volsync-list-{{ app }}" timeout="{{ timeout }}"
    export SECRET_NFS_DOMAIN
    SECRET_NFS_DOMAIN="$(kubectl --context "{{ context }}" -n flux-system get secret cluster-secrets -o json | jq -er '.data.SECRET_NFS_DOMAIN | @base64d')"
    envsubst '$app $ns $job $timeout $SECRET_NFS_DOMAIN' < "{{ templates_dir }}/list.tmpl.yaml" \
        | kubectl --context "{{ context }}" create -f -
    bash "{{ scripts_dir }}/wait-for-operation-job.sh" "${job}" "${ns}" "${timeout}"
    kubectl --context "{{ context }}" -n "${ns}" delete job "${job}"

[doc('Inspect Restic locks in an R2 repository')]
locks-r2 app ns="default" timeout="600":
    [[ "{{ timeout }}" =~ ^[1-9][0-9]*$ ]] || { echo "timeout must be a positive integer" >&2; exit 64; }
    bash "{{ scripts_dir }}/preflight-r2-operation.sh" "{{ app }}" "{{ ns }}" inspect
    export app="{{ app }}" ns="{{ ns }}" job="volsync-r2-locks-{{ app }}" timeout="{{ timeout }}"
    envsubst '$app $ns $job $timeout' < "{{ templates_dir }}/locks-r2.tmpl.yaml" \
        | kubectl --context "{{ context }}" create -f -
    bash "{{ scripts_dir }}/wait-for-operation-job.sh" "${job}" "${ns}" "${timeout}"
    kubectl --context "{{ context }}" -n "${ns}" delete job "${job}"

[doc('Safely remove stale Restic locks from an R2 repository')]
unlock-r2 app ns="default" timeout="600" verify="false" backupTimeout="7200":
    [[ "{{ timeout }}" =~ ^[1-9][0-9]*$ ]] || { echo "timeout must be a positive integer" >&2; exit 64; }
    [[ "{{ backupTimeout }}" =~ ^[1-9][0-9]*$ ]] || { echo "backupTimeout must be a positive integer" >&2; exit 64; }
    [[ "{{ verify }}" == "true" || "{{ verify }}" == "false" ]] || { echo "verify must be true or false" >&2; exit 64; }
    bash "{{ scripts_dir }}/preflight-r2-operation.sh" "{{ app }}" "{{ ns }}" exclusive
    export app="{{ app }}" ns="{{ ns }}" job="volsync-r2-unlock-{{ app }}" timeout="{{ timeout }}"
    envsubst '$app $ns $job $timeout' < "{{ templates_dir }}/unlock.tmpl.yaml" \
        | kubectl --context "{{ context }}" create -f -
    bash "{{ scripts_dir }}/wait-for-operation-job.sh" "${job}" "${ns}" "${timeout}"
    kubectl --context "{{ context }}" -n "${ns}" delete job "${job}"
    if [[ "{{ verify }}" == "true" ]]; then
        just volsync backup "{{ app }}" "{{ ns }}" r2 "{{ backupTimeout }}"
    fi

[doc('Deprecated alias for unlock-r2')]
unlock app ns="default" timeout="600" verify="false" backupTimeout="7200":
    echo "DEPRECATED - use 'just volsync unlock-r2 {{ app }} {{ ns }}'."
    just volsync unlock-r2 "{{ app }}" "{{ ns }}" "{{ timeout }}" "{{ verify }}" "{{ backupTimeout }}"

[doc('Trigger and verify an ad-hoc VolSync backup')]
backup app ns="default" type="kopia" timeout="7200":
    [[ "{{ type }}" =~ ^(kopia|r2|all)$ ]] || { echo "type must be kopia, r2, or all" >&2; exit 64; }
    [[ "{{ timeout }}" =~ ^[1-9][0-9]*$ ]] || { echo "timeout must be a positive integer" >&2; exit 64; }
    bash "{{ scripts_dir }}/trigger-backup.sh" "{{ app }}" "{{ ns }}" "{{ type }}" "{{ timeout }}"

[doc('Deprecated alias for a Kopia backup')]
snapshot app ns="default" timeout="7200":
    echo "DEPRECATED - use 'just volsync backup {{ app }} {{ ns }} kopia'."
    just volsync backup "{{ app }}" "{{ ns }}" kopia "{{ timeout }}"

[doc('Restore a PVC for an application')]
restore app ns="default" previous="" restoreAsOf="" timeout="7200":
    [[ "{{ timeout }}" =~ ^[1-9][0-9]*$ ]] || { echo "timeout must be a positive integer" >&2; exit 64; }
    [[ -z "{{ previous }}" || "{{ previous }}" =~ ^[0-9]+$ ]] || { echo "previous must be a non-negative integer" >&2; exit 64; }
    [[ -z "{{ restoreAsOf }}" || "{{ restoreAsOf }}" =~ ^[0-9T:.Zz+\-]+$ ]] || { echo "restoreAsOf must be a valid RFC3339 timestamp" >&2; exit 64; }
    export app="{{ app }}" ns="{{ ns }}" previous="{{ previous }}" restoreAsOf="{{ restoreAsOf }}" timeout="{{ timeout }}"
    export controller claim puid pgid job
    controller="$({{ scripts_dir }}/which-controller.sh "${app}" "${ns}")"
    claim="$(kubectl -n "${ns}" get replicationsources/"${app}" -o jsonpath="{.spec.sourcePVC}")"
    puid="$(kubectl -n "${ns}" get replicationsources/"${app}" -o jsonpath="{.spec.kopia.moverSecurityContext.runAsUser}")"
    pgid="$(kubectl -n "${ns}" get replicationsources/"${app}" -o jsonpath="{.spec.kopia.moverSecurityContext.runAsGroup}")"
    flux -n flux-system suspend kustomization "${app}"
    flux -n "${ns}" suspend helmrelease "${app}"
    kubectl -n "${ns}" scale "${controller}" --replicas 0
    kubectl -n "${ns}" wait pod --for delete --selector="app.kubernetes.io/name=${app}" --timeout=2m
    job="volsync-wipe-${app}"
    envsubst < <(cat "{{ templates_dir }}/wipe.tmpl.yaml") | kubectl apply -f -
    bash "{{ scripts_dir }}/wait-for-job.sh" "${job}" "${ns}"
    kubectl -n "${ns}" wait job/"${job}" --for condition=complete --timeout=120m
    kubectl -n "${ns}" logs job/"${job}" --container main
    kubectl -n "${ns}" delete job "${job}"
    job="volsync-dst-${app}"
    manifest="$(envsubst < "{{ templates_dir }}/replicationdestination.tmpl.yaml")"
    if [[ -n "${previous}" ]]; then
        manifest="$(echo "${manifest}" | yq ".spec.kopia.previous = ${previous}")"
    fi
    if [[ -n "${restoreAsOf}" ]]; then
        manifest="$(echo "${manifest}" | yq ".spec.kopia.restoreAsOf = \"${restoreAsOf}\"")"
    fi
    echo "${manifest}" | kubectl apply -f -
    bash "{{ scripts_dir }}/wait-for-replicationdestination.sh" "${job}" "${ns}" "${timeout}"
    kubectl -n "${ns}" delete replicationdestination "${job}"
    flux -n "${ns}" resume helmrelease "${app}"
    flux -n flux-system resume kustomization "${app}"

[doc('Wipe the PVC for an application')]
wipe app ns="default":
    export app="{{ app }}" ns="{{ ns }}"
    export controller claim puid pgid job
    controller="$({{ scripts_dir }}/which-controller.sh "${app}" "${ns}")"
    claim="$(kubectl -n "${ns}" get replicationsources/"${app}" -o jsonpath="{.spec.sourcePVC}")"
    puid="$(kubectl -n "${ns}" get replicationsources/"${app}" -o jsonpath="{.spec.kopia.moverSecurityContext.runAsUser}")"
    pgid="$(kubectl -n "${ns}" get replicationsources/"${app}" -o jsonpath="{.spec.kopia.moverSecurityContext.runAsGroup}")"
    flux -n flux-system suspend kustomization "${app}"
    flux -n "${ns}" suspend helmrelease "${app}"
    kubectl -n "${ns}" scale "${controller}" --replicas 0
    kubectl -n "${ns}" wait pod --for delete --selector="app.kubernetes.io/name=${app}" --timeout=2m
    job="volsync-wipe-${app}"
    envsubst < <(cat "{{ templates_dir }}/wipe.tmpl.yaml") | kubectl apply -f -
    bash "{{ scripts_dir }}/wait-for-job.sh" "${job}" "${ns}"
    kubectl -n "${ns}" wait job/"${job}" --for condition=complete --timeout=120m
    kubectl -n "${ns}" logs job/"${job}" --container main
    kubectl -n "${ns}" delete job "${job}"
    flux -n "${ns}" resume helmrelease "${app}"
    flux -n flux-system resume kustomization "${app}"

[doc('Delete volume populator PVCs in all namespaces')]
cleanup:
    kubectl get pvc --all-namespaces --no-headers | grep "dst-dest" | awk '{print $1 "/" $2}' | while IFS=/ read -r ns name; do
        [[ -n "${ns}" && -n "${name}" ]] && kubectl delete pvc -n "${ns}" "${name}"
    done || true
    kubectl get pvc --all-namespaces --no-headers | grep "dst-cache" | awk '{print $1 "/" $2}' | while IFS=/ read -r ns name; do
        [[ -n "${ns}" && -n "${name}" ]] && kubectl delete pvc -n "${ns}" "${name}"
    done || true
    kubectl get volumesnapshot --all-namespaces --no-headers | grep "dst-dest" | awk '{print $1 "/" $2}' | while IFS=/ read -r ns name; do
        [[ -n "${ns}" && -n "${name}" ]] && kubectl delete volumesnapshot -n "${ns}" "${name}"
    done || true
