#!/bin/sh
# Home side of the sensei AWS DR (dr/PLAN.md §3.2), every minute:
#  1. heartbeat -> DynamoDB sensei-dr (item "home")
#  2. DR state ACTIVE/FAILBACK -> fence home: suspend Flux + scale sensei-prod/dittofeed to 0
#  3. state back to STANDBY/DRILL and `drctl failback complete` approved -> unfence
set -eu
TABLE=sensei-dr
APPS="sensei-prod-api sensei-prod-app sensei-prod-worker sensei-prod-admin dittofeed dittofeed-temporal"
ANN=sensei-dr/fence-replicas

ddb_item() {
  aws dynamodb get-item --table-name "$TABLE" --consistent-read --key "{\"pk\":{\"S\":\"$1\"}}" --output json
}
set_home() { # set_home <attr> <BOOL value>
  aws dynamodb update-item --table-name "$TABLE" --key '{"pk":{"S":"home"}}' \
    --update-expression "SET $1 = :v" --expression-attribute-values "{\":v\":{\"BOOL\":$2}}" >/dev/null
}

aws dynamodb update-item --table-name "$TABLE" --key '{"pk":{"S":"home"}}' \
  --update-expression "SET lastHeartbeat = :t" \
  --expression-attribute-values "{\":t\":{\"N\":\"$(date +%s)\"}}" >/dev/null

state="$(ddb_item dr | jq -r '.Item.state.S // "STANDBY"')"
home="$(ddb_item home)"
fenced="$(echo "$home" | jq -r '.Item.fenced.BOOL // false')"
approved="$(echo "$home" | jq -r '.Item.unfenceApproved.BOOL // false')"

fence() {
  for app in $APPS; do
    kubectl -n flux-system patch kustomization "$app" --type merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
    kubectl -n sensei patch helmrelease "$app" --type merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
    replicas="$(kubectl -n sensei get deploy "$app" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || continue
    saved="$(kubectl -n sensei get deploy "$app" -o jsonpath="{.metadata.annotations.sensei-dr/fence-replicas}")"
    [ -n "$saved" ] || kubectl -n sensei annotate deploy "$app" "$ANN=$replicas" >/dev/null
    kubectl -n sensei scale deploy "$app" --replicas=0 >/dev/null
  done
  for cj in $(kubectl -n sensei get cronjob -o name | grep '/sensei-prod-'); do
    kubectl -n sensei patch "$cj" --type merge -p '{"spec":{"suspend":true}}' >/dev/null
  done
  [ "$fenced" = true ] || { set_home fenced true; echo "FENCED home sensei-prod (DR state $state)"; }
}

unfence() {
  for app in $APPS; do
    saved="$(kubectl -n sensei get deploy "$app" -o jsonpath="{.metadata.annotations.sensei-dr/fence-replicas}" 2>/dev/null)" || saved=""
    if [ -n "$saved" ]; then
      kubectl -n sensei scale deploy "$app" --replicas="$saved" >/dev/null
      kubectl -n sensei annotate deploy "$app" "$ANN-" >/dev/null
    fi
  done
  for cj in $(kubectl -n sensei get cronjob -o name | grep '/sensei-prod-'); do
    kubectl -n sensei patch "$cj" --type merge -p '{"spec":{"suspend":false}}' >/dev/null
  done
  for app in $APPS; do
    kubectl -n sensei patch helmrelease "$app" --type merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
    kubectl -n flux-system patch kustomization "$app" --type merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
  done
  set_home fenced false
  set_home unfenceApproved false
  echo "UNFENCED home sensei-prod"
}

case "$state" in
  ACTIVE|FAILBACK) fence ;;
  *) if [ "$fenced" = true ] && [ "$approved" = true ]; then unfence; fi ;;
esac
echo "heartbeat ok state=$state fenced=$fenced"
