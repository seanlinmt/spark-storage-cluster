#!/bin/bash
# NVMe-oF Cluster Safe Reboot Script
#
# Detects which node it's running on (ai or ai2) and performs a graceful
# teardown of the NVMe-oF cluster before rebooting.
#
# Usage: sudo nvme-safe-reboot.sh [--no-reboot]
#
# Teardown order:
#   1. Put Pacemaker node into standby (unmounts GFS2 on this node)
#   2. Disconnect NVMe-oF initiator connections
#   3. Stop RAID array (Node 1 only)
#   4. Remove NVMe-oF target exports
#   5. Detach loop devices
#   6. Stop Pacemaker/Corosync
#   7. Reboot (unless --no-reboot)

set -uo pipefail

NODE1_IP="192.168.177.11"
NODE2_IP="192.168.177.12"
MD_DEVICE="/dev/md0"
LOOP_DEVICE="/dev/loop27"
MOUNT_POINT="/mnt/nvmeof"
SHARED_POOL="/shared_pool.img"

NO_REBOOT=false
if [[ "${1:-}" == "--no-reboot" ]]; then
    NO_REBOOT=true
fi

# --- Detect which node we are ---
HOSTNAME=$(hostname)
case "$HOSTNAME" in
    ai)  NODE_ID=1; LOCAL_IP="$NODE1_IP"; PORT_NUM=1 ;;
    ai2) NODE_ID=2; LOCAL_IP="$NODE2_IP"; PORT_NUM=2 ;;
    *)
        echo "ERROR: Unknown hostname '$HOSTNAME'. Expected 'ai' or 'ai2'."
        exit 1
        ;;
esac

echo "=========================================="
echo "NVMe-oF Safe Reboot - Node $NODE_ID ($HOSTNAME)"
echo "=========================================="

# --- STEP 1: Pacemaker Standby ---
echo "[1/6] Putting this node into Pacemaker standby..."
if pcs status >/dev/null 2>&1; then
    pcs node standby "$LOCAL_IP"
    # Wait for GFS2 to unmount on this node
    for i in $(seq 1 30); do
        if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
            echo "  GFS2 unmounted."
            break
        fi
        echo "  Waiting for GFS2 unmount... ($i/30)"
        sleep 2
    done
    # Force unmount if Pacemaker didn't do it
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        echo "  WARNING: Force unmounting $MOUNT_POINT"
        umount -l "$MOUNT_POINT" 2>/dev/null || true
    fi
else
    echo "  Pacemaker not running, skipping standby."
    umount -l "$MOUNT_POINT" 2>/dev/null || true
fi

# --- STEP 2: Disconnect NVMe-oF initiator ---
echo "[2/6] Disconnecting NVMe-oF initiator connections..."
nvme disconnect-all 2>/dev/null || true
sleep 2

# --- STEP 3: Stop RAID (Node 1 only) ---
if [[ "$NODE_ID" -eq 1 ]]; then
    echo "[3/6] Stopping RAID array $MD_DEVICE..."
    mdadm --stop "$MD_DEVICE" 2>/dev/null || true
    sleep 1
else
    echo "[3/6] Skipping RAID teardown (Node 2 does not own RAID)."
fi

# --- STEP 4: Remove NVMe-oF target exports ---
echo "[4/6] Removing NVMe-oF target exports..."
# Unlink subsystems from port
rm -f /sys/kernel/config/nvmet/ports/$PORT_NUM/subsystems/* 2>/dev/null || true
rmdir /sys/kernel/config/nvmet/ports/$PORT_NUM 2>/dev/null || true

# Disable and remove namespaces
for ns in /sys/kernel/config/nvmet/subsystems/*/namespaces/*; do
    [ -d "$ns" ] || continue
    echo 0 > "$ns/enable" 2>/dev/null || true
    rmdir "$ns" 2>/dev/null || true
done

# Remove allowed hosts and subsystems
rm -f /sys/kernel/config/nvmet/subsystems/*/allowed_hosts/* 2>/dev/null || true
rmdir /sys/kernel/config/nvmet/subsystems/* 2>/dev/null || true
rmdir /sys/kernel/config/nvmet/hosts/* 2>/dev/null || true

# --- STEP 5: Detach loop devices ---
echo "[5/6] Detaching loop device..."
LOOP_DEV=$(losetup -j "$SHARED_POOL" 2>/dev/null | cut -d: -f1 | head -n1)
if [[ -n "$LOOP_DEV" ]]; then
    losetup -d "$LOOP_DEV" 2>/dev/null || true
    echo "  Detached $LOOP_DEV"
else
    echo "  No loop device attached to $SHARED_POOL"
fi

# --- STEP 6: Stop Pacemaker/Corosync ---
echo "[6/6] Stopping cluster services..."
systemctl stop pacemaker 2>/dev/null || true
systemctl stop corosync 2>/dev/null || true

echo ""
echo "=========================================="
echo "Node $NODE_ID ($HOSTNAME) teardown complete."
if [[ "$NO_REBOOT" == true ]]; then
    echo "Reboot skipped (--no-reboot). System is safe to reboot manually."
    echo "=========================================="
else
    echo "Rebooting in 5 seconds..."
    echo "=========================================="
    sleep 5
    reboot
fi
