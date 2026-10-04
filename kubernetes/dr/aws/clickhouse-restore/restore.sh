#!/bin/sh
# Restore the newest remote clickhouse-backup into a DR ClickHouse pod via its backup sidecar.
# Usage: restore.sh <namespace> <controller> <tables-glob>
# The sidecar runs `clickhouse-backup server` in DR (never `watch`), with the home S3 settings,
# so this only reads the home backups.
set -eu
ns="$1"; controller="$2"; tables="$3"

pod=""
until [ -n "$pod" ] && kubectl -n "$ns" exec "$pod" -c clickhouse-backup -- clickhouse-backup tables >/dev/null 2>&1; do
  echo "waiting for $ns/$controller clickhouse"
  sleep 15
  pod="$(kubectl -n "$ns" get pod -l "app.kubernetes.io/controller=$controller" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
done

latest="$(kubectl -n "$ns" exec "$pod" -c clickhouse-backup -- clickhouse-backup list remote \
  | grep -v broken | awk 'NF {print $1}' | tail -n 1)"
if [ -z "$latest" ]; then
  echo "no remote backups found for $ns/$controller" >&2
  exit 1
fi

echo "restoring $latest ($tables) into $ns/$pod"
kubectl -n "$ns" exec "$pod" -c clickhouse-backup -- \
  clickhouse-backup restore_remote --rm --tables="$tables" "$latest"
kubectl -n "$ns" exec "$pod" -c clickhouse-backup -- clickhouse-backup delete local "$latest" || true
echo "restore of $ns/$controller complete"
