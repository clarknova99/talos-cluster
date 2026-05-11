# AGENTS.md — Cluster Context for AI Agents

This file gives AI agents the context needed to work in this repo without requiring manual briefing each session.

---

## Committing Changes

**Always use the task runner to commit** — never use raw `git` or `flux` commands to commit and push:

```bash
task flux:commit -- "<commit message>"
```

This single command: pulls latest, stages all changes, commits, pushes, and triggers a Flux reconcile. Example:

```bash
task flux:commit -- "add homepage to default namespace"
```

You can also invoke this as the `/flux-commit` slash command, which will auto-generate a commit message from the diff if none is provided.

> **Why**: A bare `git push` without the reconcile step leaves the cluster out of sync until the next 1h interval. The task ensures changes are applied immediately.

---

## What This Repo Is

This is a **GitOps-managed home Kubernetes cluster** using:
- **Talos Linux** as the OS on all nodes
- **Flux CD** as the GitOps operator (changes to this repo automatically reconcile to the cluster)
- **Helm** (via HelmRelease) as the primary deployment mechanism
- **Kustomize** as the config layering tool
- **SOPS + Age** for secrets encryption

**GitHub remote**: `https://github.com/clarknova99/talos-cluster.git` (branch: `main`)

Any change merged to `main` will be automatically applied to the cluster by Flux within the reconciliation interval (default 30m for apps, 1h for the root).

---

## Cluster Hardware

| Node | Device | RAM | Role | IP |
|------|--------|-----|------|----|
| mercury | Beelink EQ13 | 32GB | Control Plane | 192.168.3.241 |
| venus | Beelink EQ13 | 32GB | Control Plane | 192.168.3.101 |
| earth | Beelink EQ13 | 32GB | Control Plane | 192.168.3.214 |
| mars | Intel NUC8i5BEH | 32GB | Worker | 192.168.3.102 |
| jupiter | Intel NUC11PAHi7 | 64GB | Worker | 192.168.3.219 |

- Kubernetes version: v1.35.0 — Cluster name: `home-kubernetes`
- Talos version: v1.12.3
- Control plane VIP / API endpoint: `192.168.3.20` (`https://192.168.3.20:6443`)
- Network: Firewalla Gold router, Zyxel GS1900-24E switch, APC SMT1500C UPS

---

## Directory Structure

```
talos-cluster/
├── kubernetes/
│   ├── apps/               # All application workloads, organized by namespace
│   │   ├── {namespace}/
│   │   │   ├── kustomization.yaml   # Namespace aggregator — lists all app ks.yaml files
│   │   │   └── {app-name}/
│   │   │       ├── ks.yaml          # Flux Kustomization (in flux-system namespace)
│   │   │       └── app/
│   │   │           ├── kustomization.yaml  # Kustomize resource list
│   │   │           ├── helmrelease.yaml    # HelmRelease definition
│   │   │           ├── config.yaml         # ConfigMap (optional)
│   │   │           └── rbac.yaml           # RBAC (optional)
│   ├── bootstrap/
│   │   ├── flux/           # Initial Flux bootstrap
│   │   └── talos/          # Talos node configs and talconfig.yaml
│   ├── components/
│   │   ├── sops/           # cluster-secrets.sops.yaml (global encrypted vars)
│   │   └── volsync/        # Reusable VolSync backup templates
│   └── flux/
│       ├── cluster/        # Root Flux Kustomizations (ks.yaml)
│       ├── repositories/   # HelmRepository, OCIRepository, GitRepository definitions
│       │   ├── helm/
│       │   ├── oci/
│       │   └── git/
│       └── vars/           # Flux variable substitution sources
├── bootstrap/              # talhelper bootstrap files
├── config.yaml             # Master bootstrap config (domains, IPs, tunnel IDs)
└── .sops.yaml              # SOPS encryption rules
```

---

## Namespaces and Their Apps

| Namespace | Apps |
|-----------|------|
| `flux-system` | flux-operator, flux-instance |
| `cert-manager` | cert-manager |
| `kube-system` | cilium, coredns, metrics-server, minio, node-feature-discovery, spegel, reloader, csi-driver-nfs, intel-gpu-resource-driver, openebs |
| `network` | cloudflared, envoy-gateway, external-dns, k8s-gateway, echo-server |
| `database` | cloudnative-pg, dragonfly, influxdb, clickhouse |
| `default` | authelia, homepage, it-tools, kite, lldap, synology, website, whoami |
| `media` | plex, sonarr, radarr, bazarr, prowlarr, qbittorrent, sabnzbd, flaresolverr, invidious |
| `observability` | kube-prometheus-stack, grafana, victoria-logs, fluent-bit, alloy, gatus, smartctl-exporter, kromgo |
| `rook-ceph` | rook-ceph (distributed block/object storage) |
| `openebs-system` | openebs (local PV storage) |
| `volsync-system` | volsync, kopia, snapshot-controller |
| `system-upgrade` | system-upgrade-controller |
| `actions-runner-system` | actions-runner-controller |
| `sensei` | sensei-{dev,stage,prod}, langfuse, litellm, n8n, dittofeed, rybbit |

---

## How Flux Works in This Repo

Two root Kustomizations drive everything (`kubernetes/flux/cluster/ks.yaml`):

1. **`cluster-repositories`** — reconciles all HelmRepository, OCIRepository, GitRepository objects from `kubernetes/flux/repositories/`. Interval: 1h.
2. **`cluster-apps`** — reconciles all application Kustomizations from `kubernetes/apps/`. Interval: 1h. SOPS decryption enabled. Variable substitution from `cluster-secrets` Secret.

Each app has its own `ks.yaml` (a `Kustomization` in the `flux-system` namespace) that points to the app's `app/` directory. Flux evaluates these and applies whatever Kubernetes resources are defined there.

**Global patches** applied automatically to all HelmReleases by Flux:
- CRD handling: `CreateReplace` on install and upgrade
- Install failure: `remediation.retries: 3`, cleanup on failure
- Upgrade failure: `remediation.strategy: rollback`, `remediation.retries: 3`

---

## Secrets and Variable Substitution

**SOPS + Age** is used for all secrets. The Age public key is in `.sops.yaml`. Secret files follow the pattern `*.sops.yaml`.

All global secrets live in `kubernetes/components/sops/cluster-secrets.sops.yaml` — a single `Secret` in `flux-system`. Flux substitutes `${SECRET_VAR_NAME}` placeholders across all manifests.

Key variable names (from cluster-secrets):
- `${SECRET_DOMAIN}` — primary domain (bigwang.org)
- `${SECRET_DOMAIN_TWO}`, `${SECRET_DOMAIN_THREE}` — secondary domains
- `${SECRET_CLOUDFLARE_API_TOKEN}` — for DNS challenges and external-dns
- Database, OAuth, API keys, and service credentials follow the `SECRET_*` naming pattern

**Never commit plaintext secrets.** Encrypt with `sops --encrypt` before committing any file containing credentials.

---

## Adding a New Application

### 1. Create the directory structure

```
kubernetes/apps/{namespace}/{app-name}/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    └── helmrelease.yaml
```

### 2. Write `ks.yaml` (Flux Kustomization)

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app {app-name}
  namespace: flux-system
spec:
  targetNamespace: {namespace}
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./kubernetes/apps/{namespace}/{app-name}/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: false
  interval: 30m
  retryInterval: 1m
  timeout: 5m
  postBuild:
    substituteFrom:
      - kind: Secret
        name: cluster-secrets
```

### 3. Write `app/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
```

### 4. Write `app/helmrelease.yaml`

Most apps use the `app-template` OCI chart from bjw-s:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: {app-name}
  namespace: {namespace}
spec:
  chartRef:
    kind: OCIRepository
    name: app-template
    namespace: flux-system
  interval: 30m
  values:
    controllers:
      {app-name}:
        containers:
          app:
            image:
              repository: {image}
              tag: {tag}
    service:
      app:
        controller: {app-name}
        ports:
          http:
            port: {port}
```

For apps with their own Helm chart, use `HelmRepository` instead:
```yaml
  chartRef:
    kind: HelmRepository
    name: {repo-name}      # must exist in kubernetes/flux/repositories/helm/
    namespace: flux-system
```

### 5. Register in the namespace kustomization

Edit `kubernetes/apps/{namespace}/kustomization.yaml` and add:
```yaml
resources:
  - ./{app-name}/ks.yaml
```

### 6. Expose the app via Envoy Gateway (optional)

Add an HTTPRoute inside the HelmRelease values or as a separate manifest.

**External** (goes through Cloudflare — internet accessible):
```yaml
route:
  main:
    parentRefs:
      - name: envoy-external
        namespace: network
        sectionName: https
    hostnames:
      - {app-name}.${SECRET_DOMAIN}
    annotations:
      external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"
```

**Internal only** (LAN access, bypasses Cloudflare):
```yaml
route:
  main:
    parentRefs:
      - name: envoy-internal
        namespace: network
        sectionName: https
    hostnames:
      - {app-name}.${SECRET_DOMAIN}
    annotations:
      external-dns.alpha.kubernetes.io/exclude: "true"
```

**Dual-mode** (both external and internal, same backend — use different hostnames or two separate HTTPRoute resources):
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {app-name}-external
  annotations:
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"
spec:
  parentRefs:
    - name: envoy-external
      namespace: network
      sectionName: https
  hostnames:
    - {app-name}.${SECRET_DOMAIN}
  rules:
    - backendRefs:
        - name: {app-name}
          port: {port}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {app-name}-internal
  annotations:
    external-dns.alpha.kubernetes.io/exclude: "true"
spec:
  parentRefs:
    - name: envoy-internal
      namespace: network
      sectionName: https
  hostnames:
    - {app-name}.${SECRET_DOMAIN}
  rules:
    - backendRefs:
        - name: {app-name}
          port: {port}
```

**Advanced HTTPRoute patterns** (standalone manifests, not inside app-template `route:`):

```yaml
# Path-based routing with URL rewrite
rules:
  - matches:
      - path:
          type: PathPrefix
          value: /api
    filters:
      - type: URLRewrite
        urlRewrite:
          path:
            type: ReplacePrefixMatch
            replacePrefixMatch: /
    backendRefs:
      - name: {app-name}
        port: {port}

# Header-based routing (e.g. canary by header)
rules:
  - matches:
      - headers:
          - name: X-Version
            value: beta
    backendRefs:
      - name: {app-name}-beta
        port: {port}
  - backendRefs:
      - name: {app-name}-stable
        port: {port}

# Traffic splitting (canary deployment — 10% to v2)
rules:
  - backendRefs:
      - name: {app-name}-v2
        port: {port}
        weight: 10
      - name: {app-name}-v1
        port: {port}
        weight: 90
```

**Gateway selection rules**:
- Use `envoy-external` only for services that need internet access
- Default to `envoy-internal` for everything else
- Never expose admin panels externally unless protected by Authelia
- TLS is automatic — no per-service cert config needed, wildcard certs cover `*.${SECRET_DOMAIN}` and `*.${SECRET_DOMAIN_TWO}`

### 7. Add VolSync persistence (optional)

In `ks.yaml`, add:
```yaml
spec:
  components:
    - ../../../../components/volsync
  postBuild:
    substitute:
      VOLSYNC_CAPACITY: 10Gi
      VOLSYNC_SCHEDULE: "0 3 * * *"
      VOLSYNC_UID: "568"
      VOLSYNC_GID: "568"
```

---

## Removing an Application

1. Remove the app's entry from `kubernetes/apps/{namespace}/kustomization.yaml`
2. Delete the `kubernetes/apps/{namespace}/{app-name}/` directory
3. Commit and push — Flux will prune the resources from the cluster because `prune: true` is set on the Kustomization

> **Note**: For storage-backed apps, manually delete PVCs after removal if not handled by VolSync cleanup.

---

## Networking Architecture

### IP Allocations

| Resource | IP |
|----------|----|
| Pod CIDR | 10.69.0.0/16 |
| Service CIDR | 10.96.0.0/16 |
| Control Plane VIP | 192.168.3.20 |
| K8s-Gateway (internal DNS) | 192.168.3.22 |
| Envoy External Gateway | 192.168.3.26 |
| Envoy Internal Gateway | 192.168.3.27 |
| Victoria Logs | 192.168.3.28 |
| Prometheus | 192.168.3.29 |

### CNI: Cilium

- Installed in `kube-system` namespace via HelmRelease
- L2 announcements configured via a separate Kustomization (`cilium-l2-config`)
- L2 announcements advertise LoadBalancer IPs on the LAN
- Network policies enabled
- **Known bug**: Intermittent LB service failures from stale BPF map entries — see `memory/project_cilium_l2_bug.md` for the fix procedure

### Traffic Flow (External)

```
Internet → Cloudflare (DNS + proxy) → cloudflared tunnel → envoy-external Service (192.168.3.26) → HTTPRoute → Pod
```

- `cloudflared` runs in-cluster and maintains the Cloudflare tunnel
- External-DNS watches HTTPRoutes and creates DNS records in Cloudflare automatically
- TLS is terminated at Envoy using certs from cert-manager (Let's Encrypt via DNS-01)

Cloudflared tunnel routes all traffic for `*.${SECRET_DOMAIN}` and `*.${SECRET_DOMAIN_TWO}` to `envoy-external.network.svc.cluster.local:443`. Unmatched hostnames return HTTP 404 at the tunnel level.

DNS endpoints managed by External-DNS:
- `external.${SECRET_DOMAIN}` → Cloudflare tunnel
- `external.${SECRET_DOMAIN_TWO}` → Cloudflare tunnel
- App subdomains CNAME to `external.${SECRET_DOMAIN}` (proxied through Cloudflare)

### Traffic Flow (Internal / LAN)

```
LAN client → k8s-gateway (192.168.3.22, port 53) → resolves to envoy-internal IP → Envoy → Pod
```

- k8s-gateway returns Envoy's internal LB IP for in-cluster DNS queries
- HTTPRoutes with `parentRefs: name: envoy-internal` are LAN-only

### Gateways

| Gateway | Namespace | Ports | IP |
|---------|-----------|-------|----|
| `envoy-external` | `network` | 80, 443 | 192.168.3.26 |
| `envoy-internal` | `network` | 80, 443 | 192.168.3.27 |

Wildcard TLS certs are provisioned for `*.${SECRET_DOMAIN}` and `*.${SECRET_DOMAIN_TWO}`.

### DNS

- `cert-manager` handles TLS cert issuance via Let's Encrypt DNS-01 (Cloudflare)
- `external-dns` handles automatic DNS record creation in Cloudflare
- `k8s-gateway` handles internal LAN DNS resolution

---

## Storage

| Class | Provider | Use case |
|-------|----------|----------|
| Rook-Ceph | `rook-ceph` namespace | Distributed block/object, replicated across nodes |
| OpenEBS | `openebs-system` namespace | Local PVs, node-pinned workloads |
| NFS | `csi-driver-nfs` in `kube-system` | NAS-backed volumes |
| MinIO | `kube-system` namespace | S3-compatible in-cluster object storage |

**VolSync** (`volsync-system`) provides PVC backup and replication. Apps opt in via the `components/volsync` component in their Kustomization.

---

## Databases

All in the `database` namespace:

| App | Type | Notes |
|-----|------|-------|
| `cloudnative-pg` | PostgreSQL operator | Manages HA Postgres clusters (cluster, cluster2, cluster3) |
| `dragonfly` | Redis-compatible | Used by authelia and others |
| `influxdb` | Time-series | Metrics storage |
| `clickhouse` | Columnar analytics | ClickHouse cluster |

---

## Troubleshooting Guide

### Check Flux reconciliation status

```bash
# All Kustomizations
flux get kustomizations -A

# All HelmReleases
flux get helmreleases -A

# Specific app
flux get kustomization {app-name} -n flux-system
flux get helmrelease {app-name} -n {namespace}
```

### Force reconcile after a commit

```bash
flux reconcile source git flux-system
flux reconcile kustomization cluster-apps
flux reconcile kustomization {app-name} -n flux-system
```

### Check Flux events and errors

```bash
flux events -n flux-system --for Kustomization/{app-name}
kubectl describe kustomization {app-name} -n flux-system
kubectl describe helmrelease {app-name} -n {namespace}
```

### Check pod logs

```bash
kubectl logs -n {namespace} -l app.kubernetes.io/name={app-name} --tail=100
kubectl logs -n {namespace} deploy/{app-name} --previous   # if pod crashed
```

### Check pod status and events

```bash
kubectl get pods -n {namespace}
kubectl describe pod -n {namespace} {pod-name}
```

### Networking issues

```bash
# Check if LB IP is assigned
kubectl get svc -n {namespace}

# Check Cilium L2 announcements (if LB IP not reachable)
kubectl exec -n kube-system ds/cilium -- cilium bpf lb list
kubectl exec -n kube-system ds/cilium -- cilium service list

# Cilium overall health (CLI tool)
cilium status

# Check Envoy gateway routes
kubectl get httproute -A
kubectl describe httproute {route-name} -n {namespace}
kubectl get gateway -n network
kubectl describe gateway envoy-external -n network
kubectl describe gateway envoy-internal -n network

# Envoy gateway controller logs
kubectl logs -n network -l app.kubernetes.io/name=envoy-gateway --tail=50

# Envoy proxy logs (the actual data-plane pods, not the controller)
kubectl logs -n network -l gateway.envoyproxy.io/owning-gateway-name=envoy-external --tail=50
kubectl logs -n network -l gateway.envoyproxy.io/owning-gateway-name=envoy-internal --tail=50

# Cloudflared tunnel health
kubectl get pods -n network -l app.kubernetes.io/name=cloudflared
kubectl logs -n network -l app.kubernetes.io/name=cloudflared --tail=50

# External-DNS — check if record was created
kubectl logs -n network -l app.kubernetes.io/name=external-dns --tail=50
kubectl get dnsendpoint -A

# Check Cilium pod logs (for network policy or BPF issues)
kubectl logs -n kube-system ds/cilium --tail=50
```

### Cilium L2 BPF stale entry bug (intermittent LB failures)

**Symptom**: Intermittent TCP timeouts to LoadBalancer VIPs (e.g. `curl http://192.168.3.32:3000`). Services work sometimes and fail other times depending on which node ARP resolves to.

**Root cause**: The Cilium L2 announcement reconciler fails to clean up `cilium_l2_responder_v4` BPF map entries when leases change hands. Multiple nodes accumulate the same VIP in their BPF maps, causing ARP conflicts. Reconciler logs show: `"Error(s) while full reconciling l2 responder map" ... "delete X.X.X.X@8: key does not exist"`.

**Fix procedure** (run steps in order):

```bash
# 1. Delete the policy to trigger cleanup
kubectl delete ciliuml2announcementpolicy l2-policy

# 2. Delete all L2 announce leases
kubectl get lease -n kube-system -o name | grep l2announce | xargs kubectl delete -n kube-system

# 3. Wipe BPF maps on every Cilium pod
for pod in $(kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-agent -o name | sed 's|pod/||'); do
  kubectl -n kube-system exec $pod -- bash -c '
    bpftool map dump pinned /sys/fs/bpf/tc/globals/cilium_l2_responder_v4 2>/dev/null | \
    grep "^key:" | while read _ k1 k2 k3 k4 k5 k6 k7 k8 _; do
      bpftool map delete pinned /sys/fs/bpf/tc/globals/cilium_l2_responder_v4 key hex $k1 $k2 $k3 $k4 $k5 $k6 $k7 $k8 2>&1
    done'
done

# 4. Re-apply the policy
kubectl apply -f kubernetes/apps/kube-system/cilium/config/cilium-l2.yaml

# 5. Restart Cilium
kubectl -n kube-system rollout restart daemonset/cilium

# 6. Verify recovery — lease count should match number of LB services (currently 24)
kubectl get lease -n kube-system | grep l2announce | wc -l
```

**Healthy state**: Total BPF entries across all nodes equals the number of LoadBalancer services (24). Each VIP appears in exactly one node's map. If duplicates remain after restart, manually delete stale entries using `bpftool map delete` on the affected node.

### DNS issues

```bash
# Test internal DNS via k8s-gateway
dig @192.168.3.22 {app-name}.${SECRET_DOMAIN}

# Check k8s-gateway logs
kubectl logs -n network deploy/k8s-gateway

# Check external-dns
kubectl logs -n network deploy/external-dns
```

### Certificate issues

```bash
kubectl get certificate -A
kubectl describe certificate -n {namespace} {cert-name}
kubectl get certificaterequest -A
kubectl logs -n cert-manager deploy/cert-manager
```

### SOPS / secret issues

```bash
# Verify a secret is decrypted correctly in-cluster
kubectl get secret cluster-secrets -n flux-system -o yaml

# Check if Flux can decrypt (look at Kustomization status)
flux get kustomization cluster-apps -n flux-system
```

### Storage / PVC issues

```bash
kubectl get pvc -n {namespace}
kubectl describe pvc -n {namespace} {pvc-name}

# Rook-Ceph health
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health detail

# VolSync backup status
kubectl get replicationsource -A
kubectl get replicationdestination -A
```

### kubectl plugins and CLI tools (no pod exec required)

```bash
# CloudNative-PG: cluster status (replace postgres16vector with the cluster name)
kubectl cnpg -n database status postgres16vector

# Rook-Ceph: cluster and OSD status
kubectl rook-ceph ceph status
kubectl rook-ceph ceph osd status
kubectl rook-ceph ceph osd tree

# Browse PVC contents interactively
kubectl browse-pvc {pvc-name} -n {namespace}

# Cilium CNI health
cilium status
```

### Validating changes locally with flux-local

`flux-local` lets you validate and diff Flux manifests **without a live cluster**. Run this before committing to catch errors early.

```bash
# List all Kustomizations Flux manages
flux-local get ks --path ./kubernetes/flux/cluster

# List all HelmReleases (all namespaces, or filtered)
flux-local get hr -A --path ./kubernetes/flux/cluster
flux-local get hr -n media --path ./kubernetes/flux/cluster

# Build and render all manifests (what Flux would actually apply)
flux-local build ks --path ./kubernetes/flux/cluster

# Validate all Kustomizations build without errors
flux-local test --path ./kubernetes/flux/cluster -v

# Also validate HelmRelease rendering via helm template
flux-local test --path ./kubernetes/flux/cluster --enable-helm -v

# Diff local changes against last commit (review before pushing)
flux-local diff ks --path ./kubernetes/flux/cluster -A
```

> Run `flux-local test` after making changes to any Kustomization or HelmRelease to catch YAML errors before they hit the cluster.

### Helm values debugging

```bash
# See what values are actually applied
helm get values {release-name} -n {namespace}

# Full manifest
helm get manifest {release-name} -n {namespace}
```

### Querying logs (Victoria Logs)

Victoria Logs has a dedicated LoadBalancer IP at `192.168.3.28:9428` (HTTP). Use it directly — no TLS, no hostname needed.

Use [LogsQL](https://docs.victoriametrics.com/victorialogs/logsql/) syntax. The `app` label matches the Kubernetes app label on the pod.

> **Important**: Victoria Logs aggregates logs across all pod instances and retains them beyond pod lifetime. For crash loops, OOMKills, or evicted pods, `kubectl logs --previous` only shows the immediately prior instance. Victoria Logs is the only way to see logs across multiple restarts or from pods that no longer exist.

```bash
# Recent logs for an app (last 5 minutes)
curl -G 'http://192.168.3.28:9428/select/logsql/query' \
  --data-urlencode 'query={app="{app-label}"} _time:5m'

# Total log count (last 5 minutes)
curl -G 'http://192.168.3.28:9428/select/logsql/query' \
  --data-urlencode 'query={app="{app-label}"} _time:5m | stats count() as logs'

# Error count (last hour)
curl -G 'http://192.168.3.28:9428/select/logsql/query' \
  --data-urlencode 'query={app="{app-label}"} error _time:1h | stats count() as error_logs'

# Filter by keyword and time window
curl -G 'http://192.168.3.28:9428/select/logsql/query' \
  --data-urlencode 'query={app="{app-label}"} "panic" _time:30m'

# Logs by namespace
curl -G 'http://192.168.3.28:9428/select/logsql/query' \
  --data-urlencode 'query={namespace="{namespace}"} _time:10m'
```

**Tips**:
- Add `| stats count() as n` to count instead of stream raw lines
- Combine filters: `{app="foo"} error _time:1h` means app=foo AND contains "error" AND last hour
- Use `_time:5m`, `_time:1h`, `_time:24h` for relative time windows

### Querying metrics (Prometheus)

Prometheus has a dedicated LoadBalancer IP at `192.168.3.29:9090` (HTTP). Use it directly.

Use standard PromQL. For range queries use `/api/v1/query_range` with `start=`, `end=`, and `step=` params.

```bash
# CPU usage by pod (5-minute rate)
curl -G 'http://192.168.3.29:9090/api/v1/query' \
  --data-urlencode 'query=sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="{namespace}",pod=~"{app-prefix}-.*",container!="POD",container!=""}[5m]))'

# Memory working set by pod
curl -G 'http://192.168.3.29:9090/api/v1/query' \
  --data-urlencode 'query=sum by (pod) (container_memory_working_set_bytes{namespace="{namespace}",pod=~"{app-prefix}-.*",container!="POD",container!=""})'

# Pod restart count
curl -G 'http://192.168.3.29:9090/api/v1/query' \
  --data-urlencode 'query=kube_pod_container_status_restarts_total{namespace="{namespace}"}'

# HTTP request rate (if app exposes http_requests_total)
curl -G 'http://192.168.3.29:9090/api/v1/query' \
  --data-urlencode 'query=sum by (pod) (rate(http_requests_total{namespace="{namespace}"}[5m]))'

# Check if a target is up
curl -G 'http://192.168.3.29:9090/api/v1/query' \
  --data-urlencode 'query=up{namespace="{namespace}"}'

# Node CPU usage
curl -G 'http://192.168.3.29:9090/api/v1/query' \
  --data-urlencode 'query=100 - (avg by (node) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'

# Node memory available
curl -G 'http://192.168.3.29:9090/api/v1/query' \
  --data-urlencode 'query=node_memory_MemAvailable_bytes'
```

**Tips**:
- Always filter by `namespace=` to scope queries
- Use `pod=~"prefix-.*"` for regex pod matching
- Exclude pause containers: `container!="POD",container!=""`
- Wrap in `sum by (pod) (...)` to aggregate per pod
- Parse the response: results are in `.data.result[].value[1]` (instant) or `.data.result[].values[]` (range)

---

## Key Files Quick Reference

| File | Purpose |
|------|---------|
| `kubernetes/flux/cluster/ks.yaml` | Root Flux Kustomizations — entry point for everything |
| `kubernetes/apps/{ns}/kustomization.yaml` | Namespace aggregator — add new apps here |
| `kubernetes/apps/{ns}/{app}/ks.yaml` | Per-app Flux Kustomization |
| `kubernetes/apps/{ns}/{app}/app/helmrelease.yaml` | App deployment config |
| `kubernetes/components/sops/cluster-secrets.sops.yaml` | All global encrypted secrets |
| `kubernetes/flux/repositories/` | Helm, OCI, Git source definitions |
| `kubernetes/components/volsync/` | Reusable VolSync backup templates |
| `config.yaml` | Bootstrap config (domains, IPs, node list) |
| `.sops.yaml` | SOPS Age encryption config |
| `kubernetes/bootstrap/talos/talconfig.yaml` | Talos cluster and node config |

---

## Common Patterns to Know

- **Most apps** use the `app-template` OCI chart from bjw-s (`ghcr.io/bjw-s-labs/helm/app-template`)
- **YAML anchors** (`&app`, `*app`) are used extensively to avoid repeating the app name
- **`postBuild.substituteFrom`** pulls from `cluster-secrets` — use `${SECRET_VAR}` syntax anywhere in manifests
- **`prune: true`** on Kustomizations means removing a resource from the repo deletes it from the cluster
- **`wait: false`** is the default for apps; `wait: true` only for system-critical infra (cilium, envoy-gateway)
- **Dependencies** (`dependsOn`) are declared in `ks.yaml` when one app needs another to be healthy first
- **Multi-environment apps** (sensei) have separate Kustomizations per env (`sensei-dev`, `sensei-stage`, `sensei-prod`) in the same namespace
