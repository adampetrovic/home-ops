set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

scripts_dir := source_directory() + '/scripts'
templates_dir := source_directory() + '/templates'
context := 'admin@home-kubernetes'

[doc('Trigger and verify an ad-hoc VolSync backup')]
backup app ns="default" type="kopia" timeout="7200":
    [[ "{{ type }}" =~ ^(kopia|r2|all)$ ]] || { echo "type must be kopia, r2, or all" >&2; exit 64; }
    [[ "{{ timeout }}" =~ ^[1-9][0-9]*$ ]] || { echo "timeout must be a positive integer" >&2; exit 64; }
    bash "{{ scripts_dir }}/trigger-backup.sh" "{{ app }}" "{{ ns }}" "{{ type }}" "{{ timeout }}"

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
unlock-r2 app ns="default" timeout="600" verify="false" backup_timeout="7200":
    [[ "{{ timeout }}" =~ ^[1-9][0-9]*$ ]] || { echo "timeout must be a positive integer" >&2; exit 64; }
    [[ "{{ backup_timeout }}" =~ ^[1-9][0-9]*$ ]] || { echo "backup_timeout must be a positive integer" >&2; exit 64; }
    [[ "{{ verify }}" == "true" || "{{ verify }}" == "false" ]] || { echo "verify must be true or false" >&2; exit 64; }
    bash "{{ scripts_dir }}/preflight-r2-operation.sh" "{{ app }}" "{{ ns }}" exclusive
    export app="{{ app }}" ns="{{ ns }}" job="volsync-r2-unlock-{{ app }}" timeout="{{ timeout }}"
    envsubst '$app $ns $job $timeout' < "{{ templates_dir }}/unlock.tmpl.yaml" \
        | kubectl --context "{{ context }}" create -f -
    bash "{{ scripts_dir }}/wait-for-operation-job.sh" "${job}" "${ns}" "${timeout}"
    kubectl --context "{{ context }}" -n "${ns}" delete job "${job}"
    if [[ "{{ verify }}" == "true" ]]; then
        just volsync backup "{{ app }}" "{{ ns }}" r2 "{{ backup_timeout }}"
    fi

[doc('Check an R2 Restic repository')]
check-r2 app ns="default" timeout="3600":
    [[ "{{ timeout }}" =~ ^[1-9][0-9]*$ ]] || { echo "timeout must be a positive integer" >&2; exit 64; }
    bash "{{ scripts_dir }}/preflight-r2-operation.sh" "{{ app }}" "{{ ns }}" exclusive
    export app="{{ app }}" ns="{{ ns }}" job="volsync-r2-check-{{ app }}" timeout="{{ timeout }}"
    envsubst '$app $ns $job $timeout' < "{{ templates_dir }}/check.tmpl.yaml" \
        | kubectl --context "{{ context }}" create -f -
    bash "{{ scripts_dir }}/wait-for-operation-job.sh" "${job}" "${ns}" "${timeout}"
    kubectl --context "{{ context }}" -n "${ns}" delete job "${job}"

[doc('Create an interactive Restic debug Pod for an R2 repository')]
debug-r2 app ns="default":
    bash "{{ scripts_dir }}/preflight-r2-operation.sh" "{{ app }}" "{{ ns }}" inspect
    export app="{{ app }}" ns="{{ ns }}" job="volsync-r2-debug-{{ app }}"
    envsubst '$app $ns $job' < "{{ templates_dir }}/debug.tmpl.yaml" \
        | kubectl --context "{{ context }}" create -f -
    echo "Debug Pod {{ ns }}/volsync-r2-debug-{{ app }} created; use container r2 and delete it when finished."
