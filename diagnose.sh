#!/usr/bin/env bash
# Permanent, read-only Immich diagnostic report.

set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/.runtime/docker-compose.yml"
failures=0
warnings=0

if (( $# != 0 )); then
    printf '[ERROR] diagnose.sh takes no arguments. Just run: ./diagnose.sh\n' >&2
    exit 2
fi

if [[ $EUID -ne 0 ]]; then
    exec sudo "$SCRIPT_DIR/diagnose.sh"
fi

ok() { printf '  [OK] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; failures=$((failures + 1)); }

env_get() {
    local key=$1
    [[ -f "$ENV_FILE" ]] || return 1
    awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$ENV_FILE"
}

container_ready() {
    local state health
    state="$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || true)"
    [[ "$state" == "running" && ( "$health" == "healthy" || "$health" == "none" ) ]]
}

server_ip() {
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit } }' || true)"
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    printf '%s\n' "${ip:-SERVER_IP}"
}

printf 'Immich diagnostic report — %s\n' "$(date -Is)"
printf 'Host: %s | Kernel: %s\n' "$(hostname)" "$(uname -r)"
printf '\n[service links]\n'
printf '  Immich: http://%s:2283\n' "$(server_ip)"
printf '  PostgreSQL, Valkey, and machine learning are internal only; they have no browser homepage.\n\n'

printf '[installation]\n'
if bash -n "$SCRIPT_DIR/server.sh"; then ok 'server.sh syntax'; else fail 'server.sh syntax'; fi
if [[ -f "$ENV_FILE" ]]; then
    ok '.env exists'
    printf '  Safe settings:\n'
    awk -F= '$1 ~ /^(UPLOAD_LOCATION|DB_DATA_LOCATION|TZ|IMMICH_VERSION|COMPOSE_PROJECT_NAME|ENABLE_MACHINE_LEARNING|IMMICH_.*_MEMORY_LIMIT)$/ {printf "    %s\n", $0}' "$ENV_FILE"
    if grep -q '^DB_PASSWORD=.' "$ENV_FILE"; then ok 'database password present and redacted'; else fail 'database password missing'; fi
else
    fail '.env missing'
fi
if [[ -f "$COMPOSE_FILE" ]]; then ok 'generated Compose file exists'; else fail 'generated Compose file missing; run server.sh'; fi
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then ok "Docker $(docker version --format '{{.Server.Version}}') available"; else fail 'Docker unavailable'; fi
if [[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]] && docker compose --env-file "$ENV_FILE" --file "$COMPOSE_FILE" config --quiet >/dev/null 2>&1; then
    ok 'Compose configuration valid'
else
    fail 'Compose configuration invalid or unavailable'
fi

printf '\n[host resources]\n'
free -h
df -hT /
df -ih /
root_use="$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
(( root_use < 85 )) && ok "root filesystem ${root_use}% used" || warn "root filesystem ${root_use}% used"
if journalctl -k --since '30 days ago' --no-pager 2>/dev/null | grep -Eqi 'out of memory|oom-kill|killed process'; then
    warn 'kernel OOM event found in the last 30 days'
else
    ok 'no kernel OOM event found in the last 30 days'
fi

printf '\n[containers]\n'
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
for container in immich_server immich_postgres immich_redis; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
        fail "$container missing"
        continue
    fi
    if container_ready "$container"; then ok "$container healthy"; else fail "$container unhealthy"; fi
done
if [[ "$(env_get ENABLE_MACHINE_LEARNING 2>/dev/null || true)" == true ]]; then
    if container_ready immich_machine_learning; then ok 'immich_machine_learning healthy'; else fail 'immich_machine_learning unhealthy'; fi
fi

printf '\n[containment]\n'
for container in immich_server immich_postgres immich_redis immich_machine_learning; do
    docker inspect "$container" >/dev/null 2>&1 || continue
    line="$(docker inspect -f '{{.Name}} memory={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}} pids={{.HostConfig.PidsLimit}} log={{.HostConfig.LogConfig.Type}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}' "$container")"
    printf '  %s\n' "$line"
    memory="$(docker inspect -f '{{.HostConfig.Memory}}' "$container")"
    log_driver="$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$container")"
    (( memory > 0 )) || warn "$container has no memory limit"
    [[ "$log_driver" == local ]] || warn "$container is not using rotated local logs"
done
docker stats --no-stream --format '  {{.Name}}: {{.MemUsage}}, CPU {{.CPUPerc}}, PIDs {{.PIDs}}' 2>/dev/null || true

printf '\n[data and backups]\n'
for key in UPLOAD_LOCATION DB_DATA_LOCATION; do
    path="$(env_get "$key" 2>/dev/null || true)"
    if [[ -n "$path" && -d "$path" ]]; then ok "$key exists: $path"; else fail "$key unavailable: ${path:-unset}"; fi
done
upload="$(env_get UPLOAD_LOCATION 2>/dev/null || true)"
latest=""
if [[ -n "$upload" && -d "$upload/backups" ]]; then
    latest="$(find "$upload/backups" -maxdepth 1 -type f -name 'immich-db-*.sql.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR == 1 {sub(/^[^ ]+ /, ""); print}')"
fi
[[ -n "$latest" ]] && ok "latest verified backup: $latest" || warn 'no managed database backup found'

printf '\n[network]\n'
version="$(curl -fsS --max-time 5 http://127.0.0.1:2283/api/server/version 2>/dev/null || true)"
if [[ -n "$version" ]]; then ok "Immich API responds on port 2283: $version"; else fail 'Immich API unavailable on port 2283'; fi

if (( failures > 0 )); then
    printf '\nRESULT: %d failure(s), %d warning(s).\n' "$failures" "$warnings"
    printf '\nRecent logs from unhealthy core services:\n'
    for container in immich_postgres immich_redis immich_server; do
        container_ready "$container" && continue
        printf '\n--- %s ---\n' "$container"
        docker logs --tail=60 "$container" 2>&1 | sed -E 's/(password|secret|token|key)=([^[:space:]]+)/\1=<redacted>/Ig' || true
    done
    exit 1
fi

printf '\nRESULT: healthy with %d warning(s).\n' "$warnings"
