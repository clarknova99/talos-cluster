# CNPG Daily Logical Backups

This opt-in bundle backs up `postgres16` and `postgres16vector` without stopping PostgreSQL. It is **not registered with Flux** and does not change either Cluster manifest or replace CNPG's Barman backups/WAL archive.

| Source | Per-run staging PVC | Schedule (UTC) | Kopia retention |
|---|---|---|---|
| `postgres16` | `postgres16-logical-backup`, 20Gi | 04:15 daily | 7 daily, 4 weekly, 3 monthly |
| `postgres16vector` | `postgres16vector-logical-backup`, 50Gi | 05:15 daily | 7 daily, 4 weekly, 3 monthly |

Staging is created at backup time with `openebs-hostpath` and deleted only after a verified Kopia upload. The name stays constant, but each fresh run creates a PVC with a new UID and new backing directory. No staging PVC is created when this bundle is deployed. `WaitForFirstConsumer` lets the dump worker choose a suitable node; the VolSync mover then uses that same node-local volume. After successful cleanup the next run can use a different node. These are separate staging claims, never CNPG data PVCs.

Set `STAGING_CAPACITY` in each CronJob for a full compressed logical dump and monitor actual node disk space. OpenEBS hostpath capacity is not a guaranteed filesystem quota or reservation. Failed runs retain their local disk usage until resolved. The dump clients use the same PostgreSQL 16 image as the current clusters; update [worker-job.yaml](worker-job.yaml) and restore images with future server-version changes. Dump load can affect database latency even though no downtime is required. The supplied restore PVCs and isolated restore database remain Ceph-backed; they are separate from disposable backup staging.

## What Gets Backed Up

- A custom-format `pg_dump --create` archive for every connectable, non-template database, including `postgres`.
- `pg_dumpall --roles-only` output, including role attributes, membership, and password hashes.
- A CSV mapping archive filenames to database names, a NUL-separated database-name list, extension/version inventories, timestamps, and SHA-256 checksums.

Each database has its own consistent transaction snapshot; there is no common snapshot across databases or roles. Avoid database creation/deletion, role changes, and schema migrations during the backup window. Non-connectable databases and template customizations are excluded. Physical WAL history, tablespace layout, Kubernetes Secrets, and CNPG configuration are not logical dumps; retain their separate backups. Database tablespaces are intentionally remapped to the target's default storage during restore.

These dumps provide restore points, not point-in-time recovery. Keep Barman and WAL archiving enabled. Kopia uses the existing NAS repository at `/volume1/network-storage/volsync-backups`, mounted into movers by the cluster admission policy. This is a separate backup format, but shares the NAS failure domain with `postgres16`'s MinIO backups. Keep an independent off-site copy.

## Handoff Safety

The CronJob is a volume-free orchestrator, not the PostgreSQL client. It performs this sequence:

1. Acquire a per-cluster Kubernetes Lease using a resource-version compare-and-swap. `concurrencyPolicy: Forbid` prevents scheduled overlap; the Lease also excludes manually created Jobs. A lock can be reclaimed only when its exact owner pod has finished or no longer exists, never merely because a timer expired.
2. Check that VolSync is safely idle, then create a local staging PVC if one does not exist. Derive the upload token from the cluster name and PVC UID. An existing PVC is accepted only if it carries this workflow's labels, uses `openebs-hostpath`, and has no garbage-collection owner.
3. Create a separate `$CLUSTER-logical-backup-dump` Job. It mounts staging, dumps databases and roles, creates checksums, and atomically writes `dump-complete` with the token. A filesystem lock and this marker prevent rewriting a completed dump. The worker has no mounted Kubernetes API token or RBAC permissions.
4. After the worker completes, request that exact VolSync token. Require matching `status.lastManualSync`, `Synchronizing=False`, and `latestMoverStatus.result=Successful`. VolSync copies immutable dumps using `Direct`, not a live PostgreSQL directory.
5. Pause the source, delete the completed worker Job with foreground propagation, verify no active pod uses staging, then delete the owned PVC and wait for deletion. A final UID check prevents cleanup of a replacement claim. OpenEBS's `Delete` reclaim policy removes its backing directory; existing Kopia snapshots are unaffected.

The source name, namespace, PVC **name**, and source path remain stable for Kopia identity and retention. The PVC UID changes only the manual upload token, not the repository identity. The restore destinations explicitly name the same source identity and work when the staging PVC is absent. No per-run PVC or worker Job is owned by the orchestrator Job, so CronJob history/TTL cleanup cannot destroy a failed run's staging data.

Any dump failure, upload timeout/failure, or unknown trigger retains staging. The next invocation reconnects to that PVC: it retries a failed dump Job (the completion marker preserves already finished dumps), waits for an existing worker, resumes a pending upload without running the dumper, or finishes interrupted cleanup after a successful upload. After a successful retry, run another job if you need a newer recovery point; the retained dump may be older than the new upload timestamp. A failed node pins that retained run until the node returns. Permanent node/disk loss requires operator-reviewed abandonment of that run, not automatic replacement while an old upload is outstanding.

Never delete staging, reset a Lease, manually change the VolSync trigger, or delete a dump Job while a run is active. The worker has a two-hour deadline; the orchestrator allows 130 minutes for it, two hours for upload, bounded synchronization/cleanup waits, and a six-hour overall deadline. Failures release the Lease when possible, but do not automatically delete data. A killed orchestrator leaves a Lease that the next invocation safely reclaims after the old pod is terminal. Do not force-delete an unresponsive owner pod just to bypass the lock.

## Deploy and Enable

Run these commands from the repository root. They deploy resources; the CronJobs start suspended so you can validate the first backup before enabling schedules.

1. Check prerequisites: healthy CNPG, a working `openebs-hostpath` provisioner with `WaitForFirstConsumer` and `Delete` reclaim policy, available node disk space, the VolSync Kopia fork and mover NFS admission policy, and NAS access from cluster nodes. The `database/cloudnative-pg-secrets` Secret must contain the existing superuser `username` and `password`. Each cluster's CA Secret must contain `ca.crt`. Dump workers use TLS `verify-full` to the `-rw` Service and run as UID/GID 1000 without mounting CNPG data PVCs. Ceph is not required for staging, but is still used by the separate restore examples.

The orchestrator can manage the two named Leases and ReplicationSources, and read/delete only the two staging PVC names and two dump Job names. It can read namespace Pod metadata to verify lock ownership and mount users. Kubernetes RBAC cannot restrict `create` by resource name, so Job/PVC creation is namespace-wide; treat this as a trusted controller in `database`. Creating Jobs can indirectly access namespace credentials through pod mounts. The orchestrator itself does not mount PostgreSQL credentials, and its worker ServiceAccount has no RoleBinding.

2. Reuse the working Prometheus Kopia connection Secret in the `database` namespace. This pipes credentials directly between commands without printing values or saving plaintext to disk:

```sh
kubectl -n observability get secret kube-prometheus-stack-volsync-secret -o json |
  jq '{apiVersion:"v1", kind:"Secret", type:"Opaque",
       metadata:{name:"cnpg-logical-backups-kopia", namespace:"database"}, data:.data}' |
  kubectl apply -f -
```

Keep the repository password available securely outside the cluster. For Git-managed credentials, encrypt a separate Secret with SOPS; do not commit plaintext Secret data. Re-copy or rotate this Secret when repository credentials change.

3. Render, validate, and deploy the bundle:

```sh
BACKUP_DIR=kubernetes/apps/database/cloudnative-pg/logical-backups
kubectl apply --dry-run=server -k "$BACKUP_DIR"
kubectl apply -k "$BACKUP_DIR"
kubectl -n database get lease postgres16-logical-backup postgres16vector-logical-backup
```

Do not apply `worker-job.yaml` directly: it is a runtime template embedded in the scripts ConfigMap, not a deployable backup Job on its own. Do not apply the `restore` directory during normal deployment. No staging PVC should exist yet. Do not reapply/reset a Lease, scripts ConfigMap, or ReplicationSource while a Job or mover is active. The Lease/source `IfNotPresent` SSA annotations protect job-managed state if later adopted by Flux; CronJobs and scripts still need deliberate GitOps integration. No existing namespace Kustomization was modified by this bundle.

4. Run the first backup manually, once for each cluster. Set `CLUSTER` to `postgres16`, then repeat with `postgres16vector`:

```sh
CLUSTER=postgres16
JOB="$CLUSTER-logical-check-$(date -u +%Y%m%d%H%M%S)"
kubectl -n database create job "$JOB" --from="cronjob/$CLUSTER-logical-backup"
kubectl -n database wait --for=condition=complete "job/$JOB" --timeout=6h
kubectl -n database logs "job/$JOB" -c orchestrator
kubectl -n database get replicationsource "$CLUSTER-logical-backup" -o json |
  jq '{paused:.spec.paused, requested:.spec.trigger.manual,
       completed:.status.lastManualSync, lastSyncTime:.status.lastSyncTime,
       result:.status.latestMoverStatus.result}'
```

Require a completed orchestrator Job, matching requested/completed tokens, a fresh `lastSyncTime`, `result: Successful`, and `paused: true`. The staging PVC and dump Job should be gone after success; the source, Lease and CronJob remain. During a run or after failure, inspect `kubectl -n database logs job/$CLUSTER-logical-backup-dump -c dump` and Pod events. Successful cleanup removes the worker's local pod logs, so use centralized logs for historical diagnostics. A failed Job may leave `kubectl wait` pending until timeout. Check the NAS snapshots and complete the restore rehearsal below; a successful upload alone is not proof of recoverability.

5. Enable daily scheduling after both first backups and restore checks succeed:

```sh
kubectl -n database patch cronjob postgres16-logical-backup --type=merge -p '{"spec":{"suspend":false}}'
kubectl -n database patch cronjob postgres16vector-logical-backup --type=merge -p '{"spec":{"suspend":false}}'
```

The checked-in YAML remains suspended for safe initial deployment. For future reapplication, deliberately set `spec.suspend: false` in both cluster backup YAML files after validation. Monitor failed Jobs, retained PVCs, node disk usage, upload tokens, dump age in `metadata.txt`, and each ReplicationSource's `lastSyncTime`; these manifests do not add alerts. Complete initial uploads before maintenance because the shutdown script's 36-hour VolSync freshness check includes these sources. Finish/recover pending runs before shutdown; the script rejects unfinished Jobs and still-mounted storage consumers.

## Updating an Earlier Deployment

The previous bundle declared permanent Ceph staging PVCs and ran dumping/uploading in one Job. Do not apply this update over an active old run. Suspend both CronJobs, wait for existing Jobs and movers to finish, verify the old dumps have a successful repository snapshot, and keep the sources paused. Preserve any pending dump until it has been successfully uploaded or explicitly abandoned.

The new controller deliberately refuses legacy/unlabeled claims, even if they have the expected names. Changing storage class in place is not supported. After checking backups and obtaining approval to discard the old staging copies, remove only the two old staging claims and wait for their deletion before starting the new workflow. Never relabel a CNPG data PVC as managed staging. Applying the new bundle does not delete or convert old PVCs. Do not remove the ReplicationSources or repository Secret: retaining their names and explicit restore identity preserves access to earlier snapshots.

## Recovering a Failed Run

Start another Job from the same CronJob using the first-run commands above. It will reuse retained staging and its UID-based token rather than allocate another volume. Resolve NAS/network/credentials problems before retrying uploads. If cleanup was interrupted after successful upload, the retry only finishes cleanup; start one more Job for a fresh dump if needed.

If a Lease is held by a Running/Pending pod, inspect that pod and its Job before taking action; the controller does not assume an unreachable owner is dead. Do not delete retained PVCs or a `dump-complete` marker to make errors disappear. If the node/disk or worker identity is irrecoverably lost, suspend scheduling and inspect the source, Lease, Jobs, PVC UID and Kopia snapshots together. Confirm all old workers/movers are stopped before manually resetting state or removing failed staging, and explicitly accept losing any dump that never reached Kopia. The code intentionally stops rather than automate that data-loss decision.

## Restore Step by Step

The supplied files restore **dumps to a new PVC**, then import them into a **new isolated CNPG cluster**. They never overwrite the original CNPG PVCs. Perform one cluster rehearsal at a time with a fresh target; do not reuse a target containing data from a previous restore. Application cutover and production replacement require a separate maintenance plan.

### 1. Choose the Source and Recovery Point

```sh
BACKUP_DIR=kubernetes/apps/database/cloudnative-pg/logical-backups
export CLUSTER=postgres16
RESTORE_AS_OF=""
```

Use `CLUSTER=postgres16vector` for the vector cluster. Leave `RESTORE_AS_OF` empty for the latest available snapshot, or set an RFC3339 UTC time, such as `2026-10-01T06:00:00Z`, to select the latest snapshot at or before that time. Confirm the desired snapshot exists in Kopia first. The Kopia snapshot time is the upload time, not a cross-database transaction timestamp; inspect the restored dump metadata too.

Ensure `database/cnpg-logical-backups-kopia` is available, using the credential-copy step above or the separately secured repository password. The destination specifies the original source name, namespace, and PVC identity so restoration does not depend on the original source PVC surviving.

### 2. Restore Kopia Files to a New PVC

First confirm that `$CLUSTER-logical-restore` is not an existing PVC with data you need. The manifests create a separate staging-sized claim and a paused ReplicationDestination. Do not reuse it for another snapshot after mounting it in tools.

```sh
kubectl apply -f "$BACKUP_DIR/restore/$CLUSTER.yaml"
TOKEN="restore-$(date -u +%Y%m%d%H%M%S)"
PATCH=$(jq -nc --arg token "$TOKEN" --arg asof "$RESTORE_AS_OF" \
  '{spec:{paused:false, trigger:{manual:$token},
          kopia:{restoreAsOf:(if $asof == "" then null else $asof end)}}}')
kubectl -n database patch replicationdestination "$CLUSTER-logical-restore" --type=merge -p "$PATCH"
kubectl -n database wait "replicationdestination/$CLUSTER-logical-restore" \
  "--for=jsonpath={.status.lastManualSync}=$TOKEN" --timeout=2h
kubectl -n database wait "replicationdestination/$CLUSTER-logical-restore" \
  '--for=jsonpath={.status.conditions[?(@.type=="Synchronizing")].status}=False' --timeout=2h
kubectl -n database get replicationdestination "$CLUSTER-logical-restore" -o json |
  jq -e '.status.latestMoverStatus.result == "Successful"'
kubectl -n database patch replicationdestination "$CLUSTER-logical-restore" --type=merge -p '{"spec":{"paused":true}}'
```

Stop on any failure. Do not mount the claim in tools until the mover has finished. Check destination status and mover logs for repository/identity errors. No new source synchronization or database connection is required for this file restore.

### 3. Create an Isolated PostgreSQL Target and Tools Pod

Review [restore/target-cluster.yaml](restore/target-cluster.yaml) first. It creates `cnpg-logical-restore-target`, with an empty control database, a generated superuser Secret, and a separate 50Gi Ceph volume. Match the PostgreSQL version, required extensions/shared libraries, encoding/locale support, and available capacity to the source. Never rename this example to `postgres16` or `postgres16vector`.

```sh
kubectl apply -f "$BACKUP_DIR/restore/target-cluster.yaml"
kubectl -n database wait --for=condition=Ready cluster/cnpg-logical-restore-target --timeout=15m
yq '.spec.volumes[0].persistentVolumeClaim.claimName = strenv(CLUSTER) + "-logical-restore"' \
  "$BACKUP_DIR/restore/tools.yaml" | kubectl apply -f -
kubectl -n database wait --for=condition=Ready pod/cnpg-logical-restore-tools --timeout=5m
kubectl -n database exec cnpg-logical-restore-tools -- /bin/bash -ec \
  'cd /backup/dumps && sha256sum --check SHA256SUMS'
kubectl -n database exec cnpg-logical-restore-tools -- cat /backup/dumps/metadata.txt /backup/dumps/databases.csv
```

Require every checksum to pass. Verify database names and timestamps match the intended source. Review the `database-*.extensions.csv` inventories against the target's installed extensions before import. The tools pod mounts recovered dumps read-only and connects only to the isolated target using its own credentials and CA.

### 4. Review and Restore Roles

Role SQL contains password hashes and privileged role definitions. Treat it as a credential backup, and do not print it in logs or paste it into chat. Make a private working copy outside Git:

```sh
umask 077
RECOVERY_DIR=$(mktemp -d "$HOME/cnpg-logical-restore.XXXXXX")
kubectl -n database cp cnpg-logical-restore-tools:/backup/dumps/roles.sql "$RECOVERY_DIR/roles.sql"
code "$RECOVERY_DIR/roles.sql"
```

Review the SQL before executing it. Remove the `CREATE ROLE "postgres";` and `ALTER ROLE "postgres" ...;` statements so the target's existing administrator and generated credentials remain intact. Also review any statements involving target-existing or CNPG-managed roles, including `logical_restore_control`; reconcile conflicts explicitly rather than ignoring SQL errors. Retain the application roles and memberships needed to preserve archive ownership and grants. Apply only this reviewed copy:

```sh
kubectl -n database cp "$RECOVERY_DIR/roles.sql" cnpg-logical-restore-tools:/work/roles-reviewed.sql
kubectl -n database exec cnpg-logical-restore-tools -- \
  psql -X --no-password --set=ON_ERROR_STOP=1 --file=/work/roles-reviewed.sql
```

Do not continue if role restoration fails. Protect or securely dispose of the local working copy when finished. EmptyDir files in `/work` disappear when the tools pod is deleted.

### 5. Restore Databases into the Fresh Target

Archive filenames are indexed by the CSV and binary name list. `--create` restores original database names, ownership, and grants. The following block refuses a target with unexpected databases and replaces only the **empty `postgres` database on the new test target**, not production. Run it only after verifying `PGHOST` and the target's contents.

```sh
kubectl -n database exec -i cnpg-logical-restore-tools -- /bin/bash -se <<'RESTORE'
set -Eeuo pipefail
[[ "$PGHOST" == cnpg-logical-restore-target-rw.database.svc.cluster.local ]]
unexpected=$(psql -X --no-password --set=ON_ERROR_STOP=1 -Atc \
  "SELECT count(*) FROM pg_database WHERE NOT datistemplate AND datname NOT IN ('postgres', 'logical_restore_control')")
[[ "$unexpected" == 0 ]]
existing_relations=$(PGDATABASE=postgres psql -X --no-password --set=ON_ERROR_STOP=1 -Atc \
  "SELECT count(*) FROM pg_class JOIN pg_namespace ON pg_namespace.oid = relnamespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'")
[[ "$existing_relations" == 0 ]]
dropdb --no-password --if-exists postgres
archive_index=0
while IFS= read -r -d '' database; do
    archive_index=$((archive_index + 1))
    printf -v archive '/backup/dumps/database-%04d.dump' "$archive_index"
    pg_restore --no-password --exit-on-error --create --no-tablespaces --dbname=template1 "$archive"
    PGDATABASE="$database" vacuumdb --no-password --analyze-in-stages
done < /backup/dumps/database-names.bin
RESTORE
```

For a single database, select its archive from `databases.csv` and run `pg_restore --exit-on-error --create --no-tablespaces --dbname=template1 /backup/dumps/database-NNNN.dump` against the new target after checking that database does not already exist. A logical restore is not CNPG `bootstrap.recovery`: it does not require changing the original clusters' versioned Barman server names.

Archive imports may execute SQL functions and extension code. Restore only trusted backups into an appropriately isolated target. On any import error, stop and diagnose the first error; do not suppress failures or continue into a half-restored database. Use a new empty target for a clean retry after reviewing the existing target and PVCs.

### 6. Validate, Then Plan Any Cutover

Check expected databases, schemas, extensions, row counts, sequences, owners/grants, and application logins. Perform application read/write smoke tests against the isolated target without directing production traffic there. Store the successful rehearsal date and snapshot identity in your operational records.

For real recovery, keep application writers stopped until validation is complete. Plan Service/connection-string and Secret changes separately, enable native CNPG backup/WAL archiving on the recovered cluster with a new unused backup server name, and verify its first backup. Do not switch production to the example target solely because `pg_restore` exited successfully.

Stop the tools process when finished:

```sh
kubectl -n database delete pod cnpg-logical-restore-tools
```

Keep the recovered-dump PVC and isolated database until verification/retention decisions are complete. Removing the ReplicationDestination does not justify deleting either claim. PVCs may have `Delete` reclaim policy; delete them only after explicitly deciding the copies are no longer needed. No automated cleanup deletes data.

## Validation and Maintenance

```sh
bash scripts/test-cnpg-logical-backup.sh
bash scripts/test-cnpg-logical-backup.sh --integration
shellcheck -x kubernetes/apps/database/cloudnative-pg/logical-backups/{backup,orchestrate}.sh scripts/test-cnpg-logical-backup.sh
kubectl apply --dry-run=server -k kubernetes/apps/database/cloudnative-pg/logical-backups
kubectl apply --dry-run=server -f kubernetes/apps/database/cloudnative-pg/logical-backups/restore
```

The default tests cover dump publication, unusual database names, Lease contention/stale owners, retries, retained volumes, legacy-claim rejection and cleanup gating. `--integration` requires Docker and runs a real PostgreSQL dump/restore in a network-isolated, auto-removed container, checking roles, ownership, grants, data and sequences. It stops both temporary PostgreSQL servers on exit. These tests do not prove live OpenEBS scheduling, mover permissions, or NAS write access; complete the first-run checks and isolated restore rehearsal before relying on this policy. The shutdown preflight also checks backup freshness for any active restore-test CNPG cluster, so account for test resources before maintenance.
