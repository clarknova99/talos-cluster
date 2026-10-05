#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source scripts/shutdown-cluster.sh

TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
CALLS="$TEST_DIR/calls"
touch "$CALLS"
CONTEXT=test-context
CLUSTER_UID=test-cluster
NODE_STATE='{"items":[]}'
CEPH_STATE='{"health":{"status":"HEALTH_OK"},"osdmap":{"num_osds":5,"num_up_osds":5,"num_in_osds":5},"pgmap":{"num_pgs":393,"pgs_by_state":[{"state_name":"active+clean","count":393}]}}'
CEPH_FLAGS='[]'
DRAGONFLIES='[]'
CNPG='[{"namespace":"database","name":"postgres16","hibernation":null},{"namespace":"database","name":"postgres16vector","hibernation":null},{"namespace":"database","name":"already-asleep","hibernation":"on"}]'
SCHEDULES='[{"namespace":"sensei","name":"daily","resource":"cronjobs.batch","suspend":false},{"namespace":"sensei","name":"paused","resource":"cronjobs.batch","suspend":true}]'
RUNNERS='[{"namespace":"actions-runner-system","name":"runner","minRunners":3,"maxRunners":6}]'
WORKLOADS=$(jq -n '[10,20,30,50,60,65,70,80,81,85,90,95,100] | map({
    phase:., namespace:"test", kind:"Deployment", name:("phase-" + tostring), replicas:3,
    selector:{matchLabels:{app:("phase-" + tostring)}}})')
STATE_DIR="$TEST_DIR/recovery"
STORAGE_CLIENTS='{"items":[]}'
JOBS='{"items":[]}'
BACKUPS='{"items":[]}'
VOLSYNC_SOURCES='{"items":[]}'
BACKUP_WAIT_FAILURE=""
BACKUP_PHASE=completed
LIVE_HIBERNATION=on

record() { printf '%s\n' "$*" >> "$CALLS"; }
kubectl() { die 'Tests must never invoke real kubectl.'; }
talosctl() { die 'Tests must never invoke real talosctl.'; }
log() { record "LOG $*"; }
stage() { record "STAGE $*"; }
confirm() { record "CONFIRM $*"; }
failure_notice() {
    if [[ "${PRESERVE_TEST_DIR:-false}" != true ]]; then rm -rf -- "$TEST_DIR"; fi
}

kube() {
    record "KUBE $*"
    case "$*" in
        'get namespace kube-system '*) printf '%s' "$CLUSTER_UID" ;;
        'get pods -A -o json') printf '%s' "$STORAGE_CLIENTS" ;;
        'get jobs.batch -A -o json') printf '%s' "$JOBS" ;;
        'get backups.postgresql.cnpg.io -A -o json') printf '%s' "$BACKUPS" ;;
        'get replicationsources.volsync.backube -A -o json') printf '%s' "$VOLSYNC_SOURCES" ;;
        'get volumeattachments.storage.k8s.io -o name') : ;;
        '-n database get clusters.postgresql.cnpg.io '*)
            jq -n --arg hibernation "$LIVE_HIBERNATION" '{metadata:{annotations:{"cnpg.io/hibernation":$hibernation}}}'
            ;;
        '-n database create -f - -o json')
            local request
            request=$(jq -e 'select(.apiVersion == "postgresql.cnpg.io/v1" and .kind == "Backup" and
                .metadata.namespace == "database" and .spec.method == "barmanObjectStore" and .spec.target == "primary")')
            record "BACKUP_REQUEST $(jq -r '.spec.cluster.name' <<< "$request")"
            jq '.metadata.name = (.metadata.generateName + "test")' <<< "$request"
            ;;
        '-n database get backups.postgresql.cnpg.io '*)
            local cluster phase destination
            cluster=${5%-pre-shutdown-test}
            phase=completed
            if [[ "$cluster" == "$BACKUP_WAIT_FAILURE" ]]; then phase=$BACKUP_PHASE; fi
            destination=s3://cloudnative-pg/
            if [[ "$cluster" == postgres16vector ]]; then destination=s3://sensei-cnpg/; fi
            jq -n --arg name "$5" --arg cluster "$cluster" --arg phase "$phase" --arg destination "$destination" '{
                metadata:{name:$name, namespace:"database"}, spec:{cluster:{name:$cluster}},
                status:{phase:$phase, backupId:"test-backup-id", serverName:($cluster + "-v4"), destinationPath:$destination}
            }'
            ;;
        *' wait --for=jsonpath={.status.phase}=completed backups.postgresql.cnpg.io/'*)
            if [[ -n "$BACKUP_WAIT_FAILURE" && "$*" == *"/$BACKUP_WAIT_FAILURE-pre-shutdown-test "* ]]; then
                return 1
            fi
            ;;
        *' get pods '*) : ;;
        *' scale '*|*' wait '*|wait\ *|*' patch '*) : ;;
        *) die "Unexpected mock Kubernetes command: $*" ;;
    esac
}

cnpg() {
    record "CNPG $*"
    if [[ "$1" == hibernate && "$2" == off && "$LIVE_HIBERNATION" != on ]]; then
        return 1
    fi
}
talos() {
    record "TALOS $*"
    if [[ "$2" == etcd ]]; then printf 'mock snapshot\n' > "$4"; fi
}
ceph_cmd() {
    record "CEPH $*"
    case "$1" in
        status) printf '%s' "$CEPH_STATE" ;;
        osd) : ;;
        *) die "Unexpected mock Ceph command: $*" ;;
    esac
}

assert_contains() { grep -Fq -- "$1" "$CALLS" || die "Missing expected call: $1"; }
assert_absent() { if grep -Fq -- "$1" "$CALLS"; then die "Unexpected call: $1"; fi; }
assert_before() {
    local first second
    first=$(grep -nF -- "$1" "$CALLS" | head -1 | cut -d: -f1)
    second=$(grep -nF -- "$2" "$CALLS" | head -1 | cut -d: -f1)
    [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]] || die "Expected $1 before $2"
}

test_shutdown_restore() {
    shutdown_cluster
    [[ -s "$STATE_DIR/etcd.snapshot" && -s "$STATE_DIR/state.json" ]]
    assert_before 'etcd snapshot' 'scale Deployment/phase-10'
    assert_before 'scale Deployment/phase-10' 'scale Deployment/phase-20'
    assert_before 'scale Deployment/phase-20' 'patch cronjobs.batch'
    assert_before 'maxRunners":0' 'scale Deployment/phase-30'
    assert_before 'get pods -l app=phase-50' 'BACKUP_REQUEST postgres16'
    assert_before 'BACKUP_REQUEST postgres16' 'get backups.postgresql.cnpg.io postgres16-pre-shutdown-test'
    assert_before 'BACKUP_REQUEST postgres16vector' 'get backups.postgresql.cnpg.io postgres16vector-pre-shutdown-test'
    assert_before 'get backups.postgresql.cnpg.io postgres16vector-pre-shutdown-test' 'CNPG hibernate on postgres16'
    assert_before 'CNPG hibernate on postgres16vector' 'scale Deployment/phase-60'
    assert_before 'CNPG hibernate on postgres16vector' 'scale Deployment/phase-65'
    assert_before 'CNPG hibernate on postgres16vector' 'scale Deployment/phase-70'
    assert_contains 'backups.postgresql.cnpg.io/postgres16-pre-shutdown-test --timeout=3600s'
    assert_contains 'backups.postgresql.cnpg.io/postgres16vector-pre-shutdown-test --timeout=3600s'
    jq -e '.status.phase == "completed" and .status.serverName == "postgres16-v4" and
        .status.destinationPath == "s3://cloudnative-pg/" and .status.backupId == "test-backup-id"' \
        "$STATE_DIR/cnpg-backup-database-postgres16.json" >/dev/null
    jq -e '.status.phase == "completed" and .status.serverName == "postgres16vector-v4" and
        .status.destinationPath == "s3://sensei-cnpg/"' \
        "$STATE_DIR/cnpg-backup-database-postgres16vector.json" >/dev/null
    assert_before 'scale Deployment/phase-70' 'CEPH osd set noout'
    assert_before 'scale Deployment/phase-80' 'scale Deployment/phase-85'
    assert_before 'scale Deployment/phase-85' 'scale Deployment/phase-90'
    assert_before 'scale Deployment/phase-90' 'scale Deployment/phase-100'
    assert_before 'scale Deployment/phase-100' 'TALOS 192.168.3.102 shutdown'
    assert_before 'TALOS 192.168.3.219 shutdown' 'TALOS 192.168.3.214 shutdown'
    assert_absent 'hibernate on already-asleep'
    assert_absent 'BACKUP_REQUEST already-asleep'
    : > "$CALLS"
    restore_cluster
    assert_before 'scale Deployment/phase-100 --replicas=3' 'scale Deployment/phase-90 --replicas=3'
    assert_before 'scale Deployment/phase-80 --replicas=3' 'CEPH osd unset noout'
    assert_before 'CEPH osd unset noout' 'CNPG hibernate off postgres16'
    assert_before 'CNPG hibernate off postgres16vector' 'CONFIRM START-APPLICATIONS'
    assert_before 'CONFIRM START-APPLICATIONS' 'scale Deployment/phase-50 --replicas=3'
    assert_before 'scale Deployment/phase-50 --replicas=3' 'scale Deployment/phase-20 --replicas=3'
    assert_before 'scale Deployment/phase-20 --replicas=3' 'scale Deployment/phase-10 --replicas=3'
    assert_contains '--for=jsonpath={.status.readyReplicas}=3'
    assert_contains 'minRunners":3,"maxRunners":6'
    assert_contains 'paused --type=merge -p {"spec":{"suspend":true}}'
    assert_absent 'hibernate off already-asleep'
    assert_absent 'shutdown --force'
    assert_absent 'BACKUP_REQUEST'
}

test_restore_already_running() {
    save_state
    LIVE_HIBERNATION=off
    restore_cluster
    assert_absent 'CNPG hibernate off'
    assert_contains 'wait --for=condition=Ready clusters.postgresql.cnpg.io postgres16 --timeout=600s'
    assert_before 'wait --for=condition=Ready clusters.postgresql.cnpg.io postgres16vector' 'CONFIRM START-APPLICATIONS'
    assert_contains 'scale Deployment/phase-10 --replicas=3'
}

assert_backup_blocks_shutdown() {
    BACKUP_WAIT_FAILURE=postgres16vector
    (
        PRESERVE_TEST_DIR=true
        shutdown_cluster
    ) > "$TEST_DIR/backup-failure" 2>&1 &
    local child=$!
    if wait "$child"; then die 'Expected final backup failure to stop shutdown.'; fi
    grep -Fq 'Final PostgreSQL backup database/postgres16vector-pre-shutdown-test did not complete' "$TEST_DIR/backup-failure"
    jq -e --arg phase "$BACKUP_PHASE" '.status.phase == $phase' \
        "$STATE_DIR/cnpg-backup-database-postgres16vector.json" >/dev/null
    assert_contains 'BACKUP_REQUEST postgres16'
    assert_contains 'BACKUP_REQUEST postgres16vector'
    assert_absent 'CNPG hibernate on'
    assert_absent 'scale Deployment/phase-65'
    assert_absent 'scale Deployment/phase-70'
    assert_absent 'CEPH osd set noout'
    assert_absent 'shutdown --force'
}

test_backup_failure_blocks_shutdown() {
    BACKUP_PHASE=failed
    assert_backup_blocks_shutdown
}

test_backup_timeout_blocks_shutdown() {
    BACKUP_PHASE=running
    assert_backup_blocks_shutdown
}

mock_existing_backups() {
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    CNPG=$(jq --arg timestamp "$timestamp" 'map(.lastSuccessfulBackup = $timestamp)' <<< "$CNPG")
    BACKUPS=$(jq --arg timestamp "$timestamp" '{items:[.[] | select(.hibernation != "on") | {
        metadata:{namespace:.namespace, name:(.name + "-nightly")},
        spec:{cluster:{name:.name}, method:"barmanObjectStore"},
        status:{phase:"completed", stoppedAt:$timestamp, backupId:"existing-id"}
    }]}' <<< "$CNPG")
    VOLSYNC_SOURCES=$(jq '{items:[.[] | select(.hibernation != "on") | {
        metadata:{namespace:.namespace, name:(.name + "-logical-backup")},
        status:{lastSyncTime:"2000-01-01T00:00:00Z"}
    }]}' <<< "$CNPG")
}

test_existing_barman_shutdown() {
    mock_existing_backups
    USE_EXISTING_BARMAN_BACKUPS=true
    load_existing_barman_backups
    assert_recent_backups
    shutdown_cluster
    assert_absent BACKUP_REQUEST
    assert_contains 'Using operator-validated existing Barman backup database/postgres16vector-nightly'
    assert_before 'Using operator-validated existing Barman backup database/postgres16vector-nightly' 'CNPG hibernate on postgres16'
    assert_contains 'TALOS 192.168.3.241 shutdown'
    jq -e '.useExistingBarmanBackups == true and (.existingBarmanBackups | length) == 2' "$STATE_DIR/state.json" >/dev/null
    jq -e '.metadata.name == "postgres16vector-nightly" and .status.backupId == "existing-id"' \
        "$STATE_DIR/cnpg-backup-database-postgres16vector.json" >/dev/null
}

test_reject_existing_missing_backup() {
    mock_existing_backups
    USE_EXISTING_BARMAN_BACKUPS=true
    BACKUPS=$(jq '.items |= map(select(.spec.cluster.name != "postgres16vector"))' <<< "$BACKUPS")
    load_existing_barman_backups
}

test_reject_existing_stale_backup() {
    mock_existing_backups
    USE_EXISTING_BARMAN_BACKUPS=true
    BACKUPS=$(jq '.items[0].status.stoppedAt = "2000-01-01T00:00:00Z"' <<< "$BACKUPS")
    load_existing_barman_backups
}

test_reject_existing_failed_backup() {
    mock_existing_backups
    USE_EXISTING_BARMAN_BACKUPS=true
    BACKUPS=$(jq '.items[0].status.phase = "failed"' <<< "$BACKUPS")
    load_existing_barman_backups
}

test_reject_existing_wrong_method() {
    mock_existing_backups
    USE_EXISTING_BARMAN_BACKUPS=true
    BACKUPS=$(jq '.items[0].spec.method = "volumeSnapshot"' <<< "$BACKUPS")
    load_existing_barman_backups
}

test_reject_unrelated_stale_volsync() {
    mock_existing_backups
    USE_EXISTING_BARMAN_BACKUPS=true
    load_existing_barman_backups
    VOLSYNC_SOURCES=$(jq '.items += [{metadata:{namespace:"media",name:"plex"},status:{}}]' <<< "$VOLSYNC_SOURCES")
    assert_recent_backups
}

test_reject_stale_volsync_by_default() {
    mock_existing_backups
    assert_recent_backups
}

test_preserve_noout() {
    CEPH_FLAGS='["noout"]'
    save_state
    restore_cluster
    assert_absent 'CEPH osd unset noout'
}

test_default_read_only() {
    preflight() { record PREFLIGHT; }
    main
    assert_contains PREFLIGHT
    assert_absent 'CONFIRM'
    assert_absent 'KUBE'
    assert_absent 'TALOS'
}

test_reject_degraded() {
    require_clean_ceph "$(jq '.pgmap.pgs_by_state[0].state_name = "active+degraded"' <<< "$CEPH_STATE")"
}

test_reject_missing_osd() {
    require_clean_ceph "$(jq '.osdmap.num_up_osds = 4' <<< "$CEPH_STATE")"
}

test_reject_storage_client() {
    STORAGE_CLIENTS='{"items":[{"metadata":{"namespace":"test","name":"writer"},"status":{"phase":"Running"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"data"}}]}}]}'
    require_no_storage_clients
}

test_reject_job() {
    JOBS='{"items":[{"metadata":{"namespace":"test","name":"pending-job"},"spec":{},"status":{}}]}'
    assert_idle
}

test_reject_volatile_data() {
    DRAGONFLIES='["dragonfly"]'
    shutdown_cluster
}

test_reject_health_warning() {
    CEPH_STATE=$(jq '.health.status = "HEALTH_WARN"' <<< "$CEPH_STATE")
    shutdown_cluster
}

test_reject_old_backup() {
    CNPG='[{"namespace":"database","name":"postgres","lastSuccessfulBackup":"2000-01-01T00:00:00Z"}]'
    assert_recent_backups
}

test_reject_conflicting_modes() {
    STATE_DIR=""
    main --dry-run --restore "$TEST_DIR"
}

test_reject_wrong_cluster() {
    save_state
    CLUSTER_UID=another-cluster
    restore_cluster
}

if [[ "${1:-}" == --case ]]; then
    "$2"
    exit 0
fi

for test_case in test_shutdown_restore test_restore_already_running test_backup_failure_blocks_shutdown test_backup_timeout_blocks_shutdown test_existing_barman_shutdown test_preserve_noout test_default_read_only; do
    bash "$0" --case "$test_case"
    printf 'PASS %s\n' "$test_case"
done

while IFS='|' read -r test_case expected; do
    if bash "$0" --case "$test_case" > "$TEST_DIR/result" 2>&1; then
        die "Expected failure: $test_case"
    fi
    grep -Fq -- "$expected" "$TEST_DIR/result" || die "Wrong failure reason: $test_case"
    printf 'PASS %s\n' "$test_case"
done <<'CASES'
test_reject_degraded|all placement groups active+clean
test_reject_missing_osd|all placement groups active+clean
test_reject_storage_client|Storage consumers remain
test_reject_job|Unfinished Jobs must complete
test_reject_volatile_data|Dragonfly data is volatile
test_reject_health_warning|Review Ceph health warnings first
test_reject_old_backup|PostgreSQL backups missing
test_reject_existing_missing_backup|Existing Barman backup metadata is missing
test_reject_existing_stale_backup|Existing Barman backup metadata is missing
test_reject_existing_failed_backup|Existing Barman backup metadata is missing
test_reject_existing_wrong_method|Existing Barman backup metadata is missing
test_reject_unrelated_stale_volsync|media/plex
test_reject_stale_volsync_by_default|VolSync backups missing
test_reject_conflicting_modes|Choose only one mode
test_reject_wrong_cluster|Cluster identity does not match
CASES
