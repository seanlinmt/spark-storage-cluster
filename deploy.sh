#!/bin/bash
set -e

NODE1_IP="192.168.20.63"
NODE2_IP="192.168.20.229"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "Deploying to Node 1 ($NODE1_IP)..."
scp $SSH_OPTS "corosync.conf" $NODE1_IP:/tmp/
scp $SSH_OPTS "nvme-safe-reboot.sh" $NODE1_IP:/tmp/
scp $SSH_OPTS "systemd/Node 1/nvme-boot-node1.sh" $NODE1_IP:/tmp/
scp $SSH_OPTS "systemd/Node 1/nvme-cluster-init.service" $NODE1_IP:/tmp/
scp $SSH_OPTS "systemd/Node 1/stacd.conf" $NODE1_IP:/tmp/
scp $SSH_OPTS "systemd/nvme-cluster-health.sh" $NODE1_IP:/tmp/
scp $SSH_OPTS "systemd/nvme-cluster-health.service" $NODE1_IP:/tmp/
scp $SSH_OPTS "systemd/nvme-cluster-health.timer" $NODE1_IP:/tmp/
scp $SSH_OPTS "systemd/corosync.service" $NODE1_IP:/tmp/
scp $SSH_OPTS "systemd/pacemaker.service" $NODE1_IP:/tmp/
scp $SSH_OPTS "systemd/sbd-fix-pidfile.conf" $NODE1_IP:/tmp/
scp $SSH_OPTS "systemd/sbd-defaults.conf" $NODE1_IP:/tmp/

ssh $SSH_OPTS $NODE1_IP '
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
  sudo mkdir -p /etc/systemd/system/sbd.service.d
  sudo mv /tmp/sbd-fix-pidfile.conf /etc/systemd/system/sbd.service.d/override.conf
  sudo mv /tmp/sbd-defaults.conf /etc/default/sbd
  sudo systemctl daemon-reload
  sudo systemctl enable --now stacd
  sudo systemctl enable --now nvme-cluster-health.timer
  echo "Node 1 deployment complete."
'

echo "Deploying to Node 2 ($NODE2_IP)..."
scp $SSH_OPTS "corosync.conf" $NODE2_IP:/tmp/
scp $SSH_OPTS "nvme-safe-reboot.sh" $NODE2_IP:/tmp/
scp $SSH_OPTS "systemd/Node 2/nvme-boot-node2.sh" $NODE2_IP:/tmp/
scp $SSH_OPTS "systemd/Node 2/nvme-cluster-init.service" $NODE2_IP:/tmp/
scp $SSH_OPTS "systemd/Node 2/stacd.conf" $NODE2_IP:/tmp/
scp $SSH_OPTS "systemd/nvme-cluster-health.sh" $NODE2_IP:/tmp/
scp $SSH_OPTS "systemd/nvme-cluster-health.service" $NODE2_IP:/tmp/
scp $SSH_OPTS "systemd/nvme-cluster-health.timer" $NODE2_IP:/tmp/
scp $SSH_OPTS "systemd/corosync.service" $NODE2_IP:/tmp/
scp $SSH_OPTS "systemd/pacemaker.service" $NODE2_IP:/tmp/
scp $SSH_OPTS "systemd/sbd-fix-pidfile.conf" $NODE2_IP:/tmp/
scp $SSH_OPTS "systemd/sbd-defaults.conf" $NODE2_IP:/tmp/

ssh $SSH_OPTS $NODE2_IP '
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
  sudo mkdir -p /etc/systemd/system/sbd.service.d
  sudo mv /tmp/sbd-fix-pidfile.conf /etc/systemd/system/sbd.service.d/override.conf
  sudo mv /tmp/sbd-defaults.conf /etc/default/sbd
  sudo systemctl daemon-reload
  sudo systemctl enable --now stacd
  sudo systemctl enable --now nvme-cluster-health.timer
  echo "Node 2 deployment complete."
'
