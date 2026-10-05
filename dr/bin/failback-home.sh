#!/usr/bin/env bash
# Home-side failback steps (dr/FAILBACK-CHECKLIST.md). Called by `drctl failback <step>`.
# Each step checks its preconditions and refuses to run when it is not safe.
#
#   stop-home-apps    stop the other home apps that use postgres16vector (recorded for restart)
#   rebuild-home      delete the stale home postgres16vector and recreate it as a replica of the
#                     AWS DR archive (site keeps serving from AWS meanwhile)
#   lag               how far the home replica trails AWS
#   promote           promote the home replica (after `drctl failback freeze`)
#   cutover           freeze + promote + dns + complete + unfence in one go, with warm-started
#                     home pods (the fast path; replaces the four manual steps)
#   start-home-apps   restart the apps stopped by stop-home-apps
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
DRCTL="$ROOT/dr/bin/drctl"
export AWS_PROFILE="${AWS_PROFILE:-mike-sensei}" AWS_REGION="${AWS_REGION:-us-east-1}"
NS=database
CLUSTER=postgres16vector
KS=cloudnative-pg-cluster3
MANIFEST=kubernetes/apps/database/cloudnative-pg/cluster3/cluster16vector.yaml
BUCKET=sensei-cnpg
ANN=sensei-dr/failback-replicas
# Home workloads (besides sensei-prod/dittofeed, which dr-guard fences) using postgres16vector.
# Each name is the Deployment, HelmRelease and Flux Kustomization name.
CONSUMERS=(
  observability/metabase
  sensei/langfuse-v3 sensei/langfuse-dev sensei/litellm-dev sensei/n8n sensei/rybbit
  sensei/sensei-dev-api sensei/sensei-dev-app sensei/sensei-dev-worker sensei/sensei-dev-admin
  sensei/sensei-stage-api sensei/sensei-stage-app sensei/sensei-stage-worker sensei/sensei-stage-admin
)

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

dr_json() { "$DRCTL" _status-json; }
primary() { kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}' 2>/dev/null; }
psql_home() {
  local p
  p="$(primary)"
  [ -n "$p" ] || die "home $CLUSTER has no running primary yet (still restoring?): kubectl -n $NS get cluster $CLUSTER"
  kubectl -n "$NS" exec "$p" -c postgres -- psql -qAt "$@"
}
client_connections() {
  psql_home -F ' | ' -c "select datname, coalesce(nullif(application_name,''),'-'), count(*) from pg_stat_activity
    where datname is not null and backend_type='client backend' and pid <> pg_backend_pid() group by 1,2"
}
s3_prefix_exists() { [ -n "$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$1/" --max-items 1 --query 'Contents[0].Key' --output text 2>/dev/null | grep -v None)" ]; }

commit_manifest() { # commit_manifest <message>: commit + push ONLY the cluster manifest
  git -C "$ROOT" add "$MANIFEST"
  git -C "$ROOT" commit -q -m "$1" -- "$MANIFEST"
  git -C "$ROOT" push -q
  flux reconcile source git flux-system >/dev/null
}

stop_home_apps() {
  for t in "${CONSUMERS[@]}"; do
    ns=${t%%/*} n=${t##*/}
    r="$(kubectl -n "$ns" get deploy "$n" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || continue
    kubectl -n flux-system patch kustomization "$n" --type merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
    kubectl -n "$ns" patch helmrelease "$n" --type merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
    if [ -z "$(kubectl -n "$ns" get deploy "$n" -o jsonpath="{.metadata.annotations.sensei-dr/failback-replicas}")" ]; then
      kubectl -n "$ns" annotate deploy "$n" "$ANN=$r" >/dev/null
    fi
    kubectl -n "$ns" scale deploy "$n" --replicas=0 >/dev/null
    echo "stopped $t (was $r)"
  done
  step "waiting for client connections to drain"
  for _ in $(seq 1 18); do [ -z "$(client_connections)" ] && { echo "no client connections"; return; }; sleep 10; done
  echo "still connected:"; client_connections
  die "connections remain; stop those clients (or add them to CONSUMERS) and re-run"
}

start_home_apps() {
  for t in "${CONSUMERS[@]}"; do
    ns=${t%%/*} n=${t##*/}
    r="$(kubectl -n "$ns" get deploy "$n" -o jsonpath="{.metadata.annotations.sensei-dr/failback-replicas}" 2>/dev/null)" || continue
    [ -n "$r" ] || continue
    kubectl -n "$ns" scale deploy "$n" --replicas="$r" >/dev/null
    kubectl -n "$ns" annotate deploy "$n" "$ANN-" >/dev/null
    kubectl -n "$ns" patch helmrelease "$n" --type merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
    kubectl -n flux-system patch kustomization "$n" --type merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
    echo "started $t ($r)"
  done
}

rebuild_home() {
  local status dr_server home_old home_new n
  status="$(dr_json)"
  [ "$(jq -r '.dr.state' <<<"$status")" = ACTIVE ] || die "DR must be ACTIVE (serving) while home is rebuilt"
  [ "$(jq -r '.dr.desiredMode' <<<"$status")" = failover ] || die "DR is frozen; run 'drctl failback unfreeze' first so the site stays up"
  dr_server="$(jq -r '.instance.serverName // empty' <<<"$status")"
  [ -n "$dr_server" ] || die "no DR serverName recorded"
  s3_prefix_exists "$dr_server/base" || die "no base backup in s3://$BUCKET/$dr_server/ yet"

  cd "$ROOT"
  [ "$(git branch --show-current)" = main ] || die "check out main first"
  git pull -q --rebase --autostash
  git diff --quiet -- "$MANIFEST" || die "$MANIFEST has local changes"
  home_old="$(sed -nE 's/.*serverName: &currentCluster (postgres16vector-v[0-9]+).*/\1/p' "$MANIFEST")"
  [ -n "$home_old" ] || die "cannot find the current serverName in $MANIFEST"
  home_new="postgres16vector-v$(( ${home_old##*-v} + 1 ))"
  s3_prefix_exists "$home_new" && die "s3://$BUCKET/$home_new/ already exists; pick a new serverName by hand"

  if kubectl -n "$NS" get cluster "$CLUSTER" >/dev/null 2>&1; then
    n="$(client_connections)"
    [ -z "$n" ] || { echo "$n"; die "clients are still connected; run 'drctl failback stop-home-apps' first"; }
  fi
  echo "DR source:  $dr_server"
  echo "serverName: $home_old -> $home_new"

  step "suspending $KS and deleting the stale home cluster"
  flux suspend kustomization "$KS" >/dev/null
  kubectl -n "$NS" delete cluster "$CLUSTER" --ignore-not-found --wait=true
  for _ in $(seq 1 30); do
    [ "$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | grep -cE "^$CLUSTER-[0-9]+ ")" = 0 ] && break; sleep 5
  done

  step "pointing $MANIFEST at the DR archive (replica cluster)"
  python3 - "$MANIFEST" "$home_new" "$dr_server" <<'PY'
import re, sys
path, new_server, dr_server = sys.argv[1:]
s = open(path).read()
s = re.sub(r"serverName: &currentCluster postgres16vector-v\d+", f"serverName: &currentCluster {new_server}", s, count=1)
s = re.sub(r"source: &previousCluster \S+", f"source: &previousCluster {dr_server}", s, count=1)
if re.search(r"^  replica:\n", s, re.M):
    s = re.sub(r"(^  replica:\n    enabled: )\w+", r"\1true", s, count=1, flags=re.M)
else:
    anchor = f"      source: &previousCluster {dr_server}\n"
    s = s.replace(anchor, anchor + "\n  # Failback from AWS DR: follow the DR WAL archive as a read-only replica cluster\n"
                  "  # until `drctl failback promote` sets enabled: false.\n"
                  "  replica:\n    enabled: true\n    source: *previousCluster\n", 1)
open(path, "w").write(s)
PY
  git --no-pager diff -- "$MANIFEST"
  commit_manifest "restore $CLUSTER from AWS DR ($dr_server) as a replica cluster"
  flux resume kustomization "$KS" >/dev/null
  echo "home is restoring as a replica of $dr_server (about 15-25 min); the site stays on AWS."
  echo "watch: kubectl -n $NS get cluster $CLUSTER -w   then: drctl failback lag"
}

dr_lsn() {
  "$DRCTL" exec "kubectl -n database exec \$(kubectl -n database get cluster postgres16vector -o jsonpath={.status.currentPrimary}) -c postgres -- psql -qAt -c 'select pg_current_wal_lsn()'" \
    | grep -oE '^[0-9A-F]+/[0-9A-F]+' | head -1
}

lag() { # prints bytes the home replica trails the DR primary (<= 0: caught up)
  local lsn
  lsn="$(dr_lsn)"
  [ -n "$lsn" ] || die "could not read the DR WAL position"
  psql_home -c "select pg_wal_lsn_diff('$lsn', pg_last_wal_replay_lsn())::bigint"
}

show_lag() {
  local b
  b="$(lag)"
  echo "home replica trails AWS by ${b} bytes (<= 0 means caught up)"
  psql_home -c "select 'last replayed transaction: ' || coalesce(pg_last_xact_replay_timestamp()::text, 'none yet')"
}

FENCED_APPS=(sensei-prod-api sensei-prod-app sensei-prod-worker sensei-prod-admin dittofeed dittofeed-temporal)
GATED_APPS=(sensei-prod-api sensei-prod-app sensei-prod-worker sensei-prod-admin) # start before promotion
T0=$(date +%s)
elapsed() { local d=$(( $(date +%s) - T0 )); printf '%dm%02ds' $((d / 60)) $((d % 60)); }
tstep() { echo "==> [$(date -u +%H:%M:%S)Z +$(elapsed)] $*"; }

wait_caught_up() { # wait_caught_up <poll seconds>
  local b
  for _ in $(seq 1 200); do
    b="$(lag)"
    [ "${b:-1}" -le 0 ] && { echo "caught up"; return; }
    echo "  ${b} bytes behind"; sleep "$1"
  done
  die "home did not catch up (still ${b} bytes behind); check WAL archiving on DR"
}

scheduled_backup_suspend() { # scheduled_backup_suspend true|false
  for sb in $(kubectl -n "$NS" get scheduledbackup -o jsonpath="{range .items[?(@.spec.cluster.name=='$CLUSTER')]}{.metadata.name}{' '}{end}"); do
    kubectl -n "$NS" patch scheduledbackup "$sb" --type merge -p "{\"spec\":{\"suspend\":$1}}" >/dev/null
  done
}

promote_core() { # promote_core <poll seconds>: replica -> primary, then a base backup
  [ "$(psql_home -c 'select pg_is_in_recovery()')" = t ] || die "home $CLUSTER is not a replica (already promoted?)"
  # A backup session on the primary would hold the post-promotion restart (smartShutdownTimeout).
  scheduled_backup_suspend true
  wait_caught_up "$1"

  cd "$ROOT"
  git pull -q --rebase --autostash
  python3 - "$MANIFEST" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s2 = re.sub(r"(^  replica:\n    enabled: )true", r"\1false", s, count=1, flags=re.M)
assert s2 != s, "replica.enabled: true not found"
open(p, "w").write(s2)
PY
  commit_manifest "promote $CLUSTER (failback from AWS DR complete)"
  flux reconcile kustomization "$KS" >/dev/null
  tstep "promotion requested; waiting until home is writable and healthy"
  # Promotion changes archive_mode, so CNPG restarts the primary once right after promoting.
  for _ in $(seq 1 120); do
    if [ "$(psql_home -c 'select pg_is_in_recovery()' 2>/dev/null)" = f ] \
       && [ "$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.phase}')" = "Cluster in healthy state" ] \
       && ! kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q False; then
      break
    fi
    sleep "$1"
  done
  [ "$(psql_home -c 'select pg_is_in_recovery()')" = f ] || die "not promoted yet; check: kubectl -n $NS get cluster $CLUSTER"
  kubectl -n "$NS" get cluster "$CLUSTER"
  scheduled_backup_suspend false
  # The daily ScheduledBackup does not fire for a recreated cluster; without a base backup in the
  # new serverName a future DR failover would have nothing to restore from.
  tstep "starting a base backup into the new serverName"
  kubectl -n "$NS" apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $CLUSTER-failback-$(date -u +%Y%m%d%H%M)
spec:
  method: barmanObjectStore
  cluster:
    name: $CLUSTER
EOF
}

promote() {
  local status
  status="$(dr_json)"
  [ "$(jq -r '.dr.desiredMode' <<<"$status")" = maintenance ] || die "freeze DR first: drctl failback freeze"
  [ "$(jq -r '.instance.appliedMode' <<<"$status")" = maintenance ] || die "DR has not applied maintenance mode yet"
  step "waiting for the home replica to replay the last DR WAL"
  promote_core 5
  echo "next: drctl failback dns && drctl failback complete && drctl failback start-home-apps"
}

dr_stop_now() { # stop sensei-prod/dittofeed on DR directly and switch WAL (faster than the agent)
  "$DRCTL" exec '
    for d in sensei-prod-api sensei-prod-app sensei-prod-worker sensei-prod-admin dittofeed dittofeed-temporal; do
      kubectl -n sensei scale deploy "$d" --replicas=0 >/dev/null 2>&1
    done
    for i in $(seq 1 60); do
      n=$(kubectl -n sensei get pods --no-headers 2>/dev/null | grep -cE "^(sensei-prod-(api|app|worker|admin)-[0-9a-f]{8,10}-|dittofeed-temporal-[0-9a-f]{8,10}-|dittofeed-[0-9a-f]{8,10}-)")
      [ "$n" = 0 ] && break; sleep 1
    done
    P=$(kubectl -n database get cluster postgres16vector -o jsonpath={.status.currentPrimary})
    kubectl -n database exec "$P" -c postgres -- psql -qAt -c "select pg_switch_wal()" >/dev/null
    echo "DR apps stopped; WAL switched"' | grep -E "stopped|rror" || die "could not stop DR apps"
}

unfence_now() { # what dr-guard does on unfence, without waiting for its next run
  local saved
  for app in "${FENCED_APPS[@]}"; do
    saved="$(kubectl -n sensei get deploy "$app" -o jsonpath="{.metadata.annotations.sensei-dr/fence-replicas}" 2>/dev/null)" || saved=""
    if [ -n "$saved" ]; then
      kubectl -n sensei scale deploy "$app" --replicas="$saved" >/dev/null
      kubectl -n sensei annotate deploy "$app" "sensei-dr/fence-replicas-" >/dev/null
    fi
  done
  for cj in $(kubectl -n sensei get cronjob -o name | grep '/sensei-prod-'); do
    kubectl -n sensei patch "$cj" --type merge -p '{"spec":{"suspend":false}}' >/dev/null
  done
  for app in "${FENCED_APPS[@]}"; do
    kubectl -n sensei patch helmrelease "$app" --type merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
    kubectl -n flux-system patch kustomization "$app" --type merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
  done
}

public_health() {
  local ip
  ip="$(curl -s -H 'accept: application/dns-json' 'https://cloudflare-dns.com/dns-query?name=senseichess.com&type=A' | jq -r '.Answer[0].data')"
  curl -s -m 10 --resolve "senseichess.com:443:$ip" https://senseichess.com/health
}

cutover() {
  local status b ready freeze_at
  status="$(dr_json)"
  [ "$(jq -r '.dr.state' <<<"$status")" = ACTIVE ] || die "DR must be ACTIVE"
  [ "$(jq -r '.dr.desiredMode' <<<"$status")" = failover ] || die "DR is already frozen; use the manual steps (promote/dns/complete)"
  [ "$(psql_home -c 'select pg_is_in_recovery()')" = t ] || die "home $CLUSTER is not a replica; run rebuild-home first"
  ready="$(kubectl -n "$NS" get cluster "$CLUSTER" -o jsonpath='{.status.readyInstances}')"
  [ "${ready:-0}" -ge 3 ] || die "home $CLUSTER has ${ready:-0}/3 ready instances; wait for the standbys"
  b="$(lag)"
  [ "${b:-999999999}" -le 268435456 ] || die "home trails AWS by ${b} bytes; wait for 'drctl failback lag' to be small"
  kubectl -n sensei get cronjob dr-guard >/dev/null || die "dr-guard CronJob not found at home"
  cd "$ROOT"
  [ "$(git branch --show-current)" = main ] || die "check out main first"
  git diff --quiet -- "$MANIFEST" || die "$MANIFEST has local changes"

  tstep "warm start: pausing dr-guard and starting home sensei-prod (pods wait for a writable database)"
  kubectl -n sensei patch cronjob dr-guard --type merge -p '{"spec":{"suspend":true}}' >/dev/null
  # Never leave dr-guard paused, whatever happens below.
  trap 'kubectl -n sensei patch cronjob dr-guard --type merge -p "{\"spec\":{\"suspend\":false}}" >/dev/null 2>&1
        if [ -z "${CUTOVER_DONE:-}" ]; then
          echo "cutover did not finish. If DNS still points at AWS, put the site back with: dr/bin/drctl failback unfreeze" >&2
        fi' EXIT
  for app in "${GATED_APPS[@]}"; do
    r="$(kubectl -n sensei get deploy "$app" -o jsonpath="{.metadata.annotations.sensei-dr/fence-replicas}")"
    [ -n "$r" ] && kubectl -n sensei scale deploy "$app" --replicas="$r" >/dev/null
  done

  freeze_at=$(date +%s)
  tstep "freeze: DOWNTIME STARTS"
  "$DRCTL" failback freeze >/dev/null
  dr_stop_now
  tstep "promoting home"
  promote_core 3
  tstep "switching DNS home and completing"
  "$DRCTL" failback dns >/dev/null
  "$DRCTL" failback complete >/dev/null
  unfence_now
  kubectl -n sensei patch cronjob dr-guard --type merge -p '{"spec":{"suspend":false}}' >/dev/null
  kubectl -n sensei create job --from=cronjob/dr-guard "dr-guard-cutover-$(date +%s)" >/dev/null # clears fenced flags
  tstep "waiting for sensei-prod and the public site"
  for _ in $(seq 1 90); do
    [ "$(public_health)" = '{"status":"healthy"}' ] \
      && [ "$(kubectl -n sensei get deploy sensei-prod-api -o jsonpath='{.status.availableReplicas}')" -ge 1 ] 2>/dev/null && break
    sleep 2
  done
  tstep "site healthy: $(public_health)  downtime $(( ($(date +%s) - freeze_at) / 60 ))m$(( ($(date +%s) - freeze_at) % 60 ))s"
  CUTOVER_DONE=1
  start_home_apps
  "$DRCTL" status | sed -n 1,3p
}

case "${1:-}" in
  stop-home-apps) stop_home_apps ;;
  start-home-apps) start_home_apps ;;
  rebuild-home) rebuild_home ;;
  lag) show_lag ;;
  promote) promote ;;
  cutover) cutover ;;
  *) sed -n "2,14p" "$0"; exit 2 ;;
esac
