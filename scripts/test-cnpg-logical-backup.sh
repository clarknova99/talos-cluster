#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
if [[ "${1:-}" == --integration ]]; then
    docker run --rm -i --network none --user 26:26 \
        --tmpfs /tmp:rw,uid=26,gid=26 --tmpfs /staging:rw,uid=26,gid=26 \
        --mount "type=bind,source=$PWD/kubernetes/apps/database/cloudnative-pg/logical-backups,target=/scripts,readonly" \
        --entrypoint /bin/bash ghcr.io/cloudnative-pg/postgresql:16.3-7 -se <<'INTEGRATION'
set -Eeuo pipefail
export PATH="/usr/lib/postgresql/16/bin:$PATH"
cleanup() {
    pg_ctl -D /tmp/target -m fast -w stop >/dev/null 2>&1 || true
    pg_ctl -D /tmp/source -m fast -w stop >/dev/null 2>&1 || true
}
trap cleanup EXIT
initdb -D /tmp/source --username=postgres --auth-local=trust --auth-host=reject >/dev/null
pg_ctl -D /tmp/source -o "-k /tmp -h '' -p 55432" -l /tmp/source.log -w start >/dev/null
export PGHOST=/tmp PGPORT=55432 PGUSER=postgres PGDATABASE=postgres
psql -X --set=ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE "app owner" LOGIN;
CREATE ROLE reader;
GRANT reader TO "app owner";
CREATE DATABASE "app database" OWNER "app owner";
CREATE TABLE public.marker (value text);
INSERT INTO public.marker VALUES ('postgres data');
SQL
PGDATABASE='app database' psql -X --set=ON_ERROR_STOP=1 <<'SQL'
SET ROLE "app owner";
CREATE TABLE public.records (id serial PRIMARY KEY, value text);
INSERT INTO public.records (value) VALUES ('first'), ('second');
GRANT SELECT ON public.records TO reader;
SQL
source /scripts/backup.sh
STAGING_DIR=/staging
CLUSTER_NAME=integration
exec 9> /staging/.backup.lock
flock --nonblock 9
if flock --nonblock /staging/.backup.lock true; then
    die 'Filesystem lock allowed a competing writer.'
fi
dump_databases
(cd /staging/dumps && sha256sum --check SHA256SUMS)
initdb -D /tmp/target --username=postgres --auth-local=trust --auth-host=reject >/dev/null
pg_ctl -D /tmp/target -o "-k /tmp -h '' -p 55433" -l /tmp/target.log -w start >/dev/null
export PGPORT=55433 PGUSER=postgres PGDATABASE=template1
sed -e '/^CREATE ROLE "postgres";$/d' -e '/^ALTER ROLE "postgres" /d' /staging/dumps/roles.sql |
    psql -X --set=ON_ERROR_STOP=1 >/dev/null
dropdb postgres
archive_index=0
while IFS= read -r -d '' database; do
    archive_index=$((archive_index + 1))
    printf -v archive '/staging/dumps/database-%04d.dump' "$archive_index"
    pg_restore --exit-on-error --create --no-tablespaces --dbname=template1 "$archive"
    PGDATABASE="$database" vacuumdb --analyze-in-stages >/dev/null
done < /staging/dumps/database-names.bin
[[ $(PGDATABASE=postgres psql -X -Atc 'SELECT value FROM public.marker') == 'postgres data' ]]
export PGDATABASE='app database'
[[ $(psql -X -Atc 'SELECT count(*) FROM public.records') == 2 ]]
[[ $(psql -X -Atc "SELECT nextval('public.records_id_seq')") == 3 ]]
[[ $(psql -X -Atc "SELECT tableowner FROM pg_tables WHERE schemaname = 'public' AND tablename = 'records'") == 'app owner' ]]
[[ $(psql -X -Atc "SELECT pg_has_role('app owner', 'reader', 'MEMBER')") == t ]]
[[ $(psql -X -Atc "SELECT has_table_privilege('reader', 'public.records', 'SELECT')") == t ]]
printf 'PASS isolated PostgreSQL dump/restore, role membership, ownership, grants, sequence and filesystem lock\n'
INTEGRATION
    exit 0
fi

source kubernetes/apps/database/cloudnative-pg/logical-backups/backup.sh
source kubernetes/apps/database/cloudnative-pg/logical-backups/orchestrate.sh
if [[ "${1:-}" == --case ]]; then
    TEST_DIR=$2
else
    TEST_DIR=$(mktemp -d)
    trap 'rm -rf -- "$TEST_DIR"' EXIT
fi
STAGING_DIR="$TEST_DIR/staging"
mkdir -p "$STAGING_DIR"
CALLS="$TEST_DIR/calls"
touch "$CALLS"
CLUSTER_NAME=postgres16
SOURCE_NAME=postgres16-logical-backup
NAMESPACE=database
POD_UID=test-pod
BACKUP_TOKEN=postgres16-volume-uid
MOCK_RESULT=Successful
MOCK_TIMEOUT=false
MOCK_LOCKED=false
MOCK_DUMP_FAILURE=false
export TMPDIR="$TEST_DIR"
export KUBERNETES_SERVICE_HOST=10.96.0.1
export KUBERNETES_SERVICE_PORT=443
unset KUBERNETES_SERVICE_PORT_HTTPS
SERVICE_ACCOUNT_DIR="$TEST_DIR/serviceaccount"
mkdir -p "$SERVICE_ACCOUNT_DIR"
printf 'mock-ca\n' > "$SERVICE_ACCOUNT_DIR/ca.crt"
printf 'mock-token\n' > "$SERVICE_ACCOUNT_DIR/token"

flock() { [[ "$MOCK_LOCKED" == false ]]; }
sha256sum() { shasum -a 256 "$@"; }

kube() {
    printf '%s\n' "$*" >> "$CALLS"
    if [[ "${MOCK_ORCHESTRATION:-false}" == true ]]; then orchestration_kube "$@"; return; fi
    die "Dump worker attempted a Kubernetes call: $*"
}

orchestration_kube() {
    local resource payload kind
    case "$*" in
        'get lease '*) cat "$TEST_DIR/lease" ;;
        'get pod '*--ignore-not-found*) printf '%s' "${MOCK_OWNER:-}" ;;
        'replace -f -')
            payload=$(cat)
            [[ "${MOCK_CONFLICT:-false}" == false ]] || return 1
            printf '%s' "$payload" > "$TEST_DIR/lease" ;;
        'patch lease '*) : ;;
        'get replicationsource '*) cat "$TEST_DIR/source" ;;
        'get pvc '*|'get job '*)
            resource=$2
            if [[ -f "$TEST_DIR/$resource" ]]; then cat "$TEST_DIR/$resource"; fi ;;
        'create --dry-run=client '*)
            yq -o=json kubernetes/apps/database/cloudnative-pg/logical-backups/worker-job.yaml ;;
        'create -f -'*)
            payload=$(cat)
            kind=$(jq -r .kind <<< "$payload")
            if [[ "$kind" == PersistentVolumeClaim ]]; then
                jq '.metadata.uid = "new-volume"' <<< "$payload" > "$TEST_DIR/pvc"
                cp "$TEST_DIR/pvc" "$TEST_DIR/created-pvc"
                cat "$TEST_DIR/pvc"
            else
                jq '.status.conditions = [{type:"Complete",status:"True"}]' <<< "$payload" > "$TEST_DIR/job"
                cp "$TEST_DIR/job" "$TEST_DIR/created-job"
            fi ;;
        'patch replicationsource '*--patch-file=*)
            payload=$(cat)
            jq --argjson patch "$payload" '.spec = (.spec * $patch.spec)' "$TEST_DIR/source" > "$TEST_DIR/next"
            mv "$TEST_DIR/next" "$TEST_DIR/source" ;;
        'patch replicationsource '*)
            jq '.spec.paused = true' "$TEST_DIR/source" > "$TEST_DIR/next"
            mv "$TEST_DIR/next" "$TEST_DIR/source" ;;
        'wait job/'*) [[ "${MOCK_WORKER_TIMEOUT:-false}" == false ]] ;;
        'wait replicationsource/'*)
            [[ "$MOCK_TIMEOUT" == false ]] || return 1
            jq --arg result "$MOCK_RESULT" '
                .status = {lastManualSync:.spec.trigger.manual,latestMoverStatus:{result:$result},
                    conditions:[{type:"Synchronizing",status:"False"}]}
            ' "$TEST_DIR/source" > "$TEST_DIR/next"
            mv "$TEST_DIR/next" "$TEST_DIR/source" ;;
        'get pods -o json') printf '%s' "${MOCK_PODS:-{\"items\":[]}}" ;;
        'delete job '*) rm "$TEST_DIR/job" ;;
        'delete pvc '*) rm "$TEST_DIR/pvc" ;;
        *) die "Unexpected orchestration command: $*" ;;
    esac
}

test_orchestration() {
    MOCK_ORCHESTRATION=true
    POD_NAME=test-orchestrator
    STAGING_CAPACITY=20Gi
    SCRIPT_DIR=kubernetes/apps/database/cloudnative-pg/logical-backups
    printf '%s' '{"metadata":{"resourceVersion":"1"},"spec":{}}' > "$TEST_DIR/lease"
    jq -n --arg name "$SOURCE_NAME" '{metadata:{resourceVersion:"1"},spec:{sourcePVC:$name,
        paused:true,trigger:{manual:"standby"},kopia:{copyMethod:"Direct"}}}' > "$TEST_DIR/source"
    case "$TEST_SCENARIO" in
        resume|cleanup_retry|dump_retry|completed_dump|wrong_worker)
            jq -n --arg name "$SOURCE_NAME" '{metadata:{uid:"retained-volume",
                labels:{"cnpg-backup/source":$name,"cnpg-backup/lifecycle":"per-run"}},
                spec:{storageClassName:"openebs-hostpath"}}' > "$TEST_DIR/pvc"
            jq -n --arg name "$SOURCE_NAME" '{metadata:{labels:{"cnpg-backup/source":$name},
                annotations:{"cnpg-backup/claim-uid":"retained-volume"}},
                status:{conditions:[{type:"Complete",status:"True"}]}}' > "$TEST_DIR/job" ;;
    esac
    case "$TEST_SCENARIO" in
        lease_busy|lease_dead)
            jq '.spec.holderIdentity="other" | .metadata.annotations={"cnpg-backup/holder-pod":"old-pod"}' \
                "$TEST_DIR/lease" > "$TEST_DIR/next"
            mv "$TEST_DIR/next" "$TEST_DIR/lease"
            MOCK_OWNER='{"metadata":{"uid":"other"},"status":{"phase":"Running"}}'
            if [[ "$TEST_SCENARIO" == lease_dead ]]; then MOCK_OWNER='{"metadata":{"uid":"other"},"status":{"phase":"Failed"}}'; fi ;;
        lease_conflict) MOCK_CONFLICT=true ;;
        legacy) printf '%s' '{"metadata":{"uid":"old"},"spec":{"storageClassName":"ceph-block"}}' > "$TEST_DIR/pvc" ;;
        timeout) MOCK_TIMEOUT=true ;;
        worker_timeout) MOCK_WORKER_TIMEOUT=true ;;
        failed_upload) MOCK_RESULT=Failed ;;
        mounted) MOCK_PODS='{"items":[{"status":{"phase":"Running"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"postgres16-logical-backup"}}]}}]}' ;;
        resume|cleanup_retry|lost_claim)
            jq '.spec.paused=false | .spec.trigger.manual="postgres16-retained-volume"' "$TEST_DIR/source" > "$TEST_DIR/next"
            mv "$TEST_DIR/next" "$TEST_DIR/source"
            if [[ "$TEST_SCENARIO" == cleanup_retry ]]; then
                jq '.status={lastManualSync:.spec.trigger.manual,latestMoverStatus:{result:"Successful"},
                    conditions:[{type:"Synchronizing",status:"False"}]}' "$TEST_DIR/source" > "$TEST_DIR/next"
                mv "$TEST_DIR/next" "$TEST_DIR/source"
                rm "$TEST_DIR/job"
            fi ;;
        dump_retry)
            jq '.status.conditions=[{type:"Failed",status:"True"}]' "$TEST_DIR/job" > "$TEST_DIR/next"
            mv "$TEST_DIR/next" "$TEST_DIR/job" ;;
        wrong_worker)
            jq '.metadata.annotations["cnpg-backup/claim-uid"]="another-volume"' "$TEST_DIR/job" > "$TEST_DIR/next"
            mv "$TEST_DIR/next" "$TEST_DIR/job" ;;
    esac
    orchestrate
}

pg_dumpall() {
    local destination=${!#}
    printf 'DUMP\n' >> "$CALLS"
    printf 'CREATE ROLE "example";\n' > "${destination#--file=}"
}

psql() {
    case "$*" in
        *'SELECT datname '*) printf 'postgres\000odd "name/with spaces\000' ;;
        *'SELECT extname, extversion '*) printf 'extname,extversion\nplpgsql,1.0\n' ;;
        *) die "Unexpected SQL: $*" ;;
    esac
}

pg_dump() {
    local destination=${!#}
    [[ "$MOCK_DUMP_FAILURE" == false ]] || return 1
    printf '%s\n' "$PGDATABASE" > "${destination#--file=}"
}

test_success() {
    main
    grep -Fq DUMP "$CALLS"
    [[ "$(< "$STAGING_DIR/dump-complete")" == "$BACKUP_TOKEN" ]]
    grep -Fxq 'odd "name/with spaces' "$STAGING_DIR/dumps/database-0002.dump"
    grep -Fxq 'database-0002.dump,"odd ""name/with spaces"' "$STAGING_DIR/dumps/databases.csv"
    (cd "$STAGING_DIR/dumps" && sha256sum --check SHA256SUMS)
}

test_resume() {
    printf '%s\n' "$BACKUP_TOKEN" > "$STAGING_DIR/dump-complete"
    main
    if grep -Fq DUMP "$CALLS"; then die 'Retry overwrote a pending dump.'; fi
    [[ "$(< "$STAGING_DIR/dump-complete")" == "$BACKUP_TOKEN" ]]
    [[ ! -s "$CALLS" ]] || die 'Completed dump was rewritten or triggered Kubernetes calls.'
}

test_locked() {
    MOCK_LOCKED=true
    main
}

test_dump_failure() {
    MOCK_DUMP_FAILURE=true
    main
}

test_conflicting_token() {
    printf 'another-volume\n' > "$STAGING_DIR/dump-complete"
    main
}

test_client_config() {
    configure_client
    jq -e --arg account_dir "$SERVICE_ACCOUNT_DIR" '
        .clusters[0].cluster.server == "https://10.96.0.1:443" and
        .clusters[0].cluster["certificate-authority"] == ($account_dir + "/ca.crt") and
        .users[0].user.tokenFile == ($account_dir + "/token") and
        (.users[0].user | has("token") | not) and
        .contexts[0].context.namespace == "database" and .["current-context"] == "in-cluster"
    ' "$KUBECONFIG" >/dev/null
    if grep -Fq mock-token "$KUBECONFIG"; then die 'Token value copied into kubeconfig.'; fi
}

test_client_ipv6() {
    KUBERNETES_SERVICE_HOST=fd00::1
    configure_client
    jq -e '.clusters[0].cluster.server == "https://[fd00::1]:443"' "$KUBECONFIG" >/dev/null
}

test_client_missing_token() {
    rm "$SERVICE_ACCOUNT_DIR/token"
    configure_client
}

test_client_missing_endpoint() {
    unset KUBERNETES_SERVICE_HOST
    configure_client
}

if [[ "${1:-}" == --case ]]; then
    "$3"
    exit 0
fi

for test_case in test_success test_resume test_locked test_dump_failure test_conflicting_token test_client_config test_client_ipv6 test_client_missing_token test_client_missing_endpoint; do
    case_dir="$TEST_DIR/$test_case"
    mkdir -p "$case_dir/staging"
    touch "$case_dir/calls"
    expected_exit=0
    case "$test_case" in test_locked|test_dump_failure|test_conflicting_token|test_client_missing_token|test_client_missing_endpoint) expected_exit=1 ;; esac
    actual_exit=0
    bash "$0" --case "$case_dir" "$test_case" > "$case_dir/output" 2>&1 || actual_exit=$?
    [[ "$actual_exit" == "$expected_exit" ]] || { cat "$case_dir/output"; die "Unexpected result for $test_case"; }
    case "$test_case" in
        test_locked|test_conflicting_token)
            if grep -Fq DUMP "$case_dir/calls"; then die 'Unsafe dump was started.'; fi ;;
        test_dump_failure)
            [[ ! -e "$case_dir/staging/dump-complete" ]]
            if grep -Fq 'patch ' "$case_dir/calls"; then die 'Partial dump triggered an upload.'; fi ;;
    esac
    printf 'PASS %s\n' "$test_case"
done

for scenario in success lease_busy lease_dead lease_conflict legacy timeout worker_timeout failed_upload mounted resume cleanup_retry dump_retry completed_dump lost_claim wrong_worker; do
    case_dir="$TEST_DIR/orchestration-$scenario"
    mkdir -p "$case_dir/staging"
    touch "$case_dir/calls"
    expected_exit=1
    case "$scenario" in success|lease_dead|resume|cleanup_retry|dump_retry|completed_dump) expected_exit=0 ;; esac
    actual_exit=0
    TEST_SCENARIO="$scenario" bash "$0" --case "$case_dir" test_orchestration > "$case_dir/output" 2>&1 || actual_exit=$?
    [[ "$actual_exit" == "$expected_exit" ]] || { cat "$case_dir/output"; die "Unexpected orchestration result: $scenario"; }
    case "$scenario" in
        success|lease_dead|resume|cleanup_retry|dump_retry|completed_dump) [[ ! -e "$case_dir/pvc" && ! -e "$case_dir/job" ]] ;;
        timeout|worker_timeout|failed_upload|mounted) [[ -s "$case_dir/pvc" ]] ;;
    esac
    case "$scenario" in
        resume|cleanup_retry|completed_dump)
            [[ ! -e "$case_dir/created-pvc" && ! -e "$case_dir/created-job" ]] ;;
        dump_retry) [[ ! -e "$case_dir/created-pvc" && -e "$case_dir/created-job" ]] ;;
        lost_claim|lease_busy|lease_conflict|legacy|wrong_worker)
            [[ ! -e "$case_dir/created-pvc" && ! -e "$case_dir/created-job" ]] ;;
        success)
            jq -e '.spec.storageClassName == "openebs-hostpath" and .metadata.ownerReferences == null' "$case_dir/created-pvc" >/dev/null
            jq -e '.spec.template.spec.automountServiceAccountToken == false and .metadata.ownerReferences == null and
                .spec.ttlSecondsAfterFinished == null and
                any(.spec.template.spec.containers[0].env[]; .name == "BACKUP_TOKEN" and .value == "postgres16-new-volume")' "$case_dir/created-job" >/dev/null ;;
    esac
    if [[ "$expected_exit" != 0 ]] && grep -Fq 'delete pvc' "$case_dir/calls"; then die 'Failure deleted staging.'; fi
    printf 'PASS orchestration_%s\n' "$scenario"
done
