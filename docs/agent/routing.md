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

Apps that need Authelia SSO/ext-auth include the `authelia-proxy` Kustomize component in their app-level `kustomization.yaml`, not in `ks.yaml`. The protected HTTPRoute name must match the component's `${APP}` substitution; for normal app-template routes this is usually the app name.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./externalsecret.yaml
components:
  - ../../../../components/authelia-proxy
```

The component creates an Envoy `SecurityPolicy` targeting the app HTTPRoute by name (`${APP}`), forwarding auth checks to `authelia.security.svc.cluster.local`.

A `ReferenceGrant` in the `security` namespace authorises cross-namespace access. If adding Authelia to an app in a new namespace, add that namespace to `kubernetes/apps/security/authelia/app/referencegrant.yaml`.

## Cloudflare Tunnel

External traffic flows:

```text
Internet → Cloudflare → cloudflared pod → envoy-external Gateway service → app
```

Cloudflare Tunnel is configured in `kubernetes/apps/network/cloudflared/app/configs/config.yaml` and forwards all `*.${SECRET_PUBLIC_DOMAIN}` traffic to the `envoy-external` service.
