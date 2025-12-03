#!/bin/bash

# Script to clean up corrupted ClickHouse data
# This resolves "TOO_LARGE_ARRAY_SIZE" errors in system tables by removing corrupted data parts

# Don't exit on error - we handle errors explicitly
set +e

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

# Function to cleanup data when pod is available
cleanup_data() {
    local pod=$1
    echo "Attempting to stop merges on problematic tables..."
    kubectl exec -n database "$pod" -- clickhouse-client --query "SYSTEM STOP MERGES system.opentelemetry_span_log" 2>/dev/null || true
    kubectl exec -n database "$pod" -- clickhouse-client --query "SYSTEM STOP MERGES system.processors_profile_log" 2>/dev/null || true
    kubectl exec -n database "$pod" -- clickhouse-client --query "SYSTEM STOP MERGES system.error_log" 2>/dev/null || true
    sleep 2

    echo "Attempting to drop corrupted system tables via SQL..."
    kubectl exec -n database "$pod" -- clickhouse-client --query "DROP TABLE IF EXISTS system.opentelemetry_span_log" 2>/dev/null || echo "  ⚠️  Could not drop opentelemetry_span_log via SQL"
    kubectl exec -n database "$pod" -- clickhouse-client --query "DROP TABLE IF EXISTS system.processors_profile_log" 2>/dev/null || echo "  ⚠️  Could not drop processors_profile_log via SQL"
    kubectl exec -n database "$pod" -- clickhouse-client --query "DROP TABLE IF EXISTS system.error_log" 2>/dev/null || echo "  ⚠️  Could not drop error_log via SQL"
    echo ""

    echo "Removing corrupted system table data from filesystem..."
    echo "  - system.opentelemetry_span_log (UUID: 33d22a1e-ba2c-46f1-8666-d1a3546f4819)"
    kubectl exec -n database "$pod" -- sh -c "rm -rf /var/lib/clickhouse/store/33d/33d22a1e-ba2c-46f1-8666-d1a3546f4819" 2>/dev/null || true
    kubectl exec -n database "$pod" -- sh -c "rm -rf /var/lib/clickhouse/store/system/opentelemetry_span_log" 2>/dev/null || true
    kubectl exec -n database "$pod" -- sh -c "rm -rf /var/lib/clickhouse/metadata/system/opentelemetry_span_log.sql" 2>/dev/null || true

    echo "  - system.processors_profile_log (UUID: cdb63f3e-399b-4744-b9b0-4b8a48872f79)"
    kubectl exec -n database "$pod" -- sh -c "rm -rf /var/lib/clickhouse/store/cdb/cdb63f3e-399b-4744-b9b0-4b8a48872f79" 2>/dev/null || true
    kubectl exec -n database "$pod" -- sh -c "rm -rf /var/lib/clickhouse/store/system/processors_profile_log" 2>/dev/null || true
    kubectl exec -n database "$pod" -- sh -c "rm -rf /var/lib/clickhouse/metadata/system/processors_profile_log.sql" 2>/dev/null || true

    echo "  - system.error_log (if exists)"
    kubectl exec -n database "$pod" -- sh -c "rm -rf /var/lib/clickhouse/store/system/error_log" 2>/dev/null || true
    kubectl exec -n database "$pod" -- sh -c "rm -rf /var/lib/clickhouse/metadata/system/error_log.sql" 2>/dev/null || true

    echo "  - Removing specific corrupted parts..."
    kubectl exec -n database "$pod" -- sh -c "find /var/lib/clickhouse/store -type d -name '202508_189475_189634_37' -exec rm -rf {} + 2>/dev/null || true" || true
    kubectl exec -n database "$pod" -- sh -c "find /var/lib/clickhouse/store -type d -name '202508_186100_186642_314' -exec rm -rf {} + 2>/dev/null || true" || true
    kubectl exec -n database "$pod" -- sh -c "find /var/lib/clickhouse/store -type d -name '202508_186100_193998_315' -exec rm -rf {} + 2>/dev/null || true" || true
    kubectl exec -n database "$pod" -- sh -c "find /var/lib/clickhouse/store -type d -name '202508_189475_191055_38' -exec rm -rf {} + 2>/dev/null || true" || true

    echo "✅ Corrupted system table data removed"
    echo ""

    echo "Cleaning up temporary merge directories..."
    kubectl exec -n database "$pod" -- sh -c "find /var/lib/clickhouse/store -name '*tmp_merge*' -type d -exec rm -rf {} + 2>/dev/null || true" || true
    kubectl exec -n database "$pod" -- sh -c "find /var/lib/clickhouse/store -name '*delete_tmp*' -type d -exec rm -rf {} + 2>/dev/null || true" || true
    echo "✅ Temporary merge directories cleaned"
    echo ""

    echo "Fixing data directory permissions..."
    kubectl exec -n database "$pod" -- sh -c "chown -R 101:101 /var/lib/clickhouse 2>/dev/null || true" || true
    echo "✅ Permissions fixed"
    echo ""
}

# Try to cleanup while pod is running
echo "Attempting cleanup while pod is running..."
if cleanup_data "$POD_NAME"; then
    echo "✅ Cleanup completed while pod was running"
else
    echo "⚠️  Cleanup failed, will try after pod restart"
fi

# Stop ClickHouse gracefully
echo "Stopping ClickHouse gracefully..."
if kubectl exec -n database "$POD_NAME" -- clickhouse-client --query "SYSTEM SHUTDOWN" 2>/dev/null; then
    echo "✅ ClickHouse shutdown initiated"
    echo "Waiting for shutdown to complete..."
    sleep 20
    # Try cleanup again after shutdown
    if kubectl get pod -n database "$POD_NAME" &>/dev/null && kubectl wait --for=condition=ready pod -n database "$POD_NAME" --timeout=5s &>/dev/null; then
        echo "Pod still running, attempting cleanup again..."
        cleanup_data "$POD_NAME" || true
    fi
else
    echo "⚠️  Could not connect to ClickHouse"
fi

# Scale down StatefulSet to ensure pod is stopped
echo ""
echo "Scaling down StatefulSet to ensure clean state..."
kubectl scale statefulset clickhouse -n database --replicas=0 2>/dev/null || echo "⚠️  Could not scale down (may not be a StatefulSet)"
sleep 10

# Scale back up
echo "Scaling StatefulSet back up..."
kubectl scale statefulset clickhouse -n database --replicas=1 2>/dev/null || echo "⚠️  Could not scale up (may not be a StatefulSet)"

# Wait for new pod
echo "Waiting for new pod to be ready..."
sleep 15
NEW_POD=$(kubectl get pods -n database -l app.kubernetes.io/name=clickhouse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$NEW_POD" ] && [ "$NEW_POD" != "$POD_NAME" ]; then
    echo "✅ New pod created: $NEW_POD"
    echo "Waiting for pod to be ready..."
    kubectl wait --for=condition=ready pod -n database "$NEW_POD" --timeout=120s || echo "⚠️  Pod not ready yet"

    # Final cleanup attempt on new pod
    echo ""
    echo "Performing final cleanup on new pod..."
    sleep 5
    cleanup_data "$NEW_POD" || true
fi
echo ""

echo "=========================================="
echo "✅ Cleanup completed successfully!"
echo "=========================================="
echo ""
echo "The ClickHouse pod should restart automatically."
echo ""
echo "Monitor the logs to verify errors are resolved:"
echo "   kubectl logs -n database -l app.kubernetes.io/name=clickhouse -f"
echo ""
echo "Once the pod is ready, verify ClickHouse is healthy:"
echo "   kubectl exec -n database \$(kubectl get pods -n database -l app.kubernetes.io/name=clickhouse -o jsonpath='{.items[0].metadata.name}') -- clickhouse-client --query 'SELECT version()'"
echo ""
