#!/bin/bash
# NVMe-oF Cluster Bootstrap Script - Node 1 (ai.local - 192.168.177.11)
#
# Architecture:
#   Node2 exports /shared_pool.img via NVMe-oF (node2-shared)
#   Node1 creates RAID0 from: local loop + imported from node2
#   Node1 exports combined RAID0 via NVMe-oF (node1-shared)
#   Both nodes mount /mnt/nvmeof via GFS2 (managed by Pacemaker)
#
# Safety: This script is idempotent. If the cluster is already healthy,
# it exits immediately without touching anything.

set -euo pipefail

NODE1_IP="192.168.177.11"
NODE2_IP="192.168.177.12"
NVMET_PORT="4420"
LOCAL_SUBSYSTEM="nqn.2026-03.dgx:node1-shared"
REMOTE_SUBSYSTEM="nqn.2026-03.dgx:node2-shared"
MD_DEVICE="/dev/md0"
LOOP_DEVICE="/dev/loop101"
MOUNT_POINT="/mnt/nvmeof"
SHARED_POOL="/shared_pool.img"
NODE1_HOSTNQN="nqn.2014-08.org.nvmexpress:uuid:b5f22a9e-bfe0-11d3-8b92-30c5993d9a55"
NODE2_HOSTNQN="nqn.2014-08.org.nvmexpress:uuid:1d0edabc-bfdf-11d3-8d2d-30c5993def45"
# Fixed NVMe target identifiers — MUST be stable across reboots to prevent
# "identifiers changed for nsid" errors that break RAID0 on the initiator side.
LOCAL_SERIAL="node1-serial-001"
LOCAL_NGUID="44a4ab3929c14cdabb9df62843bd3b68"
LOCAL_UUID="11111111-1111-1111-1111-111111111111"

echo "=========================================="
echo "NVMe-oF Cluster Bootstrap - Node 1"
echo "=========================================="

# ============================================================
# HEALTH CHECK — skip destructive cleanup if cluster is healthy
# ============================================================
check_healthy() {
    local healthy=true

    # 1. Loop device mapped?
    if ! losetup -j "$SHARED_POOL" | grep -q .; then
        echo "  [health] Loop device not mapped"
        healthy=false
    fi

    # 2. RAID0 is active (not broken, not inactive)?
    if [ -b "$MD_DEVICE" ]; then
        if grep -q "broken" /proc/mdstat 2>/dev/null; then
            echo "  [health] RAID0 is BROKEN"
            healthy=false
        elif ! grep -q "^md0 : active" /proc/mdstat 2>/dev/null; then
            echo "  [health] RAID0 is not active"
            healthy=false
        fi
    else
        echo "  [health] $MD_DEVICE does not exist"
        healthy=false
    fi

    # 3. NVMe target exported?
    if [ ! -d "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM" ]; then
        echo "  [health] NVMe target not exported"
        healthy=false
    fi

    $healthy
}

echo "[0/6] Running health check..."
if check_healthy; then
    echo "Cluster is HEALTHY — nothing to do."
    exit 0
fi
echo "  Cluster needs repair — proceeding with bootstrap."

# ============================================================
# STEP 1: TARGETED CLEANUP (only break what's already broken)
# ============================================================
echo "[1/6] Cleaning up stale state..."

# Unmount GFS2 if mounted
if mount | grep -q "$MOUNT_POINT"; then
    umount -l "$MOUNT_POINT" 2>/dev/null || true
fi

# Determine RAID state
RAID_NEEDS_REBUILD=false
if [ -b "$MD_DEVICE" ]; then
    RAID_STATE=$(grep "^md0" /proc/mdstat 2>/dev/null || echo "")
    if echo "$RAID_STATE" | grep -q "broken\|inactive"; then
        echo "  RAID is broken/inactive — will rebuild."
        RAID_NEEDS_REBUILD=true
        # Disconnect NVMe first so RAID can release devices
        nvme disconnect -n "$REMOTE_SUBSYSTEM" 2>/dev/null || true
        sleep 2
        mdadm --stop "$MD_DEVICE" 2>/dev/null || true
    elif echo "$RAID_STATE" | grep -q "active"; then
        echo "  RAID is active — keeping it running."
    fi
else
    echo "  No RAID device — will build."
    RAID_NEEDS_REBUILD=true
    nvme disconnect -n "$REMOTE_SUBSYSTEM" 2>/dev/null || true
fi

# Clean up NVMe target configuration (our export only)
rm -f /sys/kernel/config/nvmet/ports/1/subsystems/* 2>/dev/null || true
rmdir /sys/kernel/config/nvmet/ports/1 2>/dev/null || true
for ns in /sys/kernel/config/nvmet/subsystems/"$LOCAL_SUBSYSTEM"/namespaces/*; do
  [ -d "$ns" ] || continue
  echo 0 > "$ns/enable" 2>/dev/null || true
  rmdir "$ns" 2>/dev/null || true
done
rm -f /sys/kernel/config/nvmet/subsystems/"$LOCAL_SUBSYSTEM"/allowed_hosts/* 2>/dev/null || true
rmdir /sys/kernel/config/nvmet/subsystems/"$LOCAL_SUBSYSTEM" 2>/dev/null || true
echo "Cleanup done."

# --- [2/6] Robust Loop Setup ---
echo "[2/6] Setting up loop device..."

# Reuse existing mapping if the file is already attached
LOOP_DEV=$(losetup -j "$SHARED_POOL" | cut -d: -f1 | head -n1)
if [ -z "$LOOP_DEV" ]; then
    # Not yet mapped — attach to the preferred device
    losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    LOOP_DEV=$(losetup --show "$LOOP_DEVICE" "$SHARED_POOL" 2>/dev/null) \
        || LOOP_DEV=$(losetup --show -f "$SHARED_POOL")
fi

# Final check that it has size
LOOP_SIZE=$(blockdev --getsize64 "$LOOP_DEV" 2>/dev/null || echo 0)
if [ "$LOOP_SIZE" -eq 0 ]; then
    echo "ERROR: $LOOP_DEV reports 0 size!"
    exit 1
fi
echo "Loop device ready: $LOOP_DEV ($((LOOP_SIZE/1024/1024/1024)) GB)"

# Update LOOP_DEVICE to whatever we actually got
LOOP_DEVICE="$LOOP_DEV"

# --- STEP 3: WAIT FOR STACD TO CONNECT TO NODE 2 ---
echo "[3/6] Waiting for stacd to connect to Node 2 ($REMOTE_SUBSYSTEM)..."

modprobe nvme-rdma
# stacd handles the actual connection in the background. We just wait for the device.

REMOTE_NVME=""
echo "[3/6] Scanning for block device matching $REMOTE_SUBSYSTEM..."

for ((i=1; i<=150; i++)); do
    # Find the subsystem directory matching our remote NQN
    # || echo "" keeps pipefail from triggering on empty results
    SUB_DIR=$(grep -l "$REMOTE_SUBSYSTEM" /sys/class/nvme-subsystem/nvme-subsys*/subsysnqn 2>/dev/null | xargs dirname 2>/dev/null || echo "")

    if [ -n "$SUB_DIR" ]; then
        # Use discovered $SUB_DIR (not hardcoded subsys index) to find namespace
        DEV_NAME=$(find -L "$SUB_DIR" -maxdepth 1 -name "nvme[1-9]*n[1-9]*" -print -quit 2>/dev/null | xargs basename 2>/dev/null || echo "")

        if [ -n "$DEV_NAME" ]; then
            DEV_NAME=$(echo "$DEV_NAME" | tr -d '[:space:]')

            if [ -b "/dev/$DEV_NAME" ]; then
                REMOTE_NVME="/dev/$DEV_NAME"
                echo "    Success: Found $REMOTE_NVME on attempt $i."
                break
            fi
        fi
    fi

    echo "    Attempt $i/150: Waiting for $REMOTE_SUBSYSTEM from stacd..."
    sleep 2
done

    echo "Remote NVMe device $REMOTE_NVME"
else
    echo "[3/6] RAID active — skipping NVMe reconnection."
    # Get the remote device name from the active RAID
    REMOTE_NVME=$(grep "^md0" /proc/mdstat | grep -oP 'nvme\S+' | sed 's/\[.*//' | head -1)
    [ -n "$REMOTE_NVME" ] && REMOTE_NVME="/dev/$REMOTE_NVME"
    echo "  Existing remote device: $REMOTE_NVME"
fi

# --- [4/6] Persistent RAID Assembly ---
echo "[4/6] Finalizing RAID0 state..."

# 1. Ensure the loop device isn't empty (Safety check)
LOOP_SIZE=$(blockdev --getsize64 "$LOOP_DEVICE" 2>/dev/null || echo 0)
if [ "$LOOP_SIZE" -eq 0 ]; then
    echo "ERROR: $LOOP_DEVICE is empty. Re-mapping to /shared_pool.img..."
    losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    losetup "$LOOP_DEVICE" /shared_pool.img
fi

# 2. Assemble only — NEVER --create on an existing array (that destroys GFS2)
# Check if RAID is already active with both devices
if grep -q "^md0 : active" /proc/mdstat 2>/dev/null; then
    echo "  RAID0 already active."
else
    ASSEMBLE_OK=0
    for attempt in $(seq 1 5); do
        if mdadm --assemble --run --force /dev/md0 "$LOOP_DEVICE" "$REMOTE_NVME" 2>/dev/null; then
            echo "  Success: RAID0 assembled from existing metadata (attempt $attempt)."
            ASSEMBLE_OK=1
            break
        fi
        echo "  Assemble attempt $attempt/5 failed, retrying in 2s..."
        sleep 2
    done

    if [ "$ASSEMBLE_OK" -eq 0 ]; then
        echo "ERROR: Could not assemble RAID0. DO NOT use --create on an existing array."
        echo "  If this is initial setup, run manually: mdadm --create --run --force /dev/md0 --level=0 --raid-devices=2 $LOOP_DEVICE $REMOTE_NVME"
        exit 1
    fi
fi

# --- STEP 5: EXPORT VIA NVMe-oF TARGET ---
echo "[5/6] Configuring NVMe-oF target..."

modprobe nvmet
modprobe nvmet-rdma

mkdir -p "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1"
echo -n "$MD_DEVICE" > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1/device_path"

# Pin serial number so initiators see the same identity after reboots
echo "$LOCAL_SERIAL" > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/attr_serial"

# Pin namespace UUID (nguid) for stable device identification
echo "$LOCAL_NGUID" > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1/device_nguid"

# Pin device_uuid for stable device identification
echo "$LOCAL_UUID" > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1/device_uuid"

echo 1 > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1/enable"

# Host ACLs - restrict to node1 and node2 only (no allow_any_host)
mkdir -p "/sys/kernel/config/nvmet/hosts/$NODE1_HOSTNQN"
mkdir -p "/sys/kernel/config/nvmet/hosts/$NODE2_HOSTNQN"
ALLOWED_HOSTS_DIR="/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/allowed_hosts"
echo 0 > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/attr_allow_any_host"
ln -sf "/sys/kernel/config/nvmet/hosts/$NODE1_HOSTNQN" "$ALLOWED_HOSTS_DIR/"
ln -sf "/sys/kernel/config/nvmet/hosts/$NODE2_HOSTNQN" "$ALLOWED_HOSTS_DIR/"

mkdir -p /sys/kernel/config/nvmet/ports/1
echo "ipv4"        > /sys/kernel/config/nvmet/ports/1/addr_adrfam
echo "rdma"        > /sys/kernel/config/nvmet/ports/1/addr_trtype
echo "$NVMET_PORT" > /sys/kernel/config/nvmet/ports/1/addr_trsvcid
echo "$NODE1_IP"   > /sys/kernel/config/nvmet/ports/1/addr_traddr
ln -sf "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM" \
    /sys/kernel/config/nvmet/ports/1/subsystems/

echo "Target listening on $NODE1_IP:$NVMET_PORT (hosts: node1, node2 only)"

# --- STEP 6: PERSIST mdadm.conf ---
echo "[6/6] Persisting mdadm.conf..."

mkdir -p /etc/mdadm
mdadm --detail --scan > /etc/mdadm/mdadm.conf
mkdir -p "$MOUNT_POINT"
echo "mdadm.conf updated. Mount point $MOUNT_POINT ready."

# Pacemaker unstandby — run in background since pacemaker starts AFTER this script
# (this service has Before=corosync.service pacemaker.service)
if command -v pcs &>/dev/null; then
    (
        # Wait for pacemaker to be ready (max 120s)
        for i in $(seq 1 24); do
            if pcs status &>/dev/null; then
                pcs node unstandby "$NODE1_IP" 2>/dev/null || true
                pcs node unstandby "$NODE2_IP" 2>/dev/null || true
                break
            fi
            sleep 5
        done
    ) &
    disown
fi

echo ""
echo "=========================================="
echo "Node 1 bootstrap complete!"
echo "  RAID0 : $MD_DEVICE  ($LOOP_DEVICE + $REMOTE_NVME)"
echo "  Target: $NODE1_IP:$NVMET_PORT -> $LOCAL_SUBSYSTEM"
echo "  Mount : $MOUNT_POINT (GFS2, via Pacemaker)"
echo "=========================================="