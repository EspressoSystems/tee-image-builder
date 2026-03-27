#!/bin/bash

# Exit immediately if any command fails
set -e

# Setup Arbitrum directory
echo "Setting up Arbitrum db directory..."
mkdir -p /opt/nitro/arbitrum || { echo "Failed to create .arbitrum directory"; exit 1; }
sudo chown -R ec2-user:ec2-user /opt/nitro/arbitrum || { echo "Failed to set permissions for .arbitrum"; exit 1; }

# Setup config directory
echo "Setting up config directory..."
mkdir -p /opt/nitro/config || { echo "Failed to create config directory"; exit 1; }
sudo chown -R ec2-user:ec2-user /opt/nitro/config || { echo "Failed to set permissions for config"; exit 1; }

# Create systemd service for socat
echo "Creating systemd service for socat..."
sudo bash -c 'cat << EOF > /etc/systemd/system/socat-vsock.service
[Unit]
Description=socat VSOCK to TCP proxy
After=network.target nfs-server.service

[Service]
ExecStart=/usr/bin/socat -d -d VSOCK-LISTEN:8004,fork,keepalive TCP:127.0.0.1:2049,keepalive,retry=5,interval=10
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF' || { echo "Failed to create socat systemd service file"; exit 1; }

# Enable and start socat service
echo "Starting socat proxy..."
sudo systemctl enable socat-vsock.service || { echo "Failed to enable socat service"; exit 1; }
sudo systemctl start socat-vsock.service || { echo "Failed to start socat service"; exit 1; }

# Configure NFS exports
echo "/opt/nitro/arbitrum 127.0.0.1/32(rw,insecure,crossmnt,no_subtree_check,sync,all_squash,anonuid=1000,anongid=1000)" | sudo tee -a /etc/exports || { echo "Failed to configure NFS exports"; exit 1; }
echo "/opt/nitro/config 127.0.0.1/32(ro,insecure,crossmnt,no_subtree_check,sync,all_squash,anonuid=1000,anongid=1000)" | sudo tee -a /etc/exports || { echo "Failed to configure NFS exports"; exit 1; }
sudo exportfs -ra || { echo "Failed to reload NFS exports"; exit 1; }

# Enable and start NFS server
sudo systemctl enable nfs-server || { echo "Failed to enable NFS server"; exit 1; }
sudo systemctl start nfs-server || { echo "Failed to start NFS server"; exit 1; }

# Verify services
echo "Verifying services..."
sudo systemctl is-active --quiet nfs-server || { echo "ERROR: NFS server not running"; exit 1; }
pgrep -x socat >/dev/null || { echo "ERROR: socat process not found"; exit 1; }

sudo sed -i \
  -e '/^cpu_count:/s/:.*$/: 4/' \
  -e '/^memory_mib:/s/:.*$/: 8192/' \
  "/etc/nitro_enclaves/allocator.yaml"

sudo systemctl enable --now nitro-enclaves-allocator.service

echo "All services configured successfully!"