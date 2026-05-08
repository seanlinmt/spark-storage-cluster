#!/bin/bash
set -e

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "Deploying to Node 1 (192.168.20.63)..."
scp $SSH_OPTS "corosync.conf" 192.168.20.63:/tmp/
scp $SSH_OPTS "nvme-safe-reboot.sh" 192.168.20.63:/tmp/
scp $SSH_OPTS "systemd/Node 1/nvme-boot-node1.sh" 192.168.20.63:/tmp/
scp $SSH_OPTS "systemd/Node 1/nvme-cluster-init.service" 192.168.20.63:/tmp/
scp $SSH_OPTS "systemd/Node 1/stacd.conf" 192.168.20.63:/tmp/
scp $SSH_OPTS "systemd/nvme-cluster-health.sh" 192.168.20.63:/tmp/
scp $SSH_OPTS "systemd/nvme-cluster-health.service" 192.168.20.63:/tmp/
scp $SSH_OPTS "systemd/nvme-cluster-health.timer" 192.168.20.63:/tmp/
scp $SSH_OPTS "systemd/corosync.service" 192.168.20.63:/tmp/
scp $SSH_OPTS "systemd/pacemaker.service" 192.168.20.63:/tmp/

ssh $SSH_OPTS 192.168.20.63 '
  sudo mv /tmp/corosync.conf /etc/corosync/corosync.conf
  sudo mv /tmp/nvme-safe-reboot.sh /usr/local/bin/
  sudo chmod +x /usr/local/bin/nvme-safe-reboot.sh
  sudo mv /tmp/nvme-boot-node1.sh /usr/local/bin/
  sudo chmod +x /usr/local/bin/nvme-boot-node1.sh
  sudo mv /tmp/nvme-cluster-health.sh /usr/local/bin/
  sudo chmod +x /usr/local/bin/nvme-cluster-health.sh
  sudo mv /tmp/nvme-cluster-init.service /etc/systemd/system/
  sudo mv /tmp/nvme-cluster-health.service /etc/systemd/system/
  sudo mv /tmp/nvme-cluster-health.timer /etc/systemd/system/
  sudo mv /tmp/corosync.service /etc/systemd/system/
  sudo mv /tmp/pacemaker.service /etc/systemd/system/
  sudo mkdir -p /etc/stas
  sudo mv /tmp/stacd.conf /etc/stas/stacd.conf
  sudo chown root:root /etc/stas/stacd.conf
  sudo systemctl daemon-reload
  sudo systemctl enable --now stacd
  sudo systemctl enable --now nvme-cluster-health.timer
  echo "Node 1 deployment complete."
'

echo "Deploying to Node 2 (192.168.20.229)..."
scp $SSH_OPTS "corosync.conf" 192.168.20.229:/tmp/
scp $SSH_OPTS "nvme-safe-reboot.sh" 192.168.20.229:/tmp/
scp $SSH_OPTS "systemd/Node 2/nvme-boot-node2.sh" 192.168.20.229:/tmp/
scp $SSH_OPTS "systemd/Node 2/nvme-cluster-init.service" 192.168.20.229:/tmp/
scp $SSH_OPTS "systemd/Node 2/stacd.conf" 192.168.20.229:/tmp/
scp $SSH_OPTS "systemd/nvme-cluster-health.sh" 192.168.20.229:/tmp/
scp $SSH_OPTS "systemd/nvme-cluster-health.service" 192.168.20.229:/tmp/
scp $SSH_OPTS "systemd/nvme-cluster-health.timer" 192.168.20.229:/tmp/
scp $SSH_OPTS "systemd/corosync.service" 192.168.20.229:/tmp/
scp $SSH_OPTS "systemd/pacemaker.service" 192.168.20.229:/tmp/

ssh $SSH_OPTS 192.168.20.229 '
  sudo mv /tmp/corosync.conf /etc/corosync/corosync.conf
  sudo mv /tmp/nvme-safe-reboot.sh /usr/local/bin/
  sudo chmod +x /usr/local/bin/nvme-safe-reboot.sh
  sudo mv /tmp/nvme-boot-node2.sh /usr/local/bin/
  sudo chmod +x /usr/local/bin/nvme-boot-node2.sh
  sudo mv /tmp/nvme-cluster-health.sh /usr/local/bin/
  sudo chmod +x /usr/local/bin/nvme-cluster-health.sh
  sudo mv /tmp/nvme-cluster-init.service /etc/systemd/system/
  sudo mv /tmp/nvme-cluster-health.service /etc/systemd/system/
  sudo mv /tmp/nvme-cluster-health.timer /etc/systemd/system/
  sudo mv /tmp/corosync.service /etc/systemd/system/
  sudo mv /tmp/pacemaker.service /etc/systemd/system/
  sudo mkdir -p /etc/stas
  sudo mv /tmp/stacd.conf /etc/stas/stacd.conf
  sudo chown root:root /etc/stas/stacd.conf
  sudo systemctl daemon-reload
  sudo systemctl enable --now stacd
  sudo systemctl enable --now nvme-cluster-health.timer
  echo "Node 2 deployment complete."
'
