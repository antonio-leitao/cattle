#!/bin/bash
# setup.sh
# Minimal home server setup for Ubuntu Server 24.04 LTS
# Usage: curl -fsSL https://raw.githubusercontent.com/antonio-leitao/cattle/master/setup.sh | sudo bash

set -e

# --- Configuration ---
REPO_URL="https://github.com/antonio-leitao/cattle.git"
REPO_DIR="/home/${SUDO_USER:-$USER}/server"
DATA_DIR="/home/${SUDO_USER:-$USER}/docker_data"

# Make apt non-interactive
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

echo "============================================"
echo "   Home Server Setup Script"
echo "============================================"

echo ">>> 1. Updating System Packages..."
apt-get update && apt-get upgrade -y $APT_OPTS

echo ">>> 2. Installing Essentials..."
apt-get install -y $APT_OPTS --no-install-recommends \
    curl git ca-certificates openssh-server

echo ">>> 3. Installing Docker..."
# Remove any conflicting packages (ignore errors if not installed)
apt-get remove -y $APT_OPTS \
    docker.io docker-compose docker-compose-v2 docker-doc \
    podman-docker containerd runc 2>/dev/null || true

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository
tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# Install Docker
apt-get update
apt-get install -y $APT_OPTS \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Add user to docker group
usermod -aG docker ${SUDO_USER:-$USER}

# Verify installation
echo "Docker version: $(docker --version)"
echo "Compose version: $(docker compose version)"

echo ">>> 4. Freeing Port 53 for AdGuard..."
if [ -f /etc/systemd/resolved.conf ]; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf "[Resolve]\nDNSStubListener=no\n" > /etc/systemd/resolved.conf.d/adguardhome.conf
    rm -f /etc/resolv.conf
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    systemctl restart systemd-resolved 2>/dev/null || true
fi

echo ">>> 5. Creating Docker Network..."
docker network create proxy_net 2>/dev/null || echo "Network proxy_net already exists."

echo ">>> 6. Creating Data Directories..."
mkdir -p "$DATA_DIR/traefik"
mkdir -p "$DATA_DIR/adguard/work"
mkdir -p "$DATA_DIR/adguard/conf"
mkdir -p "$DATA_DIR/immich"
mkdir -p "$DATA_DIR/postgres"
chown -R ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} "$DATA_DIR"

echo ">>> 7. Cloning Server Config..."
if [ ! -d "$REPO_DIR" ]; then
    sudo -u ${SUDO_USER:-$USER} git clone "$REPO_URL" "$REPO_DIR"
else
    echo "Repo already exists at $REPO_DIR"
fi

echo ">>> 8. Creating .env from template..."
ENV_FILE="$REPO_DIR/.env"
EXAMPLE_FILE="$REPO_DIR/.env.example"
if [ ! -f "$ENV_FILE" ] && [ -f "$EXAMPLE_FILE" ]; then
    cp "$EXAMPLE_FILE" "$ENV_FILE"
    chown ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} "$ENV_FILE"
    echo ""
    echo "!!! IMPORTANT: Edit $ENV_FILE and change all passwords !!!"
    echo ""
elif [ -f "$ENV_FILE" ]; then
    echo ".env already exists, skipping."
fi

echo "============================================"
echo "   Setup Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Reboot to apply Docker group: sudo reboot"
echo "  2. cd $REPO_DIR"
echo "  3. Edit .env: nano .env"
echo "  4. Start services: ./update.sh"
echo "  5. Configure AdGuard at http://YOUR_IP:3000"
echo ""
echo "Your data will be stored in: $DATA_DIR"
echo "============================================"
