# Minimal Immich Home Server

This repository runs only **Immich on a trusted home LAN**. It does not run DNS, a reverse proxy, or anything else that can make household internet depend on this server.

Immich is available at:

```text
http://SERVER_IP:2283
```

Do not forward port `2283` to the internet. Plain HTTP is appropriate only on the trusted LAN; use a private VPN for future remote access.

## The complete interface

Day-to-day installation, updates, repair, backups, and health verification are one command:

```bash
./server.sh
```

There are no modes or subcommands to remember. The script asks for `sudo` itself and then:

1. Checks Ubuntu, CPU architecture, RAM, Docker, configuration, and free space.
2. Installs Docker on a fresh Ubuntu server when necessary.
3. Repairs an existing PostgreSQL container before attempting an update.
4. Creates and verifies a PostgreSQL dump whenever an existing database is present.
5. Pulls only the configured Immich version or pinned major.
6. Reconciles the generated Compose stack without touching unrelated containers.
7. Waits for PostgreSQL, Valkey, Immich, and optional machine learning to become healthy.
8. Keeps the latest 14 routine database dumps and removes only unused dangling container images after a healthy deployment.
9. Prints the URL, container state, resource use, and storage state.

When something is wrong, the optional diagnostic is also one command:

```bash
./diagnose.sh
```

It is read-only, redacts the database password, checks health and resource containment, and prints relevant logs for unhealthy services.

## Fresh installation

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/antonio-leitao/cattle.git ~/server
cd ~/server
./server.sh
```

Fresh installations require no router changes, custom DNS, port forwarding, or reboot. The first user registered in a fresh Immich database becomes its administrator.

## Temporary migration from the previous repository version

`migrate.sh` exists only while the known Albatross installation is being migrated away from AdGuard and Traefik. All transition-specific recovery and cleanup is isolated there; neither permanent script contains migration logic.

The router's DHCP/DNS setting must first be restored from Albatross to **Automatic/default** and normal browsing must be verified. Then run:

```bash
cd ~/server
./migrate.sh
```

The migration tool:

- Detects and preserves the exact installed Immich version.
- Recreates only the broken legacy PostgreSQL container on the valid Docker network, without pulling an image.
- Verifies that the existing database has tables and records its asset count.
- Creates and verifies a pre-migration PostgreSQL dump.
- Preserves a private copy of `.env`.
- Invokes the permanent `server.sh` to deploy the minimal resource-limited stack.
- Removes legacy AdGuard and Traefik containers only after the new stack is healthy.
- Restores Ubuntu's normal `systemd-resolved` configuration while retaining backups.
- Confirms the database counts did not unexpectedly change and runs the diagnostic report.

After manually confirming the existing account, albums, and photos at `http://SERVER_IP:2283`, delete `migrate.sh` from the repository. If Immich ever presents first-time administrator setup during migration, stop and do not create a new account.

## Version policy

`IMMICH_VERSION` in `.env` must be a major tag such as `v3` or an exact stable release such as `v3.1.0`. The unsafe moving `release` tag is rejected.

Running `server.sh` updates within the configured major. Major-version changes are manual because they can have release-specific migration requirements and Immich does not support downgrades after database migrations. Read the [Immich release notes](https://github.com/immich-app/immich/releases) before changing the major in `.env`.

## Resource containment

The generated stack contains only:

- Immich server
- PostgreSQL
- Valkey
- Immich machine learning when sufficient RAM is available

Each service has a memory limit, an equal memory-plus-swap limit, a PID limit, and rotated Docker `local` logs. PostgreSQL and Valkey are not published to the LAN.

Machine learning defaults off below 8 GiB RAM. On the 16 GiB Albatross server the defaults reserve several GiB for Ubuntu and Docker:

```text
IMMICH_SERVER_MEMORY_LIMIT=4096m
IMMICH_ML_MEMORY_LIMIT=2048m
IMMICH_DB_MEMORY_LIMIT=3072m
IMMICH_REDIS_MEMORY_LIMIT=256m
```

Existing values in `.env` are preserved. To disable machine learning permanently, set:

```text
ENABLE_MACHINE_LEARNING=false
```

Then run `./server.sh`.

## Data and backups

```text
~/docker_data/immich/      # originals, thumbnails, encoded video, profiles, SQL dumps
~/docker_data/postgres/    # live PostgreSQL files
```

Managed database dumps are written to `~/docker_data/immich/backups`. A complete external backup needs the entire Immich directory plus a recent verified `.sql.gz` dump. A copy on the same disk is not a backup.

The database and library paths are preserved across updates. Changing the URL does not change an Immich account: after migration, set the mobile app endpoint to `http://SERVER_IP:2283` and sign in again if requested.

## Generated files

```text
~/server/
├── server.sh       # permanent one-command manager
├── diagnose.sh     # permanent optional read-only diagnostic
├── migrate.sh      # temporary; removed after verified migration
├── .env            # private persistent settings
└── .runtime/       # generated Compose definition
```

Do not edit `.runtime/docker-compose.yml`; it is regenerated from `server.sh`.

## Future services

Jellyfin and any Arr/download stack should be a separate, independently resource-limited project. They do not require AdGuard and must not make household DNS or internet access depend on Albatross.

## License

MIT
