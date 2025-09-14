# StreamJelly — Jellyfin Overlay for OBS (Now Playing)

**StreamJelly** is a self-hosted **Jellyfin overlay for OBS** that shows **NOW PLAYING** with album art, title/artist, and a live progress bar.
_"New Neon Edition — Your Jellyfin tracks, your OBS overlay."_

## For StreamJelly community members
In OBS → Browser Source → URL:
https://overlay.yourdomain.tld/overlay?user=<your-jellyfin-username>[&sig=<signature>]
Suggested size: Width 820, Height 220. Done.
Some links may include `&sig=` and should be copied intact.

## For creators/self-hosters

### Quick Start (Docker)
```bash
git clone https://github.com/YOURORG/streamjelly.git
cd streamjelly
cp server/.env.example server/.env   # set JF_BASE, JF_TOKEN, JF_USER
sudo docker compose up -d --build
```

OBS Browser Source → http://<server-ip>:8080/overlay

Admin UI → http://<server-ip>:8080/admin

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

### Caddy (Auto-TLS)
```bash
sudo apt-get install -y caddy
sudo cp caddy/Caddyfile.sample /etc/caddy/Caddyfile
# edit domain in /etc/caddy/Caddyfile
sudo systemctl reload caddy
# Use: https://overlay.yourdomain.tld/overlay in OBS
```

### Env Vars (server/.env)
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
JF_USERS_ALLOW=kenbee
OVERLAY_SIGNING_KEY=
```

* `JF_USERS_ALLOW` — comma-separated Jellyfin usernames allowed to use `/overlay`.
* `OVERLAY_SIGNING_KEY` — optional key for URL signatures; if set, `/overlay` and `/api/nowplaying` require `?sig=<hmac>` (`HMAC_SHA256(user,key)`).

### Signed links (optional)
```bash
# Generate a signature (hex) for ?user=<name>
node -e 'const c=require("crypto");const [,,key,u]=process.argv;console.log(c.createHmac("sha256",key).update(u).digest("hex"))' <OVERLAY_SIGNING_KEY> <user>
```

### Troubleshooting
```bash
# Jellyfin reachability (from server)
curl -H "X-MediaBrowser-Token: $JF_TOKEN" "$JF_BASE/Sessions?ActiveWithinSeconds=180"
# SSE sanity
curl -N "http://localhost:8080/api/nowplaying/stream?user=<you>"
```

## Why StreamJelly

StreamJelly delivers DMCA-safe, Jellyfin-backed overlays so creators can show now playing info without risking takedowns.

## How it works

Server polls Jellyfin `/Sessions`, broadcasts updates via SSE; the overlay page renders art/title/artist/progress. Secrets never touch OBS.

## License

MIT
