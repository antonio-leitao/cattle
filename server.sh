#!/usr/bin/env bash
# Minimal, idempotent Immich home-server manager for Ubuntu.
# The Docker Compose definition is embedded below so this is the only
# operational file that needs to be audited and kept up to date.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/.runtime"
ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$RUNTIME_DIR/docker-compose.yml"
LOCK_FILE="/run/lock/immich-home.lock"

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    NC=''
fi

log_info() { printf '%b>>>%b %s\n' "$GREEN" "$NC" "$*"; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }

on_error() {
    local exit_code=$?
    log_error "Command failed at line $1 (exit $exit_code)."
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

usage() {
    cat <<'EOF'
Usage: ./server.sh COMMAND

Commands:
  install       Install/repair Docker and converge the Immich stack
  status        Show container health, resource use, disk space, and URL
  doctor        Validate the installation without changing it
  check-update  Download newer images if available, but do not deploy them
  update        Back up the database, pull images, deploy, and verify health
  backup        Create a PostgreSQL dump in the Immich backups directory
  start         Start/reconcile the stack without pulling newer images
  stop          Gracefully stop the Immich containers
  restart       Recreate/restart the stack and verify health
  logs [service] Follow logs (default: immich-server)
  version       Show this script's version

Mutating commands should be run with sudo. Status, doctor, check-update, and
logs can run without sudo after the user's Docker group membership is active.
EOF
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This command changes the server. Run: sudo ./server.sh $1"
        exit 1
    fi
}

require_linux() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        log_error "This manager supports Linux servers only."
        exit 1
    fi
}

require_supported_ubuntu() {
    local architecture
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        log_error "Automatic installation supports Ubuntu Server only."
        exit 1
    fi
    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        log_warn "This manager is tested on Ubuntu 24.04 LTS; detected ${VERSION_ID:-unknown}."
    fi

    architecture="$(uname -m)"
    case "$architecture" in
        x86_64|aarch64|arm64) ;;
        *)
            log_error "Unsupported CPU architecture: $architecture"
            exit 1
            ;;
    esac
}

actual_user() {
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
    else
        id -un
    fi
}

user_home() {
    local user=$1
    getent passwd "$user" | awk -F: 'NR == 1 { print $6 }'
}

env_get() {
    local key=$1
    [[ -f "$ENV_FILE" ]] || return 1
    awk -F= -v wanted="$key" '
        $1 == wanted {
            sub(/^[^=]*=/, "")
            print
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$ENV_FILE"
}

env_set() {
    local key=$1 value=$2 temp
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || return 1
    [[ "$value" != *$'\n'* ]] || return 1
    temp="$(mktemp "$RUNTIME_DIR/env.XXXXXX")"
    awk -v wanted="$key" -v replacement="$key=$value" '
        BEGIN { replaced = 0 }
        $0 ~ "^" wanted "=" {
            if (!replaced) print replacement
            replaced = 1
            next
        }
        { print }
        END { if (!replaced) print replacement }
    ' "$ENV_FILE" > "$temp"
    chmod 600 "$temp"
    mv -f "$temp" "$ENV_FILE"
}

memory_mebibytes() {
    awk '/^MemTotal:/ { printf "%d\n", $2 / 1024 }' /proc/meminfo
}

default_project_name() {
    local existing_project
    existing_project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' immich_server 2>/dev/null || true)"
    if [[ -n "$existing_project" && "$existing_project" != "<no value>" ]]; then
        printf '%s\n' "$existing_project"
    else
        printf '%s\n' "immich"
    fi
}

running_immich_major() {
    local value api

    value="$(docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' immich_server 2>/dev/null || true)"
    if [[ "$value" =~ ^v?([0-9]+)[.] ]]; then
        printf 'v%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    value="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' immich_server 2>/dev/null \
        | awk -F= '$1 == "IMMICH_BUILD_IMAGE" || $1 == "IMMICH_SOURCE_REF" { print $2; exit }' || true)"
    if [[ "$value" =~ ^v?([0-9]+)[.] ]]; then
        printf 'v%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    api="$(curl -fsS --max-time 5 http://127.0.0.1:2283/api/server/version 2>/dev/null || true)"
    value="$(printf '%s\n' "$api" | sed -n 's/.*"major"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf 'v%s\n' "$value"
        return 0
    fi

    return 1
}

preserve_running_immich_major() {
    local major server_image ml_image
    major="$(running_immich_major || true)"
    if [[ ! "$major" =~ ^v[0-9]+$ ]]; then
        log_error "Could not identify the version of the existing Immich container."
        log_error "Set IMMICH_VERSION in $ENV_FILE to its current major (for example v2), then rerun install."
        return 1
    fi

    server_image="$(docker inspect -f '{{.Image}}' immich_server)"
    docker image tag "$server_image" "ghcr.io/immich-app/immich-server:$major"

    if docker inspect immich_machine_learning >/dev/null 2>&1; then
        ml_image="$(docker inspect -f '{{.Image}}' immich_machine_learning)"
        docker image tag "$ml_image" "ghcr.io/immich-app/immich-machine-learning:$major"
    fi

    env_set IMMICH_VERSION "$major"
    log_warn "Pinned the existing Immich installation to $major; migration will not silently upgrade it."
}

resource_defaults() {
    local total_mb=$1
    if (( total_mb < 6144 )); then
        DEFAULT_ML_ENABLED=false
        DEFAULT_SERVER_MEMORY=1280m
        DEFAULT_ML_MEMORY=1024m
        DEFAULT_DB_MEMORY=1536m
        DEFAULT_REDIS_MEMORY=128m
    elif (( total_mb < 8192 )); then
        DEFAULT_ML_ENABLED=false
        DEFAULT_SERVER_MEMORY=2048m
        DEFAULT_ML_MEMORY=1024m
        DEFAULT_DB_MEMORY=2048m
        DEFAULT_REDIS_MEMORY=128m
    elif (( total_mb < 12288 )); then
        DEFAULT_ML_ENABLED=true
        DEFAULT_SERVER_MEMORY=2560m
        DEFAULT_ML_MEMORY=1536m
        DEFAULT_DB_MEMORY=2048m
        DEFAULT_REDIS_MEMORY=256m
    else
        DEFAULT_ML_ENABLED=true
        DEFAULT_SERVER_MEMORY=4096m
        DEFAULT_ML_MEMORY=2048m
        DEFAULT_DB_MEMORY=3072m
        DEFAULT_REDIS_MEMORY=256m
    fi
}

write_new_env() {
    local user=$1 home=$2 total_mb=$3 password project group
    group="$(id -gn "$user")"
    password="$(openssl rand -hex 24)"
    project="$(default_project_name)"
    resource_defaults "$total_mb"

    cat > "$ENV_FILE" <<EOF
# Generated by server.sh. Keep this file private and backed up.
UPLOAD_LOCATION=$home/docker_data/immich
DB_DATA_LOCATION=$home/docker_data/postgres
TZ=Europe/Rome
IMMICH_VERSION=v3
DB_PASSWORD=$password
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
COMPOSE_PROJECT_NAME=$project
ENABLE_MACHINE_LEARNING=$DEFAULT_ML_ENABLED
IMMICH_SERVER_MEMORY_LIMIT=$DEFAULT_SERVER_MEMORY
IMMICH_ML_MEMORY_LIMIT=$DEFAULT_ML_MEMORY
IMMICH_DB_MEMORY_LIMIT=$DEFAULT_DB_MEMORY
IMMICH_REDIS_MEMORY_LIMIT=$DEFAULT_REDIS_MEMORY
EOF

    chmod 600 "$ENV_FILE"
    chown "$user":"$group" "$ENV_FILE"
    log_info "Created $ENV_FILE with a random database password."
}

ensure_env_key() {
    local key=$1 value=$2
    if ! env_get "$key" >/dev/null; then
        env_set "$key" "$value"
    fi
}

prepare_env() {
    local user=$1 home=$2 total_mb=$3 current_version group
    group="$(id -gn "$user")"
    mkdir -p "$RUNTIME_DIR"

    if [[ ! -f "$ENV_FILE" ]]; then
        write_new_env "$user" "$home" "$total_mb"
    else
        chmod 600 "$ENV_FILE"
        if [[ $EUID -eq 0 ]]; then
            chown "$user":"$group" "$ENV_FILE"
        fi

        ensure_env_key UPLOAD_LOCATION "$home/docker_data/immich"
        ensure_env_key DB_DATA_LOCATION "$home/docker_data/postgres"
        ensure_env_key TZ "Europe/Rome"
        ensure_env_key IMMICH_VERSION "v3"
        ensure_env_key DB_USERNAME "postgres"
        ensure_env_key DB_DATABASE_NAME "immich"
        ensure_env_key COMPOSE_PROJECT_NAME "$(default_project_name)"

        if ! env_get DB_PASSWORD >/dev/null; then
            env_set DB_PASSWORD "$(openssl rand -hex 24)"
        fi

        current_version="$(env_get IMMICH_VERSION)"
        if [[ "$current_version" == "release" ]]; then
            if docker inspect immich_server >/dev/null 2>&1; then
                preserve_running_immich_major
            else
                env_set IMMICH_VERSION "v3"
                log_warn "Changed IMMICH_VERSION from the moving 'release' tag to supported major 'v3'."
            fi
        elif [[ ! "$current_version" =~ ^v?[0-9]+([.][0-9]+){0,2}$ ]]; then
            log_error "Unsupported IMMICH_VERSION value: $current_version"
            exit 1
        fi

        resource_defaults "$total_mb"
        ensure_env_key ENABLE_MACHINE_LEARNING "$DEFAULT_ML_ENABLED"
        ensure_env_key IMMICH_SERVER_MEMORY_LIMIT "$DEFAULT_SERVER_MEMORY"
        ensure_env_key IMMICH_ML_MEMORY_LIMIT "$DEFAULT_ML_MEMORY"
        ensure_env_key IMMICH_DB_MEMORY_LIMIT "$DEFAULT_DB_MEMORY"
        ensure_env_key IMMICH_REDIS_MEMORY_LIMIT "$DEFAULT_REDIS_MEMORY"
    fi

    chmod 600 "$ENV_FILE"
    if [[ $EUID -eq 0 ]]; then
        chown "$user":"$group" "$ENV_FILE"
    fi
}

validate_env() {
    local key value
    for key in UPLOAD_LOCATION DB_DATA_LOCATION IMMICH_VERSION DB_PASSWORD DB_USERNAME DB_DATABASE_NAME COMPOSE_PROJECT_NAME ENABLE_MACHINE_LEARNING IMMICH_SERVER_MEMORY_LIMIT IMMICH_ML_MEMORY_LIMIT IMMICH_DB_MEMORY_LIMIT IMMICH_REDIS_MEMORY_LIMIT; do
        value="$(env_get "$key" || true)"
        if [[ -z "$value" ]]; then
            log_error "Missing required setting $key in $ENV_FILE"
            return 1
        fi
    done

    [[ "$(env_get UPLOAD_LOCATION)" == /* ]] || { log_error "UPLOAD_LOCATION must be an absolute path."; return 1; }
    [[ "$(env_get DB_DATA_LOCATION)" == /* ]] || { log_error "DB_DATA_LOCATION must be an absolute path."; return 1; }
    [[ "$(env_get IMMICH_VERSION)" =~ ^v?[0-9]+([.][0-9]+){0,2}$ ]] || { log_error "IMMICH_VERSION must be a major or exact stable version."; return 1; }
    [[ "$(env_get DB_PASSWORD)" =~ ^[A-Za-z0-9]+$ ]] || { log_error "DB_PASSWORD may contain only A-Za-z0-9."; return 1; }
    [[ "$(env_get DB_USERNAME)" =~ ^[A-Za-z0-9_]+$ ]] || { log_error "DB_USERNAME contains unsupported characters."; return 1; }
    [[ "$(env_get DB_DATABASE_NAME)" =~ ^[A-Za-z0-9_]+$ ]] || { log_error "DB_DATABASE_NAME contains unsupported characters."; return 1; }
    [[ "$(env_get COMPOSE_PROJECT_NAME)" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { log_error "COMPOSE_PROJECT_NAME contains unsupported characters."; return 1; }
    [[ "$(env_get ENABLE_MACHINE_LEARNING)" =~ ^(true|false)$ ]] || { log_error "ENABLE_MACHINE_LEARNING must be true or false."; return 1; }

    for key in IMMICH_SERVER_MEMORY_LIMIT IMMICH_ML_MEMORY_LIMIT IMMICH_DB_MEMORY_LIMIT IMMICH_REDIS_MEMORY_LIMIT; do
        [[ "$(env_get "$key")" =~ ^[1-9][0-9]*(m|g)$ ]] || { log_error "$key must use a value such as 1536m or 2g."; return 1; }
    done

    if [[ "$(env_get UPLOAD_LOCATION)" == "$(env_get DB_DATA_LOCATION)" ]]; then
        log_error "UPLOAD_LOCATION and DB_DATA_LOCATION must be different directories."
        return 1
    fi
}

render_compose() {
    local temp
    mkdir -p "$RUNTIME_DIR"
    temp="$(mktemp "$RUNTIME_DIR/compose.XXXXXX")"
    cat > "$temp" <<'YAML'
# Generated by server.sh. Edit server.sh, not this file.
x-logging: &default-logging
  driver: local
  options:
    max-size: "10m"
    max-file: "3"

services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION}
    pull_policy: missing
    volumes:
      - ${UPLOAD_LOCATION}:/data
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - ../.env
    ports:
      - "2283:2283"
    depends_on:
      redis:
        condition: service_healthy
      database:
        condition: service_healthy
    restart: unless-stopped
    stop_grace_period: 2m
    healthcheck:
      disable: false
    mem_limit: ${IMMICH_SERVER_MEMORY_LIMIT}
    memswap_limit: ${IMMICH_SERVER_MEMORY_LIMIT}
    pids_limit: 512
    logging: *default-logging

  immich-machine-learning:
    profiles: ["ml"]
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION}
    pull_policy: missing
    volumes:
      - model-cache:/cache
    env_file:
      - ../.env
    restart: unless-stopped
    stop_grace_period: 1m
    healthcheck:
      disable: false
    mem_limit: ${IMMICH_ML_MEMORY_LIMIT}
    memswap_limit: ${IMMICH_ML_MEMORY_LIMIT}
    pids_limit: 256
    logging: *default-logging

  redis:
    container_name: immich_redis
    image: docker.io/valkey/valkey:9@sha256:8e8d64b405ce18f41b8e5ee20aa4687a8ed0022d1298f2ce31cdcf3a76e09411
    pull_policy: missing
    command: valkey-server --loglevel warning
    healthcheck:
      test: valkey-cli ping || exit 1
    restart: unless-stopped
    mem_limit: ${IMMICH_REDIS_MEMORY_LIMIT}
    memswap_limit: ${IMMICH_REDIS_MEMORY_LIMIT}
    pids_limit: 128
    logging: *default-logging

  database:
    container_name: immich_postgres
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23
    pull_policy: missing
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: "--data-checksums"
    volumes:
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    shm_size: 128mb
    restart: unless-stopped
    stop_grace_period: 2m
    healthcheck:
      disable: false
    mem_limit: ${IMMICH_DB_MEMORY_LIMIT}
    memswap_limit: ${IMMICH_DB_MEMORY_LIMIT}
    pids_limit: 256
    logging: *default-logging

volumes:
  model-cache:
YAML
    chmod 600 "$temp"
    mv -f "$temp" "$COMPOSE_FILE"
}

machine_learning_enabled() {
    [[ "$(env_get ENABLE_MACHINE_LEARNING 2>/dev/null || true)" == "true" ]]
}

compose() {
    local project
    project="$(env_get COMPOSE_PROJECT_NAME)"
    if machine_learning_enabled; then
        docker compose --project-name "$project" --env-file "$ENV_FILE" --file "$COMPOSE_FILE" --profile ml "$@"
    else
        docker compose --project-name "$project" --env-file "$ENV_FILE" --file "$COMPOSE_FILE" "$@"
    fi
}

install_docker() {
    local missing_dependencies=()
    command -v curl >/dev/null 2>&1 || missing_dependencies+=(curl)
    command -v openssl >/dev/null 2>&1 || missing_dependencies+=(openssl)
    if (( ${#missing_dependencies[@]} > 0 )); then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates "${missing_dependencies[@]}"
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log_info "Docker Engine and the Compose plugin are already installed."
        systemctl enable --now docker
        return
    fi

    log_info "Installing Docker Engine from Docker's official Ubuntu repository..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl

    for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed'; then
            apt-get remove -y "$package"
        fi
    done

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        log_error "Automatic Docker installation supports Ubuntu only."
        exit 1
    fi
    local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    if [[ -z "$codename" ]]; then
        log_error "Could not determine the Ubuntu codename."
        exit 1
    fi

    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
        "$(dpkg --print-architecture)" "$codename" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    docker compose version
}

ensure_docker_access() {
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed. Run: sudo ./server.sh install"
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        log_error "The Docker Compose plugin is missing. Run: sudo ./server.sh install"
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        log_error "Cannot access Docker. Use sudo or sign out and back in after installation."
        exit 1
    fi
}

prepare_data_directories() {
    local user=$1 upload db group
    group="$(id -gn "$user")"
    upload="$(env_get UPLOAD_LOCATION)"
    db="$(env_get DB_DATA_LOCATION)"

    if [[ ! -d "$upload" ]]; then
        mkdir -p "$upload"
        chown "$user":"$group" "$upload"
        chmod 750 "$upload"
    fi

    if [[ ! -d "$db" ]]; then
        mkdir -p "$db"
        chown 999:999 "$db"
        chmod 700 "$db"
    fi
}

available_kib() {
    df -Pk "$1" | awk 'NR == 2 { print $4 }'
}

check_free_space() {
    local minimum_gib=$1 path=$2 available required
    available="$(available_kib "$path")"
    required=$((minimum_gib * 1024 * 1024))
    if (( available < required )); then
        log_error "$path has less than ${minimum_gib} GiB free. Free space before continuing."
        return 1
    fi
}

docker_root_directory() {
    docker info --format '{{.DockerRootDir}}' 2>/dev/null || printf '%s\n' /var/lib/docker
}

cleanup_legacy_dns() {
    local override=/etc/systemd/resolved.conf.d/adguardhome.conf timestamp restart_resolved=false
    timestamp="$(date +%Y%m%d-%H%M%S)"

    if [[ -f "$override" ]] && grep -q '^DNSStubListener=no$' "$override"; then
        mv "$override" "$override.disabled-$timestamp"
        restart_resolved=true
        log_info "Disabled the legacy AdGuard systemd-resolved override (backup retained)."
    fi

    if [[ ! -L /etc/resolv.conf ]] && grep -q 'Temporary DNS configuration for AdGuard Home setup' /etc/resolv.conf 2>/dev/null; then
        mv /etc/resolv.conf "/etc/resolv.conf.adguard-backup-$timestamp"
        ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl enable --now systemd-resolved
        restart_resolved=true
        log_info "Restored Ubuntu's normal system resolver; the old file was backed up."
    fi

    if [[ "$restart_resolved" == true ]]; then
        systemctl restart systemd-resolved
    fi
}

remove_legacy_containers() {
    local container
    for container in traefik adguard; do
        if docker inspect "$container" >/dev/null 2>&1; then
            docker rm -f "$container" >/dev/null
            log_info "Removed legacy $container container; its data directory was retained."
        fi
    done
}

confirm_router_dns_reset() {
    local answer
    if ! docker inspect adguard >/dev/null 2>&1; then
        return 0
    fi

    if [[ "${CONFIRM_ROUTER_DNS_RESET:-}" == "1" ]]; then
        return 0
    fi

    log_warn "The legacy AdGuard container is still running."
    log_warn "Before it is removed, restore the router/DHCP DNS setting to Automatic or the router's normal DNS."
    log_warn "Reconnect household devices and verify normal browsing first."

    if [[ -t 0 ]]; then
        read -r -p "Router DNS is restored and verified? Type YES to continue: " answer
        if [[ "$answer" == "YES" ]]; then
            return 0
        fi
    fi

    log_error "Migration stopped safely; AdGuard was not removed."
    log_error "For a non-interactive run after verification: sudo env CONFIRM_ROUTER_DNS_RESET=1 ./server.sh install"
    exit 1
}

refuse_unmigrated_legacy() {
    if docker inspect adguard >/dev/null 2>&1; then
        log_error "Legacy AdGuard is still present. Run sudo ./server.sh install to perform the guarded migration first."
        exit 1
    fi
}

remove_disabled_machine_learning() {
    if ! machine_learning_enabled && docker inspect immich_machine_learning >/dev/null 2>&1; then
        docker rm -f immich_machine_learning >/dev/null
        log_info "Removed the machine-learning container because it is disabled; its model cache was retained."
    fi
}

validate_compose() {
    validate_env
    compose config --quiet
}

configured_image() {
    local service=$1
    compose config | awk -v wanted="$service:" '
        $1 == wanted { in_service = 1; next }
        in_service && $1 == "image:" && !printed { print $2; printed = 1 }
        in_service && /^[^ ]/ { in_service = 0 }
    '
}

container_ready() {
    local name=$1 state health
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true)"
    [[ "$state" == "running" && ( "$health" == "healthy" || "$health" == "none" ) ]]
}

wait_for_health() {
    local deadline=$((SECONDS + 300)) required=(immich_postgres immich_redis immich_server) container all_ready
    if machine_learning_enabled; then
        required+=(immich_machine_learning)
    fi

    log_info "Waiting for Immich services to become healthy..."
    while (( SECONDS < deadline )); do
        all_ready=true
        for container in "${required[@]}"; do
            if ! container_ready "$container"; then
                all_ready=false
                break
            fi
        done
        if [[ "$all_ready" == true ]]; then
            log_info "All enabled services are healthy."
            return 0
        fi
        sleep 3
    done

    log_error "Services did not become healthy within five minutes."
    compose ps || true
    compose logs --tail=80 immich-server database redis || true
    return 1
}

server_ip() {
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i+1); exit } }' || true)"
    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{ print $1 }' || true)"
    fi
    printf '%s\n' "${ip:-SERVER_IP}"
}

create_backup() {
    local upload db_user db_name backup_dir timestamp temp final owner group
    upload="$(env_get UPLOAD_LOCATION)"
    db_user="$(env_get DB_USERNAME)"
    db_name="$(env_get DB_DATABASE_NAME)"
    backup_dir="$upload/backups"
    timestamp="$(date +%Y%m%d-%H%M%S)"
    final="$backup_dir/immich-db-$timestamp.sql.gz"
    temp="$final.partial"

    if ! container_ready immich_postgres; then
        log_error "PostgreSQL is not healthy; refusing to create an unreliable backup."
        return 1
    fi

    mkdir -p "$backup_dir"
    log_info "Creating PostgreSQL backup..." >&2
    docker exec immich_postgres pg_dump --clean --if-exists --dbname="$db_name" --username="$db_user" | gzip -c > "$temp"
    gzip -t "$temp"
    [[ -s "$temp" ]]
    mv "$temp" "$final"
    if [[ $EUID -eq 0 ]]; then
        owner="$(actual_user)"
        group="$(id -gn "$owner")"
        chown "$owner":"$group" "$final" 2>/dev/null || true
    fi
    printf '%s\n' "$final"
}

with_lock() {
    local command=$1
    shift
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_error "Another Immich operation is already running."
        exit 1
    fi
    "$command" "$@"
}

prepare_runtime() {
    local user home total_mb group
    require_linux
    user="$(actual_user)"
    group="$(id -gn "$user")"
    home="$(user_home "$user")"
    if [[ -z "$home" ]]; then
        log_error "Could not determine the home directory for $user."
        exit 1
    fi
    total_mb="$(memory_mebibytes)"
    prepare_env "$user" "$home" "$total_mb"
    render_compose
    if [[ $EUID -eq 0 ]]; then
        chown -R "$user":"$group" "$RUNTIME_DIR"
    fi
    validate_env
}

load_runtime() {
    require_linux
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "$ENV_FILE is missing. Run: sudo ./server.sh install"
        exit 1
    fi
    mkdir -p "$RUNTIME_DIR"
    render_compose
    validate_env
}

do_install() {
    local user total_mb upload backup_path
    require_linux
    require_supported_ubuntu
    user="$(actual_user)"
    total_mb="$(memory_mebibytes)"

    if (( total_mb < 4096 )); then
        log_error "Immich needs at least 4 GiB RAM with machine learning disabled."
        exit 1
    elif (( total_mb < 8192 )); then
        log_warn "Less than 8 GiB RAM detected; machine learning will be disabled by default."
    fi

    install_docker
    usermod -aG docker "$user"
    confirm_router_dns_reset
    prepare_runtime
    prepare_data_directories "$user"
    upload="$(env_get UPLOAD_LOCATION)"
    check_free_space 2 "$upload"
    check_free_space 2 "$(env_get DB_DATA_LOCATION)"
    check_free_space 3 "$(docker_root_directory)"
    validate_compose

    if docker inspect immich_postgres >/dev/null 2>&1; then
        if ! container_ready immich_postgres; then
            log_error "An existing PostgreSQL container is not healthy; refusing to modify the stack without a backup."
            exit 1
        fi
        backup_path="$(create_backup)"
        log_info "Pre-migration backup verified: $backup_path"
    fi

    log_info "Starting the minimal Immich stack without pulling unexpected updates..."
    # Keep legacy containers alive until direct Immich access is verified.
    compose up -d
    wait_for_health
    remove_legacy_containers
    remove_disabled_machine_learning
    cleanup_legacy_dns
    compose up -d --remove-orphans

    printf '\n%bImmich is ready:%b http://%s:2283\n' "$CYAN" "$NC" "$(server_ip)"
    if [[ "$user" != "root" ]]; then
        printf 'Docker group access will apply after your next login. No reboot is required.\n'
    fi
}

do_start() {
    prepare_runtime
    ensure_docker_access
    refuse_unmigrated_legacy
    validate_compose
    compose up -d --remove-orphans
    wait_for_health
    printf 'Immich: http://%s:2283\n' "$(server_ip)"
}

do_stop() {
    prepare_runtime
    ensure_docker_access
    compose stop
}

do_restart() {
    prepare_runtime
    ensure_docker_access
    refuse_unmigrated_legacy
    validate_compose
    compose up -d --force-recreate --remove-orphans
    wait_for_health
}

do_backup() {
    prepare_runtime
    ensure_docker_access
    check_free_space 1 "$(env_get UPLOAD_LOCATION)"
    create_backup
}

do_check_update() {
    local service container current_id local_id image update_count=0
    load_runtime
    ensure_docker_access
    validate_compose
    check_free_space 3 "$(docker_root_directory)"

    log_info "Downloading image metadata/layers without changing running containers..."
    compose pull --quiet --policy always

    for service in immich-server redis database; do
        container="$(compose ps -q "$service")"
        current_id="$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null || true)"
        image="$(configured_image "$service")"
        local_id="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)"
        if [[ -n "$current_id" && -n "$local_id" && "$current_id" != "$local_id" ]]; then
            printf 'Update available: %s\n' "$service"
            update_count=$((update_count + 1))
        fi
    done

    if machine_learning_enabled; then
        service=immich-machine-learning
        container="$(compose ps -q "$service")"
        current_id="$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null || true)"
        image="$(configured_image "$service")"
        local_id="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)"
        if [[ -n "$current_id" && -n "$local_id" && "$current_id" != "$local_id" ]]; then
            printf 'Update available: %s\n' "$service"
            update_count=$((update_count + 1))
        fi
    fi

    if (( update_count == 0 )); then
        printf 'Running containers already use the configured images.\n'
    else
        printf 'Run sudo ./server.sh update after reviewing Immich release notes.\n'
    fi
}

do_update() {
    local upload backup_path
    prepare_runtime
    ensure_docker_access
    refuse_unmigrated_legacy
    validate_compose
    upload="$(env_get UPLOAD_LOCATION)"
    check_free_space 5 "$upload"
    check_free_space 2 "$(env_get DB_DATA_LOCATION)"

    backup_path="$(create_backup)"
    log_info "Pre-update backup verified: $backup_path"
    check_free_space 3 "$(docker_root_directory)"
    log_info "Pulling configured container images..."
    compose pull --policy always
    log_info "Deploying update; old images are retained for diagnostics."
    compose up -d --remove-orphans
    if ! wait_for_health; then
        log_error "Update failed health verification. Database backup: $backup_path"
        log_error "Immich downgrades are unsupported; inspect logs before taking further action."
        return 1
    fi
    printf 'Update complete. Immich: http://%s:2283\n' "$(server_ip)"
}

do_status() {
    local upload db db_probe container state health restarts oom latest_backup
    local stats_containers=(immich_server immich_postgres immich_redis)
    load_runtime
    ensure_docker_access
    upload="$(env_get UPLOAD_LOCATION)"
    db="$(env_get DB_DATA_LOCATION)"

    printf '%bImmich home server%b\n' "$CYAN" "$NC"
    printf 'URL: http://%s:2283\n' "$(server_ip)"
    printf 'Machine learning: %s\n\n' "$(env_get ENABLE_MACHINE_LEARNING)"
    compose ps

    printf '\nContainer health:\n'
    for container in immich_server immich_postgres immich_redis immich_machine_learning; do
        if ! docker inspect "$container" >/dev/null 2>&1; then
            [[ "$container" == "immich_machine_learning" ]] && ! machine_learning_enabled && continue
            printf '  %-28s missing\n' "$container"
            continue
        fi
        state="$(docker inspect -f '{{.State.Status}}' "$container")"
        health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$container")"
        restarts="$(docker inspect -f '{{.RestartCount}}' "$container")"
        oom="$(docker inspect -f '{{.State.OOMKilled}}' "$container")"
        printf '  %-28s state=%-9s health=%-9s restarts=%-3s oom=%s\n' "$container" "$state" "$health" "$restarts" "$oom"
    done

    printf '\nLive resource use:\n'
    if machine_learning_enabled; then
        stats_containers+=(immich_machine_learning)
    fi
    docker stats --no-stream --format '  {{.Name}}: {{.MemUsage}} ({{.MemPerc}}), CPU {{.CPUPerc}}, PIDs {{.PIDs}}' \
        "${stats_containers[@]}" 2>/dev/null || true

    printf '\nMemory:\n'
    free -h
    printf '\nStorage:\n'
    db_probe="$db"
    if [[ ! -x "$db_probe" ]]; then
        db_probe="$(dirname "$db")"
    fi
    df -h "$upload" "$db_probe" | awk 'NR == 1 || !seen[$1]++'
    printf '\nDocker disk use:\n'
    docker system df

    latest_backup=""
    if [[ -d "$upload/backups" ]]; then
        latest_backup="$(find "$upload/backups" -maxdepth 1 -type f -name 'immich-db-*.sql.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR == 1 { sub(/^[^ ]+ /, ""); newest = $0 } END { if (newest) print newest }')"
    fi
    printf '\nLatest managed backup: %s\n' "${latest_backup:-none}"
}

do_doctor() {
    local failures=0 upload db
    printf 'server.sh %s doctor\n' "$SCRIPT_VERSION"

    if bash -n "$SCRIPT_DIR/server.sh"; then
        printf '  [OK] script syntax\n'
    else
        printf '  [FAIL] script syntax\n'
        failures=$((failures + 1))
    fi

    if [[ ! -f "$ENV_FILE" ]]; then
        printf '  [FAIL] %s is missing; run install\n' "$ENV_FILE"
        return 1
    fi

    render_compose
    if validate_env; then
        printf '  [OK] environment configuration\n'
    else
        failures=$((failures + 1))
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        printf '  [OK] Docker Engine and Compose plugin\n'
    else
        printf '  [FAIL] Docker Engine or Compose plugin missing\n'
        failures=$((failures + 1))
    fi

    if docker info >/dev/null 2>&1; then
        if compose config --quiet; then
            printf '  [OK] generated Compose configuration\n'
        else
            printf '  [FAIL] generated Compose configuration\n'
            failures=$((failures + 1))
        fi
    else
        printf '  [FAIL] Docker daemon unavailable or permission denied\n'
        failures=$((failures + 1))
    fi

    upload="$(env_get UPLOAD_LOCATION)"
    db="$(env_get DB_DATA_LOCATION)"
    for path in "$upload" "$db"; do
        if [[ -d "$path" ]]; then
            printf '  [OK] data path %s\n' "$path"
        else
            printf '  [FAIL] data path unavailable: %s\n' "$path"
            failures=$((failures + 1))
        fi
    done

    if curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:2283/; then
        printf '  [OK] Immich responds on port 2283\n'
    else
        printf '  [FAIL] Immich does not respond on port 2283\n'
        failures=$((failures + 1))
    fi

    if (( failures > 0 )); then
        printf '%d doctor check(s) failed.\n' "$failures"
        return 1
    fi
    printf 'All doctor checks passed.\n'
}

do_logs() {
    local service=${1:-immich-server}
    load_runtime
    ensure_docker_access
    compose logs --tail=200 --follow "$service"
}

main() {
    local command=${1:-}
    case "$command" in
        install)
            require_root install
            with_lock do_install
            ;;
        start)
            require_root start
            with_lock do_start
            ;;
        stop)
            require_root stop
            with_lock do_stop
            ;;
        restart)
            require_root restart
            with_lock do_restart
            ;;
        update)
            require_root update
            with_lock do_update
            ;;
        backup)
            require_root backup
            with_lock do_backup
            ;;
        check-update)
            do_check_update
            ;;
        status)
            do_status
            ;;
        doctor)
            do_doctor
            ;;
        logs)
            shift
            do_logs "${1:-immich-server}"
            ;;
        version)
            printf 'server.sh %s\n' "$SCRIPT_VERSION"
            ;;
        help|-h|--help|'')
            usage
            ;;
        *)
            log_error "Unknown command: $command"
            usage >&2
            exit 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
