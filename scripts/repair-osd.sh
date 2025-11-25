#!/bin/bash

# Script to repair a crashed Rook Ceph OSD
# Usage: ./repair-osd.sh <osd-id> [namespace]
# Example: ./repair-osd.sh 4 rook-ceph

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if OSD ID is provided
if [ $# -lt 1 ]; then
    log_error "Usage: $0 <osd-id> [namespace]"
    log_error "Example: $0 4 rook-ceph"
    exit 1
fi

OSD_ID="$1"
NAMESPACE="${2:-rook-ceph}"

log_info "Starting repair process for OSD ${OSD_ID} in namespace ${NAMESPACE}"

# Check if kubectl and rook-ceph plugin are available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl is not installed or not in PATH"
    exit 1
fi

if ! kubectl rook-ceph ceph status &> /dev/null; then
    log_error "kubectl rook-ceph plugin is not available or cluster is not accessible"
    exit 1
fi

# Step 1: Check OSD status
log_info "Step 1: Checking OSD ${OSD_ID} status..."
OSD_STATUS=$(kubectl rook-ceph ceph osd tree 2>/dev/null | grep -E "osd\.${OSD_ID}\s" || echo "")
if [ -z "$OSD_STATUS" ]; then
    log_warn "OSD ${OSD_ID} not found in osd tree. It may already be purged."
else
    log_info "Current OSD status: ${OSD_STATUS}"
fi

# Step 2: Check if OSD is safe to destroy
log_info "Step 2: Checking if OSD ${OSD_ID} is safe to destroy..."
SAFE_TO_DESTROY=$(kubectl rook-ceph ceph osd safe-to-destroy "${OSD_ID}" 2>&1 || echo "")
if echo "$SAFE_TO_DESTROY" | grep -q "safe to destroy"; then
    log_info "OSD ${OSD_ID} is safe to destroy"
else
    log_warn "OSD ${OSD_ID} may not be safe to destroy. Proceeding anyway..."
    log_warn "Output: ${SAFE_TO_DESTROY}"
fi

# Step 3: Destroy the OSD in Ceph
log_info "Step 3: Destroying OSD ${OSD_ID} in Ceph cluster..."
if kubectl rook-ceph ceph osd destroy "${OSD_ID}" --yes-i-really-mean-it 2>&1 | grep -q "destroyed"; then
    log_info "OSD ${OSD_ID} destroyed successfully"
else
    log_warn "OSD ${OSD_ID} may have already been destroyed or doesn't exist"
fi

# Step 4: Purge the OSD from Ceph
log_info "Step 4: Purging OSD ${OSD_ID} from Ceph cluster..."
if kubectl rook-ceph ceph osd purge "${OSD_ID}" --yes-i-really-mean-it 2>&1 | grep -q "purged"; then
    log_info "OSD ${OSD_ID} purged successfully"
else
    log_warn "OSD ${OSD_ID} may have already been purged"
fi

# Step 5: Get OSD pod and deployment information
log_info "Step 5: Finding OSD ${OSD_ID} deployment and pods..."
# Try multiple label selectors as Rook may use different labels
OSD_POD=$(kubectl get pods -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
          kubectl get pods -n "${NAMESPACE}" -l "osd=${OSD_ID}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
          kubectl get pods -n "${NAMESPACE}" -l "app=rook-ceph-osd,app.kubernetes.io/instance=${OSD_ID}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
OSD_DEPLOYMENT=$(kubectl get deployment -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
                 kubectl get deployment -n "${NAMESPACE}" -l "osd=${OSD_ID}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
                 kubectl get deployment -n "${NAMESPACE}" -l "app=rook-ceph-osd,app.kubernetes.io/instance=${OSD_ID}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
                 kubectl get deployment -n "${NAMESPACE}" | grep "osd-${OSD_ID}" | awk '{print $1}' | head -1 || echo "")

# Step 6: Delete OSD deployment
if [ -n "$OSD_DEPLOYMENT" ]; then
    log_info "Step 6: Deleting OSD deployment ${OSD_DEPLOYMENT}..."
    kubectl delete deployment -n "${NAMESPACE}" "${OSD_DEPLOYMENT}" --wait=false
    log_info "OSD deployment ${OSD_DEPLOYMENT} deleted"
else
    log_warn "No OSD deployment found for OSD ${OSD_ID}"
fi

# Step 7: Get node name and OSD UUID for cleanup
# Try to get info from existing pod, or from osd info command
NODE_NAME=""
OSD_UUID=""
CLUSTER_FSID=""

if [ -n "$OSD_POD" ]; then
    NODE_NAME=$(kubectl get pod -n "${NAMESPACE}" "${OSD_POD}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
    # Try different label names for OSD UUID
    OSD_UUID=$(kubectl get pod -n "${NAMESPACE}" "${OSD_POD}" -o jsonpath='{.metadata.labels.ceph-osd-uuid}' 2>/dev/null || \
               kubectl get pod -n "${NAMESPACE}" "${OSD_POD}" -o jsonpath='{.metadata.labels.ROOK_OSD_UUID}' 2>/dev/null || \
               kubectl get pod -n "${NAMESPACE}" "${OSD_POD}" -o jsonpath='{.metadata.annotations.ceph-osd-uuid}' 2>/dev/null || echo "")
    CLUSTER_FSID=$(kubectl get pod -n "${NAMESPACE}" "${OSD_POD}" -o jsonpath='{.metadata.labels.ceph-cluster-id}' 2>/dev/null || \
                   kubectl get pod -n "${NAMESPACE}" "${OSD_POD}" -o jsonpath='{.metadata.labels.ROOK_CLUSTER_ID}' 2>/dev/null || echo "")
fi

# If we don't have the info from pod, try to get it from Ceph
if [ -z "$OSD_UUID" ] || [ -z "$CLUSTER_FSID" ]; then
    OSD_INFO=$(kubectl rook-ceph ceph osd info "${OSD_ID}" 2>/dev/null || echo "")
    if [ -n "$OSD_INFO" ]; then
        # Extract UUID from osd info (format: exists,up <uuid>)
        OSD_UUID=$(echo "$OSD_INFO" | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | tail -1 || echo "")
        # Get cluster FSID from ceph status
        CLUSTER_FSID=$(kubectl rook-ceph ceph status 2>/dev/null | grep -oE 'id:\s+[a-f0-9-]+' | awk '{print $2}' || echo "")
    fi
fi

# Get node name from osd tree if not found
if [ -z "$NODE_NAME" ]; then
    OSD_TREE=$(kubectl rook-ceph ceph osd tree 2>/dev/null || echo "")
    if [ -n "$OSD_TREE" ]; then
        # Extract hostname from osd tree (format: -XX hostname)
        NODE_NAME=$(echo "$OSD_TREE" | grep -B1 "osd\.${OSD_ID}" | grep "host" | awk '{print $2}' || echo "")
    fi
fi

# Clean up data directory if we have the necessary information
if [ -n "$NODE_NAME" ] && [ -n "$OSD_UUID" ] && [ -n "$CLUSTER_FSID" ]; then
    OSD_DATA_DIR="/var/lib/rook/rook-ceph/${CLUSTER_FSID}_${OSD_UUID}"

    log_info "Step 7: Cleaning up OSD data directory on node ${NODE_NAME}..."
    log_info "OSD data directory: ${OSD_DATA_DIR}"

    # Create a job to clean up the data directory
    CLEANUP_JOB="cleanup-osd-${OSD_ID}-$(date +%s)"
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${CLEANUP_JOB}
  namespace: ${NAMESPACE}
spec:
  template:
    spec:
      hostNetwork: true
      hostPID: true
      nodeSelector:
        kubernetes.io/hostname: ${NODE_NAME}
      containers:
      - name: cleanup
        image: alpine:3.19
        command: ["sh", "-c", "rm -rf ${OSD_DATA_DIR} && ls -la /var/lib/rook/rook-ceph/ 2>/dev/null | grep -q ${OSD_UUID} && echo 'Directory still exists' || echo 'Directory cleaned successfully'"]
        securityContext:
          privileged: true
        volumeMounts:
        - name: rook-data
          mountPath: /var/lib/rook
      volumes:
      - name: rook-data
        hostPath:
          path: /var/lib/rook
      restartPolicy: Never
EOF

    # Wait for cleanup job to complete
    log_info "Waiting for cleanup job to complete..."
    if kubectl wait --for=condition=complete --timeout=60s job/${CLEANUP_JOB} -n "${NAMESPACE}" 2>/dev/null; then
        CLEANUP_LOG=$(kubectl logs -n "${NAMESPACE}" -l job-name="${CLEANUP_JOB}" --tail=1 2>/dev/null || echo "")
        log_info "Cleanup result: ${CLEANUP_LOG}"
        kubectl delete job -n "${NAMESPACE}" "${CLEANUP_JOB}" --wait=false 2>/dev/null || true
    else
        log_warn "Cleanup job timed out or failed, but continuing..."
        kubectl delete job -n "${NAMESPACE}" "${CLEANUP_JOB}" --wait=false 2>/dev/null || true
    fi
else
    log_warn "Could not determine all required information for cleanup:"
    log_warn "  Node: ${NODE_NAME:-not found}"
    log_warn "  OSD UUID: ${OSD_UUID:-not found}"
    log_warn "  Cluster FSID: ${CLUSTER_FSID:-not found}"
    log_warn "Skipping data directory cleanup. You may need to manually clean up."
fi

# Step 8: Delete prepare job to trigger recreation
log_info "Step 8: Triggering OSD recreation..."
if [ -n "$NODE_NAME" ]; then
    PREPARE_JOB="rook-ceph-osd-prepare-${NODE_NAME}"
    if kubectl get job -n "${NAMESPACE}" "${PREPARE_JOB}" &>/dev/null; then
        log_info "Deleting prepare job ${PREPARE_JOB} to trigger recreation..."
        kubectl delete job -n "${NAMESPACE}" "${PREPARE_JOB}" --wait=false
    fi
fi

# Step 9: Wait for Rook to recreate the OSD
log_info "Step 9: Waiting for Rook to recreate OSD ${OSD_ID}..."
log_info "This may take a few minutes. Monitoring progress..."

MAX_WAIT=300  # 5 minutes
ELAPSED=0
INTERVAL=10

while [ $ELAPSED -lt $MAX_WAIT ]; do
    # Check if OSD deployment exists (try multiple label selectors)
    NEW_DEPLOYMENT=$(kubectl get deployment -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
                     kubectl get deployment -n "${NAMESPACE}" -l "osd=${OSD_ID}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
                     kubectl get deployment -n "${NAMESPACE}" | grep "osd-${OSD_ID}" | awk '{print $1}' | head -1 || echo "")

    if [ -n "$NEW_DEPLOYMENT" ]; then
        # Check if OSD pod is running (try multiple label selectors)
        OSD_POD_STATUS=$(kubectl get pods -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || \
                         kubectl get pods -n "${NAMESPACE}" -l "osd=${OSD_ID}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || \
                         kubectl get pods -n "${NAMESPACE}" | grep "osd-${OSD_ID}" | awk '{print $3}' | head -1 || echo "")

        if [ "$OSD_POD_STATUS" = "Running" ]; then
            # Check if OSD is up in Ceph
            OSD_UP=$(kubectl rook-ceph ceph osd tree 2>/dev/null | grep -E "osd\.${OSD_ID}\s.*up" || echo "")
            if [ -n "$OSD_UP" ]; then
                log_info "OSD ${OSD_ID} is now up and running!"
                break
            fi
        fi

        log_info "OSD ${OSD_ID} pod status: ${OSD_POD_STATUS} (waiting...)"
    else
        log_info "OSD ${OSD_ID} deployment not yet created (waiting...)"
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

# Step 10: Final status check
log_info "Step 10: Final status check..."
echo ""
OSD_TREE_OUTPUT=$(kubectl rook-ceph ceph osd tree 2>/dev/null | grep -E "osd\.${OSD_ID}\s" || echo "")
if [ -n "$OSD_TREE_OUTPUT" ]; then
    echo "$OSD_TREE_OUTPUT"
else
    log_warn "OSD ${OSD_ID} not found in osd tree"
fi
echo ""
POD_OUTPUT=$(kubectl get pods -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" 2>/dev/null || \
             kubectl get pods -n "${NAMESPACE}" -l "osd=${OSD_ID}" 2>/dev/null || \
             kubectl get pods -n "${NAMESPACE}" | grep "osd-${OSD_ID}" || echo "")
if [ -n "$POD_OUTPUT" ]; then
    echo "$POD_OUTPUT"
else
    log_warn "No pods found for OSD ${OSD_ID}"
fi
echo ""

# Check cluster health
CLUSTER_STATUS=$(kubectl rook-ceph ceph status 2>/dev/null | grep -E "(health|osd:)" || echo "")
log_info "Cluster status:"
echo "$CLUSTER_STATUS"
echo ""

if [ $ELAPSED -ge $MAX_WAIT ]; then
    log_warn "Timeout waiting for OSD ${OSD_ID} to come up. Please check manually:"
    log_warn "  kubectl get pods -n ${NAMESPACE} -l ceph-osd-id=${OSD_ID}"
    log_warn "  kubectl rook-ceph ceph osd tree"
    exit 1
else
    log_info "OSD ${OSD_ID} repair completed successfully!"
    log_info "The cluster is now recovering data. Monitor with:"
    log_info "  kubectl rook-ceph ceph status"
    log_info "  kubectl rook-ceph ceph osd tree"
fi

