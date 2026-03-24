#!/bin/bash
# =============================================================================
# status.sh - Home Server Status Dashboard
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Change to script directory
cd "$(dirname "$0")"

# Load .env
source .env 2>/dev/null || true
IP=$(hostname -I | awk '{print $1}')

# --- Helper Functions ---
status_icon() {
    local state="$1"
    if [[ "$state" == *"Up"* ]] || [[ "$state" == *"running"* ]]; then
        echo -e "${GREEN}●${NC}"
    else
        echo -e "${RED}●${NC}"
    fi
}

human_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1073741824}") GB"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}") MB"
    else
        echo "${bytes} B"
    fi
}

dir_size() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sb "$dir" 2>/dev/null | awk '{print $1}'
    else
        echo "0"
    fi
}

container_state() {
    docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "not found"
}

container_uptime() {
    local started
    started=$(docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null) || return
    local start_epoch=$(date -d "$started" +%s 2>/dev/null) || return
    local now_epoch=$(date +%s)
    local diff=$((now_epoch - start_epoch))
    local days=$((diff / 86400))
    local hours=$(( (diff % 86400) / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))
    if [ $days -gt 0 ]; then
        echo "${days}d ${hours}h"
    elif [ $hours -gt 0 ]; then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}

echo ""
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}   Home Server Status${NC}"
echo -e "${DIM}   ${IP} · $(date '+%Y-%m-%d %H:%M')${NC}"
echo -e "${BOLD}============================================${NC}"
echo ""

# --- Traefik ---
state=$(container_state traefik)
echo -e "$(status_icon "$state")  ${BOLD}Traefik${NC} ${DIM}(reverse proxy)${NC}"
echo -e "   State:     $state · up $(container_uptime traefik)"
echo -e "   Dashboard: ${CYAN}http://$IP:8080${NC}"
echo ""

# --- AdGuard ---
state=$(container_state adguard)
echo -e "$(status_icon "$state")  ${BOLD}AdGuard Home${NC} ${DIM}(DNS)${NC}"
echo -e "   State:     $state · up $(container_uptime adguard)"
echo -e "   Admin:     ${CYAN}http://$IP:3000${NC}"
if [ -d ~/docker_data/adguard ]; then
    size=$(human_size $(dir_size ~/docker_data/adguard))
    echo -e "   Data:      ~/docker_data/adguard ($size)"
fi
# Check if DNS is actually responding
if command -v nslookup &> /dev/null && [ -n "$DOMAIN" ]; then
    dns_result=$(nslookup "photos.$DOMAIN" "$IP" 2>/dev/null | grep -c "$IP") || true
    if [ "$dns_result" -gt 0 ] 2>/dev/null; then
        echo -e "   DNS:       ${GREEN}resolving *.${DOMAIN} → ${IP}${NC}"
    else
        echo -e "   DNS:       ${YELLOW}*.${DOMAIN} not resolving — check DNS rewrites${NC}"
    fi
fi
echo ""

# --- Immich ---
state=$(container_state immich_server)
ml_state=$(container_state immich_machine_learning)
redis_state=$(container_state immich_redis)
pg_state=$(container_state immich_postgres)

echo -e "$(status_icon "$state")  ${BOLD}Immich${NC} ${DIM}(photos)${NC}"
echo -e "   Server:    $state · up $(container_uptime immich_server)"
echo -e "   ML:        $ml_state · up $(container_uptime immich_machine_learning)"
echo -e "   Redis:     $redis_state"
echo -e "   Postgres:  $pg_state"
if [ -n "$DOMAIN" ]; then
    echo -e "   URL:       ${CYAN}http://photos.${DOMAIN}${NC}"
fi

# Photo storage
PHOTO_DIR="${UPLOAD_LOCATION:-$HOME/docker_data/immich}"
if [ -d "$PHOTO_DIR" ]; then
    size=$(human_size $(dir_size "$PHOTO_DIR"))
    echo -e "   Photos:    $PHOTO_DIR ($size)"
    # Count files
    photo_count=$(find "$PHOTO_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.raw' -o -iname '*.dng' -o -iname '*.cr2' -o -iname '*.nef' -o -iname '*.arw' \) 2>/dev/null | wc -l)
    video_count=$(find "$PHOTO_DIR" -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.mkv' -o -iname '*.webm' \) 2>/dev/null | wc -l)
    echo -e "   Library:   ${photo_count} photos, ${video_count} videos"
fi

# Database storage
DB_DIR="${DB_DATA_LOCATION:-$HOME/docker_data/postgres}"
if [ -d "$DB_DIR" ]; then
    size=$(human_size $(dir_size "$DB_DIR"))
    echo -e "   Database:  $DB_DIR ($size)"
fi
echo ""

# --- Disk Usage ---
echo -e "${BOLD}── Disk ──${NC}"
root_usage=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 " used)"}')
echo -e "   Root:      $root_usage"

# Check if photos are on a separate mount
if [ -n "$PHOTO_DIR" ] && [ "$(df "$PHOTO_DIR" | awk 'NR==2 {print $1}')" != "$(df / | awk 'NR==2 {print $1}')" ]; then
    photo_usage=$(df -h "$PHOTO_DIR" | awk 'NR==2 {print $3 " / " $2 " (" $5 " used)"}')
    echo -e "   Photos:    $photo_usage"
fi
echo ""

# --- Docker ---
echo -e "${BOLD}── Docker ──${NC}"
echo -e "   Images:    $(docker images -q | wc -l)"
echo -e "   Volumes:   $(docker volume ls -q | wc -l)"
dangling=$(docker images -f dangling=true -q | wc -l)
if [ "$dangling" -gt 0 ]; then
    echo -e "   Dangling:  ${YELLOW}${dangling} (run: docker image prune -f)${NC}"
fi
echo ""
echo -e "${BOLD}============================================${NC}"
echo ""
