#!/usr/bin/env bash
# sensei DR agent (systemd timer, every 30 s): applies the orchestrator's desired mode to the
# cluster, runs the failback freeze backup, and reports readiness to DynamoDB (item "instance").
set -uo pipefail
# shellcheck source=/dev/null
source /etc/sensei-dr.env
export AWS_DEFAULT_REGION="$AWS_REGION" KUBECONFIG=/etc/rancher/k3s/k3s.yaml PATH="/usr/local/bin:$PATH"
source /opt/sensei-dr/lib.sh
STATE_DIR=/var/lib/sensei-dr
mkdir -p "$STATE_DIR"
[ -f /var/lib/sensei-dr-bootstrapped ] || exit 0

desired="$(ddb_get dr desiredMode)"
applied="$(cm_get DR_MODE)"

# ---- 1. mode changes (drill -> failover, failover <-> maintenance) ------------------------------
if [ -n "$desired" ] && [ "$desired" != "$applied" ] && mode_vars "$desired" >/dev/null; then
  apply_mode_vars "$desired" "$(cm_get DR_RUN_ID)" "$(cm_get DR_SOURCE_SERVER)" "$(cm_get DR_TARGET_SERVER)"
  kubectl -n flux-system annotate --overwrite kustomization dr-apps reconcile.fluxcd.io/requestedAt="$(date +%s)" >/dev/null
  logger -t sensei-dr "mode $applied -> $desired"
  applied="$desired"
  rm -f "$STATE_DIR/freeze-backup"
fi

# ---- 2. failback freeze: once sensei-prod is down, switch WAL and take a final base backup -----
backup_status=""
if [ "$applied" = "maintenance" ]; then
  running="$(kubectl -n sensei get deploy -l 'app.kubernetes.io/instance in (sensei-prod-app,sensei-prod-api,sensei-prod-worker,sensei-prod-admin)' \
              -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null | grep -cv '^0\?$' || true)"
  if [ ! -f "$STATE_DIR/freeze-backup" ] && [ "$running" = "0" ]; then
    primary="$(kubectl -n database get cluster postgres16vector -o jsonpath='{.status.currentPrimary}')"
    kubectl -n database exec "$primary" -c postgres -- psql -qAt -c 'select pg_switch_wal()' >/dev/null
    name="dr-freeze-$(date -u +%Y%m%d%H%M%S)"
    kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${name}
  namespace: database
spec:
  method: barmanObjectStore
  cluster:
    name: postgres16vector
EOF
    echo "$name" >"$STATE_DIR/freeze-backup"
  fi
  if [ -f "$STATE_DIR/freeze-backup" ]; then
    name="$(cat "$STATE_DIR/freeze-backup")"
    backup_status="${name}:$(kubectl -n database get backup "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"
  else
    backup_status="waiting for sensei-prod to stop"
  fi
fi

# ---- 3. readiness ---------------------------------------------------------------------------------
pg_phase="$(kubectl -n database get cluster postgres16vector -o jsonpath='{.status.phase}' 2>/dev/null)"
avail() { kubectl -n "$1" get deploy "$2" -o jsonpath='{.status.availableReplicas}' 2>/dev/null; }
app_ip="$(kubectl -n sensei get svc sensei-prod-app -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
health=down
[ -n "$app_ip" ] && curl -sf -m 5 "http://${app_ip}:8000/health" >/dev/null && health=ok

ready=false
if [ "$pg_phase" = "Cluster in healthy state" ] && [ "${applied}" != "maintenance" ] && [ "$health" = ok ] \
   && [ "$(avail sensei sensei-prod-api)" -ge 1 ] 2>/dev/null && [ "$(avail network cloudflared-dr)" -ge 1 ] 2>/dev/null; then
  ready=true
fi

ks_total="$(kubectl -n flux-system get kustomizations --no-headers 2>/dev/null | wc -l)"
ks_ready="$(kubectl -n flux-system get kustomizations --no-headers 2>/dev/null | awk '$3=="True"' | wc -l)"
ch="$(kubectl -n dr-system get jobs -o jsonpath='{range .items[*]}{.metadata.name}={.status.succeeded}/{.status.failed} {end}' 2>/dev/null)"
if [ "$ready" = true ]; then phase=ready
elif [ "$applied" = maintenance ]; then phase=maintenance
elif [ "$pg_phase" != "Cluster in healthy state" ]; then phase=restoring
else phase=starting; fi

report ready="$ready" appliedMode="${applied:-none}" phase="$phase" \
  message="postgres: ${pg_phase:-pending}; app health: ${health}; flux ${ks_ready}/${ks_total} ready" \
  clickhouseRestore="${ch:-pending}" lastBackup="${backup_status:-none}"
