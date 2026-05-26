// Ollama Bearer-token auth sidecar for the DARKO / EISA Homelab.
//
// Purpose: validate `Authorization: Bearer <token>` against a SHA-256-hashed
// allow-list. Caddy's forward_auth directive calls this service before
// proxying to ollama:11434.
//
// Two ways to declare valid tokens, both supported simultaneously:
//
//   1. Hashed file at /tokens/tokens.json - issued/rotated by
//      `files/scripts/ollama-token.ps1`. Plaintext never touches disk;
//      only SHA-256 hashes are stored. Reloaded automatically on mtime
//      change within ~5s.
//
//   2. Plaintext env vars (operator-friendly for one-off cloud consumers
//      like the executive-brief Cloud Run instance):
//        - OLLAMA_TOKEN_<LABEL>=<token>        per-tenant, label from var name
//        - OLLAMA_TOKENS=tok1,tok2,tok3        unlabelled, comma-separated
//      Set them in `files/.env`; docker-compose forwards via `env_file: .env`.
//      The sidecar hashes them in memory at startup, never logs the plaintext.
//      Trade-off: plaintext sits in `.env` (a `chmod 600` host file). On a
//      homelab that's an acceptable bargain for "drop a token and go".
//
// Security:
//   - Constant-time comparison via crypto.timingSafeEqual prevents
//     timing-attack token recovery.
//   - lastUsedAt is written to /tokens-runtime/last-used.json (rw mount).
//     A separate file keeps the auth-rules file fully immutable from the
//     sidecar's perspective (if /tokens-runtime is read-only, last-used
//     tracking degrades silently - auth itself is unaffected).
//   - File-based tokens reload on every request via a 5-second mtime cache.
//     New tokens take effect within 5s of `ollama-token.ps1 issue` without
//     restarting the container. Env-based tokens are read once at startup -
//     change them in `.env` and `docker compose restart ollama-auth`.
//
// Routes:
//   GET  /healthz   -> 200 OK (no auth)
//   ANY  /          -> 200 if token valid, 401 otherwise

'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 8080);
const HOST = process.env.HOST || '0.0.0.0';
const TOKENS_FILE = process.env.TOKENS_FILE || '/tokens/tokens.json';
const RUNTIME_FILE = process.env.RUNTIME_FILE || '/tokens-runtime/last-used.json';
const RELOAD_TTL_MS = 5_000;
const LASTUSED_FLUSH_MS = 10_000;

// ---------- env-declared tokens (one-shot at startup) ----------

function sha256Hex(s) {
  return crypto.createHash('sha256').update(s, 'utf8').digest('hex');
}

/**
 * Read OLLAMA_TOKEN_<LABEL>=<token> and OLLAMA_TOKENS=tok1,tok2,... from
 * the environment, hash each one, and emit them in the same shape as
 * file-backed entries. Plaintext never crosses the function boundary -
 * the returned objects only carry hashes.
 */
function loadEnvTokens() {
  const out = [];

  // Per-tenant labelled vars - e.g. OLLAMA_TOKEN_EXECUTIVE_BRIEF=...
  for (const [key, val] of Object.entries(process.env)) {
    if (!key.startsWith('OLLAMA_TOKEN_') || !val) continue;
    const trimmed = String(val).trim();
    if (!trimmed) continue;
    const rawLabel = key.slice('OLLAMA_TOKEN_'.length);
    const label = rawLabel.toLowerCase().replace(/_/g, '-');
    out.push({
      id: `env-${label}`,
      label: `env:${label}`,
      sha256: sha256Hex(trimmed),
      disabled: false,
      expiresAt: null,
    });
  }

  // Bare comma-separated list - lower-effort alternative for users who
  // just want a single token. Index becomes the label.
  const list = (process.env.OLLAMA_TOKENS || '').split(',').map((t) => t.trim()).filter(Boolean);
  list.forEach((tok, i) => {
    out.push({
      id: `env-list-${i + 1}`,
      label: `env:list-${i + 1}`,
      sha256: sha256Hex(tok),
      disabled: false,
      expiresAt: null,
    });
  });

  return out;
}

const ENV_TOKENS = loadEnvTokens();

// ---------- token cache (file-backed) ----------

let cache = { entries: [], mtimeMs: 0, loadedAt: 0 };

function loadFileTokens() {
  const now = Date.now();
  if (cache.loadedAt && now - cache.loadedAt < RELOAD_TTL_MS) return cache.entries;
  try {
    const stat = fs.statSync(TOKENS_FILE);
    if (stat.mtimeMs === cache.mtimeMs && cache.entries.length) {
      cache.loadedAt = now;
      return cache.entries;
    }
    const raw = fs.readFileSync(TOKENS_FILE, 'utf8');
    const data = JSON.parse(raw);
    const tokens = Array.isArray(data.tokens) ? data.tokens : [];
    cache = {
      entries: tokens.map((t) => ({
        id: String(t.id || ''),
        label: String(t.label || ''),
        sha256: String(t.sha256 || '').toLowerCase(),
        disabled: !!t.disabled,
        expiresAt: t.expiresAt ? Date.parse(t.expiresAt) : null,
      })).filter((t) => t.sha256.length === 64),
      mtimeMs: stat.mtimeMs,
      loadedAt: now,
    };
  } catch (err) {
    if (err.code !== 'ENOENT') {
      console.error('[ollama-auth] tokens.json load failed:', err.message);
    }
    cache = { entries: [], mtimeMs: 0, loadedAt: now };
  }
  return cache.entries;
}

/** Union of file + env-declared tokens. */
function loadTokens() {
  return [...ENV_TOKENS, ...loadFileTokens()];
}

// ---------- last-used (best-effort) ----------

let pendingUses = new Map();   // id -> ISO timestamp
let flushTimer = null;

function recordUse(id) {
  pendingUses.set(id, new Date().toISOString());
  if (!flushTimer) flushTimer = setTimeout(flushUses, LASTUSED_FLUSH_MS).unref();
}

function flushUses() {
  flushTimer = null;
  if (pendingUses.size === 0) return;
  const updates = Object.fromEntries(pendingUses);
  pendingUses = new Map();
  try {
    let existing = {};
    try { existing = JSON.parse(fs.readFileSync(RUNTIME_FILE, 'utf8')); } catch { /* first write */ }
    const merged = { ...existing, ...updates };
    fs.mkdirSync(path.dirname(RUNTIME_FILE), { recursive: true });
    fs.writeFileSync(RUNTIME_FILE, JSON.stringify(merged, null, 2));
  } catch (err) {
    // Best-effort. If the runtime path is read-only, accept silently —
    // auth itself is unaffected.
    if (err.code !== 'EACCES' && err.code !== 'EROFS') {
      console.error('[ollama-auth] last-used flush failed:', err.message);
    }
  }
}

// ---------- auth ----------

function safeEqualHex(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  if (a.length !== b.length) return false;
  try {
    return crypto.timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'));
  } catch {
    return false;
  }
}

function extractBearer(req) {
  const h = req.headers['authorization'] || req.headers['Authorization'];
  if (!h || typeof h !== 'string') return null;
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

function validate(token) {
  if (!token || typeof token !== 'string') return null;
  const hash = crypto.createHash('sha256').update(token, 'utf8').digest('hex');
  const entries = loadTokens();
  const now = Date.now();
  for (const e of entries) {
    if (e.disabled) continue;
    if (e.expiresAt && e.expiresAt < now) continue;
    if (safeEqualHex(e.sha256, hash)) return e;
  }
  return null;
}

// ---------- http ----------

const server = http.createServer((req, res) => {
  // Healthcheck path — no auth, for docker healthchecks / curl probes.
  if (req.url === '/healthz' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, tokens: loadTokens().length }));
    return;
  }
  const token = extractBearer(req);
  const match = token ? validate(token) : null;
  if (!match) {
    res.writeHead(401, {
      'Content-Type': 'application/json',
      'WWW-Authenticate': 'Bearer realm="ollama", error="invalid_token"',
    });
    res.end(JSON.stringify({ error: 'unauthorized' }));
    return;
  }
  recordUse(match.id);
  res.writeHead(200, { 'Content-Type': 'application/json', 'X-Token-Label': match.label });
  res.end(JSON.stringify({ ok: true }));
});

server.listen(PORT, HOST, () => {
  const fileCount = loadFileTokens().length;
  const envCount = ENV_TOKENS.length;
  const envLabels = ENV_TOKENS.map((t) => t.label).join(', ') || '(none)';
  console.log(
    `[ollama-auth] listening on http://${HOST}:${PORT}`
    + ` (file-tokens=${fileCount} env-tokens=${envCount})`,
  );
  if (envCount > 0) console.log(`[ollama-auth] env-token labels: ${envLabels}`);
});

process.on('SIGTERM', () => { flushUses(); server.close(() => process.exit(0)); });
process.on('SIGINT',  () => { flushUses(); server.close(() => process.exit(0)); });
