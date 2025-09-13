# StreamJelly — Jellyfin Overlay for OBS (Now Playing)

**StreamJelly** is a self-hosted **Jellyfin overlay for OBS** that shows **NOW PLAYING** with album art, title/artist, and a live progress bar.  
_"New Neon Edition — Your Jellyfin tracks, your OBS overlay."_

## Quick Start (Docker)
```bash
git clone https://github.com/YOURORG/streamjelly.git
cd streamjelly
cp server/.env.example server/.env   # set JF_BASE, JF_TOKEN, JF_USER
sudo docker compose up -d --build
```

OBS Browser Source → http://<server-ip>:8080/overlay

Admin UI → http://<server-ip>:8080/admin

## Caddy (Auto-TLS)
```bash
sudo apt-get install -y caddy
sudo cp caddy/Caddyfile.sample /etc/caddy/Caddyfile
# edit domain in /etc/caddy/Caddyfile
sudo systemctl reload caddy
# Use: https://overlay.yourdomain.tld/overlay in OBS
```

## Env Vars (server/.env)
```
PORT=8080
JF_BASE=https://YOUR-JELLYFIN-URL
JF_TOKEN=YOUR_API_KEY
JF_USER=your_username
JF_CLIENT=Jellyfin Media Player
JF_DEVICE=
POLL_MS=1200
THEME_ACCENT=#ff3b30
THEME_ACCENT2=#ff6b6b
THEME_ACCENT3=#ff9a8b
LABEL_NOW=NOW PLAYING
LABEL_PAUSE=PAUSED
```

## How it works

Server polls Jellyfin `/Sessions`, broadcasts updates via SSE; the overlay page renders art/title/artist/progress. Secrets never touch OBS.

## Build & Run

### Docker (recommended)
```bash
cp server/.env.example server/.env
# edit server/.env: set JF_BASE, JF_TOKEN, JF_USER
sudo docker compose up -d --build
curl -fsSL http://localhost:8080/healthz
```

### systemd (optional, no Docker)
```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs git
cd server && npm ci && cd ..
sudo rsync -a . /opt/streamjelly/
sudo cp systemd/streamjelly.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now streamjelly
```

### Caddy (preferred reverse proxy)
```bash
sudo apt-get install -y caddy
sudo cp caddy/Caddyfile.sample /etc/caddy/Caddyfile
# edit overlay.yourdomain.tld -> your domain (DNS must point here)
sudo systemctl reload caddy
# OBS URL becomes: https://overlay.yourdomain.tld/overlay
```

## License

MIT
