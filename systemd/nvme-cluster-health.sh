#!/bin/bash
# NVMe-oF Cluster Health Monitor Script
# Checks NVMe connectivity and RAID status, triggers recovery if needed

set -euo pipefail

NODE1_IP="192.168.177.11"
NODE2_IP="192.168.177.12"
MD_DEVICE="/dev/md0"
MOUNT_POINT="/mnt/nvmeof"
NODE1_LOCAL_SUBSYSTEM="nqn.2026-03.dgx:node1-shared"
NODE1_REMOTE_SUBSYSTEM="nqn.2026-03.dgx:node2-shared"

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
        if echo "$RAID_STATUS" | grep -q "broken"; then
            echo "HEALTH CHECK: RAID0 BROKEN - NVMe leg failed (identifiers likely changed)"
            echo "  Recovery: reboot both nodes (node2 first, then node1), then run fsck.gfs2 -y /dev/md0"
            HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
        elif echo "$RAID_STATUS" | grep -q "\[U_\]\|\[_U\]"; then
            echo "HEALTH CHECK: RAID0 degraded - missing disk"
            HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
        fi
    else
        echo "HEALTH CHECK: RAID0 device $MD_DEVICE not found"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi

    # Check for NVMe identifier change errors (precursor to RAID break)
    if dmesg | tail -100 | grep -q "identifiers changed for nsid"; then
        echo "HEALTH CHECK: NVMe identifiers changed - RAID0 break imminent or occurred"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi

    # Check remote subsystem is connected
    if ! grep -l "$NODE1_REMOTE_SUBSYSTEM" /sys/class/nvme-subsystem/nvme-subsys*/subsysnqn 2>/dev/null | grep -q .; then
        echo "HEALTH CHECK: Remote NVMe subsystem $NODE1_REMOTE_SUBSYSTEM not connected"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi
fi

# Report status
if [[ "$HEALTH_ISSUES" -eq 0 ]]; then
    echo "HEALTH CHECK: All systems operational on Node $NODE_ID"
    exit 0
else
    echo "HEALTH CHECK: Found $HEALTH_ISSUES issue(s) on Node $NODE_ID"
    if [[ "$NODE_ID" -eq 1 ]]; then
        echo "  Active recovery: removing NVMe-oF export and stopping RAID..."
        # Remove target export so Node 2 cannot connect to broken array when it returns
        rm -f /sys/kernel/config/nvmet/ports/1/subsystems/* 2>/dev/null || true
        rmdir /sys/kernel/config/nvmet/ports/1 2>/dev/null || true
        for ns in /sys/kernel/config/nvmet/subsystems/"$NODE1_LOCAL_SUBSYSTEM"/namespaces/*; do
            [ -d "$ns" ] || continue
            echo 0 > "$ns/enable" 2>/dev/null || true
            rmdir "$ns" 2>/dev/null || true
        done
        rm -f /sys/kernel/config/nvmet/subsystems/"$NODE1_LOCAL_SUBSYSTEM"/allowed_hosts/* 2>/dev/null || true
        rmdir /sys/kernel/config/nvmet/subsystems/"$NODE1_LOCAL_SUBSYSTEM" 2>/dev/null || true

        # Stop RAID and disconnect from Node 2
        mdadm --stop "$MD_DEVICE" 2>/dev/null || true
        nvme disconnect -n "$NODE1_REMOTE_SUBSYSTEM" 2>/dev/null || true

        echo "  Triggering nvme-cluster-init restart to wait for Node 2..."
        if systemctl is-active nvme-cluster-init.service >/dev/null 2>&1; then
            systemctl restart nvme-cluster-init.service
        else
            echo "  nvme-cluster-init is not active (already retrying or failed) — skipping restart"
        fi
    fi
    exit 1
fi
