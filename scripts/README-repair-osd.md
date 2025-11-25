# OSD Repair Script

## Overview

The `repair-osd.sh` script automates the process of repairing a crashed Rook Ceph OSD. It handles the complete repair workflow including:

1. Checking OSD status and safety
2. Destroying and purging the OSD from Ceph
3. Cleaning up Kubernetes resources (deployments, pods)
4. Removing corrupted data directories
5. Triggering Rook to recreate the OSD
6. Monitoring the recovery process

## Prerequisites

- `kubectl` installed and configured
- `kubectl rook-ceph` plugin installed
- Access to the Kubernetes cluster
- Appropriate permissions to manage Rook Ceph resources

## Usage

```bash
./scripts/repair-osd.sh <osd-id> [namespace]
```

### Parameters

- `<osd-id>`: The ID of the OSD to repair (required)
- `[namespace]`: The Kubernetes namespace where Rook Ceph is installed (optional, defaults to `rook-ceph`)

### Examples

```bash
# Repair OSD 4 in the default rook-ceph namespace
./scripts/repair-osd.sh 4

# Repair OSD 4 in a custom namespace
./scripts/repair-osd.sh 4 my-rook-namespace
```

## What the Script Does

1. **Validation**: Checks if kubectl and rook-ceph plugin are available
2. **Status Check**: Verifies the current status of the OSD
3. **Safety Check**: Confirms the OSD is safe to destroy (data is replicated)
4. **Destroy OSD**: Removes the OSD from the Ceph cluster
5. **Purge OSD**: Completely removes OSD metadata from Ceph
6. **Cleanup Resources**: Deletes the OSD deployment and pods
7. **Cleanup Data**: Removes corrupted data directories from the host node
8. **Trigger Recreation**: Deletes prepare jobs to force Rook to recreate the OSD
9. **Monitor Recovery**: Waits up to 5 minutes for the OSD to come back online
10. **Final Status**: Displays the final status of the OSD and cluster

## Output

The script provides colored output:
- **Green [INFO]**: Informational messages
- **Yellow [WARN]**: Warnings (non-critical issues)
- **Red [ERROR]**: Errors (critical failures)

## Exit Codes

- `0`: Success - OSD repaired and running
- `1`: Failure - Error occurred or timeout waiting for OSD

## Troubleshooting

If the script fails or times out:

1. Check OSD status manually:
   ```bash
   kubectl rook-ceph ceph osd tree
   kubectl get pods -n rook-ceph -l ceph-osd-id=<osd-id>
   ```

2. Check Rook operator logs:
   ```bash
   kubectl logs -n rook-ceph -l app=rook-ceph-operator --tail=100
   ```

3. Verify cluster health:
   ```bash
   kubectl rook-ceph ceph status
   ```

4. If the OSD still doesn't come up, you may need to:
   - Check for device issues on the node
   - Verify the node has available storage
   - Check if there are any node-level issues

## Notes

- The script assumes OSDs are safe to destroy (data is replicated). Always verify this before running.
- The script waits up to 5 minutes for the OSD to come back online. Large clusters may need more time.
- After repair, the cluster will automatically rebalance data back to the repaired OSD.
- Monitor cluster health after repair to ensure recovery completes successfully.

