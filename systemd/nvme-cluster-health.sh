#!/bin/bash
# NVMe-oF Cluster Health Monitor Script
# Checks NVMe connectivity, RAID status, GFS2 state, and peer reachability.
# Triggers recovery if needed; emits early warnings before a cascade.

set -euo pipefail

NODE1_IP="192.168.177.11"
NODE2_IP="192.168.177.12"
MD_DEVICE="/dev/md0"
MOUNT_POINT="/mnt/nvmeof"
NODE1_LOCAL_SUBSYSTEM="nqn.2026-03.dgx:node1-shared"
NODE1_REMOTE_SUBSYSTEM="nqn.2026-03.dgx:node2-shared"
NODE2_REMOTE_SUBSYSTEM="nqn.2026-03.dgx:node1-shared"

HOSTNAME=$(hostname)
case "$HOSTNAME" in
    ai)  NODE_ID=1; PEER_IP="$NODE2_IP" ;;
    ai2) NODE_ID=2; PEER_IP="$NODE1_IP" ;;
    *) echo "Unknown hostname '$HOSTNAME'"; exit 1 ;;
esac

HEALTH_ISSUES=0
WARN_ONLY=0

log() { echo "HEALTH CHECK [node$NODE_ID]: $*"; }

# --- Peer reachability (early warning, non-destructive) ---
if ! ping -c 1 -W 2 "$PEER_IP" >/dev/null 2>&1; then
    log "WARN: peer $PEER_IP unreachable — NVMe fabric will fail and RAID0 will lose a leg. Investigate peer node."
    HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    WARN_ONLY=1
fi

# --- GFS2 withdraw detection (non-destructive warning) ---
if dmesg 2>/dev/null | tail -300 | grep -q "gfs2:.*withdraw\|mount control error"; then
    log "WARN: GFS2 withdraw detected in dmesg — filesystem locked down. Recovery: fsck.gfs2 -y /dev/md0 on Node 1 after tearing down DLM/mounts."
    HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    WARN_ONLY=1
fi

# --- Stale read-only GFS2 mount (non-destructive warning) ---
if mount | grep " $MOUNT_POINT " | grep -qE '\bro\b'; then
    log "WARN: $MOUNT_POINT is mounted read-only (stale after withdraw). Force unmount and run fsck before remount."
    HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    WARN_ONLY=1
fi

# --- NVMe connection check (Node 2 imports from Node 1) ---
if [[ "$NODE_ID" -eq 2 ]]; then
    if ! nvme list 2>/dev/null | grep -q "nvme1n"; then
        log "NVMe connection to Node 1 lost (node1-shared not visible)"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi
fi

# --- RAID + NVMe identifier checks (Node 1 only) ---
if [[ "$NODE_ID" -eq 1 ]]; then
    if [[ -b "$MD_DEVICE" ]]; then
        RAID_STATUS=$(cat /proc/mdstat | grep -A1 "^md0" || true)
        if echo "$RAID_STATUS" | grep -q "broken"; then
            log "RAID0 BROKEN — NVMe leg failed (identifiers likely changed). Recovery: reboot both nodes (node2 first), then fsck.gfs2 -y /dev/md0"
            HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
        elif echo "$RAID_STATUS" | grep -q "\[U_\]\|\[_U\]"; then
            log "RAID0 degraded — missing disk"
            HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
        fi
    else
        log "RAID0 device $MD_DEVICE not found"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi

    if dmesg 2>/dev/null | tail -100 | grep -q "identifiers changed for nsid"; then
        log "NVMe identifiers changed — RAID0 break imminent or occurred"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi

    if ! grep -l "$NODE1_REMOTE_SUBSYSTEM" /sys/class/nvme-subsystem/nvme-subsys*/subsysnqn 2>/dev/null | grep -q .; then
        log "Remote NVMe subsystem $NODE1_REMOTE_SUBSYSTEM not connected"
        HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
    fi
fi

# --- Auto-cleanup gfs2-group once fabric is healthy but resource is failed ---
fabric_healthy() {
    if [[ "$NODE_ID" -eq 1 ]]; then
        [[ -b "$MD_DEVICE" ]] && grep -ql "$NODE1_REMOTE_SUBSYSTEM" /sys/class/nvme-subsystem/nvme-subsys*/subsysnqn 2>/dev/null
    else
        nvme list 2>/dev/null | grep -q "nvme1n"
    fi
}
if fabric_healthy 2>/dev/null; then
    if pcs status >/dev/null 2>&1; then
        if pcs status 2>/dev/null | grep -q "gfs2-group.*FAILED\|gfs2-group.*blocked\|gfs2-nvmeof.*FAILED\|gfs2-nvmeof.*blocked"; then
            log "Fabric healthy but gfs2-group is FAILED/blocked — auto-cleaning gfs2-group-clone"
            pcs resource cleanup gfs2-group-clone >/dev/null 2>&1 || true
        fi
    fi
fi

# --- Report + recovery (Node 1, broken RAID only) ---
if [[ "$HEALTH_ISSUES" -eq 0 ]]; then
    log "All systems operational"
    # Auto-clear lingering failed fencing history so it can't block future fencing.
    # In SBD watchdog-only mode, remote-fence attempts log as "failed" during a
    # peer's self-fence reboot; these entries persist and can stall later fencing.
    if pcs stonith history 2>/dev/null | grep -q "failed"; then
        pcs stonith history cleanup >/dev/null 2>&1 || true
        log "Cleared lingering failed fencing history"
    fi
    exit 0
fi

log "Found $HEALTH_ISSUES issue(s)"

if [[ "$NODE_ID" -eq 1 && "$WARN_ONLY" -eq 0 ]]; then
    RAID_BROKEN=0
    if [[ -b "$MD_DEVICE" ]]; then
        cat /proc/mdstat | grep -A1 "^md0" | grep -q "broken" && RAID_BROKEN=1
    fi
    if [[ "$RAID_BROKEN" -eq 1 ]]; then
        log "Active recovery: removing NVMe-oF export and stopping RAID..."
        rm -f /sys/kernel/config/nvmet/ports/1/subsystems/* 2>/dev/null || true
        rmdir /sys/kernel/config/nvmet/ports/1 2>/dev/null || true
        for ns in /sys/kernel/config/nvmet/subsystems/"$NODE1_LOCAL_SUBSYSTEM"/namespaces/*; do
            [ -d "$ns" ] || continue
            echo 0 > "$ns/enable" 2>/dev/null || true
            rmdir "$ns" 2>/dev/null || true
        done
        rm -f /sys/kernel/config/nvmet/subsystems/"$NODE1_LOCAL_SUBSYSTEM"/allowed_hosts/* 2>/dev/null || true
        rmdir /sys/kernel/config/nvmet/subsystems/"$NODE1_LOCAL_SUBSYSTEM" 2>/dev/null || true
        mdadm --stop "$MD_DEVICE" 2>/dev/null || true
        nvme disconnect -n "$NODE1_REMOTE_SUBSYSTEM" 2>/dev/null || true
        log "Triggering nvme-cluster-init restart to wait for Node 2..."
        if systemctl is-active nvme-cluster-init.service >/dev/null 2>&1; then
            systemctl restart nvme-cluster-init.service
        else
            log "nvme-cluster-init not active (already retrying or failed) — skipping restart"
        fi
    fi
fi

exit 1
