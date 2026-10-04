#!/usr/bin/env bash
# One-time (idempotent) bootstrap of the sensei DR instance: k3s + Flux + DR secrets/vars.
# Runs as systemd unit sensei-dr-bootstrap; config comes from /etc/sensei-dr.env (CDK user-data).
set -euo pipefail
# shellcheck source=/dev/null
source /etc/sensei-dr.env
export AWS_DEFAULT_REGION="$AWS_REGION" KUBECONFIG=/etc/rancher/k3s/k3s.yaml PATH="/usr/local/bin:$PATH"
DIR=/opt/sensei-dr
source "$DIR/lib.sh"

report phase=bootstrap message="installing packages"
dnf install -y -q jq git >/dev/null

# ---- run identity / Postgres source + target --------------------------------------------------
RUN_ID="$(ddb_get dr runId)"
[ -n "$RUN_ID" ] || RUN_ID="$(date -u +%Y%m%d%H%M)"
TARGET_SERVER="postgres16vector-dr-${RUN_ID}"

SOURCE_SERVER="$(aws ssm get-parameter --name /sensei-dr/source-server --query Parameter.Value --output text 2>/dev/null || echo auto)"
if [ "$SOURCE_SERVER" = "auto" ]; then
  # Pick the home serverName whose newest WAL segment is most recent.
  best="" best_ts=""
  for p in $(aws s3api list-objects-v2 --bucket "$CNPG_BUCKET" --delimiter / --query 'CommonPrefixes[].Prefix' --output text \
               | tr '\t' '\n' | grep -E '^postgres16vector-v[0-9]+/$'); do
    seg="$(aws s3api list-objects-v2 --bucket "$CNPG_BUCKET" --prefix "${p}wals/" --delimiter / \
             --query 'CommonPrefixes[].Prefix' --output text | tr '\t' '\n' | grep -v None | sort | tail -n1)"
    [ -n "$seg" ] || continue
    ts="$(aws s3api list-objects-v2 --bucket "$CNPG_BUCKET" --prefix "$seg" --query 'max_by(Contents,&LastModified).LastModified' --output text)"
    if [[ -z "$best_ts" || "$ts" > "$best_ts" ]]; then best="${p%/}" best_ts="$ts"; fi
  done
  SOURCE_SERVER="$best"
fi
[ -n "$SOURCE_SERVER" ] || { report phase=error message="no postgres16vector-v* backups found in s3://$CNPG_BUCKET"; exit 1; }
report phase=bootstrap runId="$RUN_ID" serverName="$TARGET_SERVER" sourceServer="$SOURCE_SERVER" \
  instanceId="$(imds instance-id)" message="installing k3s"

# ---- k3s -----------------------------------------------------------------------------------------
if ! systemctl is-active -q k3s; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable \
    INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --write-kubeconfig-mode 0644" sh -
fi
until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do sleep 5; done

# ---- flux ---------------------------------------------------------------------------------------
report phase=bootstrap message="installing flux"
if ! command -v flux >/dev/null || ! flux version --client | grep -q "$FLUX_VERSION"; then
  curl -sfL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin flux
fi
flux install --version="v${FLUX_VERSION}" >/dev/null

# ---- secrets + vars ---------------------------------------------------------------------------
kubectl create namespace network --dry-run=client -o yaml | kubectl apply -f -
aws secretsmanager get-secret-value --secret-id "$AGE_SECRET" --query SecretString --output text \
  | kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=/dev/stdin --dry-run=client -o yaml \
  | kubectl apply -f -
aws secretsmanager get-secret-value --secret-id "$CF_SECRET" --query SecretString --output text | jq -r .tunnelToken \
  | kubectl -n network create secret generic cloudflared-dr-token --from-file=token=/dev/stdin --dry-run=client -o yaml \
  | kubectl apply -f -

MODE="$(ddb_get dr desiredMode)"
[ -n "$MODE" ] || MODE=drill
apply_mode_vars "$MODE" "$RUN_ID" "$SOURCE_SERVER" "$TARGET_SERVER"

# ---- flux sources + root kustomizations --------------------------------------------------------
BRANCH="$(aws ssm get-parameter --name /sensei-dr/git-branch --query Parameter.Value --output text)"
kubectl apply -f - <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 5m
  url: ${GIT_URL}
  ref:
    branch: ${BRANCH}
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: dr-platform
  namespace: flux-system
spec:
  interval: 30m
  path: ./kubernetes/dr/aws/platform
  prune: true
  wait: true
  timeout: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: dr-secrets
  namespace: flux-system
spec:
  interval: 30m
  path: ./kubernetes/dr/aws/secrets
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: dr-apps
  namespace: flux-system
spec:
  interval: 10m
  path: ./kubernetes/dr/aws/apps
  prune: true
  dependsOn:
    - name: dr-platform
    - name: dr-secrets
  sourceRef:
    kind: GitRepository
    name: flux-system
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: dr-vars
EOF

report phase=restoring message="flux applied (branch ${BRANCH}); restoring postgres from ${SOURCE_SERVER}"
systemctl enable --now sensei-dr-agent.timer
touch /var/lib/sensei-dr-bootstrapped
