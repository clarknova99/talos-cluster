# Dittofeed Troubleshooting Guide

## User Properties Not Computing

If user properties are not being computed or are stale, follow these steps to diagnose and resolve the issue.

### Quick Diagnosis

1. **Check when properties were last computed:**
   ```bash
   kubectl exec -n sensei $(kubectl get pod -n sensei -l app.kubernetes.io/name=dittofeed-clickhouse -o jsonpath='{.items[0].metadata.name}') -c app -- clickhouse-client --query "SELECT count() as total, max(processed_at) as last_processed FROM dittofeed.processed_computed_properties_v2"
   ```

2. **Check when properties were last assigned:**
   ```bash
   kubectl exec -n sensei $(kubectl get pod -n sensei -l app.kubernetes.io/name=dittofeed-clickhouse -o jsonpath='{.items[0].metadata.name}') -c app -- clickhouse-client --query "SELECT count() as total, max(assigned_at) as last_assignment FROM dittofeed.computed_property_assignments_v2"
   ```

   If `last_processed` or `last_assignment` are more than a few hours old, the compute workflow is likely stopped.

### Common Issues and Solutions

#### Issue 1: Compute Properties Workflow Not Running

**Symptoms:**
- Properties haven't been processed in hours/days
- Queue shows no activity

**Solution:**
```bash
# Get the admin CLI pod
ADMIN_POD=$(kubectl get pod -n sensei -l app.kubernetes.io/name=dittofeed-admin-cli -o jsonpath='{.items[0].metadata.name}')

# Start the global compute properties workflow
kubectl exec -n sensei $ADMIN_POD -- /service/admin.sh start-compute-properties-global

# Verify it's running
kubectl exec -n sensei $ADMIN_POD -- /service/admin.sh get-queue-state
```

Expected output should show `totalProcessed` > 0 and the workflow processing workspaces.

#### Issue 2: ClickHouse System Table Corruption

**Symptoms:**
- ClickHouse logs showing errors like:
  - `Array size at index X is too large`
  - `TOO_LARGE_ARRAY_SIZE`
  - `CHECKSUM_DOESNT_MATCH`
  - Errors related to `system.latency_log`, `system.metric_log`, etc.

**Solution:**

1. **Identify corrupted system tables:**
   ```bash
   CH_POD=$(kubectl get pod -n sensei -l app.kubernetes.io/name=dittofeed-clickhouse -o jsonpath='{.items[0].metadata.name}')
   kubectl logs -n sensei $CH_POD -c app --tail=200 | grep -i "error"
   ```

2. **Create force drop flag (needed to drop large tables):**
   ```bash
   kubectl exec -n sensei $CH_POD -c app -- sh -c "mkdir -p /var/lib/clickhouse/flags && touch /var/lib/clickhouse/flags/force_drop_table && chmod 666 /var/lib/clickhouse/flags/force_drop_table"
   ```

3. **Drop corrupted system log tables:**
   ```bash
   kubectl exec -n sensei $CH_POD -c app -- clickhouse-client --query "
   DROP TABLE IF EXISTS system.query_log SYNC;
   DROP TABLE IF EXISTS system.query_thread_log SYNC;
   DROP TABLE IF EXISTS system.text_log SYNC;
   DROP TABLE IF EXISTS system.trace_log SYNC;
   DROP TABLE IF EXISTS system.metric_log SYNC;
   DROP TABLE IF EXISTS system.asynchronous_metric_log SYNC;
   DROP TABLE IF EXISTS system.session_log SYNC;
   DROP TABLE IF EXISTS system.part_log SYNC;
   DROP TABLE IF EXISTS system.opentelemetry_span_log SYNC;
   DROP TABLE IF EXISTS system.processors_profile_log SYNC;
   DROP TABLE IF EXISTS system.error_log SYNC;
   DROP TABLE IF EXISTS system.query_metric_log SYNC;
   DROP TABLE IF EXISTS system.query_views_log SYNC;
   DROP TABLE IF EXISTS system.asynchronous_insert_log SYNC;
   DROP TABLE IF EXISTS system.crash_log SYNC;
   DROP TABLE IF EXISTS system.background_schedule_pool_log SYNC;
   DROP TABLE IF EXISTS system.latency_log SYNC;
   DROP TABLE IF EXISTS system.metric_log_0 SYNC;
   "
   ```

4. **Clean up corrupted temporary files:**
   ```bash
   kubectl exec -n sensei $CH_POD -c app -- sh -c "find /var/lib/clickhouse/store -name 'delete_tmp_*' -type d -exec rm -rf {} + 2>/dev/null || true"
   ```

5. **Note on system table configuration:**

   **Good news!** System tables are now configured with automatic TTL (Time To Live) retention policies in the ClickHouse configuration. Data older than 1 day is automatically deleted, preventing the tables from growing too large.

   The configuration in `kubernetes/apps/sensei/dittofeed/clickhouse/helmrelease.yaml` includes:
   ```xml
   <query_log>
       <database>system</database>
       <table>query_log</table>
       <partition_by>toYYYYMM(event_date)</partition_by>
       <ttl>event_date + INTERVAL 1 DAY DELETE</ttl>
   </query_log>
   ```

   This is applied to all major system tables (query_log, metric_log, trace_log, text_log, part_log, session_log).

   **Note:** Attempting to use `<engine>None</engine>` will cause ClickHouse to fail. Always use the full table configuration with explicit database, table, partition_by, and ttl parameters.

6. **Verify TTL is applied:**

   You can verify the TTL is working:
   ```bash
   kubectl exec -n sensei $CH_POD -c app -- clickhouse-client --query "SHOW CREATE TABLE system.query_log" | grep TTL
   ```

   Expected output: `TTL event_date + toIntervalDay(1)`

7. **Restart ClickHouse to apply clean state:**
   ```bash
   kubectl rollout restart deployment -n sensei dittofeed-clickhouse
   kubectl rollout status deployment -n sensei dittofeed-clickhouse
   ```

#### Issue 3: Temporal Worker Connectivity Issues

**Symptoms:**
- Logs showing `dial tcp ... i/o timeout`
- Workers not connecting to Temporal server

**Solution:**

1. **Verify Temporal is running:**
   ```bash
   kubectl get pods -n sensei | grep dittofeed-temporal
   ```

2. **Check Temporal is listening on correct port:**
   ```bash
   TEMPORAL_POD=$(kubectl get pod -n sensei -l app.kubernetes.io/name=dittofeed-temporal -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n sensei $TEMPORAL_POD -c temporal -- sh -c "ss -tlnp | grep 7233"
   ```

3. **Restart Dittofeed app to reconnect workers:**
   ```bash
   kubectl rollout restart deployment -n sensei dittofeed
   kubectl rollout status deployment -n sensei dittofeed
   ```

4. **Verify worker is created in logs:**
   ```bash
   APP_POD=$(kubectl get pod -n sensei -l app.kubernetes.io/name=dittofeed -o jsonpath='{.items[0].metadata.name}')
   kubectl logs -n sensei $APP_POD | grep "Creating worker"
   ```

### Monitoring Health

Create a monitoring script to check system health:

```bash
#!/bin/bash
# File: check-dittofeed-health.sh

echo "=== Dittofeed Health Check ==="

# Get pod names
CH_POD=$(kubectl get pod -n sensei -l app.kubernetes.io/name=dittofeed-clickhouse -o jsonpath='{.items[0].metadata.name}')
ADMIN_POD=$(kubectl get pod -n sensei -l app.kubernetes.io/name=dittofeed-admin-cli -o jsonpath='{.items[0].metadata.name}')

echo -e "\n1. Last Property Computation:"
kubectl exec -n sensei $CH_POD -c app -- clickhouse-client --query "SELECT max(processed_at) as last_processed FROM dittofeed.processed_computed_properties_v2"

echo -e "\n2. Last Property Assignment:"
kubectl exec -n sensei $CH_POD -c app -- clickhouse-client --query "SELECT max(assigned_at) as last_assignment FROM dittofeed.computed_property_assignments_v2"

echo -e "\n3. Recent Computations (last 5 min):"
kubectl exec -n sensei $CH_POD -c app -- clickhouse-client --query "SELECT count() FROM dittofeed.computed_property_assignments_v2 WHERE assigned_at > now() - INTERVAL 5 MINUTE"

echo -e "\n4. Compute Queue State:"
kubectl exec -n sensei $ADMIN_POD -- /service/admin.sh get-queue-state 2>&1 | grep -E "queueSize|inFlightCount|totalProcessed"

echo -e "\n5. ClickHouse Errors (last 50 lines):"
kubectl logs -n sensei $CH_POD -c app --tail=50 | grep -i "error" | tail -5

echo -e "\n=== Health Check Complete ==="
```

Save this script and run periodically to monitor system health.

### Emergency Recovery

If all else fails and you need to do a complete reset:

1. **Stop compute properties workflow:**
   ```bash
   ADMIN_POD=$(kubectl get pod -n sensei -l app.kubernetes.io/name=dittofeed-admin-cli -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n sensei $ADMIN_POD -- /service/admin.sh stop-compute-properties-global
   ```

2. **Clean ClickHouse system tables (as shown in Issue 2)**

3. **Restart all Dittofeed components:**
   ```bash
   kubectl rollout restart deployment -n sensei dittofeed-clickhouse
   kubectl rollout restart deployment -n sensei dittofeed-temporal
   kubectl rollout restart deployment -n sensei dittofeed

   # Wait for all to be ready
   kubectl rollout status deployment -n sensei dittofeed-clickhouse
   kubectl rollout status deployment -n sensei dittofeed-temporal
   kubectl rollout status deployment -n sensei dittofeed
   ```

4. **Start compute properties workflow:**
   ```bash
   kubectl exec -n sensei $ADMIN_POD -- /service/admin.sh start-compute-properties-global
   ```

5. **Verify everything is working:**
   ```bash
   # Check queue state
   kubectl exec -n sensei $ADMIN_POD -- /service/admin.sh get-queue-state

   # Wait 2-3 minutes, then check for recent computations
   sleep 180
   CH_POD=$(kubectl get pod -n sensei -l app.kubernetes.io/name=dittofeed-clickhouse -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n sensei $CH_POD -c app -- clickhouse-client --query "SELECT count() FROM dittofeed.computed_property_assignments_v2 WHERE assigned_at > now() - INTERVAL 5 MINUTE"
   ```

### Prevention

To prevent future issues:

1. **System tables are disabled** in the ClickHouse configuration using `<engine>None</engine>` syntax
2. **Monitor disk usage** on the NFS mount used by ClickHouse (`/volume1/network-storage/cluster/dittofeed/clickhouse`)
3. **Regularly check** that the compute properties workflow is running
4. **Set up alerts** if properties haven't been computed in > 6 hours

### References

- Dittofeed Admin CLI: `/service/admin.sh --help`
- ClickHouse Configuration: `kubernetes/apps/sensei/dittofeed/clickhouse/helmrelease.yaml`
- Temporal Configuration: `kubernetes/apps/sensei/dittofeed/temporal/helmrelease.yaml`
- Main App Configuration: `kubernetes/apps/sensei/dittofeed/app/helmrelease.yaml`


### References

Backup:
clickhouse-backup create prod_manual_backup
clickhouse-backup list remote
clickhouse-backup restore_remote <backup_name>

# physical size of db
```sql
SELECT
  formatReadableSize(sum(bytes_on_disk)) AS size_on_disk
FROM system.parts
WHERE active AND database = 'dittofeed';
```
```
size_on_disk|
------------+
257.62 MiB  |
```
# tables row counts
```sql
SELECT
  table,
  sum(rows) AS rows
FROM system.parts
WHERE active
  AND database = 'dittofeed'
GROUP BY table
ORDER BY rows DESC;
```
```
table                           |rows   |
--------------------------------+-------+
updated_property_assignments_v2 |3565619|
computed_property_state_v3      |1383044|
computed_property_assignments_v2| 543069|
resolved_segment_state          | 522568|
user_events_v2                  | 276917|
computed_property_state_index   | 162036|
internal_events                 | 125597|
processed_computed_properties_v2|  32545|
updated_computed_property_state |   4666|
```
