#!/usr/bin/env bash
# Home-side failback steps (dr/FAILBACK-CHECKLIST.md). Called by `drctl failback <step>`.
# Each step checks its preconditions and refuses to run when it is not safe.
#
#   stop-home-apps    stop the other home apps that use postgres16vector (recorded for restart)
#   rebuild-home      delete the stale home postgres16vector and recreate it as a replica of the
#                     AWS DR archive (site keeps serving from AWS meanwhile)
#   lag               how far the home replica trails AWS
#   promote           promote the home replica (after `drctl failback freeze`)
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

promote() {
  local status b
  status="$(dr_json)"
  [ "$(jq -r '.dr.desiredMode' <<<"$status")" = maintenance ] || die "freeze DR first: drctl failback freeze"
  [ "$(jq -r '.instance.appliedMode' <<<"$status")" = maintenance ] || die "DR has not applied maintenance mode yet"
  [ "$(psql_home -c 'select pg_is_in_recovery()')" = t ] || die "home $CLUSTER is not a replica (already promoted?)"
  step "waiting for the home replica to replay the last DR WAL"
  for _ in $(seq 1 40); do
    b="$(lag)"
    [ "${b:-1}" -le 0 ] && break
    echo "  ${b} bytes behind"; sleep 15
  done
  [ "${b:-1}" -le 0 ] || die "home did not catch up (still ${b} bytes behind); check WAL archiving on DR"
  echo "caught up"

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
  step "waiting for promotion"
  for _ in $(seq 1 60); do
    [ "$(psql_home -c 'select pg_is_in_recovery()' 2>/dev/null)" = f ] && { echo "home $CLUSTER is primary"; break; }
    sleep 5
  done
  [ "$(psql_home -c 'select pg_is_in_recovery()')" = f ] || die "not promoted yet; check: kubectl -n $NS get cluster $CLUSTER"
  kubectl -n "$NS" get cluster "$CLUSTER"
  echo "next: drctl failback dns && drctl failback complete && drctl failback start-home-apps"
}

case "${1:-}" in
  stop-home-apps) stop_home_apps ;;
  start-home-apps) start_home_apps ;;
  rebuild-home) rebuild_home ;;
  lag) show_lag ;;
  promote) promote ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
