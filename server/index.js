import 'dotenv/config';
import express from 'express';
import { fetch } from 'undici';
import path from 'node:path';
import crypto from 'node:crypto';

const app = express();
app.use(express.json());
app.use('/public', express.static(path.join(process.cwd(), 'server', 'public')));

/* ---- config ---- */
const cfg = {
  port: parseInt(process.env.PORT || '8080', 10),
  jfBase: process.env.JF_BASE,
  jfToken: process.env.JF_TOKEN,
  jfClient: process.env.JF_CLIENT || 'Jellyfin Media Player',
  pollMs: parseInt(process.env.POLL_MS || '1200', 10),
  theme: {
    accent: process.env.THEME_ACCENT || '#ff3b30',
    accent2: process.env.THEME_ACCENT2 || '#ff6b6b',
    accent3: process.env.THEME_ACCENT3 || '#ff9a8b',
    labelNow: process.env.LABEL_NOW || 'NOW PLAYING',
    labelPause: process.env.LABEL_PAUSE || 'PAUSED'
  }
};

const allowed = new Set((process.env.JF_USERS_ALLOW || '')
  .split(',').map(s => s.trim().toLowerCase()).filter(Boolean));

function verifySig(user, sig) {
  const key = process.env.OVERLAY_SIGNING_KEY || '';
  if (!key) return true;
  if (!sig) return false;
  const hex = crypto.createHmac('sha256', key).update(user).digest('hex');
  return sig === hex || sig === Buffer.from(hex, 'hex').toString('base64');
}

function pickUser(req) {
  const user = (req.query.user || '').toLowerCase();
  const sig = req.query.sig || '';
  const client = req.query.client || cfg.jfClient;
  const device = req.query.device || '';
  if (!user) throw Object.assign(new Error('Missing ?user='), { status: 400 });
  if (allowed.size && !allowed.has(user)) throw Object.assign(new Error('User not allowed'), { status: 403 });
  if (!verifySig(user, sig)) throw Object.assign(new Error('Invalid signature'), { status: 403 });
  return { user, client, device };
}

const headers = {
  'Authorization': `MediaBrowser Client="StreamJelly", Device="Overlay-Server", DeviceId="streamjelly", Version="0.1", Token="${cfg.jfToken}"`,
  'X-MediaBrowser-Token': cfg.jfToken,
  'Accept': 'application/json'
};

/* ---- helpers ---- */
async function fetchNowPlayingFor({ user, client, device }) {
  const r = await fetch(`${cfg.jfBase}/Sessions?ActiveWithinSeconds=180`, { headers, cache: 'no-store' });
  if (!r.ok) throw new Error(`Jellyfin HTTP ${r.status}`);
  const sessions = await r.json();
  const s = sessions.find(x =>
    x?.UserName?.toLowerCase() === user &&
    x?.Client === client &&
    (!device || x?.DeviceName === device) &&
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

/* ---- endpoints ---- */
app.get('/api/nowplaying', async (req, res) => {
  try {
    const info = pickUser(req);
    res.json(await fetchNowPlayingFor(info));
  } catch (e) {
    res.status(e.status || 500).json({ error: String(e.message || e) });
  }
});

app.get('/api/nowplaying/stream', (req, res) => {
  let ctx;
  try { ctx = pickUser(req); }
  catch (e) { return res.status(e.status || 500).json({ error: String(e.message || e) }); }
  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'Access-Control-Allow-Origin': '*'
  });
  res.flushHeaders();
  res.write('retry: 1000\n\n');
  let last = '';
  const timer = setInterval(async () => {
    try {
      const cur = await fetchNowPlayingFor(ctx);
      const serialized = JSON.stringify(cur);
      if (serialized !== last) {
        last = serialized;
        res.write(`data: ${JSON.stringify({ type:'nowplaying', payload: cur })}\n\n`);
      }
    } catch (err) {
      res.write(`data: ${JSON.stringify({ type:'error', message: String(err) })}\n\n`);
    }
  }, cfg.pollMs);
  req.on('close', () => clearInterval(timer));
});

/* theme config (no auth; recommend gating via Caddy) */
app.get('/api/config', (_req, res) => res.json(cfg.theme));
app.put('/api/config', (req, res) => {
  const t = req.body || {};
  cfg.theme = { ...cfg.theme, ...t };
  res.json(cfg.theme);
});

/* health */
app.get('/healthz', (_req, res) => res.json({ ok: true }));

/* pages */
app.get('/overlay', (_req, res) =>
  res.sendFile(path.join(process.cwd(), 'server', 'public', 'overlay.html')));

app.get('/admin', (_req, res) =>
  res.sendFile(path.join(process.cwd(), 'server', 'public', 'admin.html')));

app.listen(cfg.port, () => {
  console.log(`StreamJelly listening on http://0.0.0.0:${cfg.port}`);
});
