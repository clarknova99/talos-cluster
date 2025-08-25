#!/bin/bash

# Script to clean up corrupted ClickHouse data
# This should be run before restarting the ClickHouse deployment

set -e

echo "Cleaning up corrupted ClickHouse data..."

# Get the ClickHouse pod name
POD_NAME=$(kubectl get pods -n database -l app.kubernetes.io/name=clickhouse -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD_NAME" ]; then
    echo "No ClickHouse pod found. Make sure the deployment is running."
    exit 1
fi

echo "Found ClickHouse pod: $POD_NAME"

# Stop ClickHouse gracefully
echo "Stopping ClickHouse..."
kubectl exec -n database "$POD_NAME" -- clickhouse-client --query "SYSTEM SHUTDOWN" || true

# Wait a moment for shutdown
sleep 10

# Remove corrupted system tables
echo "Removing corrupted system tables..."
kubectl exec -n database "$POD_NAME" -- rm -rf /var/lib/clickhouse/store/system/opentelemetry_span_log || true
kubectl exec -n database "$POD_NAME" -- rm -rf /var/lib/clickhouse/store/system/processors_profile_log || true
kubectl exec -n database "$POD_NAME" -- rm -rf /var/lib/clickhouse/store/system/error_log || true

# Clean up temporary merge directories
echo "Cleaning up temporary merge directories..."
kubectl exec -n database "$POD_NAME" -- find /var/lib/clickhouse/store -name "*tmp_merge*" -type d -exec rm -rf {} + || true
kubectl exec -n database "$POD_NAME" -- find /var/lib/clickhouse/store -name "*delete_tmp*" -type d -exec rm -rf {} + || true

# Fix permissions
echo "Fixing data directory permissions..."
kubectl exec -n database "$POD_NAME" -- chown -R 101:101 /var/lib/clickhouse || true

echo "Cleanup completed. You can now restart the ClickHouse deployment."
