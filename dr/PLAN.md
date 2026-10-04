# senseichess.com — AWS Disaster Recovery Plan

Status: deployed 2026-10-04 (AWS account 676206913924, us-east-1); drill passed the same day.
Operations: [RUNBOOK.md](RUNBOOK.md).

## 1. Goal

When the home cluster loses its internet connection (or dies), senseichess.com should come back
up in AWS automatically, from the backups that already ship to S3, and stay there until a human
deliberately fails back. Nothing in AWS should cost meaningful money while home is healthy.

| Target | Value |
|---|---|
| Detection | ~8 min (5 min heartbeat timeout + 3 failed public probes) |
| RTO (site serving from AWS) | ~70 min measured (4 min bootstrap, 59 min Postgres restore + WAL replay, 3 min apps); see §6 to shorten |
| RPO (Postgres) | Last archived WAL segment before the outage (continuous archiving, typically < 5 min) |
| RPO (ClickHouse) | Last clickhouse-backup increment (2 h dittofeed, 4 h langfuse/rybbit) |
| Idle cost | ≈ $1–2/month (Lambda every minute, DynamoDB on-demand, Secrets Manager) — no EC2/EBS while idle |
| Active cost | ≈ $0.40/h (m7i.2xlarge) + EBS |

## 2. Scope (what runs in AWS)

| Tier | Services | DR behaviour |
|---|---|---|
| 1 | sensei-prod app, api, admin, worker (+ CronJobs), litellm, Postgres `postgres16vector` | Restored and served |
| 2 | langfuse-v3 (+ dragonfly, ClickHouse `clickhouse`), rybbit (+ `rybbit-clickhouse`) | Restored; ClickHouse restored in background |
| 3 | dittofeed (+ temporal, `dittofeed-clickhouse`) | Restored; running in failover, **off** in drills |

Not in DR: sensei-dev/stage, openreplay, n8n, grafana, home services. LiteLLM's own DB (`postgres16`,
backed up only to in-cluster MinIO) is recreated empty in DR — it only holds spend logs/UI state;
the master key comes from secrets. Langfuse/LiteLLM UI SSO (Authelia at home) is unavailable in DR;
their APIs work.

## 3. Architecture

```
                 ┌──────────── home (Talos) ────────────┐
                 │ dr-guard CronJob (every 1 min)        │
                 │  • heartbeat → DynamoDB sensei-dr     │
                 │  • reads DR state; if ACTIVE → fence  │
                 │    home sensei-prod (suspend+scale 0) │
                 └───────────────┬──────────────────────┘
                                 │ HTTPS (IAM user sensei-dr-home)
 ┌────────────────────────── AWS 676206913924 / us-east-1 ──────────────────────────┐
 │ DynamoDB sensei-dr  ◄── orchestrator Lambda (EventBridge, every 1 min) ──► SNS    │
 │   home / dr / instance items      │ probes https://senseichess.com/health          │
 │                                   │ scales ASG, switches Cloudflare DNS            │
 │                                   ▼                                                │
 │ ASG sensei-dr (0..1) → EC2 m7i.2xlarge, AL2023, no inbound ports                  │
 │   user-data: k3s → Flux (public GitHub repo, kubernetes/dr/aws) → SOPS (DR age key)│
 │   CNPG restores postgres16vector from s3://sensei-cnpg (home serverName)           │
 │   clickhouse-backup restore_remote ×3 from existing S3 backups                    │
 │   cloudflared (DR tunnel "sensei-dr") → services                                   │
 │   dr-agent (systemd timer): applies desired mode, reports readiness               │
 └────────────────────────────────────────────────────────────────────────────────────┘
                                 │
                       Cloudflare (proxied DNS)
   senseichess.com, www, admin, dittofeed, langfuse, rybbit, litellm
     normal:   → external.<domain> / external.bigwang.org → home tunnel
     failover: → <dr-tunnel-id>.cfargotunnel.com
```

### 3.1 State machine (DynamoDB item `dr`)

| State | Meaning | Exits |
|---|---|---|
| `STANDBY` | ASG at 0, nothing running. `armed` once the first home heartbeat arrives. | → `FAILOVER` (auto/manual), → `DRILL` (manual) |
| `DRILL` | Instance up with side effects off; served only on `dr-drill.senseichess.com`. | → `STANDBY` (drill stop), → `FAILOVER` (real outage during drill: mode is switched in place) |
| `FAILOVER` | Instance coming up in failover mode; DNS still on home. Aborts back to `STANDBY` if home heartbeat returns before DNS switch. | → `ACTIVE` when the instance reports ready |
| `ACTIVE` | DNS points at DR. Home is fenced by dr-guard as soon as it reconnects. **Never leaves automatically.** | → `FAILBACK` (manual) |
| `FAILBACK` | DNS restored to home; DR still running (read-only safety net). | → `STANDBY` (manual `complete`) |

Trigger rule (in `STANDBY`/`DRILL`, `armed=true`): home heartbeat older than 5 min **and** the
public probe failed on 3 consecutive runs. The probe guard means a broken heartbeat job alone can
never cause a failover.

### 3.2 Split-brain protections

1. **DNS ownership:** external-dns (policy `sync`, owner `default`) owns admin/dittofeed/langfuse/
   rybbit/litellm. On failover the orchestrator rewrites those records *and* their `k8s.*` TXT
   ownership records to owner `sensei-dr`, so home external-dns treats them as foreign and does not
   revert them when it reconnects. Apex and `www` are not external-dns managed.
2. **Home fencing:** dr-guard sees `ACTIVE`/`FAILBACK` and suspends the sensei-prod/dittofeed Flux
   Kustomizations + HelmReleases, scales their Deployments to 0 and suspends CronJobs. It only
   unfences after `drctl failback complete` sets `unfenceApproved`.
3. **Backups:** DR Postgres writes WAL/base backups to a *new* serverName
   (`postgres16vector-dr-<run>`); the instance role can only `PutObject` under `postgres16vector-dr-*`.
   DR ClickHouse sidecars run `clickhouse-backup server` (no `watch`), so they never create or prune
   home backups.
4. **Drill isolation:** drills run worker=0, CronJobs suspended, dittofeed/temporal=0 and only add a
   `dr-drill` hostname — production DNS is untouched.

### 3.3 Secrets

- New **DR age key**; private half only in Secrets Manager `sensei-dr/age-key`.
- `.sops.yaml` encrypts only the files DR needs to *both* the home and DR keys:
  `kubernetes/dr/**` and the sops files of the DR app directories. Talos secrets and the full
  `cluster-secrets` stay home-key only.
- `kubernetes/dr/aws/secrets/cluster-secrets.sops.yaml` is a *subset* of cluster-secrets (only the
  `SECRET_*` vars DR manifests reference), generated by `dr/bin/build-dr-secrets.sh`.
- Cloudflare API token + DR tunnel token: Secrets Manager `sensei-dr/cloudflare` (used by Lambda and
  the instance, never in git).
- Home heartbeat credentials: IAM user `sensei-dr-home` (DynamoDB only, item-scoped), access key
  stored in Secrets Manager by CDK and SOPS-encrypted into the home dr-guard secret.

## 4. Components

| Path | What |
|---|---|
| `dr/cdk/` | CDK app (TypeScript): VPC, ASG/launch template, IAM, DynamoDB, Lambda, SNS, secrets |
| `dr/cdk/lambda/orchestrator/` | Orchestrator (Python): state machine, probe, Cloudflare DNS switch |
| `dr/cdk/assets/instance/` | Instance bootstrap + `dr-agent` (shipped as an S3 asset) |
| `kubernetes/dr/aws/` | Flux tree the DR cluster syncs (never referenced by home `cluster-apps`) |
| `kubernetes/apps/sensei/dr-guard/` | Home heartbeat + fencing CronJob |
| `dr/bin/drctl` | Operator CLI (status, drill, failover, failback, arm/disarm) |
| `dr/bin/build-dr-secrets.sh` | Regenerates the DR secret subset |
| `dr/bin/setup-secrets.sh` | Stores the Cloudflare token + DR tunnel token and the DR age key in Secrets Manager |
| `dr/bin/validate-dr-tree.py` | Offline build/validation of `kubernetes/dr/aws` for every mode |

DR Flux reuses the *home* app directories (sensei-prod, langfuse, dittofeed, rybbit, litellm,
cloudnative-pg operator, dragonfly, clickhouse) through its own Flux Kustomizations, with small
patches: replicas, sidecar `watch`→`server`, drop VolSync/openebs dependencies. StorageClass
`openebs-hostpath` exists in DR as an alias for k3s local-path, so PVC manifests apply unchanged.
DR therefore tracks home automatically when images/configs change on `main`.

## 5. Delivery steps

1. Plan + runbook (this file, RUNBOOK.md).
2. SOPS: generate DR age key, update `.sops.yaml`, `sops updatekeys` the DR-needed files, build DR
   secret subset.
3. DR Flux tree `kubernetes/dr/aws` (+ local `kustomize build` validation).
4. CDK stack + orchestrator Lambda + instance bootstrap/agent; unit-test orchestrator decisions.
5. Cloudflare DR tunnel + secrets into Secrets Manager.
6. `cdk deploy` to account 676206913924.
7. Home dr-guard (Flux app) with SOPS-encrypted IAM credentials; `flux-local test`.
8. **Drill**: start a drill, verify restore + app on `dr-drill.senseichess.com`, stop drill.
9. Merge to `main` so the home cluster picks up dr-guard when its internet returns; the first
   heartbeat arms the system.

## 6. Known limitations / follow-ups

- **Measured in the 2026-10-04 drill:** instance boot → k3s → Flux → apps applied in ~4 min;
  ClickHouse restores 3–10 min (rybbit 11 GB, dittofeed 40 GB, langfuse 53 GB); Postgres is the
  long pole: the 21 GB **bzip2** base backup extracts single-threaded at ~20 MB/s (~45 min for 59 GB)
  before WAL replay starts (up to 24 h of WAL, ~20 GB on 2026-10-03). Recommended follow-ups, in
  order of effort:
  1. Home `cluster16vector.yaml`: `data.compression: snappy` (+ `jobs: 4`) and
     `wal.compression: snappy` — 5–10× faster restore for a modest S3 size increase.
  2. Two base backups a day (`awsbackup.yaml` schedule) to halve WAL replay.
  3. Warm standby: a small always-on instance running a CNPG replica cluster from the S3 archive
     (≈ $30–60/month) → RTO of minutes.
- Failback of Postgres is a full physical restore of home `postgres16vector` from the DR serverName
  (CNPG serverName bump, the procedure already used in this repo). Writes made at home to *other*
  databases on that cluster during the DR window are lost; take a logical dump first (runbook).
- ClickHouse writes made in DR are only carried home if you run the optional ClickHouse failback
  step; otherwise analytics for the DR window stay in AWS until teardown.
- DR secret subset must be regenerated when a sensei `SECRET_*` value changes
  (`dr/bin/build-dr-secrets.sh`).
