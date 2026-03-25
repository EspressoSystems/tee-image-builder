#!/bin/bash

# Exit immediately on error and show commands
set -ex

# Update system packages
echo "Updating system packages..."
sudo yum update -y || { echo "ERROR: Failed to update packages"; exit 1; }

# Install Docker
echo "Installing docker..."
sudo yum install -y docker || { echo "ERROR: Failed to install docker"; exit 1; }
sudo systemctl enable docker || { echo "ERROR: Failed to enable docker"; exit 1; }
sudo systemctl start docker || { echo "ERROR: Failed to start docker"; exit 1; }
sudo usermod -aG docker ec2-user || echo "WARNING: Failed to add user to docker group"

# Download docker compose to bin
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose

# Give execute permission
sudo chmod +x /usr/local/bin/docker-compose

# Install enclaver
echo "Downloading and installing Enclaver..."
ARCH=$(uname -m)
LATEST_RELEASE=$(curl -s https://api.github.com/repositories/516492075/releases/latest)
DOWNLOAD_URL=$(echo "$LATEST_RELEASE" | jq -r ".assets[] | select(.name | test(\"^enclaver-linux-$ARCH.*tar.gz$\")) | .browser_download_url")
    
if [ -z "$DOWNLOAD_URL" ]; then
    echo "Could not find Enclaver download URL"
    exit 1
fi
    
curl -L "$DOWNLOAD_URL" -o enclaver.tar.gz
tar xzf enclaver.tar.gz
sudo install enclaver-*/enclaver /usr/bin/
rm -rf enclaver.tar.gz enclaver-*
enclaver --version

# Install nitro-cli
echo "Installing aws-nitro-enclaves-cli..."
sudo dnf install -y aws-nitro-enclaves-cli || { echo "ERROR: Failed to install nitro-cli"; exit 1; }

# Install dev tools
echo "Installing development tools..."
sudo dnf install -y aws-nitro-enclaves-cli-devel || { echo "ERROR: Failed to install nitro-cli-devel"; exit 1; }

# Add user to ne group
sudo usermod -aG ne ec2-user || echo "WARNING: Failed to add user to ne group"

# Install socat
echo "Installing socat..."
sudo yum install -y socat || { echo "ERROR: Failed to install socat"; exit 1; }
socat -V || { echo "ERROR: socat verification failed"; exit 1; }

# Install NFS
echo "Installing NFS..."
sudo yum install -y nfs-utils || { echo "ERROR: Failed to install nfs-utils"; exit 1; }

echo "All installations completed successfully!"