# Minimal Immich Home Server

This repository installs and operates one thing: **Immich on a trusted home LAN**.

It deliberately does not run AdGuard, Traefik, a custom DNS domain, or any other service that could make the rest of the home network depend on this machine. If the server stops, Immich stops; normal internet and Wi-Fi continue working.

Immich is available directly at:

```text
http://SERVER_IP:2283
```

Fresh installations require no router DNS changes, port forwarding, or modem configuration. Migrating the previous AdGuard-based version requires one final router change to undo its old DNS setting; see the migration section.

## Requirements

- Ubuntu Server 24.04 LTS
- A 64-bit `amd64` or `arm64` machine
- At least 4 GiB RAM with machine learning disabled
- At least 8 GiB RAM to enable machine learning
- Local Linux storage for PostgreSQL; do not put the database on a network share

The manager automatically disables Immich machine learning below 8 GiB and applies conservative per-container memory limits while reserving RAM for Ubuntu and Docker. A runaway Immich process is contained or restarted before it can exhaust the host.

## Fresh installation

Install Git, clone this repository, and run the single manager:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/antonio-leitao/cattle.git ~/server
cd ~/server
sudo ./server.sh install
```

The installation:

- Installs Docker Engine and the Docker Compose plugin when needed.
- Does not perform an unattended full operating-system upgrade.
- Generates a private `.env` file with a random PostgreSQL password.
- Creates the Immich library and database directories.
- Generates and validates the Docker Compose definition from `server.sh`.
- Starts PostgreSQL, Valkey, Immich, and optionally Immich machine learning.
- Waits up to five minutes for every enabled container to become healthy.
- Enables rotated Docker logs and memory, swap, and PID limits.
- Does not require a reboot. Docker group access becomes available on the next login.

Open the URL printed by the installer. The first user registered on a new database becomes the Immich administrator.

## Migrating this repository's previous installation

The new setup preserves the paths already used by the old stack:

```text
~/docker_data/immich
~/docker_data/postgres
```

After switching to this version of the repository, run:

1. Open the router's DHCP/DNS settings.
2. Change DNS from the server's IP back to **Automatic**, the router itself, or the router's normal default.
3. Reconnect household devices and verify that ordinary websites work while the server is disconnected or AdGuard is stopped.
4. Run the guarded migration:

```bash
cd ~/server
sudo ./server.sh install
```

This one-time router reset is unavoidable because the previous setup deliberately made AdGuard the household's only DNS server. The installer detects the legacy AdGuard container and refuses to remove it until you type `YES` confirming that DNS has been restored. It validates the new stack and creates a database backup before removing either legacy service.

During migration the manager:

- Keeps the existing `.env`, database password, library path, and database path.
- Creates and verifies a PostgreSQL backup before changing existing containers.
- Detects the running Immich major version and replaces the unsafe cross-major `IMMICH_VERSION=release` value with that major. It locally preserves the running images, so this migration does not double as a surprise Immich upgrade.
- Removes the old AdGuard and Traefik containers.
- Retains `~/docker_data/adguard` as a recoverable unused directory.
- Restores Ubuntu's normal `systemd-resolved` configuration only when it finds the exact files created by the previous installer. Backups of those files are retained under `/etc`.

The Immich account, albums, metadata, users, and photo library live in PostgreSQL and the Immich data directory—not in Traefik, AdGuard, or the URL. After migration, change the Immich mobile app's server endpoint to:

```text
http://SERVER_IP:2283
```

The app may ask you to sign in again. It will reconnect to the same server-side account and data.

If the Immich web page instead shows the first-time administrator setup, stop there and run `./server.sh doctor`; do not create a new administrator. That screen means the existing PostgreSQL data was not opened, rather than that the account was lost.

## One command for every operation

`server.sh` is the only operational source of truth. It embeds the Compose definition and generates `.runtime/docker-compose.yml`; do not edit that generated file.

```bash
./server.sh help
```

| Command | Purpose |
| --- | --- |
| `sudo ./server.sh install` | Install or repair the server and converge the stack without pulling surprise updates |
| `./server.sh status` | Show health, OOM state, restart counts, live memory/CPU use, storage, and latest backup |
| `./server.sh doctor` | Validate the script, environment, Docker, Compose, data paths, and Immich endpoint |
| `./server.sh check-update` | Download newer configured images without changing running containers |
| `sudo ./server.sh update` | Back up PostgreSQL, deploy downloaded/current images, and verify health |
| `sudo ./server.sh backup` | Create and verify a compressed PostgreSQL dump |
| `sudo ./server.sh start` | Start or reconcile the current pinned-major stack without pulling updates |
| `sudo ./server.sh stop` | Gracefully stop Immich |
| `sudo ./server.sh restart` | Recreate the stack and verify health |
| `./server.sh logs` | Follow Immich server logs |
| `./server.sh logs database` | Follow a specific Compose service's logs |

After the first login following installation, your normal user can run the read-only commands without `sudo` because it belongs to the Docker group.

## Safe updates

Immich uses major-version tags. A fresh installation starts on `v3`; a migrated installation is pinned to the major version it was already running. Routine updates therefore cannot silently cross into another major version.

Before updating:

1. Read the [Immich release notes](https://github.com/immich-app/immich/releases).
2. Check that the photo storage has at least 5 GiB free.
3. Run the update check and then the explicit update:

```bash
./server.sh check-update
sudo ./server.sh update
```

The update command refuses to proceed without a healthy PostgreSQL container, creates and verifies a database dump first, keeps old container images for diagnostics, and fails if the new stack does not become healthy. Immich does not support downgrades after database migrations, so release-note review and a real backup remain important.

Changing major versions is intentionally manual. Follow Immich's release-specific migration notes, edit `IMMICH_VERSION` in `.env` only when ready, then run the explicit update command. Do not skip required intermediate migrations.

## Backups

Immich automatically creates database dumps in the library's `backups` directory. The manager can create an additional verified dump on demand:

```bash
sudo ./server.sh backup
```

A complete backup needs both:

- `~/docker_data/immich` — originals, thumbnails, encoded video, profiles, and database dumps
- A recent `.sql.gz` database dump from `~/docker_data/immich/backups`

Copy them to storage outside this server. A second directory on the same disk is not a backup.

The raw `~/docker_data/postgres` directory is runtime database storage; prefer the verified SQL dumps for recovery.

## Resource containment

The generated `.env` contains editable limits:

```text
ENABLE_MACHINE_LEARNING=true
IMMICH_SERVER_MEMORY_LIMIT=2560m
IMMICH_ML_MEMORY_LIMIT=1536m
IMMICH_DB_MEMORY_LIMIT=2048m
IMMICH_REDIS_MEMORY_LIMIT=256m
```

Defaults are selected from the machine's total RAM only when a setting does not already exist. Existing custom values are preserved.

If the machine remains under pressure, set:

```text
ENABLE_MACHINE_LEARNING=false
```

Then run:

```bash
sudo ./server.sh start
```

Also reduce Immich job concurrency and video-transcoding threads from the Immich administration interface. Memory limits intentionally favor host survival over keeping a runaway container alive.

Docker uses the rotating `local` logging driver for every service. A single noisy container therefore cannot grow an unlimited JSON log file.

## Storage layout

```text
~/server/
├── server.sh             # The only operational source file
├── .env                  # Private generated settings; never committed
└── .runtime/             # Generated Compose file; never committed

~/docker_data/
├── immich/               # Photo library and Immich-managed database dumps
├── postgres/             # Live PostgreSQL files
└── adguard/              # Unused legacy data retained after migration
```

## Networking and security

- Port `2283` is published for LAN access.
- PostgreSQL and Valkey are not published to the LAN.
- Do not forward port `2283` to the internet.
- HTTP is suitable only for a trusted home LAN.
- For future remote access, use a private VPN such as WireGuard/Tailscale or deliberately add a properly configured HTTPS reverse proxy.
- A future Jellyfin/Arr stack should be deployed as a separate, resource-limited project so media downloads or transcoding cannot exhaust Immich or the operating system.

## Troubleshooting

Start with:

```bash
./server.sh doctor
./server.sh status
```

Then inspect logs:

```bash
./server.sh logs
./server.sh logs database
./server.sh logs immich-machine-learning
```

If the mobile app cannot connect after migration, verify that the phone is on the same Wi-Fi, that local-network permission is enabled for Immich, and that the endpoint is exactly `http://SERVER_IP:2283` without the old `photos.myserver.lan` name.

## License

MIT
