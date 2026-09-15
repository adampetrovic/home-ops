set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[doc('Delete pods with Evicted, Failed, or Succeeded status')]
delete-failed-pods:
    for phase in Evicted Failed Succeeded; do
        kubectl delete pods --field-selector "status.phase=${phase}" -A --ignore-not-found=true
    done
