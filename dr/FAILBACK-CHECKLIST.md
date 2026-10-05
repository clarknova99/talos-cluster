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
From inside your LAN, senseichess.com resolves to the home Envoy (split-horizon DNS) and shows 503
while home is fenced. That is expected; check the public site from a phone on cellular.

## 2. Stop the other home apps that use postgres16vector (no downtime)

```bash
dr/bin/drctl failback stop-home-apps
```
Suspends Flux for and scales to 0: metabase, langfuse-v3, langfuse-dev, litellm-dev, n8n, rybbit and
sensei dev/stage (sensei-prod and dittofeed are already fenced by dr-guard). It records each replica
count and waits until the database has no client connections.

## 3. Rebuild home Postgres as a replica of AWS (no downtime, ~20–30 min)

```bash
dr/bin/drctl failback rebuild-home
kubectl -n database get cluster postgres16vector -w        # until "Cluster in healthy state", 3/3
dr/bin/drctl failback lag                                   # bytes behind AWS; repeat until small
```
`rebuild-home` refuses unless AWS is serving, there is a DR base backup, no clients are connected and
the next `postgres16vector-vN` S3 prefix is unused. It then suspends `cloudnative-pg-cluster3`, deletes
the stale home cluster, commits **only** `cluster16vector.yaml` (new serverName + recovery/replica
source = the DR serverName) and resumes Flux.

## 4. Cut over (downtime starts)

```bash
dr/bin/drctl failback freeze        # AWS stops sensei-prod, switches WAL, takes a final backup
dr/bin/drctl failback promote       # waits until home has replayed AWS's last WAL, then promotes it
dr/bin/drctl failback dns           # Cloudflare records + external-dns ownership back to home
dr/bin/drctl failback complete      # STANDBY; dr-guard unfences sensei-prod/dittofeed; AWS instance stops
dr/bin/drctl failback start-home-apps
```
If anything fails before `dns`: `dr/bin/drctl failback unfreeze` puts the site back on AWS in ~2 min.

## 5. Verify (downtime ends)

```bash
kubectl -n sensei get deploy | grep -E "sensei-prod|dittofeed|langfuse|rybbit|n8n|litellm"
kubectl -n sensei get cronjob | grep sensei-prod            # SUSPEND False
kubectl -n database exec postgres16vector-1 -c postgres -- psql -d sensei-prod -Atc "select max(event_timestamp) from events"
dr/bin/drctl status                                         # STANDBY; armed=true within a minute or two
```
From outside the LAN: `https://senseichess.com/health` → `{"status":"healthy"}`.

## 6. Clean up (after the first home backup to the new prefix)

```bash
kubectl -n database get backup | tail -3                    # newest one "completed"
aws s3 ls s3://sensei-cnpg/                                  # remove old postgres16vector-dr-* prefixes once happy
```
Optionally remove the `replica:` block (now `enabled: false`) from `cluster16vector.yaml`;
`rebuild-home` re-adds it next time.

## Not covered

- ClickHouse data written while on AWS (Langfuse/Rybbit/Dittofeed analytics) is not carried home;
  home keeps its data up to the outage.
- Anything written at home to *other* databases on `postgres16vector` during the outage is replaced
  by the AWS copy (it remains in S3 under the previous `postgres16vector-vN` prefix).

## Claude Code permissions

`.claude/settings.json` allows `dr/bin/drctl failback …` and carries an `autoMode.allow` rule
describing this procedure, so Claude can run these steps in auto mode. Raw `kubectl delete` /
`flux suspend` on the database stays subject to the safety classifier; use the subcommands.
