#!/bin/bash
# setup.sh - Minimal home server setup
# Usage: curl -fsSL https://raw.githubusercontent.com/antonio-leitao/cattle/master/setup.sh | sudo bash

set -e

REPO_URL="https://github.com/antonio-leitao/cattle.git"
REPO_DIR="/home/${SUDO_USER:-$USER}/server"
DATA_DIR="/home/${SUDO_USER:-$USER}/docker_data"

export DEBIAN_FRONTEND=noninteractive

echo "============================================"
echo "   Home Server Setup Script (Minimal)"
echo "============================================"

echo ">>> 1. Updating System..."
apt-get update && apt-get upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold

echo ">>> 2. Installing Essentials..."
# Only truly essential packages - no htop/ncdu (install later if needed)
apt-get install -y --no-install-recommends curl git ca-certificates openssh-server

echo ">>> 3. Installing Docker..."
# Remove any old/conflicting packages
apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc 2>/dev/null || true

# Check if Docker is already installed
if docker compose version &> /dev/null; then
    echo "Docker already installed."
else
    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker repository (deb822 format - official method)
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update
    apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Add user to docker group
usermod -aG docker ${SUDO_USER:-$USER}

echo ">>> 4. Freeing Port 53 for AdGuard..."
if [ -f /etc/systemd/resolved.conf ]; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf "[Resolve]\nDNSStubListener=no" > /etc/systemd/resolved.conf.d/adguardhome.conf
    rm -f /etc/resolv.conf
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    systemctl restart systemd-resolved 2>/dev/null || true
fi

echo ">>> 5. Creating Docker Network & Directories..."
docker network create proxy_net 2>/dev/null || true

mkdir -p "$DATA_DIR"/{traefik,adguard/{work,conf},immich,postgres}
chown -R ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} "$DATA_DIR"

echo ">>> 6. Cloning Server Config..."
if [ ! -d "$REPO_DIR" ]; then
    sudo -u ${SUDO_USER:-$USER} git clone "$REPO_URL" "$REPO_DIR"
fi

echo ">>> 7. Creating .env from template..."
if [ ! -f "$REPO_DIR/.env" ] && [ -f "$REPO_DIR/.env.example" ]; then
    cp "$REPO_DIR/.env.example" "$REPO_DIR/.env"
    chown ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} "$REPO_DIR/.env"
    echo ""
    echo "⚠️  IMPORTANT: Edit $REPO_DIR/.env and change all passwords!"
    echo ""
fi

echo "============================================"
echo "   Setup Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Log out and back in (for docker group)"
echo "  2. cd $REPO_DIR"
echo "  3. Edit .env and change ALL passwords"
echo "  4. Run: ./update.sh"
echo "  5. Access AdGuard at http://YOUR_IP:3000"
echo "============================================"
