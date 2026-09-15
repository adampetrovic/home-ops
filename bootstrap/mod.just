set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[doc('Check local tools, credentials, rendering, and Talos node reachability before bootstrap')]
preflight:
    bash "{{ source_directory() }}/../scripts/bootstrap-preflight.sh"

[doc('Verify the core bootstrap substrate after running scripts/bootstrap-cluster.sh')]
verify:
    bash "{{ source_directory() }}/../scripts/bootstrap-verify.sh" --core

[doc('Verify full post-bootstrap GitOps convergence, storage, gateways, VolSync, and CNPG')]
verify-full:
    bash "{{ source_directory() }}/../scripts/bootstrap-verify.sh" --full
