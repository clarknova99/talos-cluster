# senseichess.com DR Runbook

Design and rationale: [PLAN.md](PLAN.md). All commands run from the repo root on a machine with the
`mike-sensei` AWS profile, `kubectl` access to home (for home steps) and the home `age.key`.

```bash
export AWS_PROFILE=mike-sensei AWS_REGION=us-east-1
dr/bin/drctl status
```

`drctl status` shows: state, armed flag, last home heartbeat, probe failures, instance state/mode/
readiness, DR serverName, and current DNS targets.

---

## 0. What happens automatically

1. Home internet drops → heartbeats stop.
2. After 5 min without a heartbeat **and** 3 consecutive failed probes of
   `https://senseichess.com/health`, the orchestrator moves `STANDBY → FAILOVER`, scales the
   `sensei-dr` ASG to 1 and emails michael@senseichess.com.
3. The instance installs k3s + Flux, restores Postgres from S3, restores ClickHouse, starts the apps
   and the DR cloudflared tunnel, then reports ready (≈70 min; most of it is the Postgres restore).
4. Orchestrator snapshots the Cloudflare records, points them at the DR tunnel, takes external-dns
   ownership, sets `ACTIVE`, emails you.
5. When home reconnects, its `dr-guard` CronJob sees `ACTIVE` and fences home sensei-prod. The site
   **stays on AWS** until you fail back.

If home comes back while still in `FAILOVER` (before DNS switched), the orchestrator aborts: ASG → 0,
state → `STANDBY`.

### Observed failover timeline (manual failover 2026-10-05, ~59 GB Postgres)

| Phase | Observed | Notes |
|---|---|---|
| Detection (automatic only) | ~8 min (by design, not yet observed) | 5 min heartbeat timeout + 3 failed probes, 1 per minute |
| `drctl failover` → instance booted, k3s + Flux installed | ~2–3 min | 00:13:53 → restoring at 00:16 UTC |
| ClickHouse restores (in parallel, not on the critical path) | rybbit 3 min 26 s, dittofeed 4 min 39 s, langfuse 7 min 17 s | done ~00:24 |
| Postgres base backup extract (21 GB bzip2 → 59 GB) | ~45 min | single-threaded bzip2, ~20 MB/s |
| Postgres WAL replay (~1 day of WAL, ~20 GB) | ~13 min | ~64 segments/min |
| Apps start → DR ready → DNS switched (`ACTIVE`) | ~3–4 min | ACTIVE at 01:21:38 |
| **Total, trigger → site live on AWS** | **67 min 45 s** | plus ~8 min detection when automatic |

### Observed drill with snappy backups (2026-10-05 16:03, after home switched to snappy)

| Phase | Observed |
|---|---|
| `drctl drill start` → k3s + Flux installed | ~2 min (16:03:00 → 16:04:41) |
| All 23 Flux Kustomizations applied | 16:08:16 (+5 min) |
| ClickHouse restores | rybbit 16:10, dittofeed 16:12, langfuse 16:16 |
| Postgres restored from `postgres16vector-v5` (snappy base + WAL) | healthy 16:19:34 (~12 min) |
| DR ready (app healthy behind the tunnel) | **16:21:06: 18 min total** |
| Data freshness | DR newest row 16:17:00 vs home 16:21:07 (~4 min, the WAL archive interval) |

So a failover now takes **~18 min + ~8 min detection** instead of ~68 min. The sensei api/worker/admin
`wait-for-writable-db` init container held those pods until Postgres was ready (logged "waiting for
a writable database"); the Flux health check on the CNPG `Cluster` in `dr-postgres` passes too early
(16 ms after creation) and does not gate the other apps, which simply retry until the database is up.

The 2026-10-04 drill used the old bzip2 backups: bootstrap ~4 min, Postgres healthy 59 min after the
cluster was created, apps ready ~3 min later. The failover timeline above also used **bzip2** backups. Home switched to snappy on
2026-10-05 (base backup 6 min 54 s instead of ~2 h); the drill above confirmed the whole failover
path now takes ~18 min.

---

## 1. Routine checks

| Check | Command | Healthy |
|---|---|---|
| System armed | `dr/bin/drctl status` | `state=STANDBY armed=true`, heartbeat age < 2 min |
| Home guard running | `kubectl -n sensei get cronjob dr-guard` / `kubectl -n sensei logs job/<latest>` | `heartbeat ok state=STANDBY` |
| Orchestrator errors | CloudWatch alarm `sensei-dr-orchestrator-errors` | OK |

Run a drill (§2) after any large change to sensei manifests, and at least quarterly.

---

## 2. Drill (no production impact)

```bash
dr/bin/drctl drill start     # ASG → 1, mode=drill, creates dr-drill.senseichess.com → DR tunnel
dr/bin/drctl status          # repeat until instance.ready=true (observed 18 min with snappy backups)
curl -sf https://dr-drill.senseichess.com/health
dr/bin/drctl shell           # SSM session on the instance (kubectl available as root)
dr/bin/drctl drill stop      # ASG → 0, removes dr-drill record, state → STANDBY
```

Drill mode: worker=0, sensei CronJobs suspended, dittofeed+temporal=0. A drill that is already
ready can be promoted with `drctl failover`: production DNS switches within ~1–2 min (the
orchestrator runs every minute). `drctl drill stop` takes effect immediately; the instance is
terminated within ~1 min. Postgres WAL/base backups go
to the run's own `postgres16vector-dr-<run>` prefix (safe to delete afterwards:
`aws s3 rm --recursive s3://sensei-cnpg/postgres16vector-dr-<run>/`).

---

## 3. Manual failover

Use when you know home will be down (planned move, ISP maintenance) or automation is disarmed.

```bash
dr/bin/drctl failover        # STANDBY/DRILL → FAILOVER; DNS switches automatically when ready
```
⏱ Observed: 67 min 45 s with the old bzip2 backups; a drill with snappy backups was ready in 18 min
(see §0). Expect ~20 min plus the DNS switch.

If a drill is already running it is promoted in place (mode drill → failover, side effects on).

---

## 4. While DR is ACTIVE

- Site, admin, langfuse API, rybbit, dittofeed and litellm serve from AWS.
- Langfuse/LiteLLM UI logins (Authelia SSO at home) do not work; APIs do.
- Inspect: `dr/bin/drctl shell`, then `kubectl get pods -A`, `kubectl -n database get cluster`.
- kubectl from your Mac (needs `brew install --cask session-manager-plugin`):
  `dr/bin/drctl kubeconfig` (writes `~/.kube/sensei-dr.yaml`), keep `dr/bin/drctl tunnel` running in
  another terminal, then `KUBECONFIG=~/.kube/sensei-dr.yaml kubectl get pods -A`. Each new instance
  has a new k3s CA, so fetch the kubeconfig again after every failover/drill.
- Logs: `kubectl -n sensei logs deploy/sensei-prod-api`.
- Cost ≈ $10/day; don't leave it running longer than needed after home is back.

---

## 5. Failback (~75 min; downtime ~8 min manual, ~1.5–2 min expected with `drctl failback cutover`)

**Use [FAILBACK-CHECKLIST.md](FAILBACK-CHECKLIST.md)**: the scripted `drctl failback` steps rebuild home as a
replica of AWS while AWS keeps serving (downtime ~5–10 min). The subsections below describe the
original manual procedure and remain as background.

Prerequisites: home internet back, `drctl status` shows recent home heartbeat and `home.fenced=true`.

### 5.1 Freeze DR and take a final backup
```bash
dr/bin/drctl failback freeze
```
- DR mode → `maintenance`: sensei-prod app/api/worker/admin + dittofeed scaled to 0 (site shows
  Cloudflare 502/530 for the duration — keep this window short).
- Agent forces a WAL switch and an on-demand base backup to `postgres16vector-dr-<run>` and waits
  for completion. `drctl status` shows `instance.lastBackup`.

### 5.2 (Optional) safety dump of home Postgres
Home `postgres16vector` will be replaced. If you changed anything at home on that cluster during the
outage (dev/stage DBs), dump it first, e.g. with `kubernetes/apps/database/cloudnative-pg/logical-backups`.

### 5.3 Restore home Postgres from DR
`drctl status` prints `dr.serverName` (e.g. `postgres16vector-dr-202610041830`). Then:

```bash
dr/bin/drctl failback home-manifest   # prints the exact edit for cluster16vector.yaml
```
Edit `kubernetes/apps/database/cloudnative-pg/cluster3/cluster16vector.yaml`:
- `backup.barmanObjectStore.serverName`: bump `postgres16vector-vN` → `postgres16vector-vN+1`
- `bootstrap.recovery.source` / `externalClusters[0].name` + `serverName`: the DR serverName

Commit (`task flux:commit -- "restore postgres16vector from DR"`), then recreate the cluster:
```bash
flux suspend kustomization cloudnative-pg-cluster3
kubectl -n database delete cluster postgres16vector     # PVCs are deleted with it
flux resume kustomization cloudnative-pg-cluster3
kubectl -n database get cluster postgres16vector -w     # wait for "Cluster in healthy state"
```
Update `awsbackup.yaml` `serverName` to the same `postgres16vector-vN+1` if it is still in use.

### 5.4 (Optional) ClickHouse DR data
Only needed if analytics written during the DR window matter:
```bash
dr/bin/drctl shell
# on the instance, for each of: database/clickhouse, sensei/dittofeed-clickhouse, sensei/rybbit-clickhouse
kubectl -n sensei exec deploy/dittofeed-clickhouse -c clickhouse-backup -- \
  env S3_PATH=dr/dittofeed-prod/clickhouse/ clickhouse-backup create_remote dr-final
```
Restore at home with the same `S3_PATH` override and `clickhouse-backup restore_remote --rm dr-final`.

### 5.5 Switch DNS home and unfence
```bash
dr/bin/drctl failback dns        # restores DNS snapshot + external-dns ownership, state → FAILBACK
dr/bin/drctl failback complete   # state → STANDBY, unfenceApproved=true, ASG → 0
```
Within a minute dr-guard resumes the home Flux Kustomizations/HelmReleases (which restore the
replica counts from git) and un-suspends CronJobs. Verify `https://senseichess.com/health` and
`kubectl -n sensei get pods`.

### 5.6 Clean up
- Keep the DR serverName prefix in S3 until home has taken a fresh base backup to `vN+1`, then
  `aws s3 rm --recursive s3://sensei-cnpg/postgres16vector-dr-<run>/`.
- The system re-arms automatically on the next home heartbeat.

---

## 6. Controls and break-glass

| Action | Command |
|---|---|
| Disable automatic failover | `dr/bin/drctl disarm` (re-arms on `drctl arm`) |
| Abort a failover before DNS switch | `dr/bin/drctl abort` (ASG → 0, state → STANDBY) |
| Force-unfence home (DR abandoned) | `kubectl -n sensei create job --from=cronjob/dr-guard dr-unfence-$(date +%s)` after `drctl failback complete`, or manually `flux resume ks sensei-prod-api …` |
| Orchestrator by hand | `aws lambda invoke --function-name sensei-dr-orchestrator /dev/stdout` |
| Instance boot log | `dr/bin/drctl shell` → `sudo journalctl -u sensei-dr-bootstrap -u sensei-dr-agent` |

### Testing the home guard without arming
`dr/bin/test-dr-guard.sh` runs the dr-guard fence/unfence cycle against any cluster with the
sensei-prod app names (e.g. the drill instance) with DynamoDB stubbed:
```bash
G=$(base64 < kubernetes/apps/sensei/dr-guard/app/dr-guard.sh | tr -d '\n'); T=$(base64 < dr/bin/test-dr-guard.sh | tr -d '\n')
dr/bin/drctl exec "echo $G | base64 -d >/tmp/g.sh; echo $T | base64 -d >/tmp/t.sh; sh /tmp/t.sh /tmp/g.sh"
```
Never send a manual heartbeat while home is offline: it arms automatic failover.

## 7. Rebuilding the DR stack from scratch

Everything except two secrets is code. Order:

```bash
# 1. DR age key (skip if sensei-dr/age-key already exists in Secrets Manager)
age-keygen -o /tmp/dr-age.key        # put the public key in .sops.yaml (DR rule), then:
for f in $(git ls-files 'kubernetes/dr/*.sops.yaml' 'kubernetes/apps/sensei/sensei-prod/*/*.sops.yaml' \
           'kubernetes/apps/sensei/litellm/app/*.sops.yaml' 'kubernetes/apps/database/cloudnative-pg/app/*.sops.yaml'); do
  SOPS_AGE_KEY_FILE=age.key sops updatekeys -y "$f"; done
# 2. Cloudflare tunnel (the external-dns API token cannot create tunnels)
cloudflared tunnel login                 # pick the senseichess.com zone
cloudflared tunnel create sensei-dr
# 3. Secrets Manager: Cloudflare token + tunnel run token (+ age key)
AWS_PROFILE=mike-sensei dr/bin/setup-secrets.sh --age-key /tmp/dr-age.key && rm /tmp/dr-age.key
# 4. AWS stack
cd dr/cdk && npm ci && AWS_PROFILE=mike-sensei npx cdk deploy
# 5. Home credentials for dr-guard (after a stack rebuild the access key changes)
aws secretsmanager get-secret-value --secret-id sensei-dr/home-credentials --query SecretString --output text \
  | jq '{apiVersion:"v1",kind:"Secret",metadata:{name:"dr-guard-aws",namespace:"sensei"},type:"Opaque",stringData:.}' \
  | yq -P > kubernetes/apps/sensei/dr-guard/app/secret.sops.yaml
SOPS_AGE_KEY_FILE=age.key sops --encrypt --in-place kubernetes/apps/sensei/dr-guard/app/secret.sops.yaml
```

Validate DR manifests offline before committing changes to `kubernetes/dr` or to DR-reused apps:
`dr/bin/validate-dr-tree.py --mode drill|failover|maintenance` and `cd dr/cdk && npm test`.

## 8. Maintenance

| When | Do |
|---|---|
| A sensei `SECRET_*` changes or a DR app starts using a new var | `dr/bin/build-dr-secrets.sh` then commit |
| A new sops file is added to a DR app dir | add it to the DR rule in `.sops.yaml`, `sops updatekeys <file>` |
| Home Postgres serverName bumped | nothing — DR picks the newest `postgres16vector-v*` prefix automatically (override: SSM `/sensei-dr/source-server`) |
| CDK changes | `cd dr/cdk && npx cdk deploy` (does not touch the ASG desired capacity) |
| Rotate DR age key | new key → Secrets Manager → `.sops.yaml` → `sops updatekeys` on DR files → rotate secrets that were exposed to the old key |
