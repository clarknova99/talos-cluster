#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
kube() { kubectl --kubeconfig="${KUBECONFIG:?}" --request-timeout=30s -n "$NAMESPACE" "$@"; }

configure_client() {
    local host=${KUBERNETES_SERVICE_HOST:-} port=${KUBERNETES_SERVICE_PORT_HTTPS:-${KUBERNETES_SERVICE_PORT:-}}
    local account_dir=${SERVICE_ACCOUNT_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}
    [[ -n "$host" && -n "$port" ]] || die 'Missing Kubernetes API service environment; run this orchestrator in its Kubernetes Job.'
    [[ -r "$account_dir/ca.crt" && -s "$account_dir/ca.crt" && -r "$account_dir/token" && -s "$account_dir/token" ]] ||
        die 'Projected service-account CA/token files are missing or unreadable.'
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then host="[$host]"; fi
    KUBECONFIG=$(mktemp "${TMPDIR:-/tmp}/cnpg-kubeconfig.XXXXXX")
    export KUBECONFIG
    jq -n --arg server "https://$host:$port" --arg ca "$account_dir/ca.crt" \
        --arg token_file "$account_dir/token" --arg namespace "$NAMESPACE" '{
        apiVersion:"v1", kind:"Config",
        clusters:[{name:"in-cluster",cluster:{server:$server,"certificate-authority":$ca}}],
        users:[{name:"service-account",user:{tokenFile:$token_file}}],
        contexts:[{name:"in-cluster",context:{cluster:"in-cluster",user:"service-account",namespace:$namespace}}],
        "current-context":"in-cluster"
    }' > "$KUBECONFIG"
}

release_lock() {
    local exit_code=$? patch
    if [[ "${LOCK_HELD:-false}" == true ]]; then
        patch=$(jq -nc --arg uid "$POD_UID" '[
            {op:"test",path:"/spec/holderIdentity",value:$uid},
            {op:"replace",path:"/spec/holderIdentity",value:""}]')
        kube patch lease "$SOURCE_NAME" --type=json -p "$patch" >/dev/null ||
            printf 'Lease release failed; the next run must verify this pod has stopped.\n' >&2
    fi
    exit "$exit_code"
}

acquire_lock() {
    local lease holder holder_pod owner
    lease=$(kube get lease "$SOURCE_NAME" -o json)
    holder=$(jq -r '.spec.holderIdentity // ""' <<< "$lease")
    if [[ -n "$holder" ]]; then
        holder_pod=$(jq -er '.metadata.annotations["cnpg-backup/holder-pod"]' <<< "$lease")
        owner=$(kube get pod "$holder_pod" --ignore-not-found -o json)
        if [[ -n "$owner" ]] && jq -e --arg uid "$holder" '
            .metadata.uid == $uid and .status.phase != "Succeeded" and .status.phase != "Failed"
        ' <<< "$owner" >/dev/null; then
            die "Another orchestrator owns the Lease: $holder_pod. No time-based lock stealing is allowed."
        fi
    fi
    jq --arg uid "$POD_UID" --arg pod "$POD_NAME" '
        .spec.holderIdentity = $uid | .metadata.annotations["cnpg-backup/holder-pod"] = $pod
    ' <<< "$lease" | kube replace -f - >/dev/null
    LOCK_HELD=true
    trap release_lock EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

read_source() {
    SOURCE=$(kube get replicationsource "$SOURCE_NAME" -o json)
    jq -e --arg name "$SOURCE_NAME" '
        .spec.sourcePVC == $name and .spec.kopia.copyMethod == "Direct" and
        (.spec.trigger.schedule // "") == ""
    ' <<< "$SOURCE" >/dev/null || die 'ReplicationSource configuration changed; refusing to proceed.'
}

require_idle_source() {
    jq -e '
        .spec.paused == true and
        (any(.status.conditions[]?; .type == "Synchronizing" and .status == "True") | not) and
        (.spec.trigger.manual == "standby" or .spec.trigger.manual == .status.lastManualSync)
    ' <<< "$SOURCE" >/dev/null || die 'VolSync has an outstanding trigger; retained staging must not be overwritten.'
}

upload_completed() {
    jq -e --arg token "$BACKUP_TOKEN" '
        .spec.trigger.manual == $token and .status.lastManualSync == $token and
        .status.latestMoverStatus.result == "Successful" and
        any(.status.conditions[]?; .type == "Synchronizing" and .status == "False")
    ' <<< "$SOURCE" >/dev/null
}

check_claim() {
    jq -e --arg name "$SOURCE_NAME" '
        .metadata.labels["cnpg-backup/source"] == $name and
        .metadata.labels["cnpg-backup/lifecycle"] == "per-run" and
        .spec.storageClassName == "openebs-hostpath" and
        ((.metadata.ownerReferences // []) | length) == 0
    ' <<< "$CLAIM" >/dev/null || die 'Unmanaged or legacy staging PVC found; it will not be changed or deleted.'
}

check_worker() {
    jq -e --arg name "$SOURCE_NAME" --arg uid "$CLAIM_UID" '
        .metadata.labels["cnpg-backup/source"] == $name and
        .metadata.annotations["cnpg-backup/claim-uid"] == $uid
    ' <<< "$WORKER" >/dev/null || die 'Dump Job does not belong to this staging PVC.'
}

worker_completed() {
    jq -e 'any(.status.conditions[]?; .type == "Complete" and .status == "True")' <<< "$WORKER" >/dev/null
}

run_worker() {
    require_idle_source
    if [[ -n "$WORKER" ]]; then
        check_worker
        if jq -e 'any(.status.conditions[]?; .type == "Failed" and .status == "True")' <<< "$WORKER" >/dev/null; then
            kube delete job "$WORKER_NAME" --cascade=foreground --wait=true --timeout=10m
            WORKER=""
        fi
    fi
    if [[ -z "$WORKER" ]]; then
        kube create --dry-run=client -f "$SCRIPT_DIR/worker-job.yaml" -o json |
            jq --arg name "$WORKER_NAME" --arg source "$SOURCE_NAME" --arg cluster "$CLUSTER_NAME" \
                --arg namespace "$NAMESPACE" --arg uid "$CLAIM_UID" --arg token "$BACKUP_TOKEN" '
                .metadata.name = $name | .metadata.namespace = $namespace |
                .metadata.labels["cnpg-backup/source"] = $source |
                .metadata.annotations["cnpg-backup/claim-uid"] = $uid |
                .spec.template.metadata.labels["cnpg-backup/source"] = $source |
                .spec.template.spec.containers[0].env |= map(
                    if .name == "CLUSTER_NAME" then .value = $cluster
                    elif .name == "BACKUP_TOKEN" then .value = $token
                    elif .name == "PGHOST" then .value = ($cluster + "-rw." + $namespace + ".svc.cluster.local")
                    else . end) |
                .spec.template.spec.volumes |= map(
                    if .name == "staging" then .persistentVolumeClaim.claimName = $source
                    elif .name == "ca" then .secret.secretName = ($cluster + "-ca")
                    else . end)
            ' | kube create -f - >/dev/null
    fi
    printf 'Waiting for dump worker %s\n' "$WORKER_NAME"
    kube wait "job/$WORKER_NAME" --for=condition=Complete --timeout=130m
    WORKER=$(kube get job "$WORKER_NAME" -o json)
    check_worker
    worker_completed || die 'Dump worker did not complete; PVC and Job retained.'
}

cleanup_staging() {
    upload_completed || die 'No successful upload for this PVC; cleanup is forbidden.'
    kube patch replicationsource "$SOURCE_NAME" --type=merge -p '{"spec":{"paused":true}}' >/dev/null
    if [[ -n "$WORKER" ]]; then
        check_worker
        worker_completed || die 'Worker is not complete; refusing cleanup.'
        kube delete job "$WORKER_NAME" --cascade=foreground --wait=true --timeout=10m
    fi
    kube get pods -o json | jq -e --arg claim "$SOURCE_NAME" '
        all(.items[];
            .status.phase == "Succeeded" or .status.phase == "Failed" or
            (any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $claim) | not))
    ' >/dev/null || die 'A pod still uses staging; PVC retained for a later cleanup retry.'
    CLAIM=$(kube get pvc "$SOURCE_NAME" -o json)
    check_claim
    [[ "$(jq -r '.metadata.uid' <<< "$CLAIM")" == "$CLAIM_UID" ]] || die 'PVC identity changed; cleanup forbidden.'
    kube delete pvc "$SOURCE_NAME" --wait=true --timeout=10m
    printf 'Verified upload %s; staging PVC deleted.\n' "$BACKUP_TOKEN"
}

orchestrate() {
    : "${CLUSTER_NAME:?}" "${SOURCE_NAME:?}" "${NAMESPACE:?}" "${POD_UID:?}" "${POD_NAME:?}" "${STAGING_CAPACITY:?}"
    SCRIPT_DIR=${SCRIPT_DIR:-/scripts}
    UPLOAD_TIMEOUT=${UPLOAD_TIMEOUT:-2h}
    WORKER_NAME="$SOURCE_NAME-dump"
    configure_client
    acquire_lock
    read_source
    CLAIM=$(kube get pvc "$SOURCE_NAME" --ignore-not-found -o json)
    WORKER=$(kube get job "$WORKER_NAME" --ignore-not-found -o json)
    if [[ -z "$CLAIM" ]]; then
        [[ -z "$WORKER" ]] || die 'Dump Job exists without its PVC; operator review is required.'
        require_idle_source
        CLAIM=$(jq -n --arg name "$SOURCE_NAME" --arg namespace "$NAMESPACE" --arg capacity "$STAGING_CAPACITY" '{
            apiVersion:"v1", kind:"PersistentVolumeClaim",
            metadata:{name:$name, namespace:$namespace,
                labels:{"cnpg-backup/source":$name,"cnpg-backup/lifecycle":"per-run"}},
            spec:{accessModes:["ReadWriteOnce"], storageClassName:"openebs-hostpath",
                resources:{requests:{storage:$capacity}}}
        }' | kube create -f - -o json)
    fi
    check_claim
    CLAIM_UID=$(jq -er '.metadata.uid' <<< "$CLAIM")
    BACKUP_TOKEN="$CLUSTER_NAME-$CLAIM_UID"
    if upload_completed; then
        cleanup_staging
        return
    fi
    jq -e '.metadata.deletionTimestamp == null' <<< "$CLAIM" >/dev/null || die 'Staging PVC is being deleted before a verified upload.'
    if [[ "$(jq -r '.spec.trigger.manual' <<< "$SOURCE")" == "$BACKUP_TOKEN" ]]; then
        [[ -n "$WORKER" ]] || die 'Pending upload lost its dump Job; PVC retained for investigation.'
        check_worker
        worker_completed || die 'An upload was requested without a completed dump Job.'
        printf 'Resuming upload %s without rewriting dumps.\n' "$BACKUP_TOKEN"
    else
        run_worker
        read_source
        require_idle_source
    fi
    jq -nc --arg token "$BACKUP_TOKEN" --arg revision "$(jq -r '.metadata.resourceVersion' <<< "$SOURCE")" '
        {metadata:{resourceVersion:$revision},spec:{paused:false,trigger:{manual:$token}}}
    ' | kube patch replicationsource "$SOURCE_NAME" --type=merge --patch-file=/dev/stdin >/dev/null
    kube wait "replicationsource/$SOURCE_NAME" "--for=jsonpath={.status.lastManualSync}=$BACKUP_TOKEN" --timeout="$UPLOAD_TIMEOUT"
    kube wait "replicationsource/$SOURCE_NAME" \
        '--for=jsonpath={.status.conditions[?(@.type=="Synchronizing")].status}=False' --timeout=10m
    read_source
    cleanup_staging
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then orchestrate "$@"; fi
