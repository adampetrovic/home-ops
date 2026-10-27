# Routing Conventions

Read this before changing app exposure, HTTPRoutes, Envoy Gateway references, Authelia protection, or Cloudflare Tunnel behavior.

## Gateway API Only

Ingress is handled by Envoy Gateway using Kubernetes Gateway API. Do not add legacy `Ingress` resources.

Two Gateway resources live in the `network` namespace:

- `envoy-internal` (`10.0.88.200`) for local-only apps using `petrovic.network`.
- `envoy-external` (`10.0.88.201`) for internet-exposed apps using `${SECRET_PUBLIC_DOMAIN}` via Cloudflare Tunnel.

Both terminate TLS on port 443 with a wildcard certificate and redirect HTTP to HTTPS.

## Route Placement

Use inline app-template `route:` definitions for simple routes owned by a single app-template HelmRelease. Use standalone `HTTPRoute` manifests when the route is shared, targets a proxy or external backend, spans unusual namespaces, needs complex rules, or belongs to a workload that is not rendered by app-template.

Current intentional standalone route locations include Flux webhooks, Envoy proxy routes, observability endpoints with custom resources, Rook-Ceph dashboard routes, and Gateway self-check routes.

## App-Template Routes

Most application workloads use the bjw-s-labs app-template `route:` key, which renders HTTPRoute resources.

Internal-only app:

```yaml
route:
  app:
    hostnames:
      - "app.petrovic.network"
    parentRefs:
      - name: envoy-internal
        namespace: network
```

Externally exposed app:

```yaml
route:
  app:
    hostnames:
      - "app.${SECRET_PUBLIC_DOMAIN}"
    parentRefs:
      - name: envoy-external
        namespace: network
```

Dual internal and external exposure:

```yaml
route:
  internal:
    hostnames:
      - "app.petrovic.network"
    parentRefs:
      - name: envoy-internal
        namespace: network
  external:
    hostnames:
      - "app.${SECRET_PUBLIC_DOMAIN}"
    parentRefs:
      - name: envoy-external
        namespace: network
```

When default backendRefs are not sufficient, add explicit rules:

```yaml
route:
  app:
    hostnames:
      - "app.petrovic.network"
    parentRefs:
      - name: envoy-internal
        namespace: network
    rules:
      - backendRefs:
          - identifier: app
            port: http
```

## Authelia Authentication

Apps that need Authelia SSO/ext-auth include the `authelia-proxy` Kustomize component in their app-level `kustomization.yaml`, not in `ks.yaml`. The component protects every HTTPRoute in the app's namespace labelled `app.kubernetes.io/name: ${APP}`, which app-template sets on all of a release's routes; standalone routes need that label added.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./externalsecret.yaml
components:
  - ../../../../components/authelia-proxy
```

The component creates an Envoy `SecurityPolicy` named `${APP}` that selects those routes by label and forwards auth checks to `authelia.security.svc.cluster.local`.

To leave one route of a protected app open, such as a public route beside an admin route, label it `authelia.petrovic.network/bypass`:

```yaml
route:
  app:
    labels:
      authelia.petrovic.network/bypass: "true"
```

A selector that matches no route is not an error, so after adding the component confirm the policy attached: `kubectl get securitypolicy <app> -n <namespace> -o jsonpath='{.status}'` should list an ancestor.

A `ReferenceGrant` in the `security` namespace authorises cross-namespace access. If adding Authelia to an app in a new namespace, add that namespace to `kubernetes/apps/security/authelia/app/referencegrant.yaml`.

## Cloudflare Tunnel

External traffic flows:

```text
Internet → Cloudflare → cloudflared pod → envoy-external Gateway service → app
```

Cloudflare Tunnel is configured in `kubernetes/apps/network/cloudflared/app/configs/config.yaml` and forwards all `*.${SECRET_PUBLIC_DOMAIN}` traffic to the `envoy-external` service.

## Public App Containment

Internet-facing apps are fenced in so a compromised one cannot reach databases, other apps, or the LAN. This only restricts what public apps can reach; it does not restrict what can reach them.

An app is public if any of its routes use `envoy-external` (any public domain, including `${SECRET_PLEX_DOMAIN}`) or it is otherwise reachable from the internet, such as Plex. Apply this to every controller of the app, including helper controllers like Immich machine learning.

1. Label the pods and stop mounting the service-account token:

   ```yaml
   controllers:
     app:
       pod:
         labels:
           policy.petrovic.network/public-app: "true"
         automountServiceAccountToken: false
   ```

   Use `defaultPodOptions` instead when every controller in the release is public. The label applies the shared `public-app` CiliumClusterwideNetworkPolicy in `kubernetes/apps/kube-system/cilium/networkpolicies/public-app.yaml`: cluster DNS and the public internet are allowed, and all other egress, including RFC 1918, CGNAT, and link-local ranges, is denied.

2. If the app needs anything private, allow exactly that in `app/networkpolicy.yaml` and list it in `app/kustomization.yaml`. Use a namespaced CiliumNetworkPolicy named after the app that selects its pods and only has `egress` rules:

   ```yaml
   ---
   # yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/cilium.io/ciliumnetworkpolicy_v2.json
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: miniflux
   spec:
     description: >-
       Allow Miniflux to reach PostgreSQL.
     endpointSelector:
       matchLabels:
         app.kubernetes.io/name: miniflux
         app.kubernetes.io/controller: miniflux
     egress:
       - toEndpoints:
           - matchLabels:
               k8s:io.kubernetes.pod.namespace: database
               cnpg.io/cluster: postgres
               cnpg.io/instanceRole: primary
         toPorts:
           - ports:
               - port: "5432"
                 protocol: TCP
   ```

Rules for dependency policies:

- Select destinations by pod labels, not IPs. Include `k8s:io.kubernetes.pod.namespace` for another namespace; omitting it means the app's own namespace.
- Ports are the pod's container port after Service translation, not the Service port. Check the destination's HelmRelease.
- Reach in-cluster services by their `*.svc.cluster.local` name. LoadBalancer IPs and `petrovic.network` names resolve to private addresses that the shared policy blocks.
- Do not allow a public app to reach `envoy-internal` or `envoy-external`; either gateway would give it a path to every app behind it.
- Shared PostgreSQL is `cnpg.io/cluster: postgres` in `database`; shared Dragonfly is `app: dragonfly, role: master` in `database`; the SMTP relay is `app.kubernetes.io/name: smtp-relay` in `network` on port 25.
- Public OIDC clients reach Authelia at `https://auth.${SECRET_PUBLIC_DOMAIN}`. CoreDNS resolves that one name through public DNS so the request goes out via Cloudflare instead of the internal gateway.
- A Kustomization-level `dependsOn` is not needed for the shared policy. Add `coredns` to `dependsOn` only for apps that rely on the public `auth.` resolution.

Before labelling an existing app, list the private destinations it actually uses so none are missed (see "Hubble Flow Visibility" in `platform.md`):

```bash
hubble observe --from-label app.kubernetes.io/name=<app> --last 500 -o compact
```

After deploying, verify the app's dependencies still work and watch for blocked connections:

```bash
hubble observe --verdict DROPPED --from-label policy.petrovic.network/public-app=true --follow
```
