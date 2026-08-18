#!/usr/bin/env bash
# Permanent, one-command Immich installer/updater/repair tool.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.1.0"
MANAGED_IMMICH_VERSION="v3"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
RUNTIME_DIR="$SCRIPT_DIR/.runtime"
COMPOSE_FILE="$RUNTIME_DIR/docker-compose.yml"
LOCK_FILE="/run/lock/immich-home.lock"

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

log_info() { printf '%b>>>%b %s\n' "$GREEN" "$NC" "$*"; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }

on_error() {
    local code=$?
    trap - ERR
    log_error "Failed at line $1 (exit $code). Existing data and verified backups were not deleted."
    log_error "For a read-only report, run: $SCRIPT_DIR/diagnose.sh"
    exit "$code"
}
trap 'on_error "$LINENO"' ERR

repository_git() {
    local owner
    if [[ $EUID -ne 0 ]]; then
        git -C "$SCRIPT_DIR" "$@"
        return
    fi
    owner="$(stat -c '%U' "$SCRIPT_DIR")"
    if [[ "$owner" != "root" && "$owner" != "UNKNOWN" ]]; then
        runuser -u "$owner" -- git -C "$SCRIPT_DIR" "$@"
    else
        git -C "$SCRIPT_DIR" "$@"
    fi
}

sync_repository() {
    local before after
    REPOSITORY_UPDATED=false

    if ! command -v git >/dev/null 2>&1 || ! repository_git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log_warn "This is not a Git checkout; continuing without checking for script updates."
        return
    fi
    if ! repository_git diff --quiet --ignore-submodules -- || ! repository_git diff --cached --quiet --ignore-submodules --; then
        log_error "Tracked repository files have local changes; refusing to overwrite them."
        log_error "Review them with: git -C $SCRIPT_DIR status"
        exit 1
    fi
    if ! repository_git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
        log_warn "The current branch has no upstream; continuing without checking for script updates."
        return
    fi

    before="$(repository_git rev-parse HEAD)"
    log_info "Checking the server repository for updates..."
    if ! repository_git pull --ff-only; then
        log_warn "Could not update the repository; continuing with the installed script."
        return
    fi
    after="$(repository_git rev-parse HEAD)"
    if [[ "$before" != "$after" ]]; then
        REPOSITORY_UPDATED=true
        log_info "Server repository updated: ${before:0:7} -> ${after:0:7}"
    else
        log_info "Server repository is already current."
    fi
}

if [[ "${SERVER_SCRIPT_LIB_ONLY:-0}" != 1 ]]; then
    if (( $# != 0 )); then
        log_error "server.sh takes no commands or arguments. Just run: ./server.sh"
        exit 2
    fi
    if [[ "${SERVER_SCRIPT_REPOSITORY_SYNCED:-0}" != 1 ]]; then
        sync_repository
        if [[ $EUID -eq 0 && "$REPOSITORY_UPDATED" == true ]]; then
            exec env SERVER_SCRIPT_REPOSITORY_SYNCED=1 "$SCRIPT_DIR/server.sh"
        fi
    fi
    if [[ $EUID -ne 0 ]]; then
        exec sudo env SERVER_SCRIPT_REPOSITORY_SYNCED=1 "$SCRIPT_DIR/server.sh"
    fi
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_error "Another Immich operation is already running."
        exit 1
    fi
fi

actual_user() {
    local owner
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
        return
    fi
    owner="$(stat -c '%U' "$SCRIPT_DIR")"
    [[ "$owner" != "UNKNOWN" ]] && printf '%s\n' "$owner" || printf 'root\n'
}

user_home() {
    getent passwd "$1" | awk -F: 'NR == 1 { print $6 }'
}

require_supported_host() {
    local architecture
    [[ "$(uname -s)" == "Linux" ]] || { log_error "Linux is required."; exit 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || { log_error "Ubuntu Server is required."; exit 1; }
    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        log_warn "Tested on Ubuntu 24.04 LTS; detected ${VERSION_ID:-unknown}."
    fi
    architecture="$(uname -m)"
    case "$architecture" in
        x86_64|aarch64|arm64) ;;
        *) log_error "Unsupported CPU architecture: $architecture"; exit 1 ;;
    esac
}

install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        systemctl enable --now docker
        return
    fi

    log_info "Installing Docker Engine and the Compose plugin..."
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
    local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$codename" ]] || { log_error "Could not determine the Ubuntu codename."; exit 1; }
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
        "$(dpkg --print-architecture)" "$codename" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
}

env_get() {
    local key=$1
    [[ -f "$ENV_FILE" ]] || return 1
    awk -F= -v wanted="$key" '
        $1 == wanted { sub(/^[^=]*=/, ""); print; found = 1; exit }
        END { if (!found) exit 1 }
    ' "$ENV_FILE"
}

env_set() {
    local key=$1 value=$2 temp
    [[ "$key" =~ ^[A-Z0-9_]+$ && "$value" != *$'\n'* ]]
    temp="$(mktemp "$RUNTIME_DIR/env.XXXXXX")"
    awk -v wanted="$key" -v replacement="$key=$value" '
        BEGIN { replaced = 0 }
        $0 ~ "^" wanted "=" { if (!replaced) print replacement; replaced = 1; next }
        { print }
        END { if (!replaced) print replacement }
    ' "$ENV_FILE" > "$temp"
    chmod 600 "$temp"
    mv -f "$temp" "$ENV_FILE"
}

ensure_env_key() {
    env_get "$1" >/dev/null 2>&1 || env_set "$1" "$2"
}

memory_mebibytes() {
    awk '/^MemTotal:/ { printf "%d\n", $2 / 1024 }' /proc/meminfo
}

resource_defaults() {
    local total_mb=$1
    if (( total_mb < 6144 )); then
        DEFAULT_ML_ENABLED=false; DEFAULT_SERVER_MEMORY=1280m; DEFAULT_ML_MEMORY=1024m
        DEFAULT_DB_MEMORY=1536m; DEFAULT_REDIS_MEMORY=128m
    elif (( total_mb < 8192 )); then
        DEFAULT_ML_ENABLED=false; DEFAULT_SERVER_MEMORY=2048m; DEFAULT_ML_MEMORY=1024m
        DEFAULT_DB_MEMORY=2048m; DEFAULT_REDIS_MEMORY=128m
    elif (( total_mb < 12288 )); then
        DEFAULT_ML_ENABLED=true; DEFAULT_SERVER_MEMORY=2560m; DEFAULT_ML_MEMORY=1536m
        DEFAULT_DB_MEMORY=2048m; DEFAULT_REDIS_MEMORY=256m
    else
        DEFAULT_ML_ENABLED=true; DEFAULT_SERVER_MEMORY=4096m; DEFAULT_ML_MEMORY=2048m
        DEFAULT_DB_MEMORY=3072m; DEFAULT_REDIS_MEMORY=256m
    fi
}

default_project_name() {
    local container project
    for container in immich_server immich_postgres; do
        project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$container" 2>/dev/null || true)"
        if [[ -n "$project" && "$project" != "<no value>" ]]; then
            printf '%s\n' "$project"
            return
        fi
    done
    printf 'immich\n'
}

prepare_environment() {
    local user=$1 home=$2 total_mb=$3 group password
    group="$(id -gn "$user")"
    mkdir -p "$RUNTIME_DIR"
    resource_defaults "$total_mb"

    if [[ ! -f "$ENV_FILE" ]]; then
        password="$(openssl rand -hex 24)"
        cat > "$ENV_FILE" <<EOF
# Generated by server.sh. Keep private and back up separately.
UPLOAD_LOCATION=$home/docker_data/immich
DB_DATA_LOCATION=$home/docker_data/postgres
TZ=Europe/Rome
IMMICH_VERSION=$MANAGED_IMMICH_VERSION
DB_PASSWORD=$password
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
COMPOSE_PROJECT_NAME=$(default_project_name)
ENABLE_MACHINE_LEARNING=$DEFAULT_ML_ENABLED
IMMICH_SERVER_MEMORY_LIMIT=$DEFAULT_SERVER_MEMORY
IMMICH_ML_MEMORY_LIMIT=$DEFAULT_ML_MEMORY
IMMICH_DB_MEMORY_LIMIT=$DEFAULT_DB_MEMORY
IMMICH_REDIS_MEMORY_LIMIT=$DEFAULT_REDIS_MEMORY
EOF
        log_info "Created private configuration at $ENV_FILE"
    else
        ensure_env_key UPLOAD_LOCATION "$home/docker_data/immich"
        ensure_env_key DB_DATA_LOCATION "$home/docker_data/postgres"
        ensure_env_key TZ "Europe/Rome"
        ensure_env_key DB_PASSWORD "$(openssl rand -hex 24)"
        ensure_env_key DB_USERNAME postgres
        ensure_env_key DB_DATABASE_NAME immich
        ensure_env_key COMPOSE_PROJECT_NAME "$(default_project_name)"
        ensure_env_key ENABLE_MACHINE_LEARNING "$DEFAULT_ML_ENABLED"
        ensure_env_key IMMICH_SERVER_MEMORY_LIMIT "$DEFAULT_SERVER_MEMORY"
        ensure_env_key IMMICH_ML_MEMORY_LIMIT "$DEFAULT_ML_MEMORY"
        ensure_env_key IMMICH_DB_MEMORY_LIMIT "$DEFAULT_DB_MEMORY"
        ensure_env_key IMMICH_REDIS_MEMORY_LIMIT "$DEFAULT_REDIS_MEMORY"
    fi

    if [[ "$(env_get IMMICH_VERSION 2>/dev/null || true)" != "$MANAGED_IMMICH_VERSION" ]]; then
        log_info "Applying the repository Immich version policy: $MANAGED_IMMICH_VERSION"
        env_set IMMICH_VERSION "$MANAGED_IMMICH_VERSION"
    fi

    chmod 600 "$ENV_FILE"
    chown "$user":"$group" "$ENV_FILE"
}

validate_environment() {
    local key value version
    for key in UPLOAD_LOCATION DB_DATA_LOCATION IMMICH_VERSION DB_PASSWORD DB_USERNAME DB_DATABASE_NAME COMPOSE_PROJECT_NAME ENABLE_MACHINE_LEARNING IMMICH_SERVER_MEMORY_LIMIT IMMICH_ML_MEMORY_LIMIT IMMICH_DB_MEMORY_LIMIT IMMICH_REDIS_MEMORY_LIMIT; do
        value="$(env_get "$key" || true)"
        [[ -n "$value" ]] || { log_error "Missing $key in $ENV_FILE"; return 1; }
    done
    [[ "$(env_get UPLOAD_LOCATION)" == /* ]] || { log_error "UPLOAD_LOCATION must be absolute."; return 1; }
    [[ "$(env_get DB_DATA_LOCATION)" == /* ]] || { log_error "DB_DATA_LOCATION must be absolute."; return 1; }
    version="$(env_get IMMICH_VERSION)"
    if [[ "$version" == "release" ]]; then
        log_error "IMMICH_VERSION=release can cross major versions. Pin a major such as v3."
        return 1
    fi
    [[ "$version" =~ ^v[0-9]+([.][0-9]+){0,2}$ ]] || { log_error "IMMICH_VERSION must look like v3 or v3.1.0."; return 1; }
    [[ "$(env_get DB_PASSWORD)" =~ ^[A-Za-z0-9]+$ ]] || { log_error "DB_PASSWORD may contain only A-Za-z0-9."; return 1; }
    [[ "$(env_get DB_USERNAME)" =~ ^[A-Za-z0-9_]+$ ]] || { log_error "Invalid DB_USERNAME."; return 1; }
    [[ "$(env_get DB_DATABASE_NAME)" =~ ^[A-Za-z0-9_]+$ ]] || { log_error "Invalid DB_DATABASE_NAME."; return 1; }
    [[ "$(env_get COMPOSE_PROJECT_NAME)" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { log_error "Invalid COMPOSE_PROJECT_NAME."; return 1; }
    [[ "$(env_get ENABLE_MACHINE_LEARNING)" =~ ^(true|false)$ ]] || { log_error "ENABLE_MACHINE_LEARNING must be true or false."; return 1; }
    for key in IMMICH_SERVER_MEMORY_LIMIT IMMICH_ML_MEMORY_LIMIT IMMICH_DB_MEMORY_LIMIT IMMICH_REDIS_MEMORY_LIMIT; do
        [[ "$(env_get "$key")" =~ ^[1-9][0-9]*(m|g)$ ]] || { log_error "$key must look like 1536m or 2g."; return 1; }
    done
    [[ "$(env_get UPLOAD_LOCATION)" != "$(env_get DB_DATA_LOCATION)" ]] || { log_error "Library and database paths must differ."; return 1; }
}

render_compose() {
    local temp
    mkdir -p "$RUNTIME_DIR"
    temp="$(mktemp "$RUNTIME_DIR/compose.XXXXXX")"
    cat > "$temp" <<'YAML'
# Generated by server.sh. Do not edit.
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
    [[ "$(env_get ENABLE_MACHINE_LEARNING)" == "true" ]]
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

prepare_directories() {
    local user=$1 group upload db
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
    chown -R "$user":"$group" "$RUNTIME_DIR"
}

check_free_gib() {
    local required=$1 path=$2 available
    available="$(df -Pk "$path" | awk 'NR == 2 { print $4 }')"
    (( available >= required * 1024 * 1024 )) || { log_error "$path has less than ${required} GiB free."; return 1; }
}

container_ready() {
    local name=$1 state health
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true)"
    [[ "$state" == "running" && ( "$health" == "healthy" || "$health" == "none" ) ]]
}

wait_for_container() {
    local name=$1 label=$2 timeout deadline
    timeout=${3:-300}
    deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if container_ready "$name"; then
            log_info "$label is healthy."
            return 0
        fi
        sleep 3
    done
    log_error "$label did not become healthy within ${timeout} seconds."
    docker logs --tail=80 "$name" 2>&1 || true
    return 1
}

recover_database_if_needed() {
    if ! docker inspect immich_postgres >/dev/null 2>&1 || container_ready immich_postgres; then
        return
    fi
    log_warn "Existing PostgreSQL is unhealthy; attempting a contained repair before any update."
    compose up -d --no-deps database
    wait_for_container immich_postgres PostgreSQL 300
}

create_backup() {
    local upload user db_name backup_dir timestamp temp final owner group
    upload="$(env_get UPLOAD_LOCATION)"
    user="$(env_get DB_USERNAME)"
    db_name="$(env_get DB_DATABASE_NAME)"
    backup_dir="$upload/backups"
    timestamp="$(date +%Y%m%d-%H%M%S)"
    final="$backup_dir/immich-db-$timestamp.sql.gz"
    temp="$final.partial"
    container_ready immich_postgres || { log_error "PostgreSQL is not healthy; refusing an unreliable backup."; return 1; }
    mkdir -p "$backup_dir"
    log_info "Creating and verifying PostgreSQL backup..." >&2
    docker exec immich_postgres pg_dump --clean --if-exists --dbname="$db_name" --username="$user" | gzip -c > "$temp"
    gzip -t "$temp"
    [[ -s "$temp" ]]
    mv "$temp" "$final"
    owner="$(actual_user)"; group="$(id -gn "$owner")"
    chown "$owner":"$group" "$final" 2>/dev/null || true
    printf '%s\n' "$final"
}

prune_old_managed_backups() {
    local backup_dir file index remove_count
    local -a backups
    backup_dir="$(env_get UPLOAD_LOCATION)/backups"
    [[ -d "$backup_dir" ]] || return
    shopt -s nullglob
    backups=("$backup_dir"/immich-db-*.sql.gz)
    shopt -u nullglob
    remove_count=$((${#backups[@]} - 14))
    (( remove_count > 0 )) || return
    for ((index=0; index<remove_count; index++)); do
        file="${backups[$index]}"
        [[ "$file" == "$backup_dir"/immich-db-*.sql.gz ]] || continue
        rm -f -- "$file"
    done
}

remove_disabled_machine_learning() {
    if ! machine_learning_enabled && docker inspect immich_machine_learning >/dev/null 2>&1; then
        docker rm -f immich_machine_learning >/dev/null
        log_info "Machine learning is disabled; its model cache was retained."
    fi
}

wait_for_stack() {
    wait_for_container immich_postgres PostgreSQL 300
    wait_for_container immich_redis Valkey 300
    wait_for_container immich_server Immich 300
    if machine_learning_enabled; then
        wait_for_container immich_machine_learning "Immich machine learning" 300
    fi
}

server_ip() {
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit } }' || true)"
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    printf '%s\n' "${ip:-SERVER_IP}"
}

show_summary() {
    local running_version
    running_version="$(curl -fsS --max-time 5 http://127.0.0.1:2283/api/server/version)"
    printf '\n%bImmich is healthy:%b http://%s:2283\n' "$CYAN" "$NC" "$(server_ip)"
    printf 'Running version: %s | Managed line: %s | Machine learning: %s\n' \
        "$running_version" "$(env_get IMMICH_VERSION)" "$(env_get ENABLE_MACHINE_LEARNING)"
    compose ps
    printf '\nResource use:\n'
    docker stats --no-stream --format '  {{.Name}}: {{.MemUsage}}, CPU {{.CPUPerc}}, PIDs {{.PIDs}}' \
        immich_server immich_postgres immich_redis $(machine_learning_enabled && printf 'immich_machine_learning' || true) 2>/dev/null || true
    printf '\nStorage:\n'
    df -h "$(env_get UPLOAD_LOCATION)" | awk 'NR <= 2'
}

main() {
    local user home total_mb backup_path had_database=false
    require_supported_host
    user="$(actual_user)"
    home="$(user_home "$user")"
    [[ -n "$home" ]] || { log_error "Could not determine the home directory for $user."; exit 1; }
    total_mb="$(memory_mebibytes)"
    (( total_mb >= 4096 )) || { log_error "Immich requires at least 4 GiB RAM."; exit 1; }

    install_docker
    usermod -aG docker "$user"
    prepare_environment "$user" "$home" "$total_mb"
    validate_environment
    render_compose
    prepare_directories "$user"
    compose config --quiet

    check_free_gib 5 "$(env_get UPLOAD_LOCATION)"
    check_free_gib 2 "$(env_get DB_DATA_LOCATION)"
    check_free_gib 5 "$(docker info --format '{{.DockerRootDir}}')"

    if docker inspect immich_postgres >/dev/null 2>&1; then
        had_database=true
        recover_database_if_needed
        backup_path="$(create_backup)"
        log_info "Verified backup: $backup_path"
    fi

    log_info "Pulling the configured Immich release and fixed dependencies..."
    compose pull --policy always
    log_info "Reconciling the complete stack..."
    compose up -d
    remove_disabled_machine_learning
    wait_for_stack
    prune_old_managed_backups
    docker image prune -f >/dev/null || log_warn "Could not remove unused dangling images."

    if [[ "$had_database" == false ]]; then
        log_info "Fresh database created; register the first administrator now."
    fi
    show_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
