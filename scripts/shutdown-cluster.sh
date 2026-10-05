#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export KUBECONFIG="${KUBECONFIG:-$ROOT_DIR/kubeconfig}"
export TALOSCONFIG="${TALOSCONFIG:-$ROOT_DIR/kubernetes/bootstrap/talos/clusterconfig/talosconfig}"
REQUEST_TIMEOUT=30s
WAIT_TIMEOUT=600s
BACKUP_WAIT_TIMEOUT=3600s
EXECUTE=false
STATE_DIR=""
RESTORE=false
ALLOW_CEPH_WARNINGS=false
ACKNOWLEDGE_VOLATILE_DATA_LOSS=false
MAX_BACKUP_AGE_SECONDS=129600
USE_EXISTING_BARMAN_BACKUPS=false
EXISTING_BARMAN_BACKUPS='[]'

usage() {
    printf '%s\n' \
        'Usage: bash scripts/shutdown-cluster.sh [--dry-run | --execute --state-dir PATH] [options]' \
        '       bash scripts/shutdown-cluster.sh --restore PATH' \
        '' \
        'Default: read-only preflight and shutdown plan. No cluster changes.' \
        '--execute requires a new recovery directory outside this repository and typed confirmation.' \
        '--allow-ceph-warnings acknowledges HEALTH_WARN, but never degraded PGs or missing OSDs.' \
        '--acknowledge-volatile-data-loss accepts loss of Dragonfly in-memory data.' \
        '--use-existing-barman-backups uses operator-validated recent Barman backups instead of new backups.' \
        '  Only matching CNPG logical-VolSync freshness checks are waived; all other checks remain.' \
        '--restore restores recorded settings after manual power-on; also requires confirmation.' \
        'Run from a local machine that will remain available while the cluster is down.' \
        'NAS, router, switch, and UPS shutdown remain manual.'
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }
kube() { kubectl --context "$CONTEXT" --request-timeout="$REQUEST_TIMEOUT" "$@"; }
cnpg() { kubectl cnpg --context "$CONTEXT" --request-timeout="$REQUEST_TIMEOUT" "$@"; }
talos() { talosctl -e "$1" -n "$1" "${@:2}"; }
ceph_cmd() { kube -n rook-ceph exec deployment/rook-ceph-tools -- ceph "$@"; }

require_clean_ceph() {
    jq -e '
        .health.status != "HEALTH_ERR" and
        .osdmap.num_osds == 5 and .osdmap.num_up_osds == 5 and .osdmap.num_in_osds == 5 and
        .pgmap.num_pgs > 0 and
        ([.pgmap.pgs_by_state[] | select(.state_name != "active+clean") | .count] | add // 0) == 0
    ' <<< "$1" >/dev/null || die 'Ceph must have 5 OSDs up/in and all placement groups active+clean.'
}

inventory_workloads() {
    kube get deployments,statefulsets -A -o json | jq '
        [.items[] | .metadata.name as $name | {
            kind: .kind, namespace: .metadata.namespace, name: .metadata.name,
            replicas: (.spec.replicas // 1), selector: .spec.selector,
            owners: [.metadata.ownerReferences[]?.kind],
            phase: (
                if .metadata.namespace == "flux-system" then
                    if .metadata.name == "flux-operator" then 10 else 20 end
                elif .metadata.namespace == "system-upgrade" or
                    .metadata.namespace == "actions-runner-system" or
                    (["reloader", "dragonfly-operator", "grafana-operator",
                                            "kube-prometheus-stack-operator", "volsync"] | index($name)) then 30
                elif .metadata.namespace == "rook-ceph" then
                    if .metadata.name == "rook-ceph-tools" then 0
                    elif .metadata.name == "rook-ceph-operator" then 80
                    elif .metadata.name == "ceph-csi-controller-manager" then 81
                    elif (.metadata.name | startswith("rook-ceph-mon-")) then 100
                    elif (.metadata.name | startswith("rook-ceph-osd-")) then 90
                    elif (.metadata.name | startswith("rook-ceph-mgr-")) then 95
                    else 85 end
                elif .metadata.namespace == "database" then
                    if .metadata.name == "cloudnative-pg" then 65 else 60 end
                elif .metadata.namespace == "kube-system" then
                    if .metadata.name == "minio" then 70 else 0 end
                elif .metadata.namespace == "network" or
                    .metadata.namespace == "cert-manager" or
                    .metadata.namespace == "openebs-system" then 0
                elif .metadata.namespace == "volsync-system" then
                    if .metadata.name == "kopia" then 70 else 0 end
                elif (.metadata.name | test("clickhouse|victoria-logs|^prometheus-|^alertmanager-")) then 60
                else 50 end
            )
        }] | sort_by(.phase, .namespace, .kind, .name)
    '
}

preflight() {
    local dependency nodes expected
    for dependency in kubectl talosctl jq; do
        command -v "$dependency" >/dev/null || die "Missing dependency: $dependency"
    done
    CONTEXT=$(kubectl config current-context)
    log "Kubernetes context: $CONTEXT"
    nodes=$(kube get nodes -o json)
    expected='{"earth":"192.168.3.214","jupiter":"192.168.3.219","mars":"192.168.3.102","mercury":"192.168.3.241","venus":"192.168.3.101"}'
    jq -e --argjson expected "$expected" '
        (.items | length) == 5 and all(.items[];
            .metadata.name as $name |
            $expected[$name] != null and
            ((.metadata.labels | has("node-role.kubernetes.io/control-plane")) ==
                (["earth", "mercury", "venus"] | index($name) != null)) and
            any(.status.addresses[]; .type == "InternalIP" and .address == $expected[$name]) and
            any(.status.conditions[]; .type == "Ready" and .status == "True")
        )
    ' <<< "$nodes" >/dev/null || die 'Expected all five home-kubernetes nodes Ready at their documented IPs.'
    NODE_STATE=$nodes
    CLUSTER_UID=$(kube get namespace kube-system -o jsonpath='{.metadata.uid}')
    CEPH_STATE=$(ceph_cmd status --format json)
    require_clean_ceph "$CEPH_STATE"
    log "Ceph: $(jq -r '.health.status' <<< "$CEPH_STATE")"
    ceph_cmd health detail
    CEPH_FLAGS=$(ceph_cmd osd dump --format json | jq '.flags | split(",")')
    WORKLOADS=$(inventory_workloads)
    SCHEDULES=$(kube get cronjobs.batch,scheduledbackups.postgresql.cnpg.io -A -o json | jq '
        [.items[] | {namespace:.metadata.namespace, name:.metadata.name,
            resource:(if .kind == "CronJob" then "cronjobs.batch" else "scheduledbackups.postgresql.cnpg.io" end),
            suspend:(.spec.suspend // false)}]')
    RUNNERS=$(kube get autoscalingrunnersets.actions.github.com -A -o json | jq '
        [.items[] | {namespace:.metadata.namespace, name:.metadata.name,
            minRunners:.spec.minRunners, maxRunners:.spec.maxRunners}]')
    CNPG=$(kube get clusters.postgresql.cnpg.io -A -o json | jq '
        [.items[] | {namespace:.metadata.namespace, name:.metadata.name,
            hibernation:.metadata.annotations["cnpg.io/hibernation"],
            lastSuccessfulBackup:.status.lastSuccessfulBackup}]')
    DRAGONFLIES=$(kube get dragonflies.dragonflydb.io -A -o json | jq '[.items[] | .metadata.name]')
    cnpg hibernate --help >/dev/null
    kube get hpa -A -o json | jq -e '.items | length == 0' >/dev/null ||
        die 'HPAs are present. This script does not manage autoscalers; review them before maintenance.'
    kube get statefulsets -A -o json | jq -e '
        all(.items[]; .spec.persistentVolumeClaimRetentionPolicy.whenScaled != "Delete")
    ' >/dev/null || die 'A StatefulSet deletes PVCs when scaled down. Review its retention policy first.'
    assert_idle
    if [[ "$USE_EXISTING_BARMAN_BACKUPS" == true ]]; then load_existing_barman_backups; fi
    assert_recent_backups
    local address
    for address in 192.168.3.102 192.168.3.219 192.168.3.214 192.168.3.101 192.168.3.241; do
        talos "$address" version --short
    done
    talosctl -e 192.168.3.241 -n 192.168.3.241,192.168.3.101,192.168.3.214 etcd status
    log 'Planned replica shutdown stages (phase 0 stays running until Talos shutdown):'
    jq -r '.[] | [.phase, .namespace, .kind, .name, .replicas] | @tsv' <<< "$WORKLOADS"
    if [[ "$USE_EXISTING_BARMAN_BACKUPS" == true ]]; then
        log 'Using operator-validated existing Barman backups; no new PostgreSQL backups will run:'
        jq -r '.[] | "  \(.metadata.namespace)/\(.spec.cluster.name): \(.metadata.name), completed \(.status.stoppedAt)"' \
            <<< "$EXISTING_BARMAN_BACKUPS"
        log 'WARNING: these backups predate shutdown; recovery beyond them depends on retained WAL.'
    else
        log 'After writers stop, require a new primary Barman backup before hibernating any active CNPG cluster:'
        jq -r '.[] | select(.hibernation != "on") | "  \(.namespace)/\(.name)"' <<< "$CNPG"
    fi
    if [[ "$DRAGONFLIES" != '[]' ]]; then
        log 'WARNING: all Dragonfly replicas will stop. In-memory sessions, queues, and other data may be lost.'
        log 'Execution requires --acknowledge-volatile-data-loss; export any important data first.'
    fi
}

assert_idle() {
    local busy
    busy=$(kube get jobs.batch -A -o json | jq -r '
        .items[] | select(.spec.suspend != true) |
        select(any(.status.conditions[]?; (.type == "Complete" or .type == "Failed") and .status == "True") | not) |
        "\(.metadata.namespace)/\(.metadata.name)"')
    [[ -z "$busy" ]] || die "Unfinished Jobs must complete before proceeding: $busy"
    busy=$(kube get backups.postgresql.cnpg.io -A -o json | jq -r '
        .items[] | select(.status.phase != "completed" and .status.phase != "failed") |
        "\(.metadata.namespace)/\(.metadata.name)"')
    [[ -z "$busy" ]] || die "PostgreSQL backups must finish before proceeding: $busy"
    busy=$(kube get replicationsources.volsync.backube -A -o json | jq -r '
        .items[] | select(any(.status.conditions[]?; .type == "Synchronizing" and .status == "True")) |
        "\(.metadata.namespace)/\(.metadata.name)"')
    [[ -z "$busy" ]] || die "VolSync transfers must finish before proceeding: $busy"
}

load_existing_barman_backups() {
    EXISTING_BARMAN_BACKUPS=$(kube get backups.postgresql.cnpg.io -A -o json | jq -e \
        --argjson clusters "$CNPG" --argjson age "$MAX_BACKUP_AGE_SECONDS" '
        .items as $backups |
        [$clusters[] | select(.hibernation != "on") | . as $cluster |
            ([$backups[] |
                select(.metadata.namespace == $cluster.namespace and .spec.cluster.name == $cluster.name) |
                select(.spec.method == "barmanObjectStore" and .status.phase == "completed") |
                ((.status.stoppedAt // "1970-01-01T00:00:00Z") | fromdateiso8601) as $timestamp |
                select(now - $timestamp <= $age and $timestamp - now <= 300)
            ] | sort_by(.status.stoppedAt) | last) //
            error("No recent completed Barman backup for " + $cluster.namespace + "/" + $cluster.name)
        ]') || die 'Existing Barman backup metadata is missing, failed, stale, or clock skewed.'
}

assert_recent_backups() {
    local stale exempt_sources='[]'
    if [[ "$USE_EXISTING_BARMAN_BACKUPS" == true ]]; then
        exempt_sources=$(jq '[.[] | .metadata.namespace + "/" + .spec.cluster.name + "-logical-backup"]' \
            <<< "$EXISTING_BARMAN_BACKUPS")
    fi
    stale=$(jq -r --argjson age "$MAX_BACKUP_AGE_SECONDS" '
        .[] | select(.hibernation != "on") |
        ((.lastSuccessfulBackup // "1970-01-01T00:00:00Z") | fromdateiso8601) as $timestamp |
        select(now - $timestamp > $age or $timestamp - now > 300) |
        "\(.namespace)/\(.name)"' <<< "$CNPG")
    [[ -z "$stale" ]] || die "PostgreSQL backups missing, over 36 hours old, or clock skewed: $stale"
    stale=$(kube get replicationsources.volsync.backube -A -o json | jq -r \
        --argjson age "$MAX_BACKUP_AGE_SECONDS" --argjson exempt "$exempt_sources" '
        .items[] | (.metadata.namespace + "/" + .metadata.name) as $source |
        select(($exempt | index($source)) == null) |
        ((.status.lastSyncTime // "1970-01-01T00:00:00Z") | fromdateiso8601) as $timestamp |
        select(now - $timestamp > $age or $timestamp - now > 300) |
        "\(.metadata.namespace)/\(.metadata.name)"')
    [[ -z "$stale" ]] || die "VolSync backups missing, over 36 hours old, or clock skewed: $stale"
}

confirm() {
    local answer
    [[ -t 0 ]] || die 'Confirmation requires an interactive terminal; unattended execution is disabled.'
    printf 'Type "%s home-kubernetes" to continue: ' "$1"
    read -r answer
    [[ "$answer" == "$1 home-kubernetes" ]] || die 'Confirmation did not match. No new changes made.'
}

stage() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$STATE_DIR/progress.log"
}

failure_notice() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        printf '\nStopped with exit code %s. No automatic rollback was attempted.\nRecovery state: %s\n' \
            "$exit_code" "$STATE_DIR" >&2
        printf 'Inspect the failure before using --restore with this directory. Do not cut power yet.\n' >&2
    fi
}

save_state() {
    [[ -n "$STATE_DIR" && ! -e "$STATE_DIR" ]] || die 'Use --state-dir with a NEW directory outside the repository.'
    local parent
    parent=$(cd -- "$(dirname -- "$STATE_DIR")" && pwd -P) || die 'Create the parent recovery directory first.'
    STATE_DIR="$parent/$(basename -- "$STATE_DIR")"
    case "$STATE_DIR/" in "$ROOT_DIR/"*) die 'Recovery data must not be stored in this Git repository.' ;; esac
    mkdir -m 700 -- "$STATE_DIR"
    jq -n --arg context "$CONTEXT" --arg uid "$CLUSTER_UID" \
        --arg kubeconfig "$KUBECONFIG" --arg talosconfig "$TALOSCONFIG" \
        --argjson nodes "$NODE_STATE" --argjson workloads "$WORKLOADS" \
        --argjson schedules "$SCHEDULES" --argjson runners "$RUNNERS" \
        --argjson cnpg "$CNPG" --argjson cephFlags "$CEPH_FLAGS" \
                --argjson useExistingBarmanBackups "$USE_EXISTING_BARMAN_BACKUPS" \
                --argjson existingBarmanBackups "$EXISTING_BARMAN_BACKUPS" \
        '{version:1, context:$context, uid:$uid, kubeconfig:$kubeconfig, talosconfig:$talosconfig,
          nodes:[$nodes.items[] | {name:.metadata.name, unschedulable:(.spec.unschedulable // false)}],
                    workloads:$workloads, schedules:$schedules, runners:$runners, cnpg:$cnpg, cephFlags:$cephFlags,
                    useExistingBarmanBackups:$useExistingBarmanBackups, existingBarmanBackups:$existingBarmanBackups}' \
        > "$STATE_DIR/state.json"
    trap failure_notice EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stage 'Saving etcd snapshot before any cluster mutations'
    talos 192.168.3.241 etcd snapshot "$STATE_DIR/etcd.snapshot"
    [[ -s "$STATE_DIR/etcd.snapshot" ]] || die 'etcd snapshot is empty.'
}

selector_for() {
    jq -er '
        [(.selector.matchLabels // {} | to_entries[] | "\(.key)=\(.value)"),
         (.selector.matchExpressions // [] | .[] |
            if .operator == "In" then "\(.key) in (\(.values | join(",")))"
            elif .operator == "NotIn" then "\(.key) notin (\(.values | join(",")))"
            elif .operator == "Exists" then .key
            elif .operator == "DoesNotExist" then "!\(.key)"
            else error("Unsupported selector operator") end)] | join(",") | select(length > 0)
    ' <<< "$1"
}

wait_no_pods() {
    local namespace=$1 selector=$2 pods
    pods=$(kube -n "$namespace" get pods -l "$selector" -o name)
    if [[ -n "$pods" ]]; then
        kube -n "$namespace" wait --for=delete pods -l "$selector" --timeout="$WAIT_TIMEOUT"
    fi
    pods=$(kube -n "$namespace" get pods -l "$selector" -o name)
    [[ -z "$pods" ]] || die "Pods reappeared in $namespace with selector $selector"
}

scale_phase() {
    local phase=$1 direction=$2 entries entry namespace name kind replicas selector
    entries=$(jq -c --argjson phase "$phase" '.[] | select(.phase == $phase)' <<< "$WORKLOADS")
    stage "$direction workload phase $phase"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        namespace=$(jq -r '.namespace' <<< "$entry")
        name=$(jq -r '.name' <<< "$entry")
        kind=$(jq -r '.kind' <<< "$entry")
        replicas=0
        if [[ "$direction" == restore ]]; then replicas=$(jq -r '.replicas' <<< "$entry"); fi
        kube -n "$namespace" scale "$kind/$name" --replicas="$replicas"
    done <<< "$entries"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        namespace=$(jq -r '.namespace' <<< "$entry")
        name=$(jq -r '.name' <<< "$entry")
        kind=$(jq -r '.kind' <<< "$entry")
        selector=$(selector_for "$entry")
        replicas=$(jq -r '.replicas' <<< "$entry")
        if [[ "$direction" == stop || "$replicas" == 0 ]]; then
            wait_no_pods "$namespace" "$selector"
        else
            kube -n "$namespace" wait "--for=jsonpath={.status.readyReplicas}=$replicas" \
                "$kind/$name" --timeout="$WAIT_TIMEOUT"
        fi
    done <<< "$entries"
}

set_schedules() {
    local direction=$1 entry namespace name resource suspend
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        namespace=$(jq -r '.namespace' <<< "$entry")
        name=$(jq -r '.name' <<< "$entry")
        resource=$(jq -r '.resource' <<< "$entry")
        suspend=true
        if [[ "$direction" == restore ]]; then suspend=$(jq -r '.suspend' <<< "$entry"); fi
        kube -n "$namespace" patch "$resource" "$name" --type=merge -p "{\"spec\":{\"suspend\":$suspend}}"
    done <<< "$(jq -c '.[]' <<< "$SCHEDULES")"
}

set_runners() {
    local direction=$1 entry namespace name patch
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        namespace=$(jq -r '.namespace' <<< "$entry")
        name=$(jq -r '.name' <<< "$entry")
        patch='{"spec":{"minRunners":0,"maxRunners":0}}'
        if [[ "$direction" == restore ]]; then
            patch=$(jq -c '{spec:{minRunners,maxRunners}}' <<< "$entry")
        fi
        kube -n "$namespace" patch autoscalingrunnersets.actions.github.com "$name" --type=merge -p "$patch"
        if [[ "$direction" == stop ]]; then
            wait_no_pods "$namespace" "actions.github.com/scale-set-name=$name,app.kubernetes.io/component=runner"
        fi
    done <<< "$(jq -c '.[]' <<< "$RUNNERS")"
}

backup_postgres() {
    local entry namespace name backup backup_name backup_file wait_result
    if [[ "$USE_EXISTING_BARMAN_BACKUPS" == true ]]; then
        while IFS= read -r backup; do
            [[ -n "$backup" ]] || continue
            namespace=$(jq -r '.metadata.namespace' <<< "$backup")
            name=$(jq -r '.spec.cluster.name' <<< "$backup")
            backup_name=$(jq -r '.metadata.name' <<< "$backup")
            backup_file="$STATE_DIR/cnpg-backup-$namespace-$name.json"
            printf '%s\n' "$backup" > "$backup_file"
            stage "Using operator-validated existing Barman backup $namespace/$backup_name; saved in $backup_file"
        done <<< "$(jq -c '.[]' <<< "$EXISTING_BARMAN_BACKUPS")"
        return
    fi
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        namespace=$(jq -r '.namespace' <<< "$entry")
        name=$(jq -r '.name' <<< "$entry")
        stage "Creating final primary Barman backup for $namespace/$name"
        backup=$(jq -n --arg namespace "$namespace" --arg name "$name" '{
            apiVersion:"postgresql.cnpg.io/v1", kind:"Backup",
            metadata:{namespace:$namespace, generateName:($name + "-pre-shutdown-")},
            spec:{cluster:{name:$name}, method:"barmanObjectStore", target:"primary"}
        }' | kube -n "$namespace" create -f - -o json)
        backup_name=$(jq -er '.metadata.name' <<< "$backup")
        backup_file="$STATE_DIR/cnpg-backup-$namespace-$name.json"
        printf '%s\n' "$backup" > "$backup_file"
        stage "Waiting for $namespace/$backup_name to complete (timeout $BACKUP_WAIT_TIMEOUT)"
        wait_result=0
        kube -n "$namespace" wait --for=jsonpath='{.status.phase}'=completed \
            "backups.postgresql.cnpg.io/$backup_name" --timeout="$BACKUP_WAIT_TIMEOUT" || wait_result=$?
        backup=$(kube -n "$namespace" get backups.postgresql.cnpg.io "$backup_name" -o json)
        printf '%s\n' "$backup" > "$backup_file"
        if [[ "$wait_result" -ne 0 ]] || ! jq -e '.status.phase == "completed"' <<< "$backup" >/dev/null; then
            die "Final PostgreSQL backup $namespace/$backup_name did not complete; inspect $backup_file. Keep power on; CNPG has not been hibernated."
        fi
        stage "Final backup completed for $namespace/$name; recovery details saved in $backup_file"
    done <<< "$(jq -c '.[] | select(.hibernation != "on")' <<< "$CNPG")"
}

set_postgres() {
    local direction=$1 entry namespace name current_hibernation
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        namespace=$(jq -r '.namespace' <<< "$entry")
        name=$(jq -r '.name' <<< "$entry")
        if [[ "$direction" == stop ]]; then
            cnpg hibernate on "$name" -n "$namespace"
            kube -n "$namespace" wait --for=condition=cnpg.io/hibernation=True \
                clusters.postgresql.cnpg.io "$name" --timeout="$WAIT_TIMEOUT"
            wait_no_pods "$namespace" "cnpg.io/cluster=$name"
        else
            current_hibernation=$(kube -n "$namespace" get clusters.postgresql.cnpg.io "$name" -o json |
                jq -r '.metadata.annotations["cnpg.io/hibernation"] // "off"')
            if [[ "$current_hibernation" == on ]]; then
                cnpg hibernate off "$name" -n "$namespace"
            fi
            kube -n "$namespace" wait --for=condition=Ready clusters.postgresql.cnpg.io "$name" --timeout="$WAIT_TIMEOUT"
        fi
    done <<< "$(jq -c '.[] | select(.hibernation != "on")' <<< "$CNPG")"
}

require_no_storage_clients() {
    local clients attachments
    clients=$(kube get pods -A -o json | jq -r '
        .items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed") |
        select(any(.spec.volumes[]?; .persistentVolumeClaim != null or .nfs != null or .csi != null or .ephemeral != null)) |
        "\(.metadata.namespace)/\(.metadata.name)"')
    [[ -z "$clients" ]] || die "Storage consumers remain; Ceph will NOT be stopped: $clients"
    attachments=$(kube get volumeattachments.storage.k8s.io -o name)
    if [[ -n "$attachments" ]]; then
        kube wait --for=delete volumeattachments.storage.k8s.io --all --timeout="$WAIT_TIMEOUT"
    fi
    attachments=$(kube get volumeattachments.storage.k8s.io -o name)
    [[ -z "$attachments" ]] || die 'VolumeAttachments remain; investigate unmounts before stopping Ceph.'
}

shutdown_cluster() {
    [[ "$ALLOW_CEPH_WARNINGS" == true || "$(jq -r '.health.status' <<< "$CEPH_STATE")" == HEALTH_OK ]] ||
        die 'Review Ceph health warnings first; --allow-ceph-warnings is an explicit acknowledgment.'
    [[ "$DRAGONFLIES" == '[]' || "$ACKNOWLEDGE_VOLATILE_DATA_LOSS" == true ]] ||
        die 'Dragonfly data is volatile. Export important data, then explicitly acknowledge potential loss.'
    log 'Confirm that backups are recoverable outside the cluster and external Ceph/NFS clients are stopped.'
    log 'Stop external PostgreSQL writers and keep them stopped through the final backups and shutdown.'
    log 'This stops applications, databases, Ceph, and all five Talos nodes. It does NOT power off the NAS or UPS.'
    confirm SHUTDOWN
    save_state
    scale_phase 10 stop
    scale_phase 20 stop
    stage 'Suspending schedules and draining GitHub runners'
    set_schedules stop
    set_runners stop
    scale_phase 30 stop
    assert_idle
    scale_phase 50 stop
    if [[ "$USE_EXISTING_BARMAN_BACKUPS" == true ]]; then
        stage 'Recording existing Barman recovery metadata; no new PostgreSQL backups requested'
    else
        stage 'Backing up PostgreSQL after application writers stop, with CNPG and MinIO still running'
    fi
    backup_postgres
    stage 'Hibernating PostgreSQL while its operator and storage are still available'
    set_postgres stop
    scale_phase 60 stop
    scale_phase 65 stop
    scale_phase 70 stop
    require_no_storage_clients
    require_clean_ceph "$(ceph_cmd status --format json)"
    stage 'Setting Ceph noout; stopping Rook and CSI operators before Ceph daemons'
    ceph_cmd osd set noout
    scale_phase 80 stop
    scale_phase 81 stop
    scale_phase 85 stop
    require_no_storage_clients
    scale_phase 90 stop
    scale_phase 95 stop
    scale_phase 100 stop
    stage 'Storage is stopped. Requesting Talos shutdown: workers first, control planes last'
    local address
    for address in 192.168.3.102 192.168.3.219 192.168.3.214 192.168.3.101 192.168.3.241; do
        talos "$address" shutdown --force --wait=false
        stage "Shutdown accepted by $address; physical power-off still needs verification"
    done
    stage 'All shutdown requests accepted. Verify all five machines are OFF, then shut down NAS, networking, and UPS.'
}

restore_cluster() {
    local saved phase
    [[ -f "$STATE_DIR/state.json" ]] || die 'Recovery state.json not found.'
    saved=$(jq -e 'select(.version == 1)' "$STATE_DIR/state.json")
    CONTEXT=$(jq -r '.context' <<< "$saved")
    KUBECONFIG=$(jq -r '.kubeconfig' <<< "$saved")
    TALOSCONFIG=$(jq -r '.talosconfig' <<< "$saved")
    [[ "$(kube get namespace kube-system -o jsonpath='{.metadata.uid}')" == "$(jq -r '.uid' <<< "$saved")" ]] ||
        die 'Cluster identity does not match the recovery state.'
    WORKLOADS=$(jq '.workloads' <<< "$saved")
    SCHEDULES=$(jq '.schedules' <<< "$saved")
    RUNNERS=$(jq '.runners' <<< "$saved")
    CNPG=$(jq '.cnpg' <<< "$saved")
    log 'Power on networking, NAS, and all five nodes first. Verify NAS exports and stable power.'
    log 'This also supports recovery from a partial shutdown; inspect progress.log before proceeding.'
    confirm RESTORE
    trap failure_notice EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    kube wait --for=condition=Ready nodes --all --timeout="$WAIT_TIMEOUT"
    for phase in 100 95 90 85 81 80; do scale_phase "$phase" restore; done
    require_clean_ceph "$(ceph_cmd status --format json)"
    if jq -e '.cephFlags | index("noout") == null' <<< "$saved" >/dev/null; then
        ceph_cmd osd unset noout
    fi
    for phase in 70 65 60; do scale_phase "$phase" restore; done
    set_postgres restore
    stage 'Databases are running. Verify data and import any separately exported Dragonfly data before resuming writers.'
    log 'Use another terminal for any data restoration. Applications and schedules remain stopped after a full shutdown.'
    confirm START-APPLICATIONS
    scale_phase 50 restore
    scale_phase 30 restore
    set_runners restore
    set_schedules restore
    scale_phase 20 restore
    scale_phase 10 restore
    stage 'Recorded replicas and schedules restored. Check Flux, databases, applications, and the next backups.'
}

main() {
    local modes=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) usage; return ;;
            --dry-run) EXECUTE=false; modes=$((modes + 1)) ;;
            --execute) EXECUTE=true; modes=$((modes + 1)) ;;
            --allow-ceph-warnings) ALLOW_CEPH_WARNINGS=true ;;
            --acknowledge-volatile-data-loss) ACKNOWLEDGE_VOLATILE_DATA_LOSS=true ;;
            --use-existing-barman-backups) USE_EXISTING_BARMAN_BACKUPS=true ;;
            --restore)
                [[ $# -ge 2 && -n "$2" ]] || die '--restore needs a recovery directory.'
                [[ -z "$STATE_DIR" ]] || die 'Specify only one recovery directory.'
                RESTORE=true
                modes=$((modes + 1))
                STATE_DIR=$2
                shift
                ;;
            --state-dir)
                [[ $# -ge 2 && -n "$2" ]] || die '--state-dir needs a path.'
                [[ -z "$STATE_DIR" ]] || die 'Specify only one recovery directory.'
                STATE_DIR=$2
                shift
                ;;
            *) die "Unknown argument: $1" ;;
        esac
        shift
    done
    [[ "$modes" -le 1 ]] || die 'Choose only one mode: --dry-run, --execute, or --restore.'
    if [[ "$RESTORE" == true ]]; then
        [[ "$EXECUTE" == false ]] || die '--restore and --execute cannot be combined.'
        restore_cluster
        return
    fi
    preflight
    if [[ "$EXECUTE" == false ]]; then
        log 'Read-only preflight complete. No cluster changes made.'
        return
    fi
    shutdown_cluster
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
