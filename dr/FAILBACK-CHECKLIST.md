# Failback checklist: AWS DR → home

Copy-paste steps for returning senseichess.com to the home cluster after a DR failover.
Background: [RUNBOOK.md](RUNBOOK.md) §5. Every home-side step is a `drctl failback` subcommand
(implemented in `dr/bin/failback-home.sh`) that checks its preconditions and refuses to run when
it is not safe.

Shape of the procedure: home Postgres is rebuilt as a **read-only replica of AWS while AWS keeps
serving**, so the only downtime is the short freeze → promote → DNS switch at the end (~5–10 min).
Nothing on AWS is deleted until the very last step, and AWS's backups stay in S3.

```bash
cd ~/code/talos-cluster && git switch main && git pull
export AWS_PROFILE=mike-sensei AWS_REGION=us-east-1
```

## 1. Home is back: check it

```bash
flux reconcile source git flux-system && flux reconcile kustomization cluster-apps
dr/bin/drctl status            # state ACTIVE, heartbeat < 60s, home.fenced=true
kubectl get nodes; kubectl get pods -A | grep -vE "Running|Completed"
```
Expected `drctl status` (2026-10-05):
```
state:      ACTIVE  (armed=false, autoArm=true)
mode:       desired=failover  run=202610050013
heartbeat:  20s ago  home.fenced=true unfenceApproved=false
probe:      failures=0  last=-
instance:   phase=ready ready=true mode=failover updated 28s ago
            postgres: Cluster in healthy state; app health: ok; flux 23/23 ready
postgres:   source=postgres16vector-v4 -> serverName=postgres16vector-dr-202610050013  lastBackup=none
```
`armed=false` is normal while ACTIVE (arming only applies in STANDBY). Before going further, confirm
home external-dns leaves the DR-owned records alone:
```bash
kubectl -n network logs deploy/external-dns --since=15m | grep "owner id does not match" | head -2
```
```
... msg="Skipping endpoint www.senseichess.com 0 IN CNAME external.bigwang.org ... because owner id does not match ...
```
From inside your LAN, senseichess.com resolves to the home Envoy (split-horizon DNS, even for
`dig @1.1.1.1`) and shows 503 while home is fenced. That is expected. Check the public site from a
phone on cellular, or resolve through DNS-over-HTTPS:
```bash
IP=$(curl -s -H 'accept: application/dns-json' 'https://cloudflare-dns.com/dns-query?name=senseichess.com&type=A' | jq -r '.Answer[0].data')
curl -s --resolve senseichess.com:443:$IP https://senseichess.com/health     # {"status":"healthy"}
```

## 2. Stop the other home apps that use postgres16vector (no downtime)

```bash
dr/bin/drctl failback stop-home-apps
```
Suspends Flux for and scales to 0: metabase, langfuse-v3, langfuse-dev, litellm-dev, n8n, rybbit and
sensei dev/stage (sensei-prod and dittofeed are already fenced by dr-guard). It records each replica
count and waits until the database has no client connections. Expected:
```
stopped observability/metabase (was 1)
stopped sensei/langfuse-v3 (was 1)
stopped sensei/langfuse-dev (was 1)
stopped sensei/litellm-dev (was 1)
stopped sensei/n8n (was 1)
stopped sensei/rybbit (was 1)
stopped sensei/sensei-dev-api (was 0)
...
==> waiting for client connections to drain
no client connections
```
If it lists remaining connections instead, add those apps to `CONSUMERS` in
`dr/bin/failback-home.sh` (or stop them by hand) and run it again.

## 3. Rebuild home Postgres as a replica of AWS (no downtime, ~20–30 min)

```bash
dr/bin/drctl failback rebuild-home
```
Expected:
```
DR source:  postgres16vector-dr-202610050013
serverName: postgres16vector-v4 -> postgres16vector-v5
==> suspending cloudnative-pg-cluster3 and deleting the stale home cluster
cluster.postgresql.cnpg.io "postgres16vector" deleted
==> pointing kubernetes/apps/database/cloudnative-pg/cluster3/cluster16vector.yaml at the DR archive (replica cluster)
-      serverName: &currentCluster postgres16vector-v4
+      serverName: &currentCluster postgres16vector-v5
-      source: &previousCluster postgres16vector-v3
+      source: &previousCluster postgres16vector-dr-202610050013
+  replica:
+    enabled: true
+    source: *previousCluster
home is restoring as a replica of postgres16vector-dr-202610050013 (about 15-25 min); the site stays on AWS.
```

The restore runs in three phases; `kubectl cnpg status` is only useful from phase B on.

**A. Base backup restore (~16 min for ~59 GB at ~50 MB/s).** CNPG runs a temporary
`…-full-recovery-…` pod. `cnpg status` shows nothing useful yet; this is normal:
```
$ kubectl cnpg status postgres16vector -n database
Replica Cluster Summary
Primary server is initializing
Designated primary:   (switching to postgres16vector-1)
Source cluster:      postgres16vector-dr-202610050013
Status:              Setting up primary Creating primary instance postgres16vector-1
Ready instances:     0
Size:                container not found
```
Watch the data directory grow instead:
```bash
kubectl -n database get pods | grep postgres16vector
kubectl -n database exec $(kubectl -n database get pod -l cnpg.io/jobRole=full-recovery -o name) -c full-recovery -- du -sh /var/lib/postgresql/data
```
```
postgres16vector-1-full-recovery-slrs6   1/1     Running   0     7m
24G	/var/lib/postgresql/data
```
Its log starts with `"msg":"Target backup found"` naming the DR backup, and ends with
`"msg":"Wait completed, proceeding to shutdown the manager"` when done.

**B. Designated primary up, standbys cloning (~10–15 min per standby over the LAN).**
```
$ kubectl cnpg status postgres16vector -n database
Replica Cluster Summary
Designated primary:      postgres16vector-1
Source cluster:          postgres16vector-dr-202610050013
Status:                  Creating a new replica Creating replica postgres16vector-2-join
Instances:               3
Ready instances:         1
Size:                    55G
...
Name                Current LSN   Replication role    Status  QoS        Manager Version  Node
postgres16vector-1  58F/D3FFFFD0  Designated primary  OK      Burstable  1.29.0           mercury
```
"Designated primary" means the read-only leader of a replica cluster; it is not writable yet.

**C. Following AWS.** Home replays AWS's WAL from S3 as AWS archives it (every few minutes):
```
$ dr/bin/drctl failback lag
home replica trails AWS by 11508728 bytes (<= 0 means caught up)
last replayed transaction: 2026-10-05 14:36:54.81284+00
```
A few MB behind and a "last replayed transaction" within a few minutes of now is healthy. Wait for
`Ready instances: 3` / `Cluster in healthy state` before step 4.
`rebuild-home` refuses unless AWS is serving, there is a DR base backup, no clients are connected and
the next `postgres16vector-vN` S3 prefix is unused. It then suspends `cloudnative-pg-cluster3`, deletes
the stale home cluster, commits **only** `cluster16vector.yaml` (new serverName + recovery/replica
source = the DR serverName) and resumes Flux.

## 4. Cut over (downtime starts; ~8 min on 2026-10-05)

Only start when step 3 shows `Ready instances: 3` / `Cluster in healthy state` and a small lag.
While standbys clone, the Kubernetes API can be briefly slow (`Unable to connect to the server:
context deadline exceeded`): the clone saturates disk/network on control-plane nodes. It recovers
on its own; check with `talosctl -n <node> etcd status` if worried.

**4a. Freeze AWS** (stops sensei-prod on AWS, switches WAL, starts a final backup):
```bash
dr/bin/drctl failback freeze
dr/bin/drctl status          # repeat until "mode=maintenance" (~20 s)
```
```
state:      ACTIVE  (armed=false, autoArm=true)
mode:       desired=maintenance  run=202610050013
instance:   phase=maintenance ready=false mode=maintenance updated 4s ago
            postgres: Cluster in healthy state; app health: ok; flux 20/23 ready
postgres:   ... lastBackup=waiting for sensei-prod to stop
```
`promote` does not wait for the AWS freeze backup; that backup is only a safety net.

**4b. Promote home** (waits for home to replay AWS's last WAL, commits `replica.enabled: false`,
waits until home is writable, then starts a base backup into the new serverName). ~5 min:
```bash
dr/bin/drctl failback promote
```
```
==> waiting for the home replica to replay the last DR WAL
  13675736 bytes behind
  16777272 bytes behind
caught up
✔ applied revision refs/heads/main@sha1:...
==> waiting for promotion
home postgres16vector is primary
NAME               AGE   INSTANCES   READY   STATUS                     PRIMARY
postgres16vector   65m   3           3       Cluster in healthy state   postgres16vector-1
==> starting a base backup into the new serverName
backup.postgresql.cnpg.io/postgres16vector-failback-202610051529 created
```
Optional sanity check that home has AWS's last writes (both lines must match):
```bash
Q="select max(event_timestamp), (select count(*) from job_queue) from events"
dr/bin/drctl exec "kubectl -n database exec \$(kubectl -n database get cluster postgres16vector -o jsonpath={.status.currentPrimary}) -c postgres -- psql -d sensei-prod -qAt -c \"$Q\""
kubectl -n database exec postgres16vector-1 -c postgres -- psql -d sensei-prod -qAt -c "$Q"
```
```
2026-10-05 15:20:20.130785|2328847
2026-10-05 15:20:20.130785|2328847
```

**4c. DNS home, complete, restart apps** (seconds):
```bash
dr/bin/drctl failback dns
dr/bin/drctl failback complete
dr/bin/drctl failback start-home-apps
```
```
{ "state": "FAILBACK", ..., "dns": [ "restore" ], "notified": [ "[sensei-dr] DNS restored to home" ] }
{ "state": "STANDBY", "armed": true, ..., "asg": 0, "notified": [ "[sensei-dr] Automatic failover armed" ] }
started observability/metabase (1)
started sensei/langfuse-v3 (1)
...
started sensei/rybbit (1)
```
`complete` approves the unfence; dr-guard scales sensei-prod/dittofeed back within ~1 minute and the
AWS instance terminates. `dr/bin/drctl status --dns` now shows the original targets:
```
state:      STANDBY  (armed=true, autoArm=true)
dns:
  senseichess.com -> external.senseichess.com
  www.senseichess.com -> external.senseichess.com
  admin.senseichess.com -> external.bigwang.org
  ...
```
If anything fails before `dns`: `dr/bin/drctl failback unfreeze` puts the site back on AWS in ~2 min.

## 5. Verify (downtime ends)

sensei-prod pods need ~1–2 min after the unfence. Until then the public site returns Envoy's
`upstream connect error or disconnect/reset before headers` (from the home cluster); that is
expected and clears by itself.
```bash
kubectl -n sensei get deploy sensei-prod-api sensei-prod-app sensei-prod-worker sensei-prod-admin
kubectl -n sensei get cronjob | grep sensei-prod            # SUSPEND False
IP=$(curl -s -H 'accept: application/dns-json' 'https://cloudflare-dns.com/dns-query?name=senseichess.com&type=A' | jq -r '.Answer[0].data')
curl -s --resolve senseichess.com:443:$IP https://senseichess.com/health
```
```
NAME                 READY   UP-TO-DATE   AVAILABLE
sensei-prod-api      3/3     3            3
sensei-prod-app      3/3     3            3
sensei-prod-worker   4/4     4            4
sensei-prod-admin    1/1     1            1
sensei-prod-daily-refresh    0 1 * * *   <none>     False ...
sensei-prod-weekly-podcast   0 7 * * 1   <none>     False ...
{"status":"healthy"}
```

## 6. Clean up (after the home base backup completes)

The post-promotion backup uses the home cluster's bzip2 settings and can take ~2 h:
```bash
kubectl -n database get backup | grep failback              # STATUS completed
aws s3 ls s3://sensei-cnpg/postgres16vector-v5/base/         # a base backup exists
aws s3 ls s3://sensei-cnpg/                                  # then remove old postgres16vector-dr-* prefixes
```
Leave the `replica:` block (`enabled: false`) in `cluster16vector.yaml`; `rebuild-home` reuses it.

## Not covered

- ClickHouse data written while on AWS (Langfuse/Rybbit/Dittofeed analytics) is not carried home;
  home keeps its data up to the outage.
- Anything written at home to *other* databases on `postgres16vector` during the outage is replaced
  by the AWS copy (it remains in S3 under the previous `postgres16vector-vN` prefix).

## Claude Code permissions

`.claude/settings.json` allows `dr/bin/drctl failback …` and carries an `autoMode.allow` rule
describing this procedure, so Claude can run these steps in auto mode. Raw `kubectl delete` /
`flux suspend` on the database stays subject to the safety classifier; use the subcommands.
