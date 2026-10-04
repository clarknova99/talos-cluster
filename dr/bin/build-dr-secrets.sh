#!/usr/bin/env bash
# Regenerate kubernetes/dr/aws/secrets/cluster-secrets.sops.yaml: the subset of the home
# cluster-secrets that the DR cluster's manifests actually reference.
# Requires the home age key (./age.key or SOPS_AGE_KEY_FILE). See dr/PLAN.md §3.3.
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$ROOT/age.key}"

SRC=kubernetes/components/sops/cluster-secrets.sops.yaml
OUT=kubernetes/dr/aws/secrets/cluster-secrets.sops.yaml

# Directories synced by the DR cluster (keep in sync with kubernetes/dr/aws/apps/*.yaml).
DIRS=(
  kubernetes/apps/sensei/sensei-prod/api
  kubernetes/apps/sensei/sensei-prod/app
  kubernetes/apps/sensei/sensei-prod/worker
  kubernetes/apps/sensei/sensei-prod/admin
  kubernetes/apps/sensei/langfusev3/app
  kubernetes/apps/sensei/dittofeed/app
  kubernetes/apps/sensei/dittofeed/clickhouse
  kubernetes/apps/sensei/dittofeed/temporal
  kubernetes/apps/sensei/rybbit/app
  kubernetes/apps/sensei/rybbit/clickhouse
  kubernetes/apps/sensei/litellm/app
  kubernetes/apps/database/cloudnative-pg/app
  kubernetes/apps/database/clickhouse/app
  kubernetes/apps/database/dragonfly/app
  kubernetes/apps/database/dragonfly/cluster
  kubernetes/dr/aws/apps
)

# Variables referenced by those manifests (comments excluded).
mapfile -t WANT < <(
  grep -rhv '^\s*#' "${DIRS[@]}" --include='*.yaml' \
    | grep -oE '\$\{[A-Z0-9_]+\}' | tr -d '${}' | sort -u
)

decrypted="$(sops -d "$SRC")"
mapfile -t HAVE < <(yq '.stringData | keys | .[]' <<<"$decrypted")

# Referenced only by manifests that DR patches out (VolSync).
EXCLUDE=(VOLSYNC_KOPIA_PASSWORD)

keep=()
for v in "${WANT[@]}"; do
  [[ "$v" == DR_* ]] && continue   # substituted from the dr-vars ConfigMap, not secrets
  printf '%s\n' "${EXCLUDE[@]}" | grep -qx "$v" && continue
  if printf '%s\n' "${HAVE[@]}" | grep -qx "$v"; then keep+=("$v"); else echo "note: $v not in cluster-secrets (skipped)" >&2; fi
done

filter="$(printf '"%s",' "${keep[@]}")"
mkdir -p "$(dirname "$OUT")"
yq "
  .metadata.name = \"cluster-secrets\" |
  .metadata.namespace = \"flux-system\" |
  .stringData |= with_entries(select(.key as \$k | [${filter%,}] | contains([\$k])))
" <<<"$decrypted" > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
sops --encrypt --in-place "$OUT"
echo "wrote $OUT with ${#keep[@]} keys"
