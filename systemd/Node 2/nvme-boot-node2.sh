#!/bin/bash
# NVMe-oF Cluster Bootstrap Script - Node 2 (ai2.local - 192.168.177.12)
#
# Architecture:
#   Node2 exports /shared_pool.img via NVMe-oF (node2-shared)
#   Node1 assembles RAID0 and exports combined volume (node1-shared)
#   Node2 imports node1-shared and mounts /mnt/nvmeof via GFS2 (managed by Pacemaker)

set -euo pipefail

NODE1_IP="192.168.177.11"
NODE2_IP="192.168.177.12"
NVMET_PORT="4420"
LOOP_DEVICE="/dev/loop100"
LOCAL_SUBSYSTEM="nqn.2026-03.dgx:node2-shared"
REMOTE_SUBSYSTEM="nqn.2026-03.dgx:node1-shared"
MOUNT_POINT="/mnt/nvmeof"
SHARED_POOL="/shared_pool.img"
NODE1_HOSTNQN="nqn.2014-08.org.nvmexpress:uuid:b5f22a9e-bfe0-11d3-8b92-30c5993d9a55"

echo "=========================================="
echo "NVMe-oF Cluster Bootstrap - Node 2"
echo "=========================================="

# --- STEP 1: CLEANUP STALE STATE ---
echo "[1/4] Cleaning up stale state..."

umount -l "$MOUNT_POINT" 2>/dev/null || true
nvme disconnect-all 2>/dev/null || true

rm -f /sys/kernel/config/nvmet/ports/2/subsystems/* 2>/dev/null || true
rmdir /sys/kernel/config/nvmet/ports/2 2>/dev/null || true
for ns in /sys/kernel/config/nvmet/subsystems/*/namespaces/*; do
  [ -d "$ns" ] || continue
  echo 0 > "$ns/enable" 2>/dev/null || true
  rmdir "$ns" 2>/dev/null || true
done
rm -f /sys/kernel/config/nvmet/subsystems/*/allowed_hosts/* 2>/dev/null || true
rmdir /sys/kernel/config/nvmet/subsystems/* 2>/dev/null || true
rmdir /sys/kernel/config/nvmet/hosts/* 2>/dev/null || true
echo "Cleanup done."

# --- STEP 2: EXPORT LOCAL POOL VIA NVMe-oF ---
echo "[2/4] Configuring NVMe-oF target (exporting $SHARED_POOL to Node 1)..."

LOOP_DEV=$(losetup -j "$SHARED_POOL" | cut -d: -f1 | head -n1)
if [ -z "$LOOP_DEV" ]; then
    LOOP_DEV=$(losetup --show "$LOOP_DEVICE" "$SHARED_POOL")
fi
echo "Loop device: $LOOP_DEV"

modprobe nvmet
modprobe nvmet-rdma

mkdir -p "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1"
echo -n "$LOOP_DEV" > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1/device_path"
# Get the UUID of the underlying device if it exists
DEVICE_UUID=$(lsblk -no UUID "$LOOP_DEV")
if [ -z "$DEVICE_UUID" ]; then
    echo "  Notice: No UUID found on $LOOP_DEV, skipping device_uuid config."
else
    echo "$DEVICE_UUID" > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1/device_uuid"
fi
echo 1 > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1/enable"

# Host ACLs - only allow Node 1 to import this export
mkdir -p "/sys/kernel/config/nvmet/hosts/$NODE1_HOSTNQN"
ALLOWED_HOSTS_DIR="/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/allowed_hosts"
# Disable global access first
echo 0 > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/attr_allow_any_host"
# Then link the allowed host
ln -sf "/sys/kernel/config/nvmet/hosts/$NODE1_HOSTNQN" "$ALLOWED_HOSTS_DIR/"

mkdir -p /sys/kernel/config/nvmet/ports/2
echo "ipv4"        > /sys/kernel/config/nvmet/ports/2/addr_adrfam
echo "rdma"        > /sys/kernel/config/nvmet/ports/2/addr_trtype
echo "$NVMET_PORT" > /sys/kernel/config/nvmet/ports/2/addr_trsvcid
echo "$NODE2_IP"   > /sys/kernel/config/nvmet/ports/2/addr_traddr
ln -sf "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM" \
    /sys/kernel/config/nvmet/ports/2/subsystems/

echo "Target listening on $NODE2_IP:$NVMET_PORT -> $LOCAL_SUBSYSTEM (node1 only)"

# --- STEP 3: CONNECT TO NODE 1 (combined RAID0 volume) ---
echo "[3/4] Waiting for Node 1 ($NODE1_IP) to export $REMOTE_SUBSYSTEM..."


modprobe nvme-rdma

MAX_RETRIES=60
RETRY=0
until nvme discover -t rdma -a "$NODE1_IP" -s "$NVMET_PORT" 2>/dev/null | grep -q "$REMOTE_SUBSYSTEM"; do
    RETRY=$((RETRY + 1))
    [ $RETRY -ge $MAX_RETRIES ] && { echo "ERROR: Timeout waiting for Node 1"; exit 1; }
    echo "  Attempt $RETRY/$MAX_RETRIES..."
    sleep 2
done

nvme connect -t rdma -a "$NODE1_IP" -s "$NVMET_PORT" -n "$REMOTE_SUBSYSTEM" || true
udevadm settle
sleep 5

# Safely find the exact device mapped to the remote NQN
REMOTE_NVME=""
echo "  Scanning for block device matching $REMOTE_SUBSYSTEM..."

for ((i=1; i<=30; i++)); do
    # First try: Check /sys/class/nvme-subsystem for the device
    for subsys in /sys/class/nvme-subsystem/nvme-subsys*; do
        [ -e "$subsys/subsysnqn" ] || continue
        if grep -q "$REMOTE_SUBSYSTEM" "$subsys/subsysnqn" 2>/dev/null; then
            # We found the subsystem, look for namespace devices (nvme*n* format)
            for ns_dev in "$subsys"/nvme*n*; do
                [ -e "$ns_dev" ] || continue
                dev_name=$(basename "$ns_dev")
                # Look for the actual block device in /dev/
                if [ -b "/dev/$dev_name" ]; then
                    REMOTE_NVME="/dev/$dev_name"
                    echo "    Found via nvme-subsystem: $REMOTE_NVME"
                    break 3
                fi
            done
        fi
    done
    
    # Second try: Check /sys/class/nvme directly (fallback)
    for subsys in /sys/class/nvme/nvme[1-9]*; do
        [ -e "$subsys/subsysnqn" ] || continue
        if grep -q "$REMOTE_SUBSYSTEM" "$subsys/subsysnqn" 2>/dev/null; then
            # We found the subsystem, look for namespace devices
            for dev_dir in "$subsys"/nvme*n*; do
                [ -e "$dev_dir" ] || continue
                dev_name=$(basename "$dev_dir")
                if [ -b "/dev/$dev_name" ]; then
                    REMOTE_NVME="/dev/$dev_name"
                    echo "    Found via nvme class: $REMOTE_NVME"
                    break 3
                fi
            done
        fi
    done
    
    echo "    Attempt $i/30: Waiting for device to appear..."
    sleep 2
done

if [ -z "$REMOTE_NVME" ]; then
    echo "ERROR: Could not find block device for $REMOTE_SUBSYSTEM"
    exit 1
fi
echo "Remote NVMe device (node1 RAID0, GFS2): $REMOTE_NVME"

# --- Force udev to create /dev/disk/by-uuid symlink for NVMe-oF device ---
echo "  Forcing blkid probe and udev update for $REMOTE_NVME..."
blkid -p $REMOTE_NVME > /dev/null 2>&1 || true
udevadm trigger --action=change --sysname-match=$(basename $REMOTE_NVME)
udevadm settle
echo "  UUID symlink ready."

# --- STEP 4: PREPARE MOUNT POINT ---
echo "[4/4] Preparing mount point..."
mkdir -p "$MOUNT_POINT"

# Clear any stale Pacemaker standby state so resources can start on this node
if command -v pcs &>/dev/null; then
    pcs node unstandby "$NODE2_IP" 2>/dev/null || true
fi

echo ""
echo "=========================================="
echo "Node 2 bootstrap complete!"
echo "  Export: $NODE2_IP:$NVMET_PORT -> $LOCAL_SUBSYSTEM ($LOOP_DEV)"
echo "  Import: $REMOTE_NVME <- Node 1 RAID0 (GFS2)"
echo "  Mount : $MOUNT_POINT (GFS2, via Pacemaker)"
echo "=========================================="