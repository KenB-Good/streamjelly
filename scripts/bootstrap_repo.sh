#!/usr/bin/env bash
set -euo pipefail

mkdir -p .
cat <<'EOF' > LICENSE
MIT License

Copyright (c) 2025 WeirdDucks Studio

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

mkdir -p .
cat <<'EOF' > README.md
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

OBS Browser Source → http://<server-ip>:8080/<your_user>/overlay
# If SIGN_KEY is set, append ?sig=$(printf <your_user> | openssl dgst -sha256 -hmac "$SIGN_KEY" -binary | xxd -p -c256)

Admin UI → http://<server-ip>:8080/admin

## Caddy (Auto-TLS)
```bash
sudo apt-get install -y caddy
sudo cp caddy/Caddyfile.sample /etc/caddy/Caddyfile
# edit domain in /etc/caddy/Caddyfile
sudo systemctl reload caddy
# Use: https://overlay.yourdomain.tld/<your_user>/overlay?sig=... in OBS
```

## Env Vars (server/.env)
```
PORT=8080
JF_BASE=https://YOUR-JELLYFIN-URL
JF_TOKEN=YOUR_API_KEY
JF_USER=your_username            # optional; per-user URLs override
JF_CLIENT=Jellyfin Media Player
JF_DEVICE=
POLL_MS=1200
SIGN_KEY=
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
EOF

mkdir -p .
cat <<'EOF' > CONTRIBUTING.md
# Contributing
- PRs welcome. Keep changes focused and under ~400 lines when possible.
- Dev: `npm --prefix server ci && npm --prefix server start`
- Please avoid committing `.env` or secrets.
EOF

mkdir -p server
cat <<'EOF' > server/package.json
{
  "name": "streamjelly",
  "version": "0.1.0",
  "type": "module",
  "private": false,
  "scripts": {
    "start": "node server/index.js",
    "dev": "NODE_ENV=development node server/index.js"
  },
  "dependencies": {
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "undici": "^6.19.8"
  }
}
EOF

mkdir -p server
cat <<'EOF' > server/.env.example
PORT=8080

# Jellyfin connection (server-side only)
JF_BASE=https://YOUR-JELLYFIN-URL
JF_TOKEN=YOUR_API_KEY
JF_USER=your_username            # optional; overridden by per-user URLs
JF_CLIENT=Jellyfin Media Player
JF_DEVICE=
POLL_MS=1200

# Signed per-user URLs (optional)
SIGN_KEY=

# Theme: New Neon Edition
THEME_ACCENT=#ff3b30
THEME_ACCENT2=#ff6b6b
THEME_ACCENT3=#ff9a8b
LABEL_NOW=NOW PLAYING
LABEL_PAUSE=PAUSED
EOF

mkdir -p server
cat <<'EOF' > server/index.js
import 'dotenv/config';
import express from 'express';
import { fetch } from 'undici';
import path from 'node:path';
import { setInterval as every } from 'node:timers';
import { createHmac } from 'node:crypto';

const app = express();
app.use(express.json());
app.use('/public', express.static(path.join(process.cwd(), 'server', 'public')));

/* ---- config ---- */
const cfg = {
  port: parseInt(process.env.PORT || '8080', 10),
  jfBase: process.env.JF_BASE,
  jfToken: process.env.JF_TOKEN,
  jfUser: (process.env.JF_USER || '').toLowerCase(),
  jfClient: process.env.JF_CLIENT || 'Jellyfin Media Player',
  jfDevice: process.env.JF_DEVICE || '',
  pollMs: parseInt(process.env.POLL_MS || '1200', 10),
  signKey: process.env.SIGN_KEY || '',
  theme: {
    accent: process.env.THEME_ACCENT || '#ff3b30',
    accent2: process.env.THEME_ACCENT2 || '#ff6b6b',
    accent3: process.env.THEME_ACCENT3 || '#ff9a8b',
    labelNow: process.env.LABEL_NOW || 'NOW PLAYING',
    labelPause: process.env.LABEL_PAUSE || 'PAUSED'
  }
};

const headers = {
  'Authorization': `MediaBrowser Client="StreamJelly", Device="Overlay-Server", DeviceId="streamjelly", Version="0.1", Token="${cfg.jfToken}"`,
  'X-MediaBrowser-Token': cfg.jfToken,
  'Accept': 'application/json'
};

const clients = new Map(); // user -> Set<res>
const lastPayload = new Map();

/* ---- helpers ---- */
async function fetchNowPlaying(user) {
  const r = await fetch(`${cfg.jfBase}/Sessions?ActiveWithinSeconds=180`, { headers, cache: 'no-store' });
  if (!r.ok) throw new Error(`Jellyfin HTTP ${r.status}`);
  const sessions = await r.json();
  const s = sessions.find(x =>
    x?.UserName?.toLowerCase() === user &&
    x?.Client === cfg.jfClient &&
    (!cfg.jfDevice || x?.DeviceName === cfg.jfDevice) &&
    x?.NowPlayingItem?.MediaType === 'Audio'
  );
  if (!s) return null;

  const it = s.NowPlayingItem || {};
  const title = it.Name || 'Unknown';
  const artist = it.AlbumArtist || (Array.isArray(it.Artists) ? it.Artists[0] : '') || '';
  const artTag = it?.ImageTags?.Primary;
  const albumId = it?.AlbumId;
  const artUrl = artTag
    ? `${cfg.jfBase}/Items/${it.Id}/Images/Primary?tag=${artTag}&maxWidth=256&quality=85`
    : (albumId ? `${cfg.jfBase}/Items/${albumId}/Images/Primary?maxWidth=256&quality=85` : '');

  const runtimeSec = (it.RunTimeTicks ?? 0) / 1e7;
  const positionSec = (s.PlayState?.PositionTicks ?? 0) / 1e7;
  const paused = !!s.PlayState?.IsPaused;

  return { title, artist, artUrl, runtimeSec, positionSec, paused, ts: Date.now() };
}
function sign(u) {
  return createHmac('sha256', cfg.signKey).update(u).digest('hex');
}

function resolveUser(req, res) {
  const user = (req.params.user || cfg.jfUser || '').toLowerCase();
  if (!user) { res.status(400).json({ error: 'user required' }); return null; }
  if (cfg.signKey) {
    const sig = String(req.query.sig || '');
    if (sig !== sign(user)) { res.status(403).json({ error: 'bad signature' }); return null; }
  }
  return user;
}

function broadcast(user, obj) {
  const data = `data: ${JSON.stringify(obj)}\n\n`;
  const set = clients.get(user);
  if (!set) return;
  for (const res of set) res.write(data);
}

/* ---- polling & stream ---- */
every(cfg.pollMs, async () => {
  for (const user of clients.keys()) {
    try {
      const cur = await fetchNowPlaying(user);
      const serialized = JSON.stringify(cur);
      if (serialized !== lastPayload.get(user)) {
        lastPayload.set(user, serialized);
        broadcast(user, { type: 'nowplaying', payload: cur });
      }
    } catch (e) {
      broadcast(user, { type: 'error', message: e.message });
    }
  }
});

/* ---- endpoints ---- */
app.get(['/api/nowplaying', '/:user/api/nowplaying'], async (req, res) => {
  const user = resolveUser(req, res); if (!user) return;
  try { res.json(await fetchNowPlaying(user)); }
  catch (e) { res.status(500).json({ error: String(e) }); }
});

app.get(['/api/nowplaying/stream', '/:user/api/nowplaying/stream'], (req, res) => {
  const user = resolveUser(req, res); if (!user) return;
  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'Access-Control-Allow-Origin': '*'
  });
  res.flushHeaders();
  res.write('retry: 1000\n\n');
  let set = clients.get(user);
  if (!set) { set = new Set(); clients.set(user, set); }
  set.add(res);
  req.on('close', () => {
    set.delete(res);
    if (!set.size) { clients.delete(user); lastPayload.delete(user); }
  });
});

/* theme config (no auth; recommend gating via Caddy) */
app.get(['/api/config', '/:user/api/config'], (_req, res) => res.json(cfg.theme));
app.put(['/api/config', '/:user/api/config'], (req, res) => {
  const t = req.body || {};
  cfg.theme = { ...cfg.theme, ...t };
  // broadcast theme to all users
  for (const u of clients.keys()) broadcast(u, { type: 'theme', payload: cfg.theme });
  res.json(cfg.theme);
});

/* health */
app.get('/healthz', (_req, res) => res.json({ ok: true }));

/* pages */
app.get(['/overlay', '/:user/overlay'], (req, res) => {
  const user = resolveUser(req, res); if (!user) return;
  res.sendFile(path.join(process.cwd(), 'server', 'public', 'overlay.html'));
});

app.get('/admin', (_req, res) =>
  res.sendFile(path.join(process.cwd(), 'server', 'public', 'admin.html')));

app.listen(cfg.port, () => {
  console.log(`StreamJelly listening on http://0.0.0.0:${cfg.port}`);
});
EOF

mkdir -p server/public
cat <<'EOF' > server/public/overlay.html
<!doctype html><meta charset="utf-8" />
<style>
  :root{ --accent:#ff3b30; --accent2:#ff6b6b; --accent3:#ff9a8b;
         --pad:12px; --radius:14px; --bg:rgba(10,10,10,.55); --text:#fff; --muted:#e7e7e7; --art:72px }
  html,body{margin:0;padding:0;background:transparent}
  #wrap{position:fixed;left:24px;bottom:24px;display:flex;align-items:center;gap:12px;
        padding:var(--pad);border-radius:var(--radius);background:var(--bg);color:var(--text);
        box-shadow:0 8px 24px rgba(0,0,0,.35),0 0 16px rgba(255,59,48,.25);
        -webkit-backdrop-filter:saturate(1.2) blur(6px);backdrop-filter:saturate(1.2) blur(6px);
        font:600 16px/1.2 system-ui,-apple-system,"Segoe UI",Inter,Arial,sans-serif;opacity:0;transition:opacity .25s}
  #art{width:var(--art);height:var(--art);border-radius:10px;overflow:hidden;background:#222;outline:2px solid rgba(255,59,48,.35);outline-offset:2px}
  #art img{width:100%;height:100%;object-fit:cover;display:block}
  #meta{min-width:280px;max-width:620px;display:flex;flex-direction:column;gap:6px}
  #label{font:800 11px/1 system-ui;letter-spacing:.12em;color:#fff;align-self:flex-start;padding:4px 10px;border-radius:999px;text-transform:uppercase;
         background:linear-gradient(90deg,var(--accent),var(--accent2));box-shadow:0 2px 12px rgba(255,59,48,.35),inset 0 -1px 0 rgba(0,0,0,.2)}
  #title{font-weight:800;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #artist{font-weight:500;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #bar{position:relative;height:8px;border-radius:6px;background:rgba(255,255,255,.18);overflow:hidden}
  #fill{position:absolute;inset:0 auto 0 0;width:0%;background:linear-gradient(90deg,var(--accent),var(--accent2),var(--accent3));opacity:.95}
  #time{display:flex;justify-content:space-between;font:600 12px/1 system-ui;color:var(--muted)}
  #err{position:fixed;left:24px;bottom:calc(24px + var(--art) + 60px);font:12px system-ui;color:#f66;opacity:.9}
</style>
<div id="wrap">
  <div id="art"><img alt=""></div>
  <div id="meta">
    <div id="label">NOW PLAYING</div>
    <div id="title"></div>
    <div id="artist"></div>
    <div id="bar"><div id="fill"></div></div>
    <div id="time"><span id="cur">0:00</span><span id="dur">0:00</span></div>
  </div>
</div>
<div id="err"></div>
<script>
  const wrap=document.querySelector('#wrap'), err=document.querySelector('#err');
  const img=document.querySelector('#art img'), titleEl=document.querySelector('#title'), artistEl=document.querySelector('#artist');
  const fill=document.querySelector('#fill'), curEl=document.querySelector('#cur'), durEl=document.querySelector('#dur'), labelEl=document.querySelector('#label');

  let runtimeSec=0, positionSec=0, paused=true, lastT=0;
  const fmt=s=>{s=Math.max(0,Math.floor(s));const m=Math.floor(s/60),n=s%60;return `${m}:${n.toString().padStart(2,'0')}`;}
  function paint(){ const pct=runtimeSec>0?Math.min(100,(positionSec/runtimeSec)*100):0; fill.style.width=`${pct}%`; curEl.textContent=fmt(positionSec); durEl.textContent=fmt(runtimeSec); }
  function animate(t){ if(!paused && runtimeSec>0){ if(lastT) positionSec+=(t-lastT)/1000; positionSec=Math.min(positionSec,runtimeSec); paint(); } lastT=t; requestAnimationFrame(animate); }
  requestAnimationFrame(animate);

  const qs=location.search||'';
  async function loadTheme(){ try{
    const t=await (await fetch('api/config'+qs,{cache:'no-store'})).json();
    document.documentElement.style.setProperty('--accent',t.accent||'#ff3b30');
    document.documentElement.style.setProperty('--accent2',t.accent2||'#ff6b6b');
    document.documentElement.style.setProperty('--accent3',t.accent3||'#ff9a8b');
  }catch{} } loadTheme();

  const es=new EventSource('api/nowplaying/stream'+qs);
  es.onmessage=(e)=>{ try{
    const {type,payload}=JSON.parse(e.data);
    if(type==='nowplaying'){
      if(!payload){ wrap.style.opacity=0; return; }
      titleEl.textContent=payload.title||'Unknown';
      artistEl.textContent=payload.artist||'';
      if(payload.artUrl) img.src=payload.artUrl;
      runtimeSec=payload.runtimeSec||0; positionSec=payload.positionSec||0; paused=!!payload.paused;
      labelEl.textContent = paused ? 'PAUSED' : 'NOW PLAYING';
      paint(); wrap.style.opacity=1; err.textContent='';
    } else if(type==='theme'){
      const t=payload||{};
      if(t.accent)  document.documentElement.style.setProperty('--accent', t.accent);
      if(t.accent2) document.documentElement.style.setProperty('--accent2', t.accent2);
      if(t.accent3) document.documentElement.style.setProperty('--accent3', t.accent3);
      labelEl.textContent = paused ? (t.labelPause||'PAUSED') : (t.labelNow||'NOW PLAYING');
    }
  }catch{ err.textContent='Stream parse error'; } };
  es.onerror=()=>{ err.textContent='Stream disconnected'; wrap.style.opacity=0; };
</script>
EOF

mkdir -p server/public
cat <<'EOF' > server/public/admin.html
<!doctype html><meta charset="utf-8" />
<style>
  body{font:14px/1.4 system-ui,Segoe UI,Inter;margin:24px;color:#111}
  label{display:block;margin:8px 0 4px}
  input[type="text"],input[type="color"]{padding:8px;border:1px solid #ccc;border-radius:8px;width:260px}
  button{margin-top:12px;padding:10px 14px;border:0;border-radius:10px;background:#111;color:#fff;font-weight:700;cursor:pointer}
  .row{display:flex;gap:24px;flex-wrap:wrap}
</style>
<h2>StreamJelly — Admin</h2>
<div class="row">
  <div><label>Accent</label><input id="accent" type="color" value="#ff3b30"></div>
  <div><label>Accent 2</label><input id="accent2" type="color" value="#ff6b6b"></div>
  <div><label>Accent 3</label><input id="accent3" type="color" value="#ff9a8b"></div>
  <div><label>Label (Now)</label><input id="labelNow" type="text" value="NOW PLAYING"></div>
  <div><label>Label (Paused)</label><input id="labelPause" type="text" value="PAUSED"></div>
</div>
<button id="save">Save & Broadcast</button>
<script>
  async function load(){ const t=await (await fetch('"'"'/api/config'"'"',{cache:'"'"'no-store'"'"'})).json();
    for (const k of ['"'"'accent'"'"','"'"'accent2'"'"','"'"'accent3'"'"','"'"'labelNow'"'"','"'"'labelPause'"'"']) {
      if (t[k]) document.getElementById(k).value = t[k];
    }
  } load();

  document.getElementById('"'"'save'"'"').onclick = async ()=>{
    const body = {};
    for (const k of ['"'"'accent'"'"','"'"'accent2'"'"','"'"'accent3'"'"','"'"'labelNow'"'"','"'"'labelPause'"'"']) body[k]=document.getElementById(k).value;
    await fetch('"'"'/api/config'"'"',{method:'"'"'PUT'"'"',headers:{'"'"'Content-Type'"'"':'"'"'application/json'"'"'},body:JSON.stringify(body)});
    alert('"'"'Updated!'"'"');
  };
</script>
EOF

mkdir -p .
cat <<'EOF' > Dockerfile
FROM node:20-alpine
WORKDIR /app
COPY server/package.json server/package-lock.json* ./server/
RUN cd server && npm ci --omit=dev
COPY server ./server
ENV NODE_ENV=production
CMD ["npm","--prefix","server","start"]
EOF

mkdir -p .
cat <<'EOF' > docker-compose.yml
services:
  streamjelly:
    build: .
    image: streamjelly:0.1
    container_name: streamjelly
    ports: ["8080:8080"]
    env_file: server/.env
    restart: unless-stopped
    volumes:
      - ./server/public:/app/server/public:ro
      - ./server/.env:/app/server/.env:ro
EOF

mkdir -p caddy
cat <<'EOF' > caddy/Caddyfile.sample
# Replace with your domain; set DNS A/AAAA to this host first.
overlay.yourdomain.tld {
  encode zstd gzip
  header {
    # helpful for overlays & SSE
    Cache-Control "no-store"
  }
  reverse_proxy 127.0.0.1:8080
  # Example OBS URL:
  #   https://overlay.yourdomain.tld/<user>/overlay?sig=...
}
EOF

mkdir -p systemd
cat <<'EOF' > systemd/streamjelly.service
[Unit]
Description=StreamJelly (Jellyfin Overlay for OBS)
After=network.target

[Service]
Type=simple
Environment=NODE_ENV=production
WorkingDirectory=/opt/streamjelly/server
ExecStart=/usr/bin/npm start
Restart=always
User=www-data
Group=www-data

[Install]
WantedBy=multi-user.target
EOF

mkdir -p scripts
cat <<'EOF' > scripts/install_docker.sh
#!/usr/bin/env bash
set -euo pipefail
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
 https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
| sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
echo "Docker ready."
EOF

mkdir -p scripts
cat <<'EOF' > scripts/install_caddy.sh
#!/usr/bin/env bash
set -euo pipefail
sudo apt-get update -y
sudo apt-get install -y caddy
echo "Caddy installed. Copy caddy/Caddyfile.sample to /etc/caddy/Caddyfile, set your domain, then:"
echo "  sudo systemctl reload caddy"
EOF

chmod +x scripts/install_docker.sh scripts/install_caddy.sh scripts/bootstrap_repo.sh
