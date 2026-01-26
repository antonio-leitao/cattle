# My Home Lab Server

A single-command setup for a home server running Immich (photos), AdGuard (DNS), and Traefik (reverse proxy).

## Quick Start (After OS Install)

```bash
curl -fsSL https://raw.githubusercontent.com/antonio-leitao/cattle/main/setup.sh | sudo bash
```

Then reboot, edit `.env`, and run `./update.sh`. That's it.

---

## Full Setup Guide

### Phase 1: Install the OS (Keyboard + Monitor Required)

1. **Install Ubuntu Server** (or Debian) from USB
2. **During installation:**
   - Connect Ethernet
   - ✏️ **Write down the IP address** (e.g., `192.168.1.50`) — you'll need this
   - ☑️ **Check "Install OpenSSH Server"** — critical for remote access
3. **First boot** — log in directly and set your hostname:
   ```bash
   sudo hostnamectl set-hostname myserver
   sudo reboot
   ```
4. **Unplug monitor and keyboard** — everything else is done remotely

---

### Phase 2: Connect Remotely

From your laptop/desktop:

```bash
ssh youruser@192.168.1.50
```

---

### Phase 3: Run Setup

```bash
curl -fsSL https://raw.githubusercontent.com/antonio-leitao/cattle/main/setup.sh | sudo bash
```

Then **reboot** to apply Docker group permissions:

```bash
sudo reboot
```

---

### Phase 4: Configure & Launch

```bash
cd ~/server

# Edit your secrets (CHANGE THE PASSWORDS!)
nano .env

# Start everything
./update.sh
```

---

### Phase 5: Configure AdGuard

1. Open `http://192.168.1.50:3000` in your browser
2. During setup wizard:
   - **Admin Interface:** Set to port `3000` (port 80 is used by Traefik)
   - **DNS Server:** Keep port `53`
3. Complete the wizard and log in
4. Go to **Filters → DNS Rewrites → Add**:
   | Domain | Answer |
   |--------|--------|
   | `*.myserver.lan` | `192.168.1.50` |
5. Set your router's DNS to `192.168.1.50` (or set it per-device)

---

## Access Your Services

| Service           | URL                         |
| ----------------- | --------------------------- |
| Immich (Photos)   | http://images.myserver.lan  |
| Traefik Dashboard | http://192.168.1.50:8080    |
| AdGuard Admin     | http://192.168.1.50:3000    |
| SSH               | `ssh youruser@myserver.lan` |

---

## Updating

To pull the latest images and restart:

```bash
cd ~/server
./update.sh
```

---

## File Structure

```
~/server/                  # Config (git-tracked)
├── docker-compose.yml
├── .env                   # Your secrets (NOT in git)
├── .env.example
├── setup.sh
└── update.sh

~/docker_data/             # Persistent data (NOT in git, back this up!)
├── adguard/
├── immich/                # Your photos
└── postgres/
```

---

## Adding More Services

Edit `docker-compose.yml` and add your service. Example pattern:

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
    - "traefik.http.services.myapp.loadbalancer.server.port=8080"
    - "traefik.http.routers.myapp.entrypoints=web"
```

Then add a DNS rewrite in AdGuard for `myapp.myserver.lan`.

---

## Troubleshooting

**Can't access `.myserver.lan` URLs?**

- Ensure your device is using AdGuard as its DNS server
- Check AdGuard DNS Rewrites are configured
- Try `nslookup images.myserver.lan 192.168.1.50`

**Port 53 already in use?**

- The setup script should handle this, but you can manually disable systemd-resolved:
  ```bash
  sudo systemctl disable systemd-resolved
  sudo systemctl stop systemd-resolved
  ```

**Docker permission denied?**

- Log out and back in (or reboot) after running setup.sh

**Check container status:**

```bash
docker compose ps
docker compose logs -f          # All logs
docker compose logs -f immich   # Specific service
```
