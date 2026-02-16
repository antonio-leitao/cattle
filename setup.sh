#!/bin/bash
# =============================================================================
# setup.sh - Home Server Setup for Ubuntu Server 24.04 LTS
# =============================================================================
# Usage: curl -fsSL https://raw.githubusercontent.com/antonio-leitao/cattle/master/setup.sh | sudo bash
# =============================================================================

set -e

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Configuration ---
REPO_URL="https://github.com/antonio-leitao/cattle.git"
REPO_DIR="/home/${SUDO_USER:-$USER}/server"
DATA_DIR="/home/${SUDO_USER:-$USER}/docker_data"
ACTUAL_USER="${SUDO_USER:-$USER}"

# Make apt non-interactive
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# --- Helper Functions ---
log_info() {
    echo -e "${GREEN}>>>${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# --- Pre-flight Checks ---
if [ "$EUID" -ne 0 ]; then
    log_error "Please run with sudo: sudo bash setup.sh"
    exit 1
fi

if [ -z "$ACTUAL_USER" ] || [ "$ACTUAL_USER" = "root" ]; then
    log_error "Please run with sudo from a non-root user, not as root directly"
    exit 1
fi

echo "============================================"
echo "   Home Server Setup Script"
echo "   User: $ACTUAL_USER"
echo "============================================"
echo ""

# --- 1. Update System ---
log_info "1. Updating System Packages..."
apt-get update
apt-get upgrade -y $APT_OPTS

# --- 2. Install Essentials ---
log_info "2. Installing Essentials..."
apt-get install -y $APT_OPTS --no-install-recommends \
    curl git ca-certificates gnupg lsb-release openssh-server

# --- 3. Install Docker ---
log_info "3. Installing Docker..."

# Check if Docker is already installed
if command -v docker &> /dev/null; then
    log_warn "Docker already installed, skipping installation"
    docker --version
else
    # Remove any conflicting packages
    log_info "   Removing conflicting packages..."
    for pkg in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
        apt-get remove -y $pkg 2>/dev/null || true
    done

    # Add Docker's official GPG key
    log_info "   Adding Docker GPG key..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker repository
    log_info "   Adding Docker repository..."
    UBUNTU_CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    
    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $UBUNTU_CODENAME stable
EOF

    # Install Docker
    log_info "   Installing Docker packages..."
    apt-get update
    apt-get install -y $APT_OPTS \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    # Verify installation
    log_info "   Verifying Docker installation..."
    docker --version
    docker compose version
fi

# Add user to docker group
log_info "   Adding $ACTUAL_USER to docker group..."
usermod -aG docker "$ACTUAL_USER"

# --- 4. Free Port 53 for AdGuard ---
log_info "4. Freeing Port 53 for AdGuard..."

# Check if systemd-resolved is using port 53
if ss -tulpn | grep -q ':53 '; then
    log_info "   Port 53 is in use, configuring systemd-resolved..."
    
    # Create override directory
    mkdir -p /etc/systemd/resolved.conf.d
    
    # Disable DNS stub listener
    cat > /etc/systemd/resolved.conf.d/adguardhome.conf <<EOF
[Resolve]
DNSStubListener=no
EOF

    # Update resolv.conf to use external DNS temporarily
    # First, backup the original if it's a real file
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi
    
    # Create a new resolv.conf with fallback DNS
    cat > /etc/resolv.conf <<EOF
# Temporary DNS configuration for AdGuard Home setup
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    # Restart systemd-resolved
    systemctl restart systemd-resolved 2>/dev/null || true
    
    log_info "   Port 53 should now be free"
else
    log_info "   Port 53 is already free"
fi

# --- 5. Create Docker Network ---
log_info "5. Creating Docker Network..."
if docker network ls | grep -q proxy_net; then
    log_warn "Network proxy_net already exists"
else
    docker network create proxy_net
    log_info "   Created proxy_net network"
fi

# --- 6. Create Data Directories ---
log_info "6. Creating Data Directories..."
mkdir -p "$DATA_DIR/adguard/work"
mkdir -p "$DATA_DIR/adguard/conf"
mkdir -p "$DATA_DIR/immich"
mkdir -p "$DATA_DIR/postgres"
mkdir -p "$DATA_DIR/glance"

# Set ownership for user-accessible directories
chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$DATA_DIR/adguard"
chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$DATA_DIR/immich"
chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$DATA_DIR/glance"

# IMPORTANT: PostgreSQL container runs as UID 999 (postgres user)
# The postgres directory must be owned by this UID or it will fail with permission denied
chown -R 999:999 "$DATA_DIR/postgres"

log_info "   Created directories in $DATA_DIR"
log_info "   Note: postgres directory owned by UID 999 (container's postgres user)"

# --- 7. Clone Repository ---
log_info "7. Cloning Server Config..."
if [ -d "$REPO_DIR" ]; then
    log_warn "Repo already exists at $REPO_DIR, pulling latest..."
    cd "$REPO_DIR"
    sudo -u "$ACTUAL_USER" git pull || true
else
    sudo -u "$ACTUAL_USER" git clone "$REPO_URL" "$REPO_DIR"
    log_info "   Cloned to $REPO_DIR"
fi

# --- 8. Create .env file ---
log_info "8. Setting up .env file..."
ENV_FILE="$REPO_DIR/.env"
EXAMPLE_FILE="$REPO_DIR/.env.example"

if [ -f "$ENV_FILE" ]; then
    log_warn ".env already exists, not overwriting"
else
    if [ -f "$EXAMPLE_FILE" ]; then
        # Copy and customize .env
        cp "$EXAMPLE_FILE" "$ENV_FILE"
        
        # Replace ${USER} with actual username in paths
        sed -i "s|\${USER}|$ACTUAL_USER|g" "$ENV_FILE"
        
        # Generate random password
        RANDOM_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)
        sed -i "s|CHANGE_ME_use_strong_password|$RANDOM_PASS|g" "$ENV_FILE"
        
        chown "$ACTUAL_USER":"$ACTUAL_USER" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        
        log_info "   Created .env with random password"
    else
        log_error ".env.example not found in repository!"
    fi
fi

# --- 9. Make scripts executable ---
log_info "9. Making scripts executable..."
chmod +x "$REPO_DIR"/*.sh 2>/dev/null || true

# --- 10. Enable Docker to start on boot ---
log_info "10. Enabling Docker to start on boot..."
systemctl enable docker
systemctl enable containerd

echo ""
echo "============================================"
echo -e "   ${GREEN}Setup Complete!${NC}"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. REBOOT to apply Docker group permissions:"
echo "     ${YELLOW}sudo reboot${NC}"
echo ""
echo "  2. After reboot, navigate to server directory:"
echo "     ${YELLOW}cd $REPO_DIR${NC}"
echo ""
echo "  3. Review your .env file (password auto-generated):"
echo "     ${YELLOW}nano .env${NC}"
echo ""
echo "  4. Start all services:"
echo "     ${YELLOW}./update.sh${NC}"
echo ""
echo "  5. Configure AdGuard Home:"
echo "     Open ${YELLOW}http://YOUR_IP:3000${NC} in browser"
echo "     - Set admin interface to port 3000"
echo "     - Set DNS to port 53"
echo "     - Add DNS rewrite: *.${DOMAIN:-myserver.lan} -> YOUR_IP"
echo ""
echo "Your data directory: $DATA_DIR"
echo "============================================"
