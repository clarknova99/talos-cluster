# Kubernetes Cluster Networking Documentation

## Quick Navigation

- **[Current Architecture](#architecture-components)** - How networking works today (Ingress-NGINX based)
- **[Deploying Services](#deploying-new-services)** - How to deploy new services right now
- **[Migration to Envoy Gateway](#migration-plan-ingress-nginx-to-envoy-gateway)** - Complete migration plan with all updates
- **[Troubleshooting](#troubleshooting)** - Common issues and solutions
- **[Quick Reference Commands](#quick-reference-commands)** - Useful kubectl commands

## Overview

This document describes the end-to-end networking architecture for the Talos Kubernetes cluster, including how traffic flows from the internet to services and how to deploy new services with proper network configuration.

**📋 Table of Contents:**
1. [Current Architecture](#architecture-components) - Cloudflared, External-DNS, Ingress-NGINX, Cert-Manager, K8s-Gateway
2. [Network Traffic Flows](#network-traffic-flows) - External and internal traffic patterns
3. [Deploying New Services](#deploying-new-services) - External, internal, and dual-mode examples
4. [Migration Plan](#migration-plan-ingress-nginx-to-envoy-gateway) - Complete Envoy Gateway migration guide
5. [Troubleshooting](#troubleshooting) - Common issues and debugging

**🔄 Migration Status:**
- Current: Ingress-NGINX (external: 192.168.3.23, internal: 192.168.3.21)
- Target: Envoy Gateway (external: 192.168.3.26, internal: 192.168.3.27)
- See [Migration Plan](#migration-plan-ingress-nginx-to-envoy-gateway) for complete step-by-step guide

## Architecture Components

### 1. Cloudflared Tunnel
**Purpose**: Provides secure tunnel from Cloudflare's edge to the cluster for internet-accessible services

**Configuration**: [kubernetes/apps/network/cloudflared](kubernetes/apps/network/cloudflared)

**How it works**:
- Runs as a deployment in the `network` namespace
- Uses Cloudflare Tunnel ID to establish secure connection to Cloudflare's network
- Routes traffic based on hostname to the appropriate ingress controller
- All external traffic flows through this tunnel (no direct port forwarding required)

**Tunnel routing** ([config.yaml](kubernetes/apps/network/cloudflared/app/configs/config.yaml)):
```yaml
ingress:
  - hostname: "*.${SECRET_DOMAIN}"
    service: https://ingress-nginx-external-controller.network.svc.cluster.local:443
  - hostname: "*.${SECRET_DOMAIN_TWO}"
    service: https://ingress-nginx-external-controller.network.svc.cluster.local:443
```

**Key details**:
- Forwards all traffic to the external ingress-nginx controller
- Uses HTTPS/HTTP2 for connections to ingress
- Configured with QUIC protocol and post-quantum encryption

### 2. External-DNS
**Purpose**: Automatically manages DNS records in Cloudflare based on Kubernetes resources

**Configuration**: [kubernetes/apps/network/external-dns](kubernetes/apps/network/external-dns)

**How it works**:
- Watches Ingress resources with `ingressClassName: external`
- Watches Gateway HTTPRoute resources
- Watches DNSEndpoint custom resources
- Automatically creates/updates/deletes DNS records in Cloudflare
- Records are prefixed with `k8s.` for identification

**Configuration highlights**:
- Only manages records for ingress class `external`
- Enables Cloudflare proxy by default (`--cloudflare-proxied`)
- Manages domains: `${SECRET_DOMAIN}` and `${SECRET_DOMAIN_TWO}`
- Uses Cloudflare API token for authentication

**DNS Endpoints**:
The cloudflared tunnel creates DNS CNAMEs ([dnsendpoint.yaml](kubernetes/apps/network/cloudflared/app/dnsendpoint.yaml)):
- `external.${SECRET_DOMAIN}` → `${TUNNEL_ID}.cfargotunnel.com`
- `external.${SECRET_DOMAIN_TWO}` → `${TUNNEL_ID}.cfargotunnel.com`

### 3. Ingress-NGINX Controllers

There are **two separate ingress controllers** for different network zones:

#### 3.1 External Ingress Controller
**Purpose**: Handles internet-facing services accessible via Cloudflare tunnel

**Configuration**: [kubernetes/apps/network/ingress-nginx/external](kubernetes/apps/network/ingress-nginx/external)

**Network details**:
- IngressClass name: `external`
- LoadBalancer IP: `192.168.3.23` (via Cilium IPAM)
- Service: `ingress-nginx-external-controller.network.svc.cluster.local`
- Ports: 80, 443

**Special features**:
- Custom error pages (ghcr.io/tarampampam/error-pages)
- GeoIP2 support with MaxMind database
- Enhanced logging with geo information
- Uses default SSL certificate: `network/${SECRET_DOMAIN/./-}-production-tls`

**Dependencies**:
- Depends on cloudflared deployment

#### 3.2 Internal Ingress Controller
**Purpose**: Handles services accessible only on local network

**Configuration**: [kubernetes/apps/network/ingress-nginx/internal](kubernetes/apps/network/ingress-nginx/internal)

**Network details**:
- IngressClass name: `internal`
- LoadBalancer IP: `192.168.3.21` (via Cilium IPAM)
- Service: `ingress-nginx-internal-controller.network.svc.cluster.local`
- Ports: 80, 443
- Default ingress class: `true`

**Key features**:
- Uses default SSL certificate: `network/${SECRET_DOMAIN/./-}-production-tls`
- Simpler configuration without public-facing features

### 4. Cert-Manager
**Purpose**: Automatically manages TLS certificates from Let's Encrypt

**Configuration**: [kubernetes/apps/cert-manager](kubernetes/apps/cert-manager)

**How it works**:
- Uses DNS-01 challenge with Cloudflare
- Creates wildcard certificates for all domains
- Two cluster issuers available:
  - `letsencrypt-production` (for production use)
  - `letsencrypt-staging` (for testing)

**Certificates**:
A single wildcard certificate is created ([production.yaml](kubernetes/apps/network/ingress-nginx/certificates/production.yaml)):
- Name: `${SECRET_DOMAIN/./-}-production`
- Secret: `${SECRET_DOMAIN/./-}-production-tls`
- Covers:
  - `${SECRET_DOMAIN}`
  - `*.${SECRET_DOMAIN}`
  - `${SECRET_DOMAIN_TWO}`
  - `*.${SECRET_DOMAIN_TWO}`

This certificate is used as the default for both ingress controllers.

### 5. K8s-Gateway
**Purpose**: Provides local DNS resolution for internal services

**Configuration**: [kubernetes/apps/network/k8s-gateway](kubernetes/apps/network/k8s-gateway)

**How it works**:
- Runs a DNS server on port 53
- LoadBalancer IP: `192.168.3.22`
- Watches Ingress, Service, and HTTPRoute resources
- Returns LoadBalancer IPs for internal hostname queries
- Domains: `${SECRET_DOMAIN}` and `${SECRET_DOMAIN_TWO}`
- TTL: 1 second (for quick updates)

**Usage**:
- Configure local DNS server (router/Pi-hole/etc.) to forward domain queries to `192.168.3.22`
- When querying `apps.bigwang.org`, returns `192.168.3.21` (internal ingress IP)
- Allows local devices to access services without going through internet

## Network Traffic Flows

### External Service Flow (Internet → Service)
```
Internet User
    ↓
Cloudflare Edge Network
    ↓
Cloudflared Tunnel (in cluster)
    ↓
Ingress-NGINX External Controller (192.168.3.23)
    ↓
Service Pod
```

**Step-by-step**:
1. User requests `https://auth.bigwang.org`
2. DNS resolves to Cloudflare (via external-dns managed CNAME)
3. Cloudflare proxies request through tunnel to cloudflared pod
4. Cloudflared forwards to `ingress-nginx-external-controller:443`
5. Ingress controller routes based on hostname to appropriate service
6. Service responds back through same path

### Internal Service Flow (Local Network → Service)
```
Local Device
    ↓
K8s-Gateway DNS (192.168.3.22)
    ↓ (returns 192.168.3.21)
    ↓
Ingress-NGINX Internal Controller (192.168.3.21)
    ↓
Service Pod
```

**Step-by-step**:
1. Local device queries `apps.bigwang.org`
2. Local DNS server forwards to k8s-gateway (192.168.3.22)
3. K8s-gateway returns IP `192.168.3.21` (internal ingress)
4. Device connects directly to `192.168.3.21:443`
5. Ingress controller routes based on hostname to appropriate service

## Deploying New Services

### External Service (Internet-Accessible)

Create an Ingress resource with the `external` ingress class:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: myapp
  annotations:
    # This tells external-dns to create a DNS record pointing to external.bigwang.org
    external-dns.alpha.kubernetes.io/target: external.bigwang.org

    # Optional: Hajimari integration for dashboard
    hajimari.io/icon: mdi:application

    # Optional: Custom nginx configurations
    # nginx.ingress.kubernetes.io/proxy-body-size: "100m"
spec:
  ingressClassName: external  # IMPORTANT: Use 'external' class
  rules:
  - host: myapp.bigwang.org
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: myapp
            port:
              number: 80
  tls:
  - hosts:
    - myapp.bigwang.org
    # Certificate is automatically provided by default-ssl-certificate
    # No need to specify secretName unless using custom cert
```

**What happens**:
1. External-DNS sees the ingress with class `external`
2. Creates DNS CNAME: `myapp.bigwang.org` → `external.bigwang.org`
3. `external.bigwang.org` → `${TUNNEL_ID}.cfargotunnel.com` (via DNSEndpoint)
4. Cloudflared tunnel routes `myapp.bigwang.org` to external ingress controller
5. External ingress routes to your service
6. TLS is handled by wildcard certificate

### Internal Service (Local Network Only)

Create an Ingress resource with the `internal` ingress class:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: myapp
  annotations:
    # Optional: Hajimari integration
    hajimari.io/icon: mdi:application
spec:
  ingressClassName: internal  # IMPORTANT: Use 'internal' class
  rules:
  - host: myapp.bigwang.org
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: myapp
            port:
              number: 80
  tls:
  - hosts:
    - myapp.bigwang.org
    # Certificate is automatically provided by default-ssl-certificate
```

**What happens**:
1. K8s-gateway detects the ingress
2. Returns `192.168.3.21` (internal ingress IP) for DNS queries
3. Local devices connect directly to internal ingress controller
4. Internal ingress routes to your service
5. TLS is handled by wildcard certificate

### Dual-Mode Service (Both Internal and External)

Create two separate Ingress resources:

```yaml
# External ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-external
  namespace: myapp
  annotations:
    external-dns.alpha.kubernetes.io/target: external.bigwang.org
spec:
  ingressClassName: external
  rules:
  - host: myapp-public.bigwang.org  # Different subdomain for external
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: myapp
            port:
              number: 80
  tls:
  - hosts:
    - myapp-public.bigwang.org
---
# Internal ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-internal
  namespace: myapp
spec:
  ingressClassName: internal
  rules:
  - host: myapp.bigwang.org  # Local subdomain
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: myapp
            port:
              number: 80
  tls:
  - hosts:
    - myapp.bigwang.org
```

## Certificate Management

### Using Default Wildcard Certificate

Both ingress controllers are configured with a default wildcard certificate that covers:
- `*.bigwang.org`
- `*.senseichess.com`

No action needed - TLS is automatically applied to all ingresses.

### Using Custom Certificate

If you need a custom certificate:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-custom-cert
  namespace: myapp
spec:
  secretName: myapp-custom-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - myapp.example.com
```

Then reference in your Ingress:

```yaml
spec:
  tls:
  - hosts:
    - myapp.example.com
    secretName: myapp-custom-tls  # References the certificate secret
```

## Network IP Allocations

The cluster uses Cilium IPAM for LoadBalancer service IP allocation:

| Service | IP | Purpose |
|---------|-----|---------|
| ingress-nginx-internal | 192.168.3.21 | Internal services ingress |
| k8s-gateway | 192.168.3.22 | Local DNS server |
| ingress-nginx-external | 192.168.3.23 | External services ingress |

## Troubleshooting

### Service not accessible from internet

1. Check ingress class is `external`:
   ```bash
   kubectl get ingress -n <namespace> <ingress-name> -o jsonpath='{.spec.ingressClassName}'
   ```

2. Verify external-dns created DNS record:
   ```bash
   # Check Cloudflare for CNAME record
   kubectl logs -n network -l app.kubernetes.io/name=external-dns
   ```

3. Check cloudflared tunnel is running:
   ```bash
   kubectl get pods -n network -l app.kubernetes.io/name=cloudflared
   kubectl logs -n network -l app.kubernetes.io/name=cloudflared
   ```

4. Verify ingress has correct annotation:
   ```bash
   kubectl get ingress -n <namespace> <ingress-name> -o yaml | grep external-dns
   # Should see: external-dns.alpha.kubernetes.io/target: external.bigwang.org
   ```

### Service not accessible from local network

1. Check ingress class is `internal`:
   ```bash
   kubectl get ingress -n <namespace> <ingress-name> -o jsonpath='{.spec.ingressClassName}'
   ```

2. Verify k8s-gateway is running:
   ```bash
   kubectl get pods -n network -l app.kubernetes.io/name=k8s-gateway
   ```

3. Test DNS resolution:
   ```bash
   dig @192.168.3.22 myapp.bigwang.org
   # Should return 192.168.3.21
   ```

4. Ensure local DNS forwards to k8s-gateway:
   - Router/Pi-hole should forward `*.bigwang.org` to `192.168.3.22`

### Certificate issues

1. Check certificate status:
   ```bash
   kubectl get certificate -A
   ```

2. Check cert-manager logs:
   ```bash
   kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager
   ```

3. Verify ClusterIssuer is ready:
   ```bash
   kubectl get clusterissuer
   ```

### Viewing current ingress resources

```bash
# List all ingresses
kubectl get ingress -A

# Show external ingresses
kubectl get ingress -A --field-selector spec.ingressClassName=external

# Show internal ingresses
kubectl get ingress -A --field-selector spec.ingressClassName=internal

# Describe specific ingress
kubectl describe ingress -n <namespace> <name>
```

## Best Practices

1. **Ingress Class Selection**:
   - Use `external` only for services that need internet access
   - Default to `internal` for security-sensitive services
   - Never expose admin panels/dashboards externally unless protected by auth

2. **DNS Naming**:
   - Use descriptive subdomains: `app.bigwang.org` not `app1.bigwang.org`
   - Keep external and internal subdomains separate if dual-mode

3. **Annotations**:
   - Always add `external-dns.alpha.kubernetes.io/target: external.bigwang.org` for external services
   - Add `hajimari.io/icon` for services appearing in the dashboard
   - Use nginx annotations sparingly - most defaults are sensible

4. **TLS**:
   - Let the default wildcard certificate handle TLS
   - Only create custom certificates if absolutely necessary
   - Always include TLS section in Ingress spec

5. **Namespaces**:
   - Keep related services in same namespace
   - Ingress can be in same namespace as service (recommended)

## Configuration Files Reference

| Component | Configuration Path |
|-----------|-------------------|
| Cloudflared | [kubernetes/apps/network/cloudflared](kubernetes/apps/network/cloudflared) |
| External-DNS | [kubernetes/apps/network/external-dns](kubernetes/apps/network/external-dns) |
| Ingress-NGINX Internal | [kubernetes/apps/network/ingress-nginx/internal](kubernetes/apps/network/ingress-nginx/internal) |
| Ingress-NGINX External | [kubernetes/apps/network/ingress-nginx/external](kubernetes/apps/network/ingress-nginx/external) |
| Cert-Manager | [kubernetes/apps/cert-manager](kubernetes/apps/cert-manager) |
| K8s-Gateway | [kubernetes/apps/network/k8s-gateway](kubernetes/apps/network/k8s-gateway) |
| Certificates | [kubernetes/apps/network/ingress-nginx/certificates](kubernetes/apps/network/ingress-nginx/certificates) |

## Migration Plan: Ingress-NGINX to Envoy Gateway

### Overview

This section provides a step-by-step migration plan from Ingress-NGINX to Envoy Gateway using the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/). The migration strategy supports running both systems in parallel, allowing you to migrate services one at a time with zero downtime.

**This plan is based on real implementations from**:
- [onedr0p/home-ops](https://github.com/onedr0p/home-ops) - Production Envoy Gateway deployment
- [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template) - Envoy Gateway templates
- [External-DNS Gateway API documentation](https://kubernetes-sigs.github.io/external-dns/latest/docs/sources/gateway-api/)
- [Envoy Gateway documentation](https://gateway.envoyproxy.io/) (v1.6.1)

### ⚠️ Important Notes Before Starting

**IP Address Assignments**:
- ✅ **192.168.3.26** for `envoy-external` gateway
- ✅ **192.168.3.27** for `envoy-internal` gateway
- These IPs are verified as available (192.168.3.24 and .25 are already in use)

**Certificate Strategy**:
- ✅ **Use existing certificate** - Do NOT create a new certificate
- The wildcard certificate in `kubernetes/apps/network/ingress-nginx/certificates/` creates the secret both systems will share
- No duplicate certificates, no Let's Encrypt rate limit concerns

**Implementation Differences from Generic Templates**:
- Uses OCIRepository (not HelmRepository) for better reliability
- Includes Zstd compression via EnvoyPatchPolicy
- Larger HTTP/2 buffer sizes for better performance
- Enhanced observability with PodMonitor and ServiceMonitor

### Why Migrate?

- **Gateway API**: Modern, standardized Kubernetes API for traffic management (GA since v1.4.0)
- **Future-proof**: Gateway API is the future of Kubernetes networking
- **Better features**: Enhanced traffic management, policy attachment, extensibility, and advanced routing
- **Ingress-NGINX deprecation**: Ingress-NGINX will be deprecated in the coming months
- **Production-tested**: Based on real implementations from onedr0p's production cluster

### Migration Strategy

The migration will happen in phases:

1. **Phase 1**: Install Envoy Gateway alongside Ingress-NGINX (parallel operation)
2. **Phase 2**: Update supporting services (external-dns, cloudflared)
3. **Phase 3**: Migrate services one-by-one from Ingress to HTTPRoute
4. **Phase 4**: Remove Ingress-NGINX after all services migrated

### Prerequisites

- ✅ Kubernetes Gateway API CRDs (will be installed with Envoy Gateway v1.6.1)
- ✅ Existing wildcard certificate (`${SECRET_DOMAIN/./-}-production-tls`) - will be shared
- ✅ Cilium IPAM with available IPs (192.168.3.26 and .27 verified available)
- ✅ Flux CD for GitOps deployment
- ✅ Prometheus Operator for monitoring (optional but recommended)

### Phase 1: Install Envoy Gateway

#### Step 1.1: Create Envoy Gateway Namespace and HelmRelease

Create the directory structure:
```bash
mkdir -p kubernetes/apps/network/envoy-gateway/app
```

Create `kubernetes/apps/network/envoy-gateway/ks.yaml`:
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app envoy-gateway
  namespace: flux-system
spec:
  targetNamespace: network
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./kubernetes/apps/network/envoy-gateway/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-kubernetes
  wait: true
  interval: 30m
  retryInterval: 1m
  timeout: 5m
```

Create `kubernetes/apps/network/envoy-gateway/app/ocirepository.yaml`:
```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: envoy-gateway
  namespace: network
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: v1.6.1  # Check for latest version
  url: oci://mirror.gcr.io/envoyproxy/gateway-helm
```

Create `kubernetes/apps/network/envoy-gateway/app/helmrelease.yaml`:
```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: envoy-gateway
  namespace: network
spec:
  chartRef:
    kind: OCIRepository
    name: envoy-gateway
  interval: 1h
  values:
    global:
      imageRegistry: mirror.gcr.io
    config:
      envoyGateway:
        extensionApis:
          enableEnvoyPatchPolicy: true
        provider:
          type: Kubernetes
          kubernetes:
            deploy:
              type: GatewayNamespace
```

Create `kubernetes/apps/network/envoy-gateway/app/kustomization.yaml`:
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ocirepository.yaml
  - ./helmrelease.yaml
  - ./envoy.yaml
  - ./observability.yaml
```

**Note**: We're using OCIRepository instead of HelmRepository, following the onedr0p pattern. This fetches directly from the OCI registry and uses `mirror.gcr.io` for better reliability.

#### Step 1.3: Create EnvoyProxy and Gateway Resources

Create `kubernetes/apps/network/envoy-gateway/app/envoy.yaml`:
```yaml
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: envoy
  namespace: network
spec:
  logging:
    level:
      default: info
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: 2
        container:
          resources:
            requests:
              cpu: 100m
            limits:
              memory: 1Gi
      envoyService:
        externalTrafficPolicy: Cluster
  shutdown:
    drainTimeout: 180s
  telemetry:
    metrics:
      prometheus:
        compression:
          type: Gzip
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: envoy
    namespace: network
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: envoy-external
  namespace: network
  annotations:
    external-dns.alpha.kubernetes.io/target: external.${SECRET_DOMAIN}
spec:
  gatewayClassName: envoy
  infrastructure:
    annotations:
      external-dns.alpha.kubernetes.io/hostname: external.${SECRET_DOMAIN}
      lbipam.cilium.io/ips: "192.168.3.26"  # New IP for envoy-external (UPDATED: .24 was in use)
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
    - name: https
      protocol: HTTPS
      port: 443
      allowedRoutes:
        namespaces:
          from: All
      tls:
        certificateRefs:
          - kind: Secret
            name: ${SECRET_DOMAIN/./-}-production-tls
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: envoy-internal
  namespace: network
  annotations:
    external-dns.alpha.kubernetes.io/target: internal.${SECRET_DOMAIN}
spec:
  gatewayClassName: envoy
  infrastructure:
    annotations:
      external-dns.alpha.kubernetes.io/hostname: internal.${SECRET_DOMAIN}
      lbipam.cilium.io/ips: "192.168.3.27"  # New IP for envoy-internal (UPDATED: .25 was in use)
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
    - name: https
      protocol: HTTPS
      port: 443
      allowedRoutes:
        namespaces:
          from: All
      tls:
        certificateRefs:
          - kind: Secret
            name: ${SECRET_DOMAIN/./-}-production-tls
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: envoy
  namespace: network
spec:
  compression:
    - type: Brotli
    - type: Gzip
  connection:
    bufferLimit: 8Mi
  targetSelectors:
    - group: gateway.networking.k8s.io
      kind: Gateway
  tcpKeepalive: {}
  timeout:
    http:
      requestTimeout: 0s
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: envoy
  namespace: network
spec:
  clientIPDetection:
    xForwardedFor:
      numTrustedHops: 1
  connection:
    bufferLimit: 4Mi
  http2:
    initialStreamWindowSize: 512Ki
    initialConnectionWindowSize: 8Mi
  targetSelectors:
    - group: gateway.networking.k8s.io
      kind: Gateway
  tcpKeepalive: {}
  timeout:
    http:
      requestReceivedTimeout: 0s
  tls:
    minVersion: "1.2"
    alpnProtocols:
      - h2
      - http/1.1
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: network
  annotations:
    external-dns.alpha.kubernetes.io/exclude: "true"
spec:
  parentRefs:
    - name: envoy-external
      namespace: network
      sectionName: http
    - name: envoy-internal
      namespace: network
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

**Note about Certificates**: We do **NOT** create a new certificate. The existing wildcard certificate in [kubernetes/apps/network/ingress-nginx/certificates/production.yaml](kubernetes/apps/network/ingress-nginx/certificates/production.yaml) already creates the secret `${SECRET_DOMAIN/./-}-production-tls` which both ingress-nginx and envoy-gateway will share during the migration. This is intentional and correct - both systems can reference the same certificate secret.

Create `kubernetes/apps/network/envoy-gateway/app/observability.yaml`:
```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: envoy-proxy
  namespace: network
spec:
  jobLabel: envoy-proxy
  namespaceSelector:
    matchNames:
      - network
  podMetricsEndpoints:
    - port: metrics
      path: /stats/prometheus
      honorLabels: true
  selector:
    matchLabels:
      app.kubernetes.io/component: proxy
      app.kubernetes.io/name: envoy
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: envoy-gateway
  namespace: network
spec:
  endpoints:
    - port: metrics
      path: /metrics
      honorLabels: true
  jobLabel: envoy-gateway
  namespaceSelector:
    matchNames:
      - network
  selector:
    matchLabels:
      control-plane: envoy-gateway
```

#### Step 1.4: Deploy Envoy Gateway

```bash
# Commit and push changes
git add kubernetes/apps/network/envoy-gateway
git commit -m "Add envoy-gateway configuration"
git push

# Wait for deployment
flux reconcile kustomization cluster --with-source
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=envoy-gateway -n network --timeout=300s
```

#### Step 1.5: Verify Installation

```bash
# Check GatewayClass
kubectl get gatewayclass

# Check Gateways
kubectl get gateway -n network

# Check Gateway IPs
kubectl get svc -n network | grep envoy

# Verify gateway status
kubectl describe gateway envoy-external -n network
kubectl describe gateway envoy-internal -n network
```

Expected output should show both gateways with assigned IPs (192.168.3.26 and 192.168.3.27).

### Phase 2: Update Supporting Services

#### Step 2.1: Update External-DNS for Gateway API Support

Edit `kubernetes/apps/network/external-dns/app/helmrelease.yaml`:

```yaml
extraArgs:
  - --ingress-class=external
  - --cloudflare-proxied
  - --gateway-name=envoy-external  # Add this
  - --crd-source-apiversion=externaldns.k8s.io/v1alpha1
  - --crd-source-kind=DNSEndpoint
policy: sync
sources: ["crd", "ingress", "gateway-httproute"]  # Add gateway-httproute
```

Apply changes:
```bash
git add kubernetes/apps/network/external-dns
git commit -m "Update external-dns for Gateway API support"
git push
flux reconcile kustomization cluster --with-source
```

#### Step 2.2: Update Cloudflared Configuration

Edit `kubernetes/apps/network/cloudflared/app/configs/config.yaml`:

Add new routing rules for Envoy Gateway:
```yaml
ingress:
  # Existing rules for ingress-nginx
  - hostname: "whoami.${SECRET_DOMAIN}"
    service: https://cilium-gateway-external-gateway.kube-system.svc.cluster.local:443
    originRequest:
      originServerName: "external-gateway.${SECRET_DOMAIN}"
  - hostname: "${SECRET_DOMAIN}"
    service: https://ingress-nginx-external-controller.network.svc.cluster.local:443
    originRequest:
      originServerName: "external.${SECRET_DOMAIN}"
  - hostname: "*.${SECRET_DOMAIN}"
    service: https://ingress-nginx-external-controller.network.svc.cluster.local:443
    originRequest:
      originServerName: "external.${SECRET_DOMAIN}"

  # Add new rules for Envoy Gateway (commented out initially)
  # Uncomment these as you migrate services
  # - hostname: "myapp.${SECRET_DOMAIN}"  # Specific service
  #   service: https://envoy-network-envoy-external.network.svc.cluster.local:443
  #   originRequest:
  #     originServerName: "myapp.${SECRET_DOMAIN}"

  - hostname: "${SECRET_DOMAIN_TWO}"
    service: https://ingress-nginx-external-controller.network.svc.cluster.local:443
    originRequest:
      originServerName: "external.${SECRET_DOMAIN_TWO}"
  - hostname: "*.${SECRET_DOMAIN_TWO}"
    service: https://ingress-nginx-external-controller.network.svc.cluster.local:443
    originRequest:
      originServerName: "external.${SECRET_DOMAIN_TWO}"
  - service: http_status:404
```

**Note**: During migration, you'll update cloudflared routing rules to point specific hostnames to Envoy Gateway as you migrate each service.

#### Step 2.3: Update K8s-Gateway for HTTPRoute Support

K8s-gateway already watches HTTPRoute resources (configured in your current setup), so no changes are needed. Verify:

```bash
kubectl get helmrelease k8s-gateway -n network -o yaml | grep watchedResources
# Should show: watchedResources: ["Ingress", "Service", "HTTPRoute"]
```

### Phase 3: Migrate Services One-by-One

This is the core migration phase. You'll convert each Ingress resource to an HTTPRoute resource.

#### Step 3.1: Choose a Service to Migrate

Start with a non-critical service for testing. For example, let's migrate the `echo-server` service.

#### Step 3.2: Migration Pattern for External Services

**Before (Ingress)**:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo-server
  namespace: network
  annotations:
    external-dns.alpha.kubernetes.io/target: external.bigwang.org
spec:
  ingressClassName: external
  rules:
  - host: echo-server.bigwang.org
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: echo-server
            port:
              number: 8080
  tls:
  - hosts:
    - echo-server.bigwang.org
```

**After (HTTPRoute)**:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo-server
  namespace: network
  annotations:
    # HTTPRoute-specific annotations
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"
    external-dns.alpha.kubernetes.io/ttl: "300"
spec:
  parentRefs:
    - name: envoy-external
      namespace: network
      sectionName: https
  hostnames:
    - echo-server.bigwang.org
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: echo-server
          port: 8080
```

**Key differences**:
- `parentRefs` replaces `ingressClassName` - references the Gateway
- `hostnames` replaces `rules[].host`
- `backendRefs` replaces `backend.service`
- TLS is handled by the Gateway, not in the HTTPRoute
- Annotations are placed on HTTPRoute, not Gateway (except for `target`)

#### Step 3.3: Migration Pattern for Internal Services

**Before (Ingress)**:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hajimari
  namespace: default
  annotations:
    hajimari.io/enable: "false"
spec:
  ingressClassName: internal
  rules:
  - host: apps.bigwang.org
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hajimari
            port:
              number: 3000
  tls:
  - hosts:
    - apps.bigwang.org
```

**After (HTTPRoute)**:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hajimari
  namespace: default
  annotations:
    hajimari.io/enable: "false"
    external-dns.alpha.kubernetes.io/exclude: "true"  # Exclude from external-dns
spec:
  parentRefs:
    - name: envoy-internal
      namespace: network
      sectionName: https
  hostnames:
    - apps.bigwang.org
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: hajimari
          namespace: default
          port: 3000
```

#### Step 3.4: Migration Procedure for Each Service

1. **Create the HTTPRoute** (keep Ingress running):
   ```bash
   # Create new HTTPRoute manifest
   # Keep the old Ingress file as backup
   kubectl apply -f path/to/httproute.yaml
   ```

2. **Update Cloudflared** (for external services only):

   Edit `kubernetes/apps/network/cloudflared/app/configs/config.yaml` to route the specific hostname to Envoy Gateway:
   ```yaml
   ingress:
     # Add BEFORE the wildcard rules
     - hostname: "echo-server.${SECRET_DOMAIN}"
       service: https://envoy-network-envoy-external.network.svc.cluster.local:443
       originRequest:
         originServerName: "echo-server.${SECRET_DOMAIN}"

     # Keep existing wildcard rules below
     - hostname: "*.${SECRET_DOMAIN}"
       service: https://ingress-nginx-external-controller.network.svc.cluster.local:443
   ```

3. **Test the HTTPRoute**:
   ```bash
   # For external services, test via public domain
   curl -v https://echo-server.bigwang.org

   # For internal services, test from local network
   curl -v https://apps.bigwang.org

   # Check HTTPRoute status
   kubectl describe httproute echo-server -n network

   # Verify DNS record (external services)
   kubectl logs -n network -l app.kubernetes.io/name=external-dns --tail=50 | grep echo-server
   ```

4. **Verify traffic flows through Envoy Gateway**:
   ```bash
   # Check envoy gateway logs
   kubectl logs -n network -l gateway.envoyproxy.io/owning-gateway-name=envoy-external --tail=50

   # Check metrics
   kubectl port-forward -n network svc/envoy-network-envoy-external 19001:19001
   # Visit http://localhost:19001/stats in browser
   ```

5. **Delete the old Ingress** (after confirming HTTPRoute works):
   ```bash
   kubectl delete ingress echo-server -n network
   # Or remove from your GitOps repo and commit
   ```

6. **Repeat for next service**

#### Step 3.5: Advanced HTTPRoute Features

Gateway API provides additional features not available in Ingress:

**Path-based routing with rewrites**:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp-api
  namespace: myapp
spec:
  parentRefs:
    - name: envoy-external
      namespace: network
  hostnames:
    - api.bigwang.org
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: myapp-v1
          port: 8080
    - matches:
        - path:
            type: PathPrefix
            value: /v2
      backendRefs:
        - name: myapp-v2
          port: 8080
```

**Header-based routing**:
```yaml
rules:
  - matches:
      - headers:
          - name: X-Version
            value: beta
    backendRefs:
      - name: myapp-beta
        port: 8080
  - backendRefs:
      - name: myapp-stable
        port: 8080
```

**Traffic splitting (canary deployments)**:
```yaml
rules:
  - backendRefs:
      - name: myapp-v2
        port: 8080
        weight: 10  # 10% traffic
      - name: myapp-v1
        port: 8080
        weight: 90  # 90% traffic
```

**Request/response header manipulation**:
```yaml
rules:
  - filters:
      - type: RequestHeaderModifier
        requestHeaderModifier:
          add:
            - name: X-Custom-Header
              value: custom-value
          remove:
            - X-Internal-Header
    backendRefs:
      - name: myapp
        port: 8080
```

#### Step 3.6: Migration Order Recommendations

Recommended migration order:
1. **Test services** (echo-server, test apps)
2. **Low-traffic services** (internal tools, dashboards)
3. **Medium-traffic services** (media services like Plex)
4. **High-traffic services** (authentication, main websites)
5. **Critical services** (flux-webhook, monitoring)

### Phase 4: Complete Migration and Cleanup

#### Step 4.1: Verify All Services Migrated

```bash
# Check for remaining Ingress resources
kubectl get ingress -A

# Verify all HTTPRoutes are working
kubectl get httproute -A

# Check Gateway status
kubectl get gateway -n network
```

#### Step 4.2: Update Cloudflared to Use Only Envoy Gateway

Once all services are migrated, simplify cloudflared configuration to route all traffic to Envoy Gateway:

Edit `kubernetes/apps/network/cloudflared/app/configs/config.yaml`:
```yaml
originRequest:
  http2Origin: true
  noHappyEyeballs: false

ingress:
  - hostname: "whoami.${SECRET_DOMAIN}"
    service: https://cilium-gateway-external-gateway.kube-system.svc.cluster.local:443
    originRequest:
      originServerName: "external-gateway.${SECRET_DOMAIN}"
  # Route ALL domains to Envoy Gateway
  - hostname: "${SECRET_DOMAIN}"
    service: https://envoy-network-envoy-external.network.svc.cluster.local:443
    originRequest:
      originServerName: "external.${SECRET_DOMAIN}"
  - hostname: "*.${SECRET_DOMAIN}"
    service: https://envoy-network-envoy-external.network.svc.cluster.local:443
    originRequest:
      originServerName: "external.${SECRET_DOMAIN}"
  - hostname: "${SECRET_DOMAIN_TWO}"
    service: https://envoy-network-envoy-external.network.svc.cluster.local:443
    originRequest:
      originServerName: "external.${SECRET_DOMAIN_TWO}"
  - hostname: "*.${SECRET_DOMAIN_TWO}"
    service: https://envoy-network-envoy-external.network.svc.cluster.local:443
    originRequest:
      originServerName: "external.${SECRET_DOMAIN_TWO}"
  - service: http_status:404
```

Apply and verify:
```bash
git add kubernetes/apps/network/cloudflared
git commit -m "Update cloudflared to route all traffic to Envoy Gateway"
git push
flux reconcile kustomization cluster --with-source

# Test external services still work
curl -v https://auth.bigwang.org
```

#### Step 4.3: Remove Ingress-NGINX

```bash
# Remove ingress-nginx from kustomization
# Edit kubernetes/apps/network/kustomization.yaml and remove ingress-nginx references

# Delete the ingress-nginx directories
rm -rf kubernetes/apps/network/ingress-nginx

# Commit changes
git add kubernetes/apps/network
git commit -m "Remove ingress-nginx - migration to Envoy Gateway complete"
git push

# Reconcile
flux reconcile kustomization cluster --with-source
```

#### Step 4.4: Verify Cleanup

```bash
# Verify ingress-nginx is removed
kubectl get pods -n network | grep ingress-nginx
# Should return no results

# Check services
kubectl get svc -n network
# Should not show ingress-nginx services

# Verify all traffic flows through Envoy Gateway
kubectl logs -n network -l gateway.envoyproxy.io/owning-gateway-name=envoy-external --tail=100
```

#### Step 4.5: Update IP Allocations Documentation

Update the IP allocation table in this document:

| Service | IP | Purpose |
|---------|-----|---------|
| k8s-gateway | 192.168.3.22 | Local DNS server |
| envoy-external | 192.168.3.26 | External services gateway (replaces 192.168.3.23) |
| envoy-internal | 192.168.3.27 | Internal services gateway (replaces 192.168.3.21) |

### Migration Checklist

Use this checklist to track your migration progress:

- [ ] Phase 1: Install Envoy Gateway
  - [ ] Create envoy-gateway namespace and configuration
  - [ ] Add Helm repository
  - [ ] Deploy EnvoyProxy, GatewayClass, and Gateways
  - [ ] Verify installation and IP allocation
- [ ] Phase 2: Update Supporting Services
  - [ ] Update external-dns for Gateway API support
  - [ ] Update cloudflared configuration
  - [ ] Verify k8s-gateway HTTPRoute support
- [ ] Phase 3: Migrate Services
  - [ ] Test service: `_____________` (fill in service name)
  - [ ] Service 1: `_____________`
  - [ ] Service 2: `_____________`
  - [ ] Service 3: `_____________`
  - [ ] (Continue for all services)
- [ ] Phase 4: Complete Migration
  - [ ] Verify all services migrated
  - [ ] Update cloudflared to use only Envoy Gateway
  - [ ] Remove ingress-nginx
  - [ ] Verify cleanup
  - [ ] Update documentation

### Troubleshooting Migration Issues

#### HTTPRoute not working

```bash
# Check HTTPRoute status
kubectl describe httproute <name> -n <namespace>

# Check Gateway status
kubectl describe gateway envoy-external -n network

# Check if Gateway accepted the route
kubectl get httproute <name> -n <namespace> -o yaml | grep -A 10 "status:"

# Check Envoy proxy logs
kubectl logs -n network -l gateway.envoyproxy.io/owning-gateway-name=envoy-external
```

#### External-DNS not creating records

```bash
# Check external-dns logs
kubectl logs -n network -l app.kubernetes.io/name=external-dns --tail=100

# Verify HTTPRoute has correct annotation
kubectl get httproute <name> -n <namespace> -o yaml | grep external-dns

# Check if Gateway has target annotation
kubectl get gateway envoy-external -n network -o yaml | grep target
```

#### Cloudflared not routing to Envoy Gateway

```bash
# Check cloudflared logs
kubectl logs -n network -l app.kubernetes.io/name=cloudflared --tail=100

# Verify Envoy Gateway service exists
kubectl get svc -n network | grep envoy

# Test internal connection
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl -v -k https://envoy-network-envoy-external.network.svc.cluster.local:443 \
  -H "Host: echo-server.bigwang.org"
```

#### Service accessible via old Ingress but not HTTPRoute

This usually means:
1. Cloudflared still routing to ingress-nginx (check cloudflared config)
2. HTTPRoute not properly configured (check `parentRefs` and `hostnames`)
3. Gateway not ready (check `kubectl get gateway`)

### Post-Migration: New Service Deployment with Gateway API

After migration is complete, deploy new services using HTTPRoute:

**External Service Template**:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: myapp
  annotations:
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"
    hajimari.io/icon: mdi:application
spec:
  parentRefs:
    - name: envoy-external
      namespace: network
      sectionName: https
  hostnames:
    - myapp.bigwang.org
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp
          port: 80
```

**Internal Service Template**:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: myapp
  annotations:
    external-dns.alpha.kubernetes.io/exclude: "true"
    hajimari.io/icon: mdi:application
spec:
  parentRefs:
    - name: envoy-internal
      namespace: network
      sectionName: https
  hostnames:
    - myapp.bigwang.org
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp
          port: 80
```

### Key Implementation Notes

#### Differences from Standard Envoy Gateway Deployments

This migration plan incorporates production-tested enhancements from onedr0p's implementation:

**1. OCIRepository Instead of HelmRepository**
```yaml
# Standard approach uses HelmRepository
kind: HelmRepository
url: https://gateway.envoyproxy.io

# Our approach uses OCIRepository
kind: OCIRepository
url: oci://mirror.gcr.io/envoyproxy/gateway-helm
```
Benefits: Better reliability, uses Google Container Registry mirror, versioned OCI artifacts

**2. Zstd Compression via EnvoyPatchPolicy**
- Adds Zstd compression support (better than Brotli/Gzip)
- Requires `enableEnvoyPatchPolicy: true` in HelmRelease
- Applied via JSONPatch to both HTTPS and HTTPS-QUIC listeners

**3. Enhanced Buffer Sizes**
- ClientTrafficPolicy buffer: 8Mi (vs default 4Mi)
- HTTP/2 stream window: 2Mi (vs default 512Ki)
- HTTP/2 connection window: 32Mi (vs default 8Mi)
- Improves performance for large requests/responses

**4. Traffic Policy**
- `externalTrafficPolicy: Local` preserves source IP addresses
- Better for logging and security policies

**5. Certificate Sharing**
- Both ingress-nginx and envoy-gateway reference the same secret
- No duplicate certificates, no Let's Encrypt rate limit concerns
- Seamless during migration, clean after

**6. Observability**
- PodMonitor for Envoy proxy metrics
- ServiceMonitor for Envoy Gateway controller metrics
- Full Prometheus integration

#### Migration Simplifications

The migration is simpler than typical ingress-to-gateway migrations:

1. **No service-by-service cloudflared updates needed**
   - Once envoy-gateway is installed, cloudflared uses wildcard routing
   - Just migrate HTTPRoutes one at a time

2. **External-DNS handles both simultaneously**
   - Supports both Ingress and HTTPRoute sources during migration
   - No DNS switchover needed

3. **Shared certificate**
   - Single wildcard cert works for both systems
   - No certificate regeneration or switchover

4. **Parallel operation**
   - Both systems run on different IPs
   - No conflicts, easy rollback

### Additional Resources

- [Kubernetes Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway Official Docs](https://gateway.envoyproxy.io/)
- [External-DNS Gateway API Guide](https://kubernetes-sigs.github.io/external-dns/latest/docs/sources/gateway-api/)
- [Gateway API v1.4 Release Notes](https://kubernetes.io/blog/2025/11/06/gateway-api-v1-4/)
- [onedr0p/home-ops](https://github.com/onedr0p/home-ops) - Production reference implementation
- [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template) - Flux templates
- [Cloudflare Tunnel with Kubernetes](https://blog.kyledev.co/posts/protecting-internet-facing-apps/)

## Quick Reference Commands

```bash
# View all network services
kubectl get svc -n network

# View ingress classes
kubectl get ingressclass

# View Gateway API resources
kubectl get gatewayclass
kubectl get gateway -A
kubectl get httproute -A

# Check external-dns managed records
kubectl get dnsendpoint -A

# View certificates
kubectl get certificate -A

# Check cloudflared tunnel status
kubectl get pods -n network -l app.kubernetes.io/name=cloudflared
kubectl logs -n network -l app.kubernetes.io/name=cloudflared --tail=50

# Check Envoy Gateway status
kubectl get pods -n network -l app.kubernetes.io/name=envoy-gateway
kubectl logs -n network -l gateway.envoyproxy.io/owning-gateway-name=envoy-external --tail=50
kubectl logs -n network -l gateway.envoyproxy.io/owning-gateway-name=envoy-internal --tail=50

# Test internal DNS
dig @192.168.3.22 test.bigwang.org

# View ingress controller logs (during migration)
kubectl logs -n network -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller -l app.kubernetes.io/instance=ingress-nginx-external --tail=50
kubectl logs -n network -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller -l app.kubernetes.io/instance=ingress-nginx-internal --tail=50
```
