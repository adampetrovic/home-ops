set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

repo_root := source_directory() + '/..'

[doc('Delete Failed (including evicted) and Succeeded pods')]
delete-failed-pods:
    for phase in Failed Succeeded; do
        kubectl delete pods --field-selector "status.phase=${phase}" -A --ignore-not-found=true
    done

[doc('Lint YAML, build every Flux Kustomization path and render the cluster locally')]
validate: lint build test

[doc('Lint YAML in kubernetes/, bootstrap/ and .github/ with the repo .yamllint')]
lint:
    cd "{{ repo_root }}"
    yamllint --strict --config-file .yamllint kubernetes bootstrap .github
    printf 'yamllint: ok\n'

[doc('Run kustomize build on every Flux Kustomization spec.path in kubernetes/apps')]
build:
    cd "{{ repo_root }}"
    paths="$(
        find kubernetes/apps -name ks.yaml -print0 \
            | xargs -0 yq eval-all --no-doc \
                'select(.apiVersion == "kustomize.toolkit.fluxcd.io/*" and .kind == "Kustomization") | .spec.path' \
            | sort -u
    )"
    if [[ -z "${paths}" ]]; then
        printf 'no Flux Kustomization paths found\n' >&2
        exit 1
    fi
    count=0
    while IFS= read -r path; do
        if ! kustomize build "${path}" >/dev/null; then
            printf 'kustomize build failed: %s\n' "${path}" >&2
            exit 1
        fi
        count=$((count + 1))
    done <<< "${paths}"
    printf 'kustomize build: %d paths ok\n' "${count}"

[doc('Render every Flux Kustomization and HelmRelease offline with flate')]
test:
    cd "{{ repo_root }}"
    flate test --path kubernetes/apps

[doc('Diff the rendered cluster against a Git revision with flate')]
diff base='origin/main':
    cd "{{ repo_root }}"
    flate diff --path kubernetes/apps --base "{{ base }}" --output diff
