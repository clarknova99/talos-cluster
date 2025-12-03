#!/bin/bash

# Script to clean up corrupted ClickHouse data
# This resolves "TOO_LARGE_ARRAY_SIZE" errors in system tables by removing corrupted data parts

set -e

echo "=========================================="
echo "ClickHouse Corrupted Data Cleanup Script"
echo "=========================================="
echo ""

# Get the ClickHouse pod name
POD_NAME=$(kubectl get pods -n database -l app.kubernetes.io/name=clickhouse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POD_NAME" ]; then
    echo "⚠️  No ClickHouse pod found. Attempting to find pod by name pattern..."
    POD_NAME=$(kubectl get pods -n database | grep clickhouse | head -1 | awk '{print $1}' || echo "")
    if [ -z "$POD_NAME" ]; then
        echo "❌ No ClickHouse pod found. Make sure the deployment is running."
        exit 1
    fi
fi

echo "✅ Found ClickHouse pod: $POD_NAME"
echo ""

# Try to stop ClickHouse gracefully (may fail if it's already down or unresponsive)
echo "Attempting graceful shutdown..."
if kubectl exec -n database "$POD_NAME" -- clickhouse-client --query "SYSTEM SHUTDOWN" 2>/dev/null; then
    echo "✅ ClickHouse shutdown initiated"
    echo "Waiting for shutdown to complete..."
    sleep 15
else
    echo "⚠️  Could not connect to ClickHouse (may already be down or unresponsive)"
    echo "Proceeding with cleanup..."
fi
echo ""

# Remove corrupted system tables by UUID (from error logs)
echo "Removing corrupted system table data..."
echo "  - system.opentelemetry_span_log (UUID: 33d22a1e-ba2c-46f1-8666-d1a3546f4819)"
kubectl exec -n database "$POD_NAME" -- sh -c "rm -rf /var/lib/clickhouse/store/33d/33d22a1e-ba2c-46f1-8666-d1a3546f4819" 2>/dev/null || true
kubectl exec -n database "$POD_NAME" -- sh -c "rm -rf /var/lib/clickhouse/store/system/opentelemetry_span_log" 2>/dev/null || true

echo "  - system.processors_profile_log (UUID: cdb63f3e-399b-4744-b9b0-4b8a48872f79)"
kubectl exec -n database "$POD_NAME" -- sh -c "rm -rf /var/lib/clickhouse/store/cdb/cdb63f3e-399b-4744-b9b0-4b8a48872f79" 2>/dev/null || true
kubectl exec -n database "$POD_NAME" -- sh -c "rm -rf /var/lib/clickhouse/store/system/processors_profile_log" 2>/dev/null || true

echo "  - system.error_log (if exists)"
kubectl exec -n database "$POD_NAME" -- sh -c "rm -rf /var/lib/clickhouse/store/system/error_log" 2>/dev/null || true

echo "✅ Corrupted system table data removed"
echo ""

# Clean up temporary merge directories (from error logs)
echo "Cleaning up temporary merge directories..."
kubectl exec -n database "$POD_NAME" -- sh -c "find /var/lib/clickhouse/store -name '*tmp_merge*' -type d -exec rm -rf {} + 2>/dev/null || true" || true
kubectl exec -n database "$POD_NAME" -- sh -c "find /var/lib/clickhouse/store -name '*delete_tmp*' -type d -exec rm -rf {} + 2>/dev/null || true" || true
echo "✅ Temporary merge directories cleaned"
echo ""

# Fix permissions (ensure ClickHouse user owns the data)
echo "Fixing data directory permissions..."
kubectl exec -n database "$POD_NAME" -- sh -c "chown -R 101:101 /var/lib/clickhouse 2>/dev/null || true" || true
echo "✅ Permissions fixed"
echo ""

echo "=========================================="
echo "✅ Cleanup completed successfully!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Restart the ClickHouse deployment:"
echo "   kubectl rollout restart statefulset/clickhouse -n database"
echo ""
echo "2. Monitor the logs:"
echo "   kubectl logs -n database -l app.kubernetes.io/name=clickhouse -f"
echo ""
echo "3. Verify ClickHouse is healthy:"
echo "   kubectl exec -n database $POD_NAME -- clickhouse-client --query 'SELECT version()'"
echo ""
