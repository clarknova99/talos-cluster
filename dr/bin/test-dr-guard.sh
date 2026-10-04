#!/bin/sh
# Exercise kubernetes/apps/sensei/dr-guard/app/dr-guard.sh fence/unfence against the cluster in
# KUBECONFIG with DynamoDB stubbed (no heartbeat is sent, nothing is armed).
# Intended for the DR drill cluster:  dr/bin/drctl exec "$(cat dr/bin/test-dr-guard.sh)" with the
# guard script inlined, or run locally against any cluster with the same app names.
# Usage: test-dr-guard.sh <path-to-dr-guard.sh>
set -eu
GUARD="$1"
STUB_DIR="$(mktemp -d)"
STATE_FILE="$STUB_DIR/state"

# Fake `aws` CLI: serves the dr/home items from $STATE_FILE (state fenced approved).
cat >"$STUB_DIR/aws" <<'EOF'
#!/bin/sh
read -r state fenced approved <"$STATE_FILE"
case "$*" in
  *get-item*'"pk":{"S":"dr"}'*) printf '{"Item":{"state":{"S":"%s"}}}\n' "$state" ;;
  *get-item*'"pk":{"S":"home"}'*) printf '{"Item":{"fenced":{"BOOL":%s},"unfenceApproved":{"BOOL":%s}}}\n' "$fenced" "$approved" ;;
  *"SET fenced = :v"*) f="$(echo "$*" | grep -o 'BOOL":[a-z]*' | cut -d: -f2)"; echo "$state $f $approved" >"$STATE_FILE" ;;
  *"SET unfenceApproved = :v"*) a="$(echo "$*" | grep -o 'BOOL":[a-z]*' | cut -d: -f2)"; read -r s f _ <"$STATE_FILE"; echo "$s $f $a" >"$STATE_FILE" ;;
  *) : ;;
esac
EOF
chmod +x "$STUB_DIR/aws"
export PATH="$STUB_DIR:$PATH" STATE_FILE

replicas() { kubectl -n sensei get deploy sensei-prod-api -o jsonpath='{.spec.replicas}'; }
suspended() { kubectl -n flux-system get kustomization sensei-prod-api -o jsonpath='{.spec.suspend}'; }

before="$(replicas)"
echo "ACTIVE false false" >"$STATE_FILE"
sh "$GUARD"
[ "$(replicas)" = 0 ] && [ "$(suspended)" = true ] || { echo "FAIL: not fenced"; exit 1; }
echo "fenced ok (api replicas $before -> 0, ks suspended)"

echo "STANDBY true false" >"$STATE_FILE"
sh "$GUARD"
[ "$(replicas)" = 0 ] || { echo "FAIL: unfenced without approval"; exit 1; }
echo "stays fenced without approval ok"

echo "STANDBY true true" >"$STATE_FILE"
sh "$GUARD"
[ "$(replicas)" = "$before" ] && [ "$(suspended)" != true ] || { echo "FAIL: not unfenced"; exit 1; }
echo "unfenced ok (api replicas back to $(replicas))"
rm -rf "$STUB_DIR"
