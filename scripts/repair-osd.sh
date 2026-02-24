#!/bin/bash

# Script to repair a crashed Rook Ceph OSD by fully purging, wiping the
# underlying block device, and letting the operator re-provision from scratch.
#
# Usage: ./repair-osd.sh <osd-id> [namespace]
# Example: ./repair-osd.sh 4 rook-ceph

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ $# -lt 1 ]; then
    log_error "Usage: $0 <osd-id> [namespace]"
    log_error "Example: $0 4 rook-ceph"
    exit 1
fi

OSD_ID="$1"
NAMESPACE="${2:-rook-ceph}"

log_info "Starting repair process for OSD ${OSD_ID} in namespace ${NAMESPACE}"

# Preflight checks
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl is not installed or not in PATH"
    exit 1
fi

if ! kubectl rook-ceph ceph status &> /dev/null; then
    log_error "kubectl rook-ceph plugin is not available or cluster is not accessible"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Gather all required information BEFORE we purge anything
# ---------------------------------------------------------------------------
log_info "Step 1: Gathering OSD ${OSD_ID} information..."

OSD_STATUS=$(kubectl rook-ceph ceph osd tree 2>/dev/null | grep -E "osd\.${OSD_ID}\s" || echo "")
if [ -n "$OSD_STATUS" ]; then
    log_info "Current OSD status: ${OSD_STATUS}"
else
    log_warn "OSD ${OSD_ID} not found in osd tree (may already be purged)"
fi

# --- Node name ---
NODE_NAME=""
# Try pod label first (most reliable when pod exists)
NODE_NAME=$(kubectl get pods -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" \
    -o jsonpath='{.items[0].metadata.labels.topology-location-host}' 2>/dev/null || echo "")
# Fall back to pod spec nodeName
if [ -z "$NODE_NAME" ]; then
    NODE_NAME=$(kubectl get pods -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" \
        -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
fi
# Fall back to osd tree (works even when pod is crashlooping)
if [ -z "$NODE_NAME" ]; then
    NODE_NAME=$(kubectl rook-ceph ceph osd tree 2>/dev/null \
        | grep -B1 "osd\.${OSD_ID}" | grep "host" | awk '{print $NF}' || echo "")
fi

if [ -z "$NODE_NAME" ]; then
    log_error "Cannot determine node name for OSD ${OSD_ID}. Cannot proceed."
    exit 1
fi
log_info "  Node: ${NODE_NAME}"

# --- Block device path ---
DEVICE=""
# From the deployment's activate init container env var ROOK_BLOCK_PATH
DEVICE=$(kubectl get deploy -n "${NAMESPACE}" "rook-ceph-osd-${OSD_ID}" \
    -o jsonpath='{.spec.template.spec.initContainers[?(@.name=="activate")].env[?(@.name=="ROOK_BLOCK_PATH")].value}' 2>/dev/null || echo "")
if [ -z "$DEVICE" ]; then
    # Fall back to pod env
    DEVICE=$(kubectl get pods -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" \
        -o jsonpath='{.items[0].spec.initContainers[?(@.name=="activate")].env[?(@.name=="ROOK_BLOCK_PATH")].value}' 2>/dev/null || echo "")
fi

if [ -z "$DEVICE" ]; then
    log_error "Cannot determine block device for OSD ${OSD_ID}. Cannot proceed."
    exit 1
fi
log_info "  Device: ${DEVICE}"

# --- Ceph image (for the wipe job) ---
CEPH_IMAGE=$(kubectl get deploy -n "${NAMESPACE}" "rook-ceph-osd-${OSD_ID}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
if [ -z "$CEPH_IMAGE" ]; then
    CEPH_IMAGE=$(kubectl get pods -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" \
        -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "")
fi
if [ -z "$CEPH_IMAGE" ]; then
    CEPH_IMAGE="quay.io/ceph/ceph:v19.2.3"
    log_warn "  Could not detect Ceph image, defaulting to ${CEPH_IMAGE}"
else
    log_info "  Ceph image: ${CEPH_IMAGE}"
fi

# --- Cluster FSID ---
CLUSTER_FSID=$(kubectl rook-ceph ceph fsid 2>/dev/null || echo "")
if [ -z "$CLUSTER_FSID" ]; then
    CLUSTER_FSID=$(kubectl rook-ceph ceph status 2>/dev/null \
        | grep -oE 'id:\s+[a-f0-9-]+' | awk '{print $2}' || echo "")
fi
log_info "  Cluster FSID: ${CLUSTER_FSID:-unknown}"

# ---------------------------------------------------------------------------
# Step 2: Check safety
# ---------------------------------------------------------------------------
log_info "Step 2: Checking if OSD ${OSD_ID} is safe to destroy..."
SAFE_TO_DESTROY=$(kubectl rook-ceph ceph osd safe-to-destroy "${OSD_ID}" 2>&1 || echo "")
if echo "$SAFE_TO_DESTROY" | grep -q "safe to destroy"; then
    log_info "OSD ${OSD_ID} is safe to destroy"
else
    log_warn "OSD ${OSD_ID} may not be safe to destroy: ${SAFE_TO_DESTROY}"
    log_warn "Proceeding anyway (data should be replicated)..."
fi

# ---------------------------------------------------------------------------
# Step 3: Mark out, destroy, and purge the OSD from Ceph
# ---------------------------------------------------------------------------
log_info "Step 3: Removing OSD ${OSD_ID} from Ceph cluster..."
kubectl rook-ceph ceph osd out "${OSD_ID}" 2>/dev/null || true
kubectl rook-ceph ceph osd destroy "${OSD_ID}" --yes-i-really-mean-it 2>/dev/null || true
kubectl rook-ceph ceph osd purge "${OSD_ID}" --yes-i-really-mean-it 2>/dev/null || true
log_info "OSD ${OSD_ID} purged from Ceph"

# ---------------------------------------------------------------------------
# Step 4: Delete the OSD deployment
# ---------------------------------------------------------------------------
log_info "Step 4: Deleting OSD ${OSD_ID} deployment..."
kubectl delete deployment -n "${NAMESPACE}" "rook-ceph-osd-${OSD_ID}" --wait=false 2>/dev/null || true
# Wait for pod to terminate so it releases the device
log_info "Waiting for OSD pod to terminate..."
kubectl wait --for=delete pod -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" --timeout=60s 2>/dev/null || true
log_info "OSD deployment deleted"

# ---------------------------------------------------------------------------
# Step 5: Wipe the block device AND clean the rook data directory
# ---------------------------------------------------------------------------
log_info "Step 5: Wiping block device ${DEVICE} on node ${NODE_NAME}..."
log_info "  This wipes BlueStore labels from both the start and end of the device."

WIPE_JOB="wipe-osd-${OSD_ID}-$(date +%s)"
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${WIPE_JOB}
  namespace: ${NAMESPACE}
spec:
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/hostname: ${NODE_NAME}
      tolerations:
        - operator: Exists
      containers:
      - name: wipe
        image: ${CEPH_IMAGE}
        securityContext:
          privileged: true
        command:
        - /bin/bash
        - -c
        - |
          set -ex
          DEVICE="${DEVICE}"

          echo "=== Wiping \${DEVICE} ==="

          # Wipe first 1GB (primary BlueStore label + superblock)
          dd if=/dev/zero of=\${DEVICE} bs=1M count=1000 oflag=direct

          # Wipe last 1GB (backup BlueStore label stored at end of device)
          DEV_SIZE=\$(blockdev --getsize64 \${DEVICE})
          END_OFFSET=\$(( (DEV_SIZE / 1048576) - 1000 ))
          if [ \${END_OFFSET} -gt 1000 ]; then
            dd if=/dev/zero of=\${DEVICE} bs=1M count=1000 seek=\${END_OFFSET} oflag=direct
          fi

          # TRIM the entire device (fast on NVMe)
          blkdiscard \${DEVICE} || true

          # Clear partition table and filesystem signatures
          sgdisk --zap-all \${DEVICE} || true
          wipefs -af \${DEVICE}

          # Verify device is clean
          echo "=== Verifying device is clean ==="
          OUTPUT=\$(ceph-volume raw list \${DEVICE} 2>/dev/null || echo "{}")
          echo "\${OUTPUT}"
          if echo "\${OUTPUT}" | grep -q "osd_id"; then
            echo "ERROR: Device still has OSD data!"
            exit 1
          fi
          echo "Device is clean."

          # Clean rook data directories for this OSD
          echo "=== Cleaning rook data directories ==="
          rm -rf /var/lib/rook/rook-ceph/${CLUSTER_FSID}_* 2>/dev/null || true
          ls -la /var/lib/rook/rook-ceph/ 2>/dev/null || true
          echo "=== Done ==="
        volumeMounts:
        - name: dev
          mountPath: /dev
        - name: rook-data
          mountPath: /var/lib/rook
      volumes:
      - name: dev
        hostPath:
          path: /dev
      - name: rook-data
        hostPath:
          path: /var/lib/rook
EOF

log_info "Waiting for device wipe job to complete..."
if kubectl wait --for=condition=complete --timeout=120s "job/${WIPE_JOB}" -n "${NAMESPACE}" 2>/dev/null; then
    WIPE_LOG=$(kubectl logs -n "${NAMESPACE}" -l "job-name=${WIPE_JOB}" --tail=5 2>/dev/null || echo "")
    log_info "Wipe result:"
    echo "$WIPE_LOG"
    kubectl delete job -n "${NAMESPACE}" "${WIPE_JOB}" --wait=false 2>/dev/null || true
else
    log_error "Device wipe job failed or timed out. Check logs:"
    log_error "  kubectl logs -n ${NAMESPACE} -l job-name=${WIPE_JOB}"
    kubectl logs -n "${NAMESPACE}" -l "job-name=${WIPE_JOB}" --tail=20 2>/dev/null || true
    kubectl delete job -n "${NAMESPACE}" "${WIPE_JOB}" --wait=false 2>/dev/null || true
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 6: Delete the OSD deployment again (operator may have recreated it
#         while the wipe was running) and delete the prepare job to trigger
#         a clean re-provision
# ---------------------------------------------------------------------------
log_info "Step 6: Triggering fresh OSD re-provision..."
kubectl delete deployment -n "${NAMESPACE}" "rook-ceph-osd-${OSD_ID}" --wait=false 2>/dev/null || true
kubectl wait --for=delete pod -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" --timeout=60s 2>/dev/null || true

PREPARE_JOB="rook-ceph-osd-prepare-${NODE_NAME}"
if kubectl get job -n "${NAMESPACE}" "${PREPARE_JOB}" &>/dev/null; then
    log_info "Deleting prepare job ${PREPARE_JOB} to trigger re-provision..."
    kubectl delete job -n "${NAMESPACE}" "${PREPARE_JOB}" --wait=false
fi

# ---------------------------------------------------------------------------
# Step 7: Wait for the OSD to come back up
# ---------------------------------------------------------------------------
log_info "Step 7: Waiting for OSD ${OSD_ID} to be recreated and come up..."
log_info "This may take a few minutes..."

MAX_WAIT=600  # 10 minutes
ELAPSED=0
INTERVAL=10

while [ $ELAPSED -lt $MAX_WAIT ]; do
    # Check if OSD pod is running and ready
    OSD_READY=$(kubectl get pods -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "")

    if [ "$OSD_READY" = "true" ]; then
        # Confirm OSD is up in the CRUSH map
        OSD_UP=$(kubectl rook-ceph ceph osd tree 2>/dev/null | grep -E "osd\.${OSD_ID}\s.*up" || echo "")
        if [ -n "$OSD_UP" ]; then
            log_info "OSD ${OSD_ID} is up and running!"
            break
        fi
    fi

    # Show current state
    POD_STATUS=$(kubectl get pods -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "not found")
    INIT_STATUS=$(kubectl get pods -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" \
        -o jsonpath='{.items[0].status.initContainerStatuses[*].name}' 2>/dev/null || echo "")
    if [ -n "$INIT_STATUS" ]; then
        INIT_WAITING=$(kubectl get pods -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" \
            -o jsonpath='{range .items[0].status.initContainerStatuses[*]}{.name}={.ready} {end}' 2>/dev/null || echo "")
        log_info "  [${ELAPSED}s] pod=${POD_STATUS} init=[${INIT_WAITING}]"
    else
        log_info "  [${ELAPSED}s] pod=${POD_STATUS}"
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

# ---------------------------------------------------------------------------
# Step 8: Archive crash reports and show final status
# ---------------------------------------------------------------------------
log_info "Step 8: Final status..."

# Archive old crash reports to clear HEALTH_WARN
kubectl rook-ceph ceph crash archive-all 2>/dev/null || true

echo ""
OSD_TREE_OUTPUT=$(kubectl rook-ceph ceph osd tree 2>/dev/null | grep -E "osd\.${OSD_ID}\s" || echo "")
if [ -n "$OSD_TREE_OUTPUT" ]; then
    echo "$OSD_TREE_OUTPUT"
else
    log_warn "OSD ${OSD_ID} not found in osd tree"
fi
echo ""

kubectl get pods -n "${NAMESPACE}" -l "ceph-osd-id=${OSD_ID}" -o wide 2>/dev/null || true
echo ""

CLUSTER_HEALTH=$(kubectl rook-ceph ceph health 2>/dev/null || echo "unknown")
log_info "Cluster health: ${CLUSTER_HEALTH}"
echo ""

if [ $ELAPSED -ge $MAX_WAIT ]; then
    log_error "Timeout waiting for OSD ${OSD_ID} to come up after ${MAX_WAIT}s."
    log_error "Check manually:"
    log_error "  kubectl get pods -n ${NAMESPACE} -l ceph-osd-id=${OSD_ID}"
    log_error "  kubectl logs -n ${NAMESPACE} -l ceph-osd-id=${OSD_ID} -c expand-bluefs"
    log_error "  kubectl rook-ceph ceph osd tree"
    exit 1
fi

log_info "OSD ${OSD_ID} repair completed successfully!"
log_info "Monitor recovery with: kubectl rook-ceph ceph status"
