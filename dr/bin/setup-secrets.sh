#!/usr/bin/env bash
# One-time (idempotent) setup of the DR secrets in AWS Secrets Manager:
#   sensei-dr/cloudflare  {apiToken, accountId, zoneId, tunnelId, tunnelToken}
#   sensei-dr/age-key     DR age private key (only with --age-key FILE)
# Reuses the external-dns Cloudflare API token from the repo (DNS:Edit is required for failover).
# The locally-managed tunnel "sensei-dr" is created through the API when the token has
# Tunnel:Edit; otherwise create it first with
#   cloudflared tunnel login && cloudflared tunnel create sensei-dr
# and this script builds the run token from ~/.cloudflared/<tunnel-id>.json.
#
# Usage: AWS_PROFILE=mike-sensei dr/bin/setup-secrets.sh [--age-key FILE] [--skip-cloudflare]
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$ROOT/age.key}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
DOMAIN="${DR_DOMAIN:-senseichess.com}"
TUNNEL_NAME=sensei-dr
AGE_FILE="" SKIP_CF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --age-key) AGE_FILE="$2"; shift 2 ;;
    --skip-cloudflare) SKIP_CF=1; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

put_secret() { # put_secret <name> <file> <description>
  if aws secretsmanager describe-secret --secret-id "$1" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --secret-id "$1" --secret-string "file://$2" >/dev/null
  else
    aws secretsmanager create-secret --name "$1" --description "$3" --secret-string "file://$2" >/dev/null
  fi
  echo "stored $1"
}

if [ -z "$SKIP_CF" ]; then
TOKEN="$(sops -d "$ROOT/kubernetes/apps/network/external-dns/app/secret.sops.yaml" | yq '.stringData."api-token"')"
cf() { # cf <method> <path> [json-body]
  curl -sf -X "$1" "https://api.cloudflare.com/client/v4$2" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' ${3:+--data "$3"}
}

ZONE_JSON="$(cf GET "/zones?name=$DOMAIN")"
ZONE_ID="$(jq -r '.result[0].id' <<<"$ZONE_JSON")"
ACCOUNT_ID="$(jq -r '.result[0].account.id' <<<"$ZONE_JSON")"

TUNNEL_ID="$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" | jq -r '.result[0].id // empty')"
if [ -z "$TUNNEL_ID" ]; then
  secret="$(openssl rand -base64 32)"
  if ! TUNNEL_ID="$(cf POST "/accounts/$ACCOUNT_ID/cfd_tunnel" \
      "$(jq -nc --arg n "$TUNNEL_NAME" --arg s "$secret" '{name:$n, tunnel_secret:$s, config_src:"local"}')" | jq -r .result.id)"; then
    echo "the API token cannot create tunnels; run: cloudflared tunnel login && cloudflared tunnel create $TUNNEL_NAME" >&2
    exit 1
  fi
  echo "created tunnel $TUNNEL_NAME ($TUNNEL_ID)"
else
  echo "tunnel $TUNNEL_NAME exists ($TUNNEL_ID)"
fi
CREDS="$HOME/.cloudflared/$TUNNEL_ID.json"
if [ -f "$CREDS" ]; then
  # run token = base64({"a": account, "t": tunnel, "s": secret})
  TUNNEL_TOKEN="$(jq -cj '{a: .AccountTag, t: .TunnelID, s: .TunnelSecret}' "$CREDS" | base64 | tr -d '\n')"
elif [ -n "${secret:-}" ]; then
  TUNNEL_TOKEN="$(jq -cjn --arg a "$ACCOUNT_ID" --arg t "$TUNNEL_ID" --arg s "$secret" '{a:$a, t:$t, s:$s}' | base64 | tr -d '\n')"
else
  TUNNEL_TOKEN="$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" | jq -r .result)" || {
    echo "no credentials for tunnel $TUNNEL_ID: expected $CREDS" >&2; exit 1; }
fi

jq -n --arg t "$TOKEN" --arg a "$ACCOUNT_ID" --arg z "$ZONE_ID" --arg i "$TUNNEL_ID" --arg k "$TUNNEL_TOKEN" \
  '{apiToken:$t, accountId:$a, zoneId:$z, tunnelId:$i, tunnelToken:$k}' >"$tmp/cf.json"
put_secret sensei-dr/cloudflare "$tmp/cf.json" "Cloudflare API token + DR tunnel for sensei DR"
fi

if [ -n "$AGE_FILE" ]; then
  grep -v '^#' "$AGE_FILE" >"$tmp/age"
  put_secret sensei-dr/age-key "$tmp/age" "DR age private key (decrypts kubernetes/dr and DR app secrets)"
fi
