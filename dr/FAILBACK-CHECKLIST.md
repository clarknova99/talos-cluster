# Failback checklist: AWS DR → home

Exact, copy-paste steps for returning senseichess.com to the home cluster after a DR failover.
Background and the general procedure: [RUNBOOK.md](RUNBOOK.md) §5.

Values for the **2026-10-05 failover** (check them with `dr/bin/drctl status` and edit if a later
failover changed them):

```bash
export AWS_PROFILE=mike-sensei AWS_REGION=us-east-1
DR_SERVER=postgres16vector-dr-202610050013   # drctl status → "serverName="
HOME_OLD=postgres16vector-v4                  # current backup.serverName in cluster16vector.yaml
HOME_NEW=postgres16vector-v5                  # next free prefix in s3://sensei-cnpg/
```

Expected downtime: **~30–40 min** (from step 3 until step 6). Do it at a quiet time.
Everything before step 3 can happen any time; until step 3 the site keeps serving from AWS.

---

## Step 0: Fence home (do this before or as soon as possible after internet returns)

Home must not run sensei-prod, Dittofeed or the sensei CronJobs on its stale data. Once home Flux
pulls `main`, `dr-guard` does this automatically within a minute, but running it yourself closes
the gap and records the correct replica counts to restore later (api 3, app 3, worker 4, admin 1):

```bash
for a in sensei-prod-api:3 sensei-prod-app:3 sensei-prod-worker:4 sensei-prod-admin:1 dittofeed:1 dittofeed-temporal:1; do n=${a%%:*}; kubectl -n flux-system patch kustomization $n --type merge -p '{"spec":{"suspend":true}}'; kubectl -n sensei patch helmrelease $n --type merge -p '{"spec":{"suspend":true}}'; kubectl -n sensei annotate --overwrite deploy $n sensei-dr/fence-replicas=${a##*:}; kubectl -n sensei scale deploy $n --replicas=0; done; for cj in $(kubectl -n sensei get cronjob -o name | grep /sensei-prod-); do kubectl -n sensei patch $cj --type merge -p '{"spec":{"suspend":true}}'; done
```

Check: `kubectl -n sensei get deploy` shows those six at `0/0`.

## Step 1: Internet is back: confirm home picked up dr-guard

```bash
flux reconcile source git flux-system
flux reconcile kustomization cluster-apps
kubectl -n sensei get cronjob dr-guard
dr/bin/drctl status
```
Expect: `state: ACTIVE`, `heartbeat: <60s ago`, `home.fenced=true`. You will also get the email
"Home is back online (DR still active)". **The site is still on AWS; nothing is urgent from here.**

## Step 2: Prepare your checkout (no cluster changes yet)

```bash
cd ~/code/talos-cluster
git switch main && git pull
grep -nE "serverName: &currentCluster|source: &previousCluster" kubernetes/apps/database/cloudnative-pg/cluster3/cluster16vector.yaml
```
Expect `postgres16vector-v4` and `postgres16vector-v3` on lines ~69 and ~83.

## Step 3: Freeze DR (downtime starts)

```bash
dr/bin/drctl failback freeze
dr/bin/drctl status        # repeat until: lastBackup=dr-freeze-...:completed  (~10 min)
```
DR stops sensei-prod, forces a WAL switch and takes a final base backup into `$DR_SERVER`.

## Step 4: Recreate home Postgres from the DR backup

Order matters: suspend, delete, then change git, then resume. (If the new serverName reaches the
old cluster first, it archives into `$HOME_NEW` and the restored cluster refuses to use it.)

```bash
flux suspend kustomization cloudnative-pg-cluster3
kubectl -n database delete cluster postgres16vector --wait=true
kubectl -n database get pvc | grep postgres16vector       # expect nothing (PVCs go with the cluster)

F=kubernetes/apps/database/cloudnative-pg/cluster3/cluster16vector.yaml
sed -i '' "s/serverName: \&currentCluster ${HOME_OLD}/serverName: \&currentCluster ${HOME_NEW}/" $F
sed -i '' "s/source: \&previousCluster postgres16vector-v[0-9]*/source: \&previousCluster ${DR_SERVER}/" $F
git diff $F                                                 # exactly the two lines above changed
git add $F && git commit -m "restore postgres16vector from DR (${DR_SERVER})" && git push
flux reconcile source git flux-system
flux resume kustomization cloudnative-pg-cluster3
kubectl -n database get cluster postgres16vector -w        # wait for "Cluster in healthy state" (~15–25 min)
```
(`git add` of one file on purpose: `task flux:commit` would also commit your unrelated local changes.)

Verify the DR writes made it home:
```bash
kubectl -n database exec postgres16vector-1 -c postgres -- psql -d sensei-prod -Atc "select max(event_timestamp) from events"
```
Expect a timestamp after the failover (2026-10-05 01:21 UTC or later), not 2026-10-03.

**If the restore fails:** run `dr/bin/drctl failback unfreeze`. AWS serves again in ~2 min (DNS never
left AWS), then debug home without time pressure.

## Step 5: Switch DNS home and unfence

```bash
dr/bin/drctl failback dns          # Cloudflare records + external-dns ownership back to home
dr/bin/drctl failback complete     # state STANDBY, approves unfence, terminates the AWS instance
```
Within ~1 minute dr-guard resumes the Flux Kustomizations/HelmReleases and restores the replica
counts recorded in step 0. Check, and fix if anything is still 0:

```bash
kubectl -n sensei get deploy sensei-prod-api sensei-prod-app sensei-prod-worker sensei-prod-admin dittofeed dittofeed-temporal
# only if any are 0/0:
kubectl -n sensei scale deploy sensei-prod-api --replicas=3; kubectl -n sensei scale deploy sensei-prod-app --replicas=3; kubectl -n sensei scale deploy sensei-prod-worker --replicas=4; kubectl -n sensei scale deploy sensei-prod-admin --replicas=1
```

## Step 6: Verify (downtime ends)

```bash
curl -s https://senseichess.com/health                    # {"status":"healthy"}
kubectl -n sensei get pods | grep -E "sensei-prod|dittofeed"
kubectl -n sensei get cronjob | grep sensei-prod            # SUSPEND False
dr/bin/drctl status                                         # STANDBY, armed=true within a minute or two
```

## Step 7: Clean up (after the first home backup to the new prefix)

The home ScheduledBackup runs immediately after the cluster is recreated:
```bash
kubectl -n database get backup | tail -3                   # newest one "completed"
aws s3 ls s3://sensei-cnpg/${HOME_NEW}/base/                # a base backup exists
aws s3 rm --recursive s3://sensei-cnpg/postgres16vector-dr-202610041835/   # drill leftovers
aws s3 rm --recursive s3://sensei-cnpg/${DR_SERVER}/
```

## Not covered here

- **ClickHouse data written while on AWS** (Langfuse/Rybbit/Dittofeed analytics for the DR window)
  is not carried home by these steps; home keeps its data up to the outage. A delta copy can be
  added before step 5 if you want it.
- Anything written at home to *other* databases on `postgres16vector` during the outage
  (sensei-dev/stage, n8n, metabase…) is replaced by the DR copy in step 4.
