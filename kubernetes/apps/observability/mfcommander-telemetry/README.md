# mfcommander-telemetry

Mirrors MFCommander's three DynamoDB tables (AWS `us-east-1`) into the `mfcommander` database on the `postgres16` CNPG cluster every 30 minutes, and provisions an admin-only Grafana dashboard over the mirror.

| Source table | Postgres table | Notes |
|---|---|---|
| `mfcommander-telemetry` | `telemetry_reports` | one row per `(install_id, day)`; `counters` is `jsonb`. `schema_version` 1 counters are range ordinals (0..5 = 0, 1, 2–5, 6–20, 21–100, >100), `schema_version` 2 counters are exact counts. Every row so far is v1: exact counts start with the first MFCommander release built with payload v2, and only from installs that have updated to it. Legacy `ttl` is ignored. |
| `mfcommander-telemetry-aggregates` | `telemetry_aggregates` | `(cohort_week, month)`; `month` is stored as the first day of that month. |
| `mfcommander-licenses` | `licenses` | attribute-restricted Scan (`Select=SPECIFIC_ATTRIBUTES`); `signed_key` is never requested. `recover-throttle#…` bookkeeping rows are skipped. Includes licensee `email` and `customer_name`. |
| — | `sync_runs` | one row per run (start, finish, row counts); rows older than 90 days are pruned. |

**Copy semantics are deliberate (owner decision, 2026-10-14).** Each run scans all three tables and writes them in one transaction:

- `telemetry_reports` and `telemetry_aggregates` are **kept forever**: rows are upserted on their DynamoDB key and never deleted, so Postgres survives a row, or a whole table, lost in AWS. `sync_runs` records how many rows each run *read*, not how many Postgres holds.
- `licenses` is an **exact mirror**: truncated and reloaded, so a refund or revocation never leaves a stale row.

**An erasure request therefore needs a manual step here.** After deleting the installation's rows in DynamoDB, delete them from the copy too:

```sql
-- as mfcommander_sync (the owner), in the mfcommander database
DELETE FROM telemetry_reports WHERE install_id = '<install-id>';
```

Monthly aggregates carry no installation identifier and need nothing.

## Layout

```
ks.yaml                          Flux Kustomization (dependsOn cloudnative-pg-cluster, grafana-instance)
app/sync.py                      the sync (python 3.13, boto3, psycopg 3) — shipped as a ConfigMap
app/test_sync.py                 pytest suite — local only, not in the kustomization
app/cronjob.yaml                 */30 CronJob; initContainer pip-installs pinned deps into an emptyDir
app/aws.sops.yaml                AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (placeholders until step 3)
app/postgres.sops.yaml           PGPASSWORD for mfcommander_sync
app/grafana-datasource.sops.yaml MFCOMMANDER_GRAFANA_PASSWORD for the datasource
app/grafana.yaml                 GrafanaDatasource `mfcommander`, GrafanaFolder `MFCommander` (Admin only), GrafanaDashboard
app/dashboards/mfcommander.json  dashboard model
```

Related changes outside this directory:

- `kubernetes/apps/database/cloudnative-pg/cluster/cluster16.yaml` declares the managed roles `mfcommander_sync` (login, owner) and `mfcommander_grafana` (login, read-only), with passwords from `mfcommander-sync-role.sops.yaml` / `mfcommander-grafana-role.sops.yaml` (basic-auth secrets in `database`).
- `kubernetes/apps/database/cloudnative-pg/cluster/database-mfcommander.yaml` is a CNPG `Database` CR that adopts the existing `mfcommander` database and transfers its ownership to `mfcommander_sync` (`databaseReclaimPolicy: retain`, so removing the CR never drops the data).

The two copies of each password must stay identical: `postgres.sops.yaml` matches `mfcommander-sync-role.sops.yaml`, and `grafana-datasource.sops.yaml` matches `mfcommander-grafana-role.sops.yaml`. To rotate, change both files of a pair.

## Privileges

- `mfcommander_sync` owns the database, so it creates the tables in `public` (owned by `pg_database_owner`) and on every run grants `USAGE` on `public`, `SELECT` on all tables, and default `SELECT` privileges to `mfcommander_grafana`.
- PUBLIC has `CONNECT` on a new database by default. The sync revokes it on `mfcommander` and grants `CONNECT` to `mfcommander_grafana` only, so other cluster roles cannot open the database (superusers are unaffected).
- `mfcommander_grafana` can only read. Grafana connects to `postgres16-ro` (replica).

## Owner steps (in order)

1. **Deploy the API stack** so the IAM user exists: in the MFCommander repo, `cd mfsoft-web/infra && npx cdk deploy MfsoftApiStack`.
2. **Create the sync user's access key** (shown once):
   ```bash
   aws iam create-access-key --user-name mfcommander-telemetry-sync
   ```
3. **Store it in the SOPS secret** (from the talos-cluster root, with the age key available):
   ```bash
   F=kubernetes/apps/observability/mfcommander-telemetry/app/aws.sops.yaml
   sops set "$F" '["stringData"]["AWS_ACCESS_KEY_ID"]' '"AKIA…"'
   sops set "$F" '["stringData"]["AWS_SECRET_ACCESS_KEY"]' '"…"'
   sops -d "$F" | grep -c REPLACE_AFTER_CDK_DEPLOY   # expect 0
   ```
4. **Commit and reconcile**: review `git status` (the task stages everything), then `task flux:commit -- "add mfcommander telemetry mirror and dashboard"`.
5. **Verify the roles, the database owner, and the first Job run**:
   ```bash
   kubectl -n database get cluster postgres16 -o jsonpath='{.status.managedRolesStatus}'; echo
   kubectl -n database get database postgres16-mfcommander   # APPLIED should be true
   kubectl -n observability create job --from=cronjob/mfcommander-telemetry-sync mfcommander-telemetry-sync-manual
   kubectl -n observability logs -f job/mfcommander-telemetry-sync-manual -c sync   # "sync complete {...}"
   kubectl -n observability delete job mfcommander-telemetry-sync-manual
   ```
   An `AccessDeniedException` on the licenses table means the Scan request and the IAM policy disagree on the attribute list; `password authentication failed` means a password pair above diverged.
6. **Open the dashboard**: Grafana → Dashboards → **MFCommander** → *MFCommander telemetry & licenses*. "Minutes since last sync" should be under 45.

If the `Database` CR cannot be used for some reason, the equivalent one-time SQL as `postgres` is:

```sql
ALTER DATABASE mfcommander OWNER TO mfcommander_sync;
```

## Tests

`test_sync.py` covers the pure conversion and scan code with in-memory fake tables (no network, no database). From this directory:

```bash
python3.13 -m venv /tmp/mfct-venv
/tmp/mfct-venv/bin/pip install pytest
cd app && PYTHONDONTWRITEBYTECODE=1 /tmp/mfct-venv/bin/python -m pytest -p no:cacheprovider test_sync.py
rm -rf /tmp/mfct-venv
```

`sync.py` imports `boto3` and `psycopg` only inside `main()`/`write_mirror()`, so the unit tests need nothing but pytest.

## Dashboard notes

- Feature reach and the trial funnel count distinct installs with a counter above zero, which is valid for both schema versions.
- Usage volume sums exact counts from `schema_version = 2` rows only; v1 range ordinals cannot be summed. The panel stays empty until a v2 release is in users' hands.
- The license roster and "Active now" ignore the dashboard time range; other license panels filter on `issued_at`, `revoked_at` or `last_validated_at`.
