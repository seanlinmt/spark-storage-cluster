#!/bin/bash
set -e

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "Deploying to Node 1 (192.168.177.11)..."
scp $SSH_OPTS "systemd/Node 1/nvme-boot-node1.sh" 192.168.177.11:/tmp/
scp $SSH_OPTS "systemd/Node 1/nvme-cluster-init.service" 192.168.177.11:/tmp/
scp $SSH_OPTS "systemd/Node 1/stacd.conf" 192.168.177.11:/tmp/

ssh $SSH_OPTS 192.168.177.11 '
  sudo mv /tmp/nvme-boot-node1.sh /usr/local/bin/
  sudo chmod +x /usr/local/bin/nvme-boot-node1.sh
  sudo mv /tmp/nvme-cluster-init.service /etc/systemd/system/
  sudo mkdir -p /etc/stas
  sudo mv /tmp/stacd.conf /etc/stas/stacd.conf
  sudo chown root:root /etc/stas/stacd.conf
  sudo systemctl daemon-reload
  sudo systemctl enable --now stacd
  echo "Node 1 deployment complete."
'

echo "Deploying to Node 2 (192.168.177.12)..."
scp $SSH_OPTS "systemd/Node 2/nvme-boot-node2.sh" 192.168.177.12:/tmp/
scp $SSH_OPTS "systemd/Node 2/nvme-cluster-init.service" 192.168.177.12:/tmp/
scp $SSH_OPTS "systemd/Node 2/stacd.conf" 192.168.177.12:/tmp/

ssh $SSH_OPTS 192.168.177.12 '
  sudo mv /tmp/nvme-boot-node2.sh /usr/local/bin/
  sudo chmod +x /usr/local/bin/nvme-boot-node2.sh
  sudo mv /tmp/nvme-cluster-init.service /etc/systemd/system/
  sudo mkdir -p /etc/stas
  sudo mv /tmp/stacd.conf /etc/stas/stacd.conf
  sudo chown root:root /etc/stas/stacd.conf
  sudo systemctl daemon-reload
  sudo systemctl enable --now stacd
  echo "Node 2 deployment complete."
'
