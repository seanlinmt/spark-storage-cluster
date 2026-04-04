#!/bin/bash
# NVMe-oF Cluster Bootstrap Script - Node 1 (ai.local - 192.168.177.11)
#
# Architecture:
#   Node2 exports /shared_pool.img via NVMe-oF (node2-shared)
#   Node1 creates RAID0 from: local loop + imported from node2
#   Node1 exports combined RAID0 via NVMe-oF (node1-shared)
#   Both nodes mount /mnt/nvmeof via GFS2 (managed by Pacemaker)

set -euo pipefail

NODE1_IP="192.168.177.11"
NODE2_IP="192.168.177.12"
NVMET_PORT="4420"
LOCAL_SUBSYSTEM="nqn.2026-03.dgx:node1-shared"
REMOTE_SUBSYSTEM="nqn.2026-03.dgx:node2-shared"
MD_DEVICE="/dev/md0"
LOOP_DEVICE="/dev/loop27"
MOUNT_POINT="/mnt/nvmeof"
SHARED_POOL="/shared_pool.img"
NODE1_HOSTNQN="nqn.2014-08.org.nvmexpress:uuid:b5f22a9e-bfe0-11d3-8b92-30c5993d9a55"
NODE2_HOSTNQN="nqn.2014-08.org.nvmexpress:uuid:1d0edabc-bfdf-11d3-8d2d-30c5993def45"

echo "=========================================="
echo "NVMe-oF Cluster Bootstrap - Node 1"
echo "=========================================="

# --- STEP 1: CLEANUP STALE STATE ---
echo "[1/6] Cleaning up stale state..."

umount -l "$MOUNT_POINT" 2>/dev/null || true
mdadm --stop "$MD_DEVICE" 2>/dev/null || true
nvme disconnect-all 2>/dev/null || true

rm -f /sys/kernel/config/nvmet/ports/1/subsystems/* 2>/dev/null || true
rmdir /sys/kernel/config/nvmet/ports/1 2>/dev/null || true
for ns in /sys/kernel/config/nvmet/subsystems/*/namespaces/*; do
  [ -d "$ns" ] || continue
  echo 0 > "$ns/enable" 2>/dev/null || true
  rmdir "$ns" 2>/dev/null || true
done
rm -f /sys/kernel/config/nvmet/subsystems/*/allowed_hosts/* 2>/dev/null || true
rmdir /sys/kernel/config/nvmet/subsystems/* 2>/dev/null || true
rmdir /sys/kernel/config/nvmet/hosts/* 2>/dev/null || true
echo "Cleanup done."

# --- [2/6] Robust Loop Setup ---
echo "[2/6] Setting up loop device..."

# Force detach if it exists so we get a clean mapping
losetup -d "$LOOP_DEVICE" 2>/dev/null || true

# Map the file specifically to loop27
if ! losetup "$LOOP_DEVICE" /shared_pool.img; then
    echo "ERROR: Failed to map /shared_pool.img to $LOOP_DEVICE"
    exit 1
fi

# Final check that it has size
LOOP_SIZE=$(blockdev --getsize64 "$LOOP_DEVICE" 2>/dev/null || echo 0)
if [ "$LOOP_SIZE" -eq 0 ]; then
    echo "ERROR: $LOOP_DEVICE reports 0 size!"
    exit 1
fi
echo "Loop device ready: $LOOP_DEVICE ($((LOOP_SIZE/1024/1024/1024)) GB)"

# --- STEP 3: CONNECT TO NODE 2 ---
echo "[3/6] Waiting for Node 2 ($NODE2_IP) to export $REMOTE_SUBSYSTEM..."

modprobe nvme-rdma

MAX_RETRIES=150
RETRY=0
until nvme discover -t rdma -a "$NODE2_IP" -s "$NVMET_PORT" 2>/dev/null | grep -q "$REMOTE_SUBSYSTEM"; do
    RETRY=$((RETRY + 1))
    [ $RETRY -ge $MAX_RETRIES ] && { echo "ERROR: Timeout waiting for Node 2"; exit 1; }
    echo "  Attempt $RETRY/$MAX_RETRIES..."
    sleep 2
done

nvme connect -t rdma -a "$NODE2_IP" -s "$NVMET_PORT" -n "$REMOTE_SUBSYSTEM" || true
udevadm settle
sleep 3

# --- STEP 3: CONNECT TO NODE 2 ---
# --- [3/6] Scanning Loop (Echo Trick / set -e Safe) ---
# --- [3/6] Scanning Loop (The "Echo Trick" Version) ---
REMOTE_NVME=""
echo "[3/6] Scanning for block device matching $REMOTE_SUBSYSTEM..."

for ((i=1; i<=30; i++)); do
    # 1. Find the subsystem directory.
    # We use ( ... ) || echo "" to ensure the variable assignment
    # never returns a non-zero exit code to the main shell.
    SUB_DIR=$(grep -l "$REMOTE_SUBSYSTEM" /sys/class/nvme-subsystem/nvme-subsys*/subsysnqn 2>/dev/null | xargs dirname 2>/dev/null || echo "")

    if [ -n "$SUB_DIR" ]; then
        # 2. Find the namespace (e.g., nvme1n2)
        # We look for a directory entry that isn't nvme0.
        # Again, we use the || echo "" trick to keep pipefail happy.
        DEV_NAME=$(find -L "/sys/class/nvme-subsystem/nvme-subsys1" -maxdepth 1 -name "nvme[1-9]*n[1-9]*" -print -quit 2>/dev/null | xargs basename 2>/dev/null || echo "")

        if [ -n "$DEV_NAME" ]; then
            # Clean any potential whitespace/newlines from xargs
            DEV_NAME=$(echo "$DEV_NAME" | tr -d '[:space:]')

            # Check if the block device is actually ready in /dev
            if [ -b "/dev/$DEV_NAME" ]; then
                REMOTE_NVME="/dev/$DEV_NAME"
                echo "    Success: Found $REMOTE_NVME on attempt $i."
                break
            fi
        fi
    fi

    echo "    Attempt $i/30: Waiting for $REMOTE_SUBSYSTEM..."
    sleep 1
done

# Final check before moving to RAID assembly
if [ -z "$REMOTE_NVME" ]; then
    echo "ERROR: Device detection timed out. No block device found for $REMOTE_SUBSYSTEM."
    # List what we DID find to help debug
    echo "Current NVMe Subsystems found:"
    grep -r "." /sys/class/nvme-subsystem/nvme-subsys*/subsysnqn 2>/dev/null || echo "None"
    exit 1
fi

echo "Remote NVMe device $REMOTE_NVME"

# --- [4/6] Persistent RAID Assembly ---
echo "[4/6] Finalizing RAID0 state..."

# 1. Ensure the loop device isn't empty (Safety check)
LOOP_SIZE=$(blockdev --getsize64 "$LOOP_DEVICE" 2>/dev/null || echo 0)
if [ "$LOOP_SIZE" -eq 0 ]; then
    echo "ERROR: $LOOP_DEVICE is empty. Re-mapping to /shared_pool.img..."
    losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    losetup "$LOOP_DEVICE" /shared_pool.img
fi

# 2. Assemble or Create
# If both disks have a matching superblock, 'assemble' will work.
# If one is blank (like our loop device was), we 'create' to sync them.
if mdadm --assemble --run --force /dev/md0 "$LOOP_DEVICE" "$REMOTE_NVME" 2>/dev/null; then
    echo "  Success: RAID0 Assembled from existing metadata."
else
    echo "  No valid RAID found on both legs. Initializing/Syncing now..."
    mdadm --create --run --force /dev/md0 --level=0 --raid-devices=2 "$LOOP_DEVICE" "$REMOTE_NVME"
fi

# --- STEP 5: EXPORT VIA NVMe-oF TARGET ---
echo "[5/6] Configuring NVMe-oF target..."

modprobe nvmet
modprobe nvmet-rdma

mkdir -p "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1"
echo -n "$MD_DEVICE" > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1/device_path"
# Get the UUID of the underlying device to ensure the export presents a stable, matching identifier
DEVICE_UUID=$(lsblk -no UUID "$MD_DEVICE")
echo "$DEVICE_UUID" > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1/device_uuid"
echo 1 > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/namespaces/1/enable"

# Host ACLs - restrict to node1 and node2 only (no allow_any_host)
mkdir -p "/sys/kernel/config/nvmet/hosts/$NODE1_HOSTNQN"
mkdir -p "/sys/kernel/config/nvmet/hosts/$NODE2_HOSTNQN"
ALLOWED_HOSTS_DIR="/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/allowed_hosts"
#ln -sf "/sys/kernel/config/nvmet/hosts/$NODE1_HOSTNQN" "$ALLOWED_HOSTS_DIR/"
#ln -sf "/sys/kernel/config/nvmet/hosts/$NODE2_HOSTNQN" "$ALLOWED_HOSTS_DIR/"
#echo 0 > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/attr_allow_any_host"
# Disable global access first
echo 0 > "/sys/kernel/config/nvmet/subsystems/$LOCAL_SUBSYSTEM/attr_allow_any_host"
# Then link the allowed hosts
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

echo ""
echo "=========================================="
echo "Node 1 bootstrap complete!"
echo "  RAID0 : $MD_DEVICE  ($LOOP_DEVICE + $REMOTE_NVME)"
echo "  Target: $NODE1_IP:$NVMET_PORT -> $LOCAL_SUBSYSTEM"
echo "  Mount : $MOUNT_POINT (GFS2, via Pacemaker)"
echo "=========================================="