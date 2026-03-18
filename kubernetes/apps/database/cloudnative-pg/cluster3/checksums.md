# PostgreSQL Data Checksums

Data checksums detect storage-level corruption (bad pages, TOAST corruption, pglz decompression failures) before they cause crashes or silent data loss. Checksums were enabled on this cluster on 2026-03-17.

## Check if checksums are enabled

```bash
# Query the primary
kubectl -n database exec postgres16vector-2 -c postgres -- \
  psql -U postgres -c "SHOW data_checksums;"
```

Expected output: `on`

## Check for checksum failures

```bash
# Query the failure counter per database
kubectl -n database exec postgres16vector-2 -c postgres -- \
  psql -U postgres -c "SELECT datname, checksum_failures, checksum_last_failure FROM pg_stat_database WHERE checksum_failures > 0;"
```

If no rows are returned, there have been no checksum failures.

### Prometheus metric

CNPG exports checksum failures via PodMonitor:

```promql
cnpg_pg_stat_database_checksum_failures{cluster="postgres16vector"}
```

Alert when this value increases above 0.

## Enable checksums on a cluster (one-time procedure)

Checksums can only be enabled when PostgreSQL is stopped. Use CNPG fencing to stop Postgres on each instance without deleting the pod.

### Prerequisites

- All instances must be healthy (`Ready` and replicating)
- Do replicas first, primary last
- Each instance takes ~5-7 minutes for ~36GB of data

### Procedure

1. Identify current roles:

```bash
kubectl -n database get pods -l cnpg.io/cluster=postgres16vector -L role -o wide
```

2. Fence a replica (stops Postgres on it):

```bash
kubectl cnpg -n database fencing on postgres16vector <pod-name>
```

3. Run pg_checksums on the fenced instance:

```bash
kubectl -n database exec <pod-name> -c postgres -- \
  pg_checksums --enable --progress --pgdata /var/lib/postgresql/data/pgdata
```

4. Unfence the instance (restarts Postgres):

```bash
kubectl cnpg -n database fencing off postgres16vector <pod-name>
```

5. Verify the instance is healthy and replicating before proceeding:

```bash
kubectl -n database get pods -l cnpg.io/cluster=postgres16vector -L role
```

6. Repeat steps 2-5 for each remaining replica, then the primary.

### Order of operations

```
replica (pod-5)  -> fence -> pg_checksums --enable -> unfence -> verify
replica (pod-1)  -> fence -> pg_checksums --enable -> unfence -> verify
primary (pod-2)  -> fence -> pg_checksums --enable -> unfence -> verify
```

Fencing the primary does not trigger an automatic switchover. Postgres stops, checksums are written, and it restarts as primary.

## Behavior when corruption is detected

- PostgreSQL raises an `ERROR` and refuses to return data from the corrupted page
- The query fails but the server stays up (no crash, no failover)
- A `WARNING: page verification failed` message is logged with the relation name and block number
- The `pg_stat_database.checksum_failures` counter increments
- To read past corrupted pages for data recovery, set per-session: `SET ignore_checksum_failure = on;`

## Notes

- Checksums are stored in the data files on disk, not in the CNPG Cluster manifest
- Recovery-based bootstraps inherit the checksum state from the backup
- Performance overhead is minimal (1-3% for CRC-32 on page reads/writes)
- If bootstrapping a new cluster via `initdb`, set `bootstrap.initdb.dataChecksums: true` in the Cluster spec
