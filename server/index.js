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
