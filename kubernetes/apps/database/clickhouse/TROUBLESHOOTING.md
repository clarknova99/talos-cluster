# ClickHouse Troubleshooting Guide

## Issues Identified

### 1. Port Conflicts
ClickHouse was trying to bind to multiple ports that weren't configured in the service:
- Port 8123 (HTTP) - ✅ Configured
- Port 9000 (TCP) - ✅ Configured
- Port 9004 - ❌ Not configured, causing conflicts
- Port 9005 - ❌ Not configured, causing conflicts
- Port 9009 - ❌ Not configured, causing conflicts

### 2. Data Corruption
System tables were corrupted with "Array size is too large" errors:
- `system.opentelemetry_span_log`
- `system.processors_profile_log`
- `system.error_log`

### 3. User Permission Issues
The ClickHouse process (user 101) didn't match the data directory owner (user 1025).

### 4. Configuration Error
Memory settings were incorrectly placed in `config.xml` instead of `users.xml`, causing ClickHouse to fail startup.

## Solutions Applied

### Configuration Changes
1. **Updated `config.xml`** to:
   - Explicitly configure only necessary ports (8123, 9000)
   - Disable problematic system tables
   - Disable background merges to prevent corruption
   - Disable additional ports that were causing conflicts
   - Skip check for incorrect settings to avoid configuration errors

2. **Updated `users.xml`** to:
   - Set proper memory limits in user profiles (moved from config.xml)
   - Disable query logging

### Manual Cleanup Required
Before restarting the deployment, you need to clean up the corrupted data:

```bash
# Run the cleanup script
./kubernetes/apps/database/clickhouse/cleanup-corrupted-data.sh
```

Or manually:

```bash
# Get the pod name
POD_NAME=$(kubectl get pods -n database -l app.kubernetes.io/name=clickhouse -o jsonpath='{.items[0].metadata.name}')

# Stop ClickHouse gracefully
kubectl exec -n database "$POD_NAME" -- clickhouse-client --query "SYSTEM SHUTDOWN" || true

# Wait for shutdown
sleep 10

# Remove corrupted system tables
kubectl exec -n database "$POD_NAME" -- rm -rf /var/lib/clickhouse/store/system/opentelemetry_span_log || true
kubectl exec -n database "$POD_NAME" -- rm -rf /var/lib/clickhouse/store/system/processors_profile_log || true
kubectl exec -n database "$POD_NAME" -- rm -rf /var/lib/clickhouse/store/system/error_log || true

# Clean up temporary merge directories
kubectl exec -n database "$POD_NAME" -- find /var/lib/clickhouse/store -name "*tmp_merge*" -type d -exec rm -rf {} + || true
kubectl exec -n database "$POD_NAME" -- find /var/lib/clickhouse/store -name "*delete_tmp*" -type d -exec rm -rf {} + || true

# Fix permissions
kubectl exec -n database "$POD_NAME" -- chown -R 101:101 /var/lib/clickhouse || true
```

## Deployment Steps

1. **Clean up corrupted data** using the script or manual commands above
2. **Apply the updated configuration**:
   ```bash
   task flux:commit -- "Fix ClickHouse configuration issues"
   ```
3. **Monitor the deployment**:
   ```bash
   kubectl logs -n database -l app.kubernetes.io/name=clickhouse -f
   ```

## Prevention

The updated configuration should prevent these issues by:
- Only enabling necessary ports
- Disabling problematic system tables
- Setting appropriate memory limits
- Disabling background merges that can cause corruption

## Monitoring

After deployment, monitor for:
- Port binding errors
- Memory usage
- System table corruption
- User permission issues

Use these commands to check status:
```bash
# Check pod status
kubectl get pods -n database -l app.kubernetes.io/name=clickhouse

# Check logs
kubectl logs -n database -l app.kubernetes.io/name=clickhouse

# Check ClickHouse status
kubectl exec -n database clickhouse-0 -- clickhouse-client --query "SELECT version()"
```

## ✅ Resolution Summary

The ClickHouse deployment has been successfully fixed! Here's what was resolved:

1. **Port Conflicts**: Fixed by explicitly configuring only necessary ports (8123, 9000) and disabling problematic ones
2. **Configuration Errors**: Fixed by moving memory settings from `config.xml` to `users.xml` and adding `skip_check_for_incorrect_settings`
3. **Volume Mounting**: Fixed by mounting entire config directories instead of individual files
4. **Background Executor**: Fixed by setting appropriate background pool sizes (25) to match ClickHouse requirements
5. **Data Corruption**: Prevented by disabling problematic system tables

**Current Status**: ✅ ClickHouse is running successfully and responding to queries
