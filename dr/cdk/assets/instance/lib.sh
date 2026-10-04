# shellcheck shell=bash
# Shared helpers for bootstrap.sh and dr-agent.sh (sourced; expects /etc/sensei-dr.env loaded).

imds() {
  local t
  t="$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
  curl -s -H "X-aws-ec2-metadata-token: $t" "http://169.254.169.254/latest/meta-data/$1"
}

# ddb_get <pk> <attribute>  -> string value or empty
ddb_get() {
  aws dynamodb get-item --table-name "$DR_TABLE" --consistent-read --key "{\"pk\":{\"S\":\"$1\"}}" \
    --output json | jq -r --arg a "$2" '.Item[$a] | if . == null then "" else (.S // .N // (.BOOL|tostring)) end'
}

# report key=value ...  -> merges attributes into the "instance" item (ready=true/false stored as BOOL)
report() {
  local names='{}' values='{}' sets=() k v i=0
  for kv in "$@" updatedAt="$(date +%s)"; do
    k="${kv%%=*}" v="${kv#*=}"
    names="$(jq -c --arg n "#k$i" --arg k "$k" '. + {($n): $k}' <<<"$names")"
    case "$k:$v" in
      ready:true|ready:false) values="$(jq -c --arg n ":v$i" --argjson b "$v" '. + {($n): {BOOL: $b}}' <<<"$values")" ;;
      updatedAt:*) values="$(jq -c --arg n ":v$i" --arg v "$v" '. + {($n): {N: $v}}' <<<"$values")" ;;
      *) values="$(jq -c --arg n ":v$i" --arg v "$v" '. + {($n): {S: $v}}' <<<"$values")" ;;
    esac
    sets+=("#k$i = :v$i")
    i=$((i + 1))
  done
  aws dynamodb update-item --table-name "$DR_TABLE" --key '{"pk":{"S":"instance"}}' \
    --update-expression "SET $(IFS=,; echo "${sets[*]}")" \
    --expression-attribute-names "$names" --expression-attribute-values "$values" >/dev/null
  logger -t sensei-dr "report $*"
}

# Replica counts / CronJob suspension per mode. Mirrors MODES in dr/bin/validate-dr-tree.py.
mode_vars() {
  case "$1" in
    drill)       echo "DR_APP_REPLICAS=1 DR_API_REPLICAS=2 DR_ADMIN_REPLICAS=1 DR_WORKER_REPLICAS=0 DR_DITTOFEED_REPLICAS=0 DR_CRON_SUSPEND=true" ;;
    failover)    echo "DR_APP_REPLICAS=1 DR_API_REPLICAS=2 DR_ADMIN_REPLICAS=1 DR_WORKER_REPLICAS=2 DR_DITTOFEED_REPLICAS=1 DR_CRON_SUSPEND=false" ;;
    maintenance) echo "DR_APP_REPLICAS=0 DR_API_REPLICAS=0 DR_ADMIN_REPLICAS=0 DR_WORKER_REPLICAS=0 DR_DITTOFEED_REPLICAS=0 DR_CRON_SUSPEND=true" ;;
    *) return 1 ;;
  esac
}

# apply_mode_vars <mode> <runId> <sourceServer> <targetServer>
apply_mode_vars() {
  local args=(--from-literal=DR_MODE="$1" --from-literal=DR_RUN_ID="$2"
              --from-literal=DR_SOURCE_SERVER="$3" --from-literal=DR_TARGET_SERVER="$4")
  for kv in $(mode_vars "$1"); do args+=(--from-literal="$kv"); done
  kubectl -n flux-system create configmap dr-vars "${args[@]}" --dry-run=client -o yaml | kubectl apply -f -
}

cm_get() {
  kubectl -n flux-system get configmap dr-vars -o "jsonpath={.data.$1}" 2>/dev/null
}
