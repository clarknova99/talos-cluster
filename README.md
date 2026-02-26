<div align="center">
  <img src="https://raw.githubusercontent.com/clarknova99/talos-cluster/main/assets/kube.png" align="center" width="144px" height="144px"/>
</div>

<div align="center">
<br/>
</div>

<div align="center">

  [![Talos](https://raw.githubusercontent.com/clarknova99/talos-cluster/refs/heads/main/kromgo/talos_version.svg)](https://github.com/kashalls/kromgo/)&nbsp;
  [![Kubernetes](https://raw.githubusercontent.com/clarknova99/talos-cluster/refs/heads/main/kromgo/kubernetes_version.svg)](https://github.com/kashalls/kromgo/)&nbsp;

</div>

<div align="center">

[![CPU-Count](https://raw.githubusercontent.com/clarknova99/talos-cluster/refs/heads/main/kromgo/cluster_cpu_core_total.svg)](https://github.com/kashalls/kromgo/)&nbsp;
[![Memory-Total](https://raw.githubusercontent.com/clarknova99/talos-cluster/refs/heads/main/kromgo/cluster_memory_total.svg)](https://github.com/kashalls/kromgo/)&nbsp;

</div>
<div align="center">

[![Age-Days](https://raw.githubusercontent.com/clarknova99/talos-cluster/refs/heads/main/kromgo/cluster_age_days.svg)](https://github.com/kashalls/kromgo/)&nbsp;
[![Node-Count](https://raw.githubusercontent.com/clarknova99/talos-cluster/refs/heads/main/kromgo/cluster_node_count.svg)](https://github.com/kashalls/kromgo/)&nbsp;
[![CPU-Usage](https://raw.githubusercontent.com/clarknova99/talos-cluster/refs/heads/main/kromgo/cluster_cpu_usage.svg)](https://github.com/kashalls/kromgo/)&nbsp;
[![Memory-Usage](https://raw.githubusercontent.com/clarknova99/talos-cluster/refs/heads/main/kromgo/cluster_memory_usage.svg)](https://github.com/kashalls/kromgo/)&nbsp;
[![Pod-Count](https://raw.githubusercontent.com/clarknova99/talos-cluster/refs/heads/main/kromgo/cluster_pod_count.svg)](https://github.com/kashalls/kromgo/)&nbsp;

</div>

---

## :book:&nbsp; Overview

This repository manages a bare-metal Kubernetes cluster running [Talos Linux](https://www.talos.dev/). Infrastructure is declared as code and deployed via [Flux CD](https://fluxcd.io/) GitOps. All traffic routing uses [Envoy Gateway](https://gateway.envoyproxy.io/) with the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/).

**Cluster Details:**
- **OS**: Talos Linux v1.12.3
- **Kubernetes**: v1.35.0
- **Cluster Name**: `home-kubernetes`
- **API Endpoint**: `https://192.168.3.20:6443` (VIP shared across control plane nodes)
- **Pod CIDR**: `10.69.0.0/16`
- **Service CIDR**: `10.96.0.0/16`
- **CNI**: Cilium (Flannel disabled)

## Nodes

| Hostname | Device | Ram | IP | Role | Install Disk |
|----------|----|------|----|------|--------------|
| mercury | Beelink EQ13  | 32GB | 192.168.3.241 | Control Plane | /dev/sdb |
| venus | Beelink EQ13  | 32GB | 192.168.3.101 | Control Plane | /dev/sdb |
| earth | Beelink EQ13  | 32GB | 192.168.3.214 | Control Plane | /dev/sdb |
| mars | Intel NUC8i5BEH  | 32GB | 192.168.3.102 | Worker | /dev/sdb |
| jupiter | Intel NUC11PAHi7   | 64GB |192.168.3.219 | Worker | /dev/sdb |

All control plane nodes share VIP `192.168.3.20` for the Kubernetes API server.


## GitOps with Flux CD

The cluster is managed entirely through GitOps using Flux CD. Changes are committed to this repository and automatically reconciled by Flux.

**Key Flux resources:**
- `cluster-repositories` — Helm, Git, and OCI repository sources
- `cluster-apps` — All application workloads, with SOPS decryption for secrets

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) and decrypted at reconciliation time. Flux variable substitution is used for templating values like `${SECRET_DOMAIN}` and `${SECRET_DOMAIN_TWO}` across manifests.

## Repository Structure

```
kubernetes/
├── apps/                         # Application workloads
│   ├── cert-manager/             # TLS certificate management
│   ├── database/                 # Databases (CloudNative-PG, Dragonfly, Redis, ClickHouse, InfluxDB)
│   ├── default/                  # General services (Authelia, Homepage, LLDAP, etc.)
│   ├── flux-system/              # Flux operator and instance
│   ├── kube-system/              # Core infrastructure (Cilium, CoreDNS, Spegel, etc.)
│   ├── media/                    # Media stack (Plex, Sonarr, Radarr, etc.)
│   ├── network/                  # Networking (Envoy Gateway, Cloudflared, External-DNS, etc.)
│   ├── observability/            # Monitoring (Prometheus, Grafana, Loki, Alloy, etc.)
│   ├── openebs-system/           # OpenEBS storage
│   ├── rook-ceph/                # Rook-Ceph storage
│   ├── sensei/                   # Sensei application environments (dev, stage, prod)
│   ├── system-upgrade/           # System upgrade controller (Tuppr)
│   ├── volsync-system/           # VolSync backup and replication
│   └── actions-runner-system/    # GitHub Actions self-hosted runners
├── bootstrap/
│   ├── flux/                     # Flux bootstrap kustomization
│   └── talos/                    # Talos node configuration (talhelper)
├── components/                   # Shared Flux components (SOPS, VolSync)
└── flux/
    ├── cluster/                  # Root Flux Kustomizations
    └── repositories/             # Helm, Git, OCI repository definitions
```

## Networking Architecture

### Component Overview

| Component | Purpose | Configuration |
|-----------|---------|---------------|
| Cloudflared | Secure tunnel from Cloudflare edge to the cluster | [kubernetes/apps/network/cloudflared](kubernetes/apps/network/cloudflared) |
| Envoy Gateway | Traffic routing via Kubernetes Gateway API | [kubernetes/apps/network/envoy-gateway](kubernetes/apps/network/envoy-gateway) |
| External-DNS | Automatic DNS record management in Cloudflare | [kubernetes/apps/network/external-dns](kubernetes/apps/network/external-dns) |
| K8s-Gateway | Local DNS resolution for in-cluster services | [kubernetes/apps/network/k8s-gateway](kubernetes/apps/network/k8s-gateway) |
| Cert-Manager | Automated TLS certificates from Let's Encrypt | [kubernetes/apps/cert-manager](kubernetes/apps/cert-manager) |
| Cilium | CNI, LoadBalancer IPAM, network policies | [kubernetes/apps/kube-system/cilium](kubernetes/apps/kube-system/cilium) |

### Network IP Allocations

Cilium LB-IPAM manages LoadBalancer service IPs:

| Service | IP | Purpose |
|---------|----|---------|
| Kubernetes API (VIP) | 192.168.3.20 | Shared control plane VIP |
| K8s-Gateway | 192.168.3.22 | Local DNS server |
| Envoy External | 192.168.3.26 | External services gateway |
| Envoy Internal | 192.168.3.27 | Internal services gateway |

### 1. Cloudflared Tunnel

Provides a secure tunnel from Cloudflare's edge network to the cluster, eliminating the need for direct port forwarding.

- Runs as a deployment in the `network` namespace
- Uses Cloudflare Tunnel ID to establish a secure connection
- Routes traffic based on hostname to Envoy Gateway
- Uses HTTP/2 origin connections

**Tunnel routing** ([config.yaml](kubernetes/apps/network/cloudflared/app/configs/config.yaml)):
```yaml
ingress:
  - hostname: "${SECRET_DOMAIN}"
    service: https://envoy-external.network.svc.cluster.local:443
  - hostname: "*.${SECRET_DOMAIN}"
    service: https://envoy-external.network.svc.cluster.local:443
  - hostname: "${SECRET_DOMAIN_TWO}"
    service: https://envoy-external.network.svc.cluster.local:443
  - hostname: "*.${SECRET_DOMAIN_TWO}"
    service: https://envoy-external.network.svc.cluster.local:443
  - service: http_status:404
```

**DNS Endpoints** ([dnsendpoint.yaml](kubernetes/apps/network/cloudflared/app/dnsendpoint.yaml)):
- `external.${SECRET_DOMAIN}` → `${SECRET_CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com`
- `external.${SECRET_DOMAIN_TWO}` → `${SECRET_CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com`
- `external-gateway.${SECRET_DOMAIN}` → `${SECRET_CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com`

### 2. Envoy Gateway

Handles all ingress traffic using the Kubernetes Gateway API. Two separate Gateways serve different network zones.

**Deployment details:**
- Helm chart: `oci://mirror.gcr.io/envoyproxy/gateway-helm` (via OCIRepository)
- 2 replicas per gateway for high availability
- EnvoyPatchPolicy enabled for advanced configuration
- GatewayClass: `envoy`

#### External Gateway (`envoy-external`)

Handles internet-facing services accessible via the Cloudflare tunnel.

- LoadBalancer IP: `192.168.3.26`
- Listeners: HTTP (port 80), HTTPS (port 443)
- HTTPS listener allows routes from all namespaces
- HTTP listener restricted to `network` and `database` namespaces (for redirects)
- Automatic HTTP → HTTPS redirect (301)

#### Internal Gateway (`envoy-internal`)

Handles services accessible only on the local network.

- LoadBalancer IP: `192.168.3.27`
- Listeners: HTTP (port 80), HTTPS (port 443)
- HTTPS listener allows routes from all namespaces
- HTTP listener restricted to same namespace (for redirects)
- Automatic HTTP → HTTPS redirect (301)

#### Traffic Policies

**BackendTrafficPolicy:**
- Compression: Zstd, Brotli, Gzip
- Connection buffer limit: 8Mi
- TCP keepalive enabled
- No request timeout (unlimited)

**ClientTrafficPolicy:**
- Client IP detection via X-Forwarded-For (1 trusted hop)
- Connection buffer: 8Mi
- HTTP/2: 2Mi stream window, 32Mi connection window, 100 max concurrent streams
- HTTP/3 enabled
- TLS minimum version: 1.2
- ALPN protocols: h2, http/1.1

**EnvoyPatchPolicy:**
- Zstd compression on both gateways via filter chain patches
- Lua filter on external gateway to extract X-Real-IP from X-Forwarded-For

### 3. External-DNS

Automatically manages DNS records in Cloudflare based on Kubernetes resources.

- Watches Gateway HTTPRoute resources (via `--gateway-name=envoy-external`)
- Watches DNSEndpoint custom resources
- Creates Cloudflare-proxied DNS records
- Records are prefixed with `k8s.` for identification
- Manages domains: `${SECRET_DOMAIN}` and `${SECRET_DOMAIN_TWO}`
- Sources: `crd`, `ingress`, `gateway-httproute`

### 4. K8s-Gateway

Provides local DNS resolution so devices on the LAN can access cluster services without routing through the internet.

- DNS server on port 53
- LoadBalancer IP: `192.168.3.22`
- Watches Ingress, Service, and HTTPRoute resources
- Returns gateway LoadBalancer IPs for hostname queries
- Domains: `${SECRET_DOMAIN}` and `${SECRET_DOMAIN_TWO}`
- TTL: 1 second

**Usage**: Configure your local DNS server (router, Pi-hole, etc.) to forward queries for `${SECRET_DOMAIN}` and `${SECRET_DOMAIN_TWO}` to `192.168.3.22`.

### 5. Cert-Manager

Manages TLS certificates from Let's Encrypt using DNS-01 challenge validation with Cloudflare.

**Cluster Issuers:**
- `letsencrypt-production` — Production certificates
- `letsencrypt-staging` — Testing certificates

**Wildcard Certificates** ([kubernetes/apps/network/envoy-gateway/certificates/production.yaml](kubernetes/apps/network/envoy-gateway/certificates/production.yaml)):

| Certificate | Secret | Covers |
|-------------|--------|--------|
| `${SECRET_DOMAIN/./-}-production` | `${SECRET_DOMAIN/./-}-production-tls` | `${SECRET_DOMAIN}`, `*.${SECRET_DOMAIN}` |
| `${SECRET_DOMAIN_TWO/./-}-production` | `${SECRET_DOMAIN_TWO/./-}-production-tls` | `${SECRET_DOMAIN_TWO}`, `*.${SECRET_DOMAIN_TWO}` |

Both Envoy Gateways reference these certificate secrets for TLS termination. No per-service certificate configuration is needed for subdomains of these domains.

## Network Traffic Flows

### External Traffic (Internet → Service)

```
Internet User
    ↓
Cloudflare Edge Network (DNS + proxy)
    ↓
Cloudflared Tunnel (in cluster)
    ↓
Envoy External Gateway (192.168.3.26)
    ↓
HTTPRoute → Service Pod
```

**Step-by-step:**
1. User requests `https://app.${SECRET_DOMAIN}`
2. DNS resolves to Cloudflare (via External-DNS managed CNAME)
3. Cloudflare proxies the request through the tunnel to the cloudflared pod
4. Cloudflared forwards to `envoy-external.network.svc.cluster.local:443`
5. Envoy matches the HTTPRoute by hostname and routes to the backend service
6. TLS is terminated at the Gateway using the wildcard certificate

### Internal Traffic (Local Network → Service)

```
Local Device
    ↓
K8s-Gateway DNS (192.168.3.22)
    ↓ (returns 192.168.3.27)
Envoy Internal Gateway (192.168.3.27)
    ↓
HTTPRoute → Service Pod
```

**Step-by-step:**
1. Local device queries `app.${SECRET_DOMAIN}`
2. Local DNS server forwards to K8s-Gateway (`192.168.3.22`)
3. K8s-Gateway returns `192.168.3.27` (internal gateway IP)
4. Device connects directly to the Envoy Internal Gateway
5. Envoy matches the HTTPRoute by hostname and routes to the backend service

## Deploying New Services

Services are exposed using HTTPRoute resources from the Kubernetes Gateway API.

### External Service (Internet-Accessible)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: myapp
  annotations:
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"
spec:
  parentRefs:
    - name: envoy-external
      namespace: network
      sectionName: https
  hostnames:
    - myapp.${SECRET_DOMAIN}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp
          port: 80
```

**What happens:**
1. External-DNS detects the HTTPRoute attached to `envoy-external`
2. Creates a Cloudflare-proxied CNAME: `myapp.${SECRET_DOMAIN}` → `external.${SECRET_DOMAIN}`
3. `external.${SECRET_DOMAIN}` → Cloudflare Tunnel (via DNSEndpoint)
4. Cloudflared forwards traffic to Envoy External Gateway
5. Envoy routes to the backend service
6. TLS is handled by the gateway's wildcard certificate

### Internal Service (Local Network Only)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: myapp
  annotations:
    external-dns.alpha.kubernetes.io/exclude: "true"
spec:
  parentRefs:
    - name: envoy-internal
      namespace: network
      sectionName: https
  hostnames:
    - myapp.${SECRET_DOMAIN}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp
          port: 80
```

**What happens:**
1. K8s-Gateway detects the HTTPRoute
2. Returns `192.168.3.27` (internal gateway IP) for DNS queries
3. Local devices connect directly to Envoy Internal Gateway
4. Envoy routes to the backend service
5. TLS is handled by the gateway's wildcard certificate

### Dual-Mode Service (Both Internal and External)

Create two separate HTTPRoute resources pointing to the same backend:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp-external
  namespace: myapp
  annotations:
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"
spec:
  parentRefs:
    - name: envoy-external
      namespace: network
      sectionName: https
  hostnames:
    - myapp-public.${SECRET_DOMAIN}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp
          port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp-internal
  namespace: myapp
  annotations:
    external-dns.alpha.kubernetes.io/exclude: "true"
spec:
  parentRefs:
    - name: envoy-internal
      namespace: network
      sectionName: https
  hostnames:
    - myapp.${SECRET_DOMAIN}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp
          port: 80
```

### Advanced HTTPRoute Features

**Path-based routing with URL rewrites:**
```yaml
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

**Header-based routing:**
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

**Traffic splitting (canary deployments):**
```yaml
rules:
  - backendRefs:
      - name: myapp-v2
        port: 8080
        weight: 10
      - name: myapp-v1
        port: 8080
        weight: 90
```

## Certificate Management

### Default Wildcard Certificates

Both Envoy Gateways are configured with wildcard certificates that cover `*.${SECRET_DOMAIN}` and `*.${SECRET_DOMAIN_TWO}`. TLS is automatically applied to all HTTPRoutes — no per-service configuration is needed.

### Custom Certificates

For domains outside the wildcard coverage:

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

Then reference the secret in a Gateway listener or use [ReferenceGrant](https://gateway-api.sigs.k8s.io/api-types/referencegrant/) to allow cross-namespace secret access.

## Storage

| Component | Purpose | Configuration |
|-----------|---------|---------------|
| Rook-Ceph | Distributed block and object storage | [kubernetes/apps/rook-ceph](kubernetes/apps/rook-ceph) |
| OpenEBS | Local PV storage | [kubernetes/apps/openebs-system](kubernetes/apps/openebs-system) |
| VolSync | PVC backup and replication | [kubernetes/apps/volsync-system](kubernetes/apps/volsync-system) |
| CSI Driver NFS | NFS volume support | [kubernetes/apps/kube-system/csi-driver-nfs](kubernetes/apps/kube-system/csi-driver-nfs) |
| MinIO | S3-compatible object storage | [kubernetes/apps/kube-system/minio](kubernetes/apps/kube-system/minio) |

## Observability

| Component | Purpose | Configuration |
|-----------|---------|---------------|
| Kube-Prometheus-Stack | Prometheus, Alertmanager, and Grafana | [kubernetes/apps/observability/kube-prometheus-stack](kubernetes/apps/observability/kube-prometheus-stack) |
| Grafana | Dashboards and visualization | [kubernetes/apps/observability/grafana](kubernetes/apps/observability/grafana) |
| Alloy | Metrics and logs collection agent | [kubernetes/apps/observability/alloy](kubernetes/apps/observability/alloy) |
| Loki | Log aggregation | [kubernetes/apps/observability/loki](kubernetes/apps/observability/loki) |
| Victoria Logs | Log storage | [kubernetes/apps/observability/victoria-logs](kubernetes/apps/observability/victoria-logs) |
| Fluent Bit | Log shipping | [kubernetes/apps/observability/fluent-bit](kubernetes/apps/observability/fluent-bit) |
| Kromgo | Cluster badge/status metrics | [kubernetes/apps/observability/kromgo](kubernetes/apps/observability/kromgo) |
| Smartctl Exporter | Disk health monitoring | [kubernetes/apps/observability/smartctl-exporter](kubernetes/apps/observability/smartctl-exporter) |

Envoy Gateway exposes metrics via PodMonitor (proxy metrics) and ServiceMonitor (controller metrics) in the `network` namespace.


## Troubleshooting

### Service not accessible from the internet

1. Verify the HTTPRoute is attached to `envoy-external`:
   ```bash
   kubectl get httproute -n <namespace> <name> -o yaml | grep -A5 parentRefs
   ```

2. Check HTTPRoute status (accepted by gateway):
   ```bash
   kubectl describe httproute <name> -n <namespace>
   ```

3. Verify External-DNS created the DNS record:
   ```bash
   kubectl logs -n network -l app.kubernetes.io/name=external-dns --tail=50
   ```

4. Check Cloudflared tunnel is running:
   ```bash
   kubectl get pods -n network -l app.kubernetes.io/name=cloudflared
   kubectl logs -n network -l app.kubernetes.io/name=cloudflared --tail=50
   ```

5. Check Envoy Gateway proxy logs:
   ```bash
   kubectl logs -n network -l gateway.envoyproxy.io/owning-gateway-name=envoy-external --tail=50
   ```

### Service not accessible from local network

1. Verify the HTTPRoute is attached to `envoy-internal`:
   ```bash
   kubectl get httproute -n <namespace> <name> -o yaml | grep -A5 parentRefs
   ```

2. Verify K8s-Gateway is running:
   ```bash
   kubectl get pods -n network -l app.kubernetes.io/name=k8s-gateway
   ```

3. Test DNS resolution:
   ```bash
   dig @192.168.3.22 myapp.${SECRET_DOMAIN}
   # Should return 192.168.3.27
   ```

4. Ensure your local DNS forwards to K8s-Gateway:
   - Router or Pi-hole should forward `${SECRET_DOMAIN}` and `${SECRET_DOMAIN_TWO}` to `192.168.3.22`

### Certificate issues

1. Check certificate status:
   ```bash
   kubectl get certificate -A
   ```

2. Check Cert-Manager logs:
   ```bash
   kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager
   ```

3. Verify ClusterIssuers are ready:
   ```bash
   kubectl get clusterissuer
   ```

### Gateway issues

1. Check Gateway status:
   ```bash
   kubectl get gateway -n network
   kubectl describe gateway envoy-external -n network
   kubectl describe gateway envoy-internal -n network
   ```

2. Check Envoy Gateway controller logs:
   ```bash
   kubectl logs -n network -l app.kubernetes.io/name=envoy-gateway --tail=50
   ```

## Quick Reference Commands

```bash
# View all network services and their IPs
kubectl get svc -n network

# View all HTTPRoutes across namespaces
kubectl get httproute -A

# View Gateway status
kubectl get gateway -n network

# View GatewayClass
kubectl get gatewayclass

# Check External-DNS managed records
kubectl get dnsendpoint -A

# View certificates
kubectl get certificate -A

# Check Cloudflared tunnel
kubectl get pods -n network -l app.kubernetes.io/name=cloudflared
kubectl logs -n network -l app.kubernetes.io/name=cloudflared --tail=50

# Check Envoy Gateway controller
kubectl get pods -n network -l app.kubernetes.io/name=envoy-gateway

# Check Envoy proxy instances
kubectl logs -n network -l gateway.envoyproxy.io/owning-gateway-name=envoy-external --tail=50
kubectl logs -n network -l gateway.envoyproxy.io/owning-gateway-name=envoy-internal --tail=50

# Test internal DNS resolution
dig @192.168.3.22 app.${SECRET_DOMAIN}

# List all pods in network namespace
kubectl get pods -n network
```

## Best Practices

1. **Gateway Selection**:
   - Use `envoy-external` only for services that need internet access
   - Default to `envoy-internal` for security-sensitive services
   - Never expose admin panels externally unless protected by authentication (e.g., Authelia)

2. **DNS Naming**:
   - Use descriptive subdomains: `app.${SECRET_DOMAIN}` not `app1.${SECRET_DOMAIN}`
   - Keep external and internal subdomains separate for dual-mode services

3. **HTTPRoute Annotations**:
   - Add `external-dns.alpha.kubernetes.io/exclude: "true"` for internal-only services
   - Add `external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"` for external services

4. **TLS**:
   - Let the gateway's wildcard certificates handle TLS automatically
   - Only create custom certificates for domains outside wildcard coverage

5. **Namespaces**:
   - Keep related services in the same namespace
   - HTTPRoutes should live in the same namespace as their backend services

## Configuration Files Reference

| Component | Configuration Path |
|-----------|-------------------|
| Cloudflared | [kubernetes/apps/network/cloudflared](kubernetes/apps/network/cloudflared) |
| Envoy Gateway | [kubernetes/apps/network/envoy-gateway](kubernetes/apps/network/envoy-gateway) |
| Envoy Gateways & Policies | [kubernetes/apps/network/envoy-gateway/gateway](kubernetes/apps/network/envoy-gateway/gateway) |
| Certificates | [kubernetes/apps/network/envoy-gateway/certificates](kubernetes/apps/network/envoy-gateway/certificates) |
| External-DNS | [kubernetes/apps/network/external-dns](kubernetes/apps/network/external-dns) |
| K8s-Gateway | [kubernetes/apps/network/k8s-gateway](kubernetes/apps/network/k8s-gateway) |
| Cert-Manager | [kubernetes/apps/cert-manager](kubernetes/apps/cert-manager) |
| Cilium | [kubernetes/apps/kube-system/cilium](kubernetes/apps/kube-system/cilium) |
| Talos Config | [kubernetes/bootstrap/talos/talconfig.yaml](kubernetes/bootstrap/talos/talconfig.yaml) |


---

Based on the fantastic [flux template](https://github.com/onedr0p/cluster-template) created by [onedr0p](https://github.com/onedr0p)
