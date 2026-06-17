# OpenReplay (self-hosted, Community Edition)

Self-hosted [OpenReplay](https://openreplay.com/) v1.27 session-replay platform running in the `sensei` namespace. Records front-end sessions stores them in MinIO, and serves replays + product analytics through the OpenReplay frontend.

> **This deployment does NOT use Kafka.** Upstream OpenReplay ships Kafka, but the CE > backend works entirely on **Redis Streams** (backed by Dragonfly). The Kafka StatefulSet > was removed. The `TOPIC_*` env vars are **Redis stream names**, not Kafka topics.

---

## At a glance

| Property | Value |
|----------|-------|
| Namespace | `sensei` |
| Chart | `app-template` (bjw-s OCI) — each OpenReplay service is a controller |
| Public URL | `https://openreplay.${SECRET_DOMAIN_TWO}` (external, Cloudflare-proxied) |
| Ingest point | `https://openreplay.${SECRET_DOMAIN_TWO}/ingest` |
| Message bus | Redis Streams on Dragonfly (`dragonfly.database.svc.cluster.local:6379/10`) |
| Metadata DB | Postgres (`postgres16-rw`, db `openreplay`) |
| Analytics DB | ClickHouse (`clickhouse.database.svc.cluster.local`, db `openreplay`) |
| Object storage | MinIO (`minio.kube-system.svc.cluster.local:9000`) |
| Shared scratch FS | Ceph RWX PVC `openreplay-shared` mounted at `/mnt/efs` (50Gi) |

`ks.yaml` declares `dependsOn`: `cloudnative-pg-cluster`, `dragonfly`, `clickhouse`, `minio`.

### Files in this directory

| File | Purpose |
|------|---------|
| `helmrelease.yaml` | All service definitions (one controller per service) + env config |
| `httproute.yaml` | Envoy Gateway routing — path-based fan-out to each service + MinIO buckets |
| `kustomization.yaml` | Kustomize resource list |
| `openreplay.sops.yaml` | `openreplay-secrets` Secret (JWT/assist/token secrets), SOPS-encrypted |
| `pvc.yaml` | `openreplay-shared` Ceph RWX PVC (`/mnt/efs`) |
| `service-minio.yaml` | Placeholder ConfigMap (the old ExternalName svc was replaced by a cross-ns backendRef) |
| `service-health.yaml` | Gatus health checks |

---

## Architecture / data flow

```
Browser (tracker 18.0.6)
   │  POST /ingest/...           POST /ingest/v1/web/images (canvas)
   ▼                                   │
http (ingest) ──► raw ─────────────────┼──────────────► sink ──► /mnt/efs/{sid}e ──► storage ──► MinIO mobs/{sid}/dom.mobe
   │             raw-assets ──► assets ─┘ (rewrites URLs, downloads CSS/JS)        │
   │                              └────► MinIO sessions-assets/{hashed-url}        └► trigger ──► storage (session-end)
   │             cache ──────────► assets (download queue)
   │
   └─ canvas images ──► canvases ──► MinIO mobs/{sid}/{ts}_{nodeId}.webp.frames.zst

ender (idle→session-end)   heuristics (issues)   db (writes metadata → Postgres/ClickHouse)
```

Replay read path: **frontend** SPA → **api** (Go v2) / **chalice** (Python legacy) →
presigned MinIO URLs → browser fetches `dom.mobs`/`dom.mobe`, `sessions-assets/*`, canvas frames.

---

## Services

Each service is an `app-template` controller in `helmrelease.yaml`. Shared env comes from the
`&sharedEnv` / `&fullEnv` YAML anchors (`*fullEnv` adds JWT/assist secrets from `openreplay-secrets`).

### Ingest & processing pipeline

| Service | Image tag | Role | Key config |
|---------|-----------|------|------------|
| **http** | `v1.27.1` | HTTP ingest endpoint. Receives tracker batches, routes DOM→`raw`, asset batches→`raw-assets`, canvas images→`canvases`. | `RECORD_CANVAS=true`, `CANVAS_QUALITY=low`, `CANVAS_FPS=1`, `BUCKET_NAME=uxtesting-records` |
| **sink** | `v1.27.0` | Consumes `raw`/`raw-ios`, writes session DOM batches to `/mnt/efs/{sid}e`. Rewrites in-`raw` asset URLs → `sessions-assets` and queues downloads on `cache`. | `ASSETS_ORIGIN`, `S3_BUCKET_ASSETS=sessions-assets`, `CACHE_THRESHOLD=1`, `fsGroup: 1000` |
| **assets** | `v1.27.1` | Consumes **`cache` AND `raw-assets`**, fetches CSS/JS, stores to `sessions-assets`. Re-emits rewritten asset batches to `raw`. | `BUCKET_NAME=sessions-assets`, `TOPIC_RAW_ASSETS=raw-assets`, `DEBUG=true` ⚠️ see CSS note |
| **canvases** | `v1.27.0` | Receives `<canvas>` frame uploads (`/v1/web/images`), stores `.webp.frames.zst` in `mobs`. | `BUCKET_NAME=mobs`, `fsGroup: 1000` |
| **images** | `v1.27.0` | Mobile screenshot ingestion. | `BUCKET_NAME=mobs` |
| **storage** | `v1.27.0` | Consumes `trigger` (session-end), compresses `/mnt/efs` files (zstd) → MinIO `mobs/{sid}/`. | `BUCKET_NAME=mobs`, `FS_CLEAN_HRS=24`, `fsGroup: 1000` |
| **ender** | `v1.27.0` | Detects idle sessions and emits session-end. | `*sharedEnv` |
| **heuristics** | `v1.27.0` | Derives issues/events (rage clicks, dead clicks, etc.). | `*sharedEnv` |
| **db** | `v1.27.0` | Persists session metadata/events to Postgres + ClickHouse. | `ch_db=openreplay` |

### API & web

| Service | Image tag | Role | Key config |
|---------|-----------|------|------------|
| **frontend** | `v1.27.11` | React SPA (UI + player). Tracker JS served from `https://static.openreplay.com`. | `TRACKER_HOST`, `HTTP_PORT=8080` |
| **api** | `v1.27.4` | Go v2 API (`/v2/api`). Generates presigned MinIO URLs. | `BUCKET_NAME=mobs`, `AWS_ENDPOINT=https://openreplay.${SECRET_DOMAIN_TWO}` (public host so presigns resolve in the browser) |
| **chalice** | `v1.27.10` | Legacy Python API (`/api`). Dashboards, analytics, auth. | ClickHouse DSN w/ creds, `S3_HOST`/`SITE_URL`=public host, `js_cache_bucket=sessions-assets` |
| **integrations** | `v1.27.0` | Webhook/issue-tracker receivers. | `BUCKET_NAME=mobs` |
| **assist** | `v1.120.0`* | WebSocket live co-browsing (`/assist`, `/ws-assist`, port 9001). | `REDIS_URL`, `CLEAR_SOCKET_TIME=720` |
| **spot** | `v1.27.0` | Spot (browser-extension UX recordings). | `BUCKET_NAME=spots`, `CACHE_ASSETS=true` |
| **sourcemapreader** | `v1.27.0` | Resolves JS stack traces against uploaded sourcemaps (port 9000). | `S3_HOST` (internal MinIO), `sourcemaps` bucket |
| **alerts** | `v1.27.2` | Evaluates metric alerts, sends notification emails. | `SITE_URL`, SMTP (`EMAIL_*` blank = disabled) |

> *`assist` is intentionally on `v1.120.0` (its own version line). **Do not copy this tag to other > services** — see the CSS troubleshooting note about how a mismatched `assets` tag broke replays.

### Why `AWS_ENDPOINT` differs per service

- **Internal** (`http://minio.kube-system.svc.cluster.local:9000`) — used by services that read/write MinIO server-side (sink, storage, assets, canvases…).
- **Public** (`https://openreplay.${SECRET_DOMAIN_TWO}`) — used by **api**/**chalice** so the   presigned URLs they hand to the browser point at a hostname the browser can resolve. AWS Sig V4
  validates the `Host` header, which matches because the HTTPRoute forwards `/mobs/`, `/spots/`,   etc. straight to MinIO without rewriting the path.

---

## MinIO buckets

| Bucket | Contents | Served how |
|--------|----------|------------|
| `mobs` | Session files: `dom.mobs` (initial snapshot), `dom.mobe` (events), `devtools.mob`, canvas `*.webp.frames.zst` | Presigned URLs (private) |
| `sessions-assets` | Cached cross-origin CSS/JS/fonts (`{hashed-url}` keys) | **Public** path `/sessions-assets/` |
| `records` | Assist recordings | Presigned |
| `spots` | Spot recordings | Presigned |
| `sourcemaps` | Uploaded JS sourcemaps | Internal |
| `uxtesting-records` | UX-testing records | — |

Routing for all of these is in `httproute.yaml`. MinIO lives in `kube-system`; the cross-namespace `backendRef` is allowed by a ReferenceGrant in `kubernetes/apps/kube-system/minio/app/referencegrant.yaml`.

---

## Tracker setup (client side)

```html
<script>
  var initOpts = {
    projectKey: "ISm4TegjKP2MVqMK1lp1",
    ingestPoint: "https://openreplay.domain.com/ingest",
    inlineCss: 3,            // fetch same-origin CSS and inline it as <style> text
    obscureTextNumbers: false,
    obscureTextEmails: false,
  };
  // tracker bundle:
  // //static.openreplay.com/18.0.6/openreplay.js   (18.0.6 == correct for backend v1.27)
</script>
```

- **Tracker version must match the backend.** `18.0.6` is the tracker that ships in the v1.27.0 source tree. Do not bump it independently.
- `inlineCss: 3` inlines **same-origin** stylesheets directly into the recording (bypasses the asset pipeline). **Cross-origin** stylesheets (CDNs, Google Fonts) still go through the `assets` service → `sessions-assets`.
- Canvas (`<canvas>`, WebGL, Chart.js, etc.) is recorded by default in tracker 18.x and requires `RECORD_CANVAS=true` on the **http** service (already set).

---

## Operations

### Commit changes (GitOps)

```bash
task flux:commit -- "fix(openreplay): <message>"   # pull, commit, push, reconcile
```

### Reconcile / inspect

```bash
flux reconcile kustomization openreplay -n flux-system --with-source
flux reconcile helmrelease openreplay -n sensei      # force re-template after image/env change
kubectl get pods -n sensei | grep openreplay
```

### Logs & metrics

```bash
# Per-service logs
kubectl logs -n sensei deploy/openreplay-<service> --tail=100

# Across restarts / dead pods (Victoria Logs)
curl -G 'http://192.168.3.28:9428/select/logsql/query' \
  --data-urlencode 'query={namespace="sensei"} "openreplay-assets" error _time:30m | stats count() as n'

# Enable verbose logging on a Go service: set DEBUG=true in its env (NOT LOG_LEVEL).
```

### Inspect the Redis Streams pipeline

```bash
# dragonfly-1 is the master (the `dragonfly` Service routes only to role=master)
kubectl exec -n database dragonfly-1 -- redis-cli -n 10 XLEN raw
kubectl exec -n database dragonfly-1 -- redis-cli -n 10 XINFO GROUPS raw-assets   # check consumer lag
kubectl exec -n database dragonfly-1 -- redis-cli -n 10 XINFO GROUPS cache
```

Streams: `raw` (DOM), `raw-assets` (asset batches), `cache` (download queue), `trigger`
(session-end), `raw-ios`, `raw-images`, `canvas-images`, `canvas-trigger`, `analytics`.

### Inspect MinIO (no `mc` in the image — use boto3 via chalice)

```bash
kubectl exec -n sensei deploy/openreplay-chalice -- python3 -c "
import boto3, os
s3 = boto3.client('s3', endpoint_url='http://minio.kube-system.svc.cluster.local:9000',
  aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'], aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY'])
r = s3.list_objects_v2(Bucket='mobs', Prefix='<sessionID>')
for o in r.get('Contents', []): print(o['Key'], o['Size'])
"
```

---

## Troubleshooting

### 🎨 CSS / JS not rendering in session replays

OpenReplay replays **recorded DOM**, it does **not** re-execute your JavaScript. Styling and visuals come from three independent mechanisms — diagnose by which one is failing.

#### 1. Site-wide unstyled replays (cross-origin CSS missing) — **FIXED, watch for regressions**

**Symptom:** Replays render structurally but most styling (especially CDN CSS, Google Fonts) is missing; `sessions-assets` bucket is empty; `raw-assets` Redis stream has growing consumer lag.

**Root cause (historical):** the `assets` image was pinned to **`v1.120.0`**, a stale build that only consumed the `cache` stream and **ignored `raw-assets`**, so cross-origin `<link href>` stylesheets were never fetched. The correct `assets` tag for this stack is **`v1.27.1`** (its source consumes both `cache` and `raw-assets`). The ECR repo `p1t3u8a3/assets` has no `v1.120.0`.

**Verify healthy:**
```bash
kubectl exec -n database dragonfly-1 -- redis-cli -n 10 XINFO GROUPS raw-assets   # cache group lag → 0
# sessions-assets should populate with cdn/font keys:
kubectl exec -n sensei deploy/openreplay-chalice -- python3 -c "import boto3,os;\
s3=boto3.client('s3',endpoint_url='http://minio.kube-system.svc.cluster.local:9000',\
aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'],aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY']);\
print(s3.list_objects_v2(Bucket='sessions-assets').get('KeyCount'))"
```

#### 2. `<canvas>` content blank (Chart.js charts, WebGL, canvas chessboards)

**Symptom:** A specific canvas-rendered widget is blank in replay even though the rest of the page is styled. **The CDN/library source is irrelevant** — OpenReplay never runs the script; it captures canvas *pixels*.

**Requires (all already set):** tracker 18.x (captures canvas by default) + `RECORD_CANVAS=true`, `CANVAS_FPS`, `CANVAS_QUALITY` on **http** + the **canvases** service running.

**Verify capture is flowing:**
```bash
kubectl exec -n database dragonfly-1 -- redis-cli -n 10 XLEN canvas-images   # >0 = capturing
kubectl logs -n sensei deploy/openreplay-canvases --tail=20                  # "response ok" /v1/web/images
# Frames land in mobs as {ts}_{nodeId}.webp.frames.zst
```
If frames exist in `mobs` but the canvas is still blank in replay, check the **browser Network tab**
during playback for failed `.webp.frames.zst` fetches from `/mobs/` (presigned-URL / host issue).
Note: capture is `CANVAS_FPS=1`, so a chart that renders and is navigated away from within ~1s may
miss its frame.

#### 3. Layout collapses / element stacks vertically (JS-driven sizing)

**Symptom:** A widget whose dimensions are computed by runtime JS (e.g. a board that measures its container or uses `ResizeObserver`) collapses in replay because that JS doesn't run. Fix on the **site side** by giving the element real CSS dimensions rather than JS-measured ones. Not solvable via cluster config.

#### Browser-side data to collect for any replay rendering bug

- **Elements:** inspect the broken node in the replay iframe — is it `<canvas>`, `<svg>`, or `<div>`? Shadow DOM?
- **Network:** `404/403` on `/sessions-assets/*` (asset pipeline) or `/mobs/*.webp.frames.zst` (canvas)?
- **Console:** decode / CORS / CSP errors during playback.

### General health

```bash
flux get helmrelease openreplay -n sensei
kubectl describe helmrelease openreplay -n sensei
```

- **`NOGROUP` / `connection refused` in a consumer (esp. `assets`)** — usually a **transient   Dragonfly master failover**. The `assets` service is the only consumer of the normally-empty
  `cache` stream, so it surfaces failovers as a restart. Self-heals once the master settles; only
  investigate if it crash-loops continuously.
- **Pod can't write `/mnt/efs`** — services that write the shared FS (sink, storage, canvases,
  images) set `pod.securityContext.fsGroup: 1000`. The PVC is Ceph RWX `openreplay-shared`.

---

## Notes & gotchas

- `_sharedEnv` / `_fullEnv` top-level keys are **YAML anchors only**; `app-template` ignores them.
- `TOPIC_RAW_ASSETS` (and other `TOPIC_*`) are **required** env vars even without Kafka — they name Redis streams. Removing them crashes the service.
- `CACHE_ASSETS` is meaningful on `sink`/`spot`/`assets` but is a **no-op on the `http` service**   (its config struct has no such field) — don't set it there expecting an effect.
- `DEBUG=true` on `assets` is verbose; drop it once the asset pipeline is confirmed healthy.
- Removing a service: delete its `controllers:` + `service:` block, commit; Flux prunes it.
- See `kubernetes/.../memory` note `project_openreplay_assets_image` for the full CSS post-mortem.
```
