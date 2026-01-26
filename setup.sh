#!/bin/bash
# setup.sh
# Run as root or with sudo
# Usage: curl -fsSL https://raw.githubusercontent.com/antonio-leitao/cattle/master/setup.sh | sudo bash

set -e # Exit immediately if a command exits with a non-zero status

# --- Configuration ---
REPO_URL="https://github.com/antonio-leitao/cattle.git" 
REPO_DIR="/home/${SUDO_USER:-$USER}/server"
DATA_DIR="/home/${SUDO_USER:-$USER}/docker_data"

echo "============================================"
echo "   Home Server Setup Script"
echo "============================================"

echo ">>> 1. Updating System Packages..."
apt-get update && apt-get upgrade -y

echo ">>> 2. Installing Essentials..."
apt-get install -y curl git htop ncdu ufw openssh-server avahi-daemon ca-certificates

echo ">>> 3. Configuring Firewall..."
ufw allow ssh
ufw allow 80/tcp      # HTTP (Traefik)
ufw allow 443/tcp     # HTTPS (Traefik, for future use)
ufw allow 53/tcp      # DNS (AdGuard)
ufw allow 53/udp      # DNS (AdGuard)
ufw allow 3000/tcp    # AdGuard initial setup (can disable after)
echo "NOTE: Run 'sudo ufw enable' manually after verifying SSH works!"

echo ">>> 4. Installing Docker..."
# Remove old/conflicting packages that might interfere
apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc 2>/dev/null || true

# Check if Docker is already properly installed with compose
if docker compose version &> /dev/null; then
    echo "Docker with Compose plugin already installed."
else
    echo "Installing Docker from official repository..."
    
    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker's official repository
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    # Install Docker Engine + Compose plugin
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Add user to docker group
usermod -aG docker ${SUDO_USER:-$USER}

# Verify installation
echo "Docker version: $(docker --version)"
echo "Compose version: $(docker compose version)"

echo ">>> 5. Creating Data Directories..."
mkdir -p "$DATA_DIR/traefik"
mkdir -p "$DATA_DIR/adguard/work"
mkdir -p "$DATA_DIR/adguard/conf"
mkdir -p "$DATA_DIR/immich"
mkdir -p "$DATA_DIR/postgres"
chown -R ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} "$DATA_DIR"

echo ">>> 6. Freeing Port 53 for AdGuard..."
if [ -f /etc/systemd/resolved.conf ]; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf "[Resolve]\nDNSStubListener=no" > /etc/systemd/resolved.conf.d/adguardhome.conf
    rm -f /etc/resolv.conf
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    systemctl restart systemd-resolved
fi

echo ">>> 7. Creating Docker Network..."
docker network create proxy_net 2>/dev/null || echo "Network proxy_net already exists."

echo ">>> 8. Cloning Server Config..."
if [ ! -d "$REPO_DIR" ]; then
    sudo -u ${SUDO_USER:-$USER} git clone "$REPO_URL" "$REPO_DIR"
else
    echo "Repo already exists at $REPO_DIR"
fi

echo ">>> 9. Creating .env from template..."
ENV_FILE="$REPO_DIR/.env"
EXAMPLE_FILE="$REPO_DIR/.env.example"
if [ ! -f "$ENV_FILE" ] && [ -f "$EXAMPLE_FILE" ]; then
    cp "$EXAMPLE_FILE" "$ENV_FILE"
    chown ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} "$ENV_FILE"
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!  IMPORTANT: Edit $ENV_FILE"
    echo "!!  Change all passwords before starting!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
elif [ -f "$ENV_FILE" ]; then
    echo ".env already exists, skipping."
fi

echo "============================================"
echo "   Setup Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Reboot (or log out/in) to apply Docker group"
echo "  2. cd $REPO_DIR"
echo "  3. Edit .env and change ALL passwords"
echo "  4. Run: ./update.sh"
echo "  5. Access AdGuard at http://YOUR_IP:3000 for initial setup"
echo "  6. Configure DNS rewrites in AdGuard"
echo ""
echo "Your data will be stored in: $DATA_DIR"
echo "============================================"
