#!/bin/bash
# =============================================================================
# update.sh - Pull latest changes and restart all services
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}>>>${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Change to script directory
cd "$(dirname "$0")"

# Check if .env exists
if [ ! -f .env ]; then
    log_error ".env file not found!"
    log_info "Create it with: cp .env.example .env && nano .env"
    exit 1
fi

# Check if docker is available
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    exit 1
fi

# Check if user can run docker
if ! docker ps &> /dev/null; then
    log_error "Cannot connect to Docker. Did you reboot after setup?"
    log_info "Try: sudo reboot"
    exit 1
fi

# Check if proxy_net exists
if ! docker network ls | grep -q proxy_net; then
    log_warn "Creating proxy_net network..."
    docker network create proxy_net
fi

log_info "Pulling latest changes from Git..."
git pull 2>/dev/null || log_warn "Git pull failed (maybe not a git repo)"

log_info "Pulling latest Docker images..."
docker compose pull

log_info "Deploying stack..."
docker compose up -d --remove-orphans

log_info "Waiting for services to start..."
sleep 5

log_info "Cleaning up old images..."
docker image prune -f

echo ""
echo "============================================"
echo -e "   ${GREEN}Deployment Complete!${NC}"
echo "============================================"
echo ""

# Show container status
log_info "Container Status:"
docker compose ps

echo ""
echo "Useful commands:"
echo "  View logs:     docker compose logs -f"
echo "  View status:   docker compose ps"
echo "  Stop all:      docker compose down"
echo "  Restart:       docker compose restart"
echo ""

# Load DOMAIN from .env for helpful URLs
source .env 2>/dev/null || true
IP=$(hostname -I | awk '{print $1}')

echo "Access your services:"
echo "  Traefik Dashboard: http://$IP:8080"
echo "  AdGuard Setup:     http://$IP:3000"
if [ -n "$DOMAIN" ]; then
    echo "  Immich:            http://images.$DOMAIN (after DNS setup)"
fi
echo "============================================"
