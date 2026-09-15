#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo "Usage: $0 <single-node-ip-or-name> <talos-installer-image> [rollout=false]" >&2
}

NODE="${1:-}"
TALOS_IMAGE="${2:-}"
ROLLOUT="${3:-false}"

if [[ -z "${NODE// }" ]]; then
    usage
    echo "Refusing to run Talos upgrade without an explicit node." >&2
    exit 64
fi

if [[ "${NODE}" == *","* ]]; then
    usage
    echo "Refusing to run single-node Talos upgrade with multiple nodes: ${NODE}" >&2
    exit 64
fi

if [[ -z "${TALOS_IMAGE// }" ]]; then
    usage
    echo "Refusing to run Talos upgrade without an explicit installer image." >&2
    exit 64
fi

if [[ "${TALOS_IMAGE}" != factory.talos.dev/metal-installer/* ]]; then
    usage
    echo "Refusing unexpected Talos installer image: ${TALOS_IMAGE}" >&2
    exit 64
fi

echo "Waiting for all jobs to complete before upgrading Talos ..."
until kubectl wait --timeout=5m \
    --for=condition=Complete jobs --all --all-namespaces;
do
    echo "Waiting for jobs to complete ..."
    sleep 10
done

if [ "${ROLLOUT}" != "true" ]; then
    echo "Suspending Flux Kustomizations ..."
    kubectl get ns -o jsonpath='{.items[*].metadata.name}' | xargs -n1 -I {} flux suspend kustomization --all -n {}
fi

echo "Upgrading Talos on node ${NODE} with ${TALOS_IMAGE} ..."
talosctl --nodes "${NODE}" upgrade \
    --image="${TALOS_IMAGE}" \
    --wait=true --timeout=10m --preserve=true

echo "Waiting for Talos to be healthy ..."
talosctl --nodes "${NODE}" health \
    --wait-timeout=10m --server=false

echo "Waiting for Ceph health to be OK ..."
until kubectl wait --timeout=5m \
    --for=jsonpath=.status.ceph.health=HEALTH_OK cephcluster \
    --all --all-namespaces;
do
    echo "Waiting for Ceph health to be OK ..."
    sleep 10
done

if [ "${ROLLOUT}" != "true" ]; then
    kubectl get ns -o jsonpath='{.items[*].metadata.name}' | xargs -n1 -I {} flux resume kustomization --all -n {}
fi
