#!/bin/bash
# NVMe-oF Cluster Health Monitor Script
# Checks NVMe connectivity and RAID status, triggers recovery if needed

set -euo pipefail

NODE1_IP="192.168.177.11"
NODE2_IP="192.168.177.12"
MD_DEVICE="/dev/md0"
MOUNT_POINT="/mnt/nvmeof"

# Determine which node we are
HOSTNAME=$(hostname)
case "$HOSTNAME" in
    ai)  NODE_ID=1; PEER_IP="$NODE2_IP" ;;
    ai2) NODE_ID=2; PEER_IP="$NODE1_IP" ;;
    *) echo "Unknown hostname '$HOSTNAME'"; exit 1 ;;
esac

HEALTH_ISSUES=0

# Check NVMe connections (Node 2 only imports from Node 1)
if [[ "$NODE_ID" -eq 2 ]]; then
    REMOTE_SUBSYSTEM="nqn.2026-03.dgx:node1-shared"
    if ! nvme list | grep -q "nvme1n" 2>/dev/null; then
        echo "HEALTH CHECK: NVMe connection to Node 1 lost"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi
fi

# Check RAID status (Node 1 only)
if [[ "$NODE_ID" -eq 1 ]]; then
    if [[ -b "$MD_DEVICE" ]]; then
        RAID_STATUS=$(cat /proc/mdstat | grep -A1 "^md0" || true)
        if echo "$RAID_STATUS" | grep -q "\[U_\]\|\[_U\]"; then
            echo "HEALTH CHECK: RAID0 degraded - missing disk"
            HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
        fi
    else
        echo "HEALTH CHECK: RAID0 device $MD_DEVICE not found"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi
fi

# Report status
if [[ "$HEALTH_ISSUES" -eq 0 ]]; then
    echo "HEALTH CHECK: All systems operational on Node $NODE_ID"
    exit 0
else
    echo "HEALTH CHECK: Found $HEALTH_ISSUES issue(s) on Node $NODE_ID"
    # Don't auto-restart - let systemd handle based on exit code
    exit 1
fi
