NODE="${1}"
TALOS_STANZA="${2}"
ROLLOUT="${3:-false}"

echo "Waiting for all jobs to complete before upgrading Talos ..."
until kubectl wait --timeout=5m \
    --for=condition=Complete jobs --all --all-namespaces;
do
    echo "Waiting for jobs to complete ..."
    sleep 10
done

if [ "${ROLLOUT}" != "true" ]; then
    echo "Suspending Flux Kustomizations ..."
    flux suspend kustomization --all
    echo "Setting CNPG maintenance mode ..."
    kubectl cnpg maintenance set postgres --reusePVC -n database
fi

echo "Upgrading Talos on node ${NODE} ..."
talosctl --nodes "${NODE}" upgrade \
    --image="factory.talos.dev/installer/${TALOS_STANZA}" \
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
    echo "Unsetting CNPG maintenance mode ..."
    flux resume kustomization --all
fi
