#!/usr/bin/env bash
# TEMPORARY: one-time migration from this repository's legacy AdGuard/Traefik stack.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOCK_FILE="/run/lock/immich-home.lock"
TEMP_DIR=""

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''
fi

info() { printf '%b>>>%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }

cleanup_temp() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && "$TEMP_DIR" == /tmp/immich-migrate.* ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

on_error() {
    local code=$?
    trap - ERR
    error "Migration stopped at line $1 (exit $code)."
    error "No library or PostgreSQL data directory was deleted. Do not create a new Immich administrator."
    cleanup_temp
    exit "$code"
}
trap 'on_error "$LINENO"' ERR
trap cleanup_temp EXIT

if [[ "${MIGRATE_SCRIPT_LIB_ONLY:-0}" != 1 ]]; then
    if (( $# != 0 )); then
        error "migrate.sh takes no arguments. Just run: ./migrate.sh"
        exit 2
    fi
    if [[ $EUID -ne 0 ]]; then
        exec sudo "$SCRIPT_DIR/migrate.sh"
    fi
    exec 9>"$LOCK_FILE"
    flock -n 9 || { error "Another Immich operation is running."; exit 1; }
fi

env_get() {
    local key=$1
    awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; found=1; exit} END {if (!found) exit 1}' "$ENV_FILE"
}

env_set() {
    local key=$1 value=$2 temp
    temp="$(mktemp "$SCRIPT_DIR/.env.XXXXXX")"
    awk -v wanted="$key" -v replacement="$key=$value" '
        BEGIN {replaced=0}
        $0 ~ "^" wanted "=" {if (!replaced) print replacement; replaced=1; next}
        {print}
        END {if (!replaced) print replacement}
    ' "$ENV_FILE" > "$temp"
    chmod 600 "$temp"
    chown --reference="$ENV_FILE" "$temp"
    mv -f "$temp" "$ENV_FILE"
}

container_ready() {
    local state health
    state="$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || true)"
    [[ "$state" == running && ( "$health" == healthy || "$health" == none ) ]]
}

wait_for_postgres() {
    local deadline=$((SECONDS + 300))
    while (( SECONDS < deadline )); do
        container_ready immich_postgres && { info "Legacy PostgreSQL recovered and healthy."; return 0; }
        sleep 3
    done
    docker logs --tail=100 immich_postgres 2>&1 || true
    error "PostgreSQL recovery did not become healthy."
    return 1
}

detect_immich_version() {
    local value
    value="$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' immich_server 2>/dev/null || true)"
    if [[ "$value" =~ ^v[0-9]+([.][0-9]+){2}$ ]]; then printf '%s\n' "$value"; return; fi
    value="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' immich_server 2>/dev/null | awk -F= '$1 == "IMMICH_BUILD_IMAGE" {print $2; exit}' || true)"
    [[ "$value" =~ ^v[0-9]+([.][0-9]+){2}$ ]] || { error "Could not identify the exact legacy Immich version."; return 1; }
    printf '%s\n' "$value"
}

table_count() {
    local table result
    for table in "$@"; do
        result="$(docker exec immich_postgres psql --username="$(env_get DB_USERNAME)" --dbname="$(env_get DB_DATABASE_NAME)" --tuples-only --no-align \
            --command="SELECT CASE WHEN to_regclass('public.$table') IS NULL THEN '' ELSE '$table' END;" 2>/dev/null || true)"
        if [[ "$result" == "$table" ]]; then
            docker exec immich_postgres psql --username="$(env_get DB_USERNAME)" --dbname="$(env_get DB_DATABASE_NAME)" --tuples-only --no-align \
                --command="SELECT count(*) FROM \"$table\";" 2>/dev/null || printf 'unknown'
            return
        fi
    done
    printf 'unknown'
}

create_migration_backup() {
    local upload backup_dir timestamp temp final
    upload="$(env_get UPLOAD_LOCATION)"
    backup_dir="$upload/backups"
    timestamp="$(date +%Y%m%d-%H%M%S)"
    final="$backup_dir/pre-migration-$timestamp.sql.gz"
    temp="$final.partial"
    mkdir -p "$backup_dir"
    info "Creating the pre-migration PostgreSQL backup..." >&2
    docker exec immich_postgres pg_dump --clean --if-exists --username="$(env_get DB_USERNAME)" --dbname="$(env_get DB_DATABASE_NAME)" | gzip -c > "$temp"
    gzip -t "$temp"
    [[ -s "$temp" ]]
    mv "$temp" "$final"
    chown "${SUDO_USER:-root}":"$(id -gn "${SUDO_USER:-root}")" "$final" 2>/dev/null || true
    printf '%s\n' "$final"
}

restore_normal_resolver() {
    local override=/etc/systemd/resolved.conf.d/adguardhome.conf timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    if [[ -f "$override" ]] && grep -q '^DNSStubListener=no$' "$override"; then
        mv "$override" "$override.disabled-$timestamp"
        info "Disabled the legacy systemd-resolved override; backup retained."
    fi
    if [[ ! -L /etc/resolv.conf ]] && grep -q 'Temporary DNS configuration for AdGuard Home setup' /etc/resolv.conf 2>/dev/null; then
        [[ -e /run/systemd/resolve/stub-resolv.conf ]] || { error "systemd-resolved stub file is unavailable; resolver cleanup stopped."; return 1; }
        mv /etc/resolv.conf "/etc/resolv.conf.adguard-backup-$timestamp"
        ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        info "Restored Ubuntu's normal /etc/resolv.conf symlink; backup retained."
    fi
    systemctl enable --now systemd-resolved
    systemctl restart systemd-resolved
}

main() {
    local answer project network_id network_name network attached db_image version backup env_backup schema_count asset_count user_count
    local new_schema_count new_asset_count new_user_count
    [[ "$(uname -s)" == Linux ]] || { error "Linux is required."; exit 1; }
    [[ -f "$ENV_FILE" ]] || { error "$ENV_FILE is missing."; exit 1; }
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { error "Docker is unavailable."; exit 1; }
    [[ -x "$SCRIPT_DIR/server.sh" && -x "$SCRIPT_DIR/diagnose.sh" ]] || { error "Permanent scripts are missing or not executable."; exit 1; }

    warn "This temporary tool will remove AdGuard and Traefik only after PostgreSQL is backed up and the new Immich stack is healthy."
    if docker inspect adguard >/dev/null 2>&1; then
        read -r -p "Router DNS is back to Automatic/default and normal browsing works? Type YES: " answer
        [[ "$answer" == YES ]] || { error "Stopped without changing containers."; exit 1; }
    fi

    df -Pk / | awk 'NR == 2 {exit !($4 >= 10 * 1024 * 1024)}' || { error "At least 10 GiB free on / is required."; exit 1; }
    version="$(detect_immich_version)"
    info "Preserving the installed Immich version: $version"

    if ! container_ready immich_postgres; then
        project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' immich_postgres 2>/dev/null || true)"
        [[ -n "$project" && "$project" != '<no value>' ]] || project=server
        network_id="$(docker network ls --filter "label=com.docker.compose.project=$project" --filter 'label=com.docker.compose.network=internal_net' --format '{{.ID}}' | head -1)"
        [[ -n "$network_id" ]] || { error "Could not find the current legacy internal Docker network."; exit 1; }
        network_name="$(docker network inspect -f '{{.Name}}' "$network_id")"
        db_image="$(docker inspect -f '{{.Config.Image}}' immich_postgres)"
        TEMP_DIR="$(mktemp -d /tmp/immich-migrate.XXXXXX)"
        cat > "$TEMP_DIR/recover.yml" <<'YAML'
services:
  database:
    container_name: immich_postgres
    image: ${MIGRATION_DB_IMAGE}
    pull_policy: never
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: "--data-checksums"
    volumes:
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    shm_size: 128mb
    restart: unless-stopped
    healthcheck:
      disable: false
networks:
  default:
    name: ${MIGRATION_NETWORK_NAME}
    external: true
YAML
        export MIGRATION_DB_IMAGE="$db_image" MIGRATION_NETWORK_NAME="$network_name"
        info "Recreating only the PostgreSQL container on $network_name without pulling images..."
        docker compose --project-name "$project" --env-file "$ENV_FILE" --file "$TEMP_DIR/recover.yml" \
            up -d --no-deps --force-recreate --pull never database
        wait_for_postgres
    else
        info "Legacy PostgreSQL is already healthy."
    fi

    schema_count="$(docker exec immich_postgres psql --username="$(env_get DB_USERNAME)" --dbname="$(env_get DB_DATABASE_NAME)" --tuples-only --no-align \
        --command="SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")"
    asset_count="$(table_count asset assets)"
    user_count="$(table_count user users)"
    (( schema_count > 0 )) || { error "The existing database has no public tables; refusing migration."; exit 1; }
    [[ "$asset_count" != unknown && "$user_count" != unknown ]] || { error "Could not locate the existing Immich asset/user tables."; exit 1; }
    info "Existing database verified: $schema_count public tables; assets: $asset_count; users: $user_count"
    backup="$(create_migration_backup)"
    info "Pre-migration backup verified: $backup"

    env_backup="$(getent passwd "${SUDO_USER:-root}" | awk -F: '{print $6}')/.immich-env-before-migration-$(date +%Y%m%d-%H%M%S)"
    cp -p "$ENV_FILE" "$env_backup"
    chmod 600 "$env_backup"
    chown "${SUDO_USER:-root}":"$(id -gn "${SUDO_USER:-root}")" "$env_backup" 2>/dev/null || true
    env_set IMMICH_VERSION "$version"
    info "Pinned .env to $version; private pre-migration copy: $env_backup"

    info "Handing off to the permanent one-command server manager..."
    flock -u 9
    "$SCRIPT_DIR/server.sh"
    flock -n 9 || { error "Could not reacquire the migration lock after server.sh."; exit 1; }

    for container in adguard traefik; do
        if docker inspect "$container" >/dev/null 2>&1; then
            docker rm -f "$container" >/dev/null
            info "Removed legacy $container container; its data was retained."
        fi
    done
    for network in proxy_net server_internal_net; do
        if docker network inspect "$network" >/dev/null 2>&1; then
            attached="$(docker network inspect -f '{{len .Containers}}' "$network")"
            if [[ "$attached" == 0 ]]; then
                docker network rm "$network" >/dev/null
                info "Removed unused legacy Docker network $network."
            else
                warn "Retained $network because $attached container(s) are still attached."
            fi
        fi
    done
    restore_normal_resolver

    curl -fsS --max-time 10 http://127.0.0.1:2283/api/server/version >/dev/null
    new_schema_count="$(docker exec immich_postgres psql --username="$(env_get DB_USERNAME)" --dbname="$(env_get DB_DATABASE_NAME)" --tuples-only --no-align \
        --command="SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")"
    new_asset_count="$(table_count asset assets)"
    new_user_count="$(table_count user users)"
    [[ "$new_schema_count" == "$schema_count" && "$new_asset_count" == "$asset_count" && "$new_user_count" == "$user_count" ]] || {
        error "Database counts changed unexpectedly (tables $schema_count->$new_schema_count, assets $asset_count->$new_asset_count, users $user_count->$new_user_count)."
        exit 1
    }

    printf '\nMigration succeeded. Database counts match and Immich answers at http://192.168.1.67:2283\n'
    printf 'Verified database backup: %s\n' "$backup"
    printf 'Now verify your existing account, albums, and several photos in the web/mobile app.\n'
    printf 'Keep migrate.sh until that manual verification is complete.\n\n'
    "$SCRIPT_DIR/diagnose.sh"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
