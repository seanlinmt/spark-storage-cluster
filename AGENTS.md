# PROJECT KNOWLEDGE BASE

**Generated:** 2026-04-08
**Project:** Spark Storage Cluster - NVMe-oF Cluster Configuration

## OVERVIEW
Infrastructure-as-Code for NVMe over Fabrics (NVMe-oF) cluster between 2 DGX Spark nodes. Uses loopback-backed images, mdadm RAID0, GFS2 filesystem, and Pacemaker/Corosync for HA.

## STRUCTURE
```
spark-storage-cluster/
├── corosync.conf          # Corosync cluster config
├── nvme-safe-reboot.sh    # Graceful cluster teardown script
├── README.md              # Full documentation
└── systemd/               # systemd unit files
    ├── Node 1/            # Node-specific boot scripts
    └── Node 2/            # Node-specific boot scripts
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Cluster boot | `systemd/Node 1/nvme-boot-node1.sh` | Node 1: builds RAID, exports |
| Cluster boot | `systemd/Node 2/nvme-boot-node2.sh` | Node 2: exports loop device |
| Safe reboot | `nvme-safe-reboot.sh` | Graceful teardown before reboot |
| Cluster config | `corosync.conf` | Quorum & transport settings |

## KEY VARIABLES (hardcoded in scripts)
- **NODE1_IP:** 192.168.177.11
- **NODE2_IP:** 192.168.177.12
- **NVMET_PORT:** 4420
- **MD_DEVICE:** /dev/md0
- **LOOP_DEVICE:** /dev/loop27
- **MOUNT_POINT:** /mnt/nvmeof

## ANTI-PATTERNS (THIS PROJECT)
- **DO NOT** run boot scripts out of order (Node 2 must export before Node 1 imports)
- **DO NOT** disable STONITH in production (see README warning)
- **DO NOT** use Docker directly on GFS2 (requires ext4 overlay)

## CONVENTIONS
- Node detection via hostname: `ai` → Node 1, `ai2` → Node 2
- Service files use `nvme-cluster-init.service` naming
- Scripts use `set -uo pipefail` for strict error handling

## COMMANDS
```bash
# Health check
pcs status
nvme list

# Manual boot (Node 2 FIRST)
sudo systemctl start nvme-cluster-init  # on node2
sudo systemctl start nvme-cluster-init  # on node1

# Recovery
sudo pcs resource cleanup gfs2-nvmeof
```

## NOTES
- RAID0 = no redundancy. If either node fails, array degrades.
- Boot order critical: Node 2 exports → Node 1 imports & builds RAID → Node 1 exports → Node 2 imports
- GFS2 requires DLM (Distributed Lock Manager) via Pacemaker