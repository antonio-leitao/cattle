# My Home Lab Server

A single-command setup for a home server running **Immich** (photos), **AdGuard Home** (DNS), and **Traefik** (reverse proxy) on Ubuntu Server 24.04 LTS.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/antonio-leitao/cattle/master/setup.sh | sudo bash
sudo reboot
cd ~/server && ./update.sh
```

Then configure AdGuard at `http://YOUR_IP:3000`.

---

## What This Sets Up

| Service          | Purpose                                               | Access                           |
| ---------------- | ----------------------------------------------------- | -------------------------------- |
| **Traefik**      | Reverse proxy - routes `*.myserver.lan` to containers | Dashboard: `http://YOUR_IP:8080` |
| **AdGuard Home** | DNS server - blocks ads, handles local DNS            | Setup: `http://YOUR_IP:3000`     |
| **Immich**       | Photo management - Google Photos alternative          | `http://images.myserver.lan`     |

---

## Full Setup Guide

### Phase 1: Install Ubuntu Server

1. **Download** [Ubuntu Server 24.04 LTS](https://ubuntu.com/download/server)
2. **Create bootable USB** with [Rufus](https://rufus.ie/) or [balenaEtcher](https://etcher.balena.io/)
3. **Install Ubuntu Server**:
   - Connect Ethernet
   - Select "Ubuntu Server (minimized)" for smaller footprint
   - ☑️ **Check "Install OpenSSH Server"** ← Critical!
   - Create your user account
4. **After first boot**, note your server's IP and MAC:
   ```bash
   ip addr show
   # IP: Look for "inet 192.168.x.x" under eth0/enp*
   # MAC: Look for "link/ether xx:xx:xx:xx:xx:xx"
   ```
5. **Set hostname** (optional):
   ```bash
   sudo hostnamectl set-hostname myserver
   ```
6. **Unplug monitor** - everything else is remote

### Phase 2: Reserve Static IP (Router)

Your server needs a fixed IP. Configure your router:

1. Open router admin (usually `192.168.1.1`)
2. Find **DHCP Reservation** / **Static Lease** / **Address Reservation**
3. Add entry:
   - MAC Address: `xx:xx:xx:xx:xx:xx` (from Phase 1)
   - IP Address: `192.168.1.50` (or your choice)
4. Save and reboot router if needed

### Phase 3: Run Setup Script

From your laptop/desktop:

```bash
# Connect to server
ssh youruser@192.168.1.50

# Run setup (as your user, with sudo)
curl -fsSL https://raw.githubusercontent.com/antonio-leitao/cattle/master/setup.sh | sudo bash

# IMPORTANT: Reboot to apply Docker permissions
sudo reboot
```

### Phase 4: Start Services

```bash
ssh youruser@192.168.1.50
cd ~/server

# Review settings (password was auto-generated)
nano .env

# Start everything
./update.sh
```

### Phase 5: Configure AdGuard Home

1. Open `http://192.168.1.50:3000`
2. **Setup Wizard**:
   - Admin Interface: Keep port `3000` (80 is used by Traefik)
   - DNS Server: Keep port `53`
3. Create admin account
4. **Add DNS Rewrite** (Settings → DNS Rewrites → Add):

   | Domain           | Answer         |
   | ---------------- | -------------- |
   | `*.myserver.lan` | `192.168.1.50` |

5. **Configure your network to use AdGuard DNS**:
   - **Option A** (Recommended): Set router's DHCP DNS to `192.168.1.50`
   - **Option B**: Set DNS manually on each device

---

## Accessing Services

| Service           | URL                        | Notes            |
| ----------------- | -------------------------- | ---------------- |
| Immich            | http://images.myserver.lan | After DNS setup  |
| Traefik Dashboard | http://192.168.1.50:8080   | Direct IP access |
| AdGuard Admin     | http://192.168.1.50:3000   | Direct IP access |

First user to register in Immich becomes admin.

---

## File Structure

```
~/server/                    # Git-tracked config
├── docker-compose.yml       # Service definitions
├── .env                     # Your secrets (NOT in git)
├── .env.example             # Template
├── setup.sh                 # Initial setup script
├── update.sh                # Update/restart script
└── README.md

~/docker_data/               # Persistent data (BACK THIS UP!)
├── adguard/
│   ├── conf/                # AdGuard configuration
│   └── work/                # AdGuard working data
├── immich/                  # Your photos and videos
└── postgres/                # Database files
```

---

## Updating

```bash
cd ~/server
./update.sh
```

This pulls latest images and restarts containers.

---

## Adding More Services

Add to `docker-compose.yml`:

```yaml
myapp:
  image: someimage:latest
  container_name: myapp
  restart: unless-stopped
  networks:
    - proxy_net
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.myapp.rule=Host(`myapp.myserver.lan`)"
    - "traefik.http.routers.myapp.entrypoints=web"
    - "traefik.http.services.myapp.loadbalancer.server.port=8080"
    - "traefik.docker.network=proxy_net"
```

Then add DNS rewrite in AdGuard for `myapp.myserver.lan → 192.168.1.50`.

---

## Troubleshooting

### Can't access `*.myserver.lan` URLs?

1. Check your device is using AdGuard as DNS:

   ```bash
   # On Linux/Mac
   cat /etc/resolv.conf
   # Should show 192.168.1.50

   # Or test directly
   nslookup images.myserver.lan 192.168.1.50
   ```

2. Verify AdGuard DNS Rewrite is configured
3. Try flushing DNS cache on your device

### Port 53 already in use?

The setup script handles this, but if needed:

```bash
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
```

### Docker permission denied?

You need to reboot after running setup.sh:

```bash
sudo reboot
```

### Container won't start?

```bash
# Check logs
docker compose logs -f immich-server
docker compose logs -f database

# Check if postgres has permission issues
ls -la ~/docker_data/postgres/
```

### Immich shows database errors?

The PostgreSQL container runs as UID 999 internally. If you see permission errors:

```bash
# Fix postgres directory ownership
sudo chown -R 999:999 ~/docker_data/postgres

# If that doesn't work, start fresh:
docker compose down
sudo rm -rf ~/docker_data/postgres/*
sudo chown -R 999:999 ~/docker_data/postgres
docker compose up -d
```

### Check container status

```bash
docker compose ps
docker compose logs -f          # All logs
docker compose logs -f immich-server  # Specific service
```

---

## Hardware Requirements

| Component | Minimum              | Recommended      |
| --------- | -------------------- | ---------------- |
| RAM       | 4GB                  | 8GB+             |
| CPU       | 2 cores              | 4 cores          |
| Storage   | 32GB + photo storage | SSD for database |

Immich ML features benefit significantly from more RAM and CPU.

---

## Backup Strategy

**Critical data to backup:**

- `~/docker_data/immich/` - Your photos/videos
- `~/docker_data/postgres/` - Database (metadata, users)
- `~/docker_data/adguard/conf/` - DNS configuration
- `~/server/.env` - Your secrets

**Backup command example:**

```bash
# Stop services for consistent backup
cd ~/server && docker compose down

# Backup
tar -czvf backup-$(date +%Y%m%d).tar.gz ~/docker_data ~/server/.env

# Restart
docker compose up -d
```

---

## Security Notes

- Change default passwords in `.env`
- AdGuard admin panel has no HTTPS by default (use VPN for remote access)
- Consider firewall rules to restrict port 53 to local network only
- Immich stores photos unencrypted - secure your server physically

---

## License

MIT
