#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
HELMFILE_DIR="${ROOT_DIR}/bootstrap/helmfile"

build_file="$(mktemp)"
expected_file="$(mktemp)"
actual_file="$(mktemp)"
values_dir="$(mktemp -d)"
trap 'rm -rf "${build_file}" "${expected_file}" "${actual_file}" "${values_dir}"' EXIT

(
    cd "${HELMFILE_DIR}"
    helmfile --file apps.yaml build >"${build_file}"
    helmfile --file apps.yaml write-values \
        --output-file-template "${values_dir}/{{ .Release.Namespace }}-{{ .Release.Name }}.yaml" \
        >/dev/null 2>&1
)

release_count="$(yq '.releases | length' "${build_file}")"

for index in $(seq 0 $((release_count - 1))); do
    name="$(yq -r ".releases[${index}].name" "${build_file}")"
    namespace="$(yq -r ".releases[${index}].namespace" "${build_file}")"

    oci_path="${ROOT_DIR}/kubernetes/apps/${namespace}/${name}/app/ocirepository.yaml"
    helmrelease_path="${ROOT_DIR}/kubernetes/apps/${namespace}/${name}/app/helmrelease.yaml"

    if [[ "${name}" == "onepassword-connect" ]]; then
        oci_path="${ROOT_DIR}/kubernetes/components/common/repos/app-template/ocirepository.yaml"
        helmrelease_path="${ROOT_DIR}/kubernetes/apps/external-secrets/external-secrets/stores/onepassword/helmrelease.yaml"
    fi

    expected_chart="$(yq -r '.spec.url' "${oci_path}")"
    expected_version="$(yq -r '.spec.ref.tag' "${oci_path}")"
    actual_chart="$(yq -r ".releases[${index}].chart" "${build_file}")"
    actual_version="$(yq -r ".releases[${index}].version" "${build_file}")"

    if [[ "${actual_chart}" != "${expected_chart}" || "${actual_version}" != "${expected_version}" ]]; then
        printf 'metadata mismatch for %s/%s\n' "${namespace}" "${name}" >&2
        printf 'expected: %s %s\n' "${expected_chart}" "${expected_version}" >&2
        printf 'actual:   %s %s\n' "${actual_chart}" "${actual_version}" >&2
        exit 1
    fi

    yq -o=json '.spec.values' "${helmrelease_path}" | jq --sort-keys . >"${expected_file}"
    yq -o=json '.' "${values_dir}/${namespace}-${name}.yaml" | jq --sort-keys . >"${actual_file}"

    if ! diff -u "${expected_file}" "${actual_file}" >/dev/null; then
        printf 'values mismatch for %s/%s\n' "${namespace}" "${name}" >&2
        diff -u "${expected_file}" "${actual_file}" >&2 || true
        exit 1
    fi

done

printf 'Bootstrap Helmfile metadata and values match canonical Flux sources.\n'
