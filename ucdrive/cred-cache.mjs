// WSG credential extraction (via CDP network-layer capture) + local cache.
//
// The credential set that authorizes OUTSIDE-UC calls:
//   ut         — URL param, stable across restarts
//   __uus      — cookie injected by UC's network stack per-request
//   x-u-kps-wg — header added by UC's native WSG module (session-scoped)
//   x-u-sign-wg— header, session-scoped
//   x-u-vcode  — header, session-scoped
// None of these are readable from JS or the cookie store; they are only
// observable on the wire, so we capture one real request's ExtraInfo headers
// through CDP and cache the result.
import { mkdirSync, readFileSync, writeFileSync, existsSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { setTimeout as sleep } from 'node:timers/promises';
import { CDP_HTTP, ensure_uc, ensure_page, close_page_socket } from './uc.mjs';

// Cross-platform per-user app-data dir (macOS / Windows / Linux XDG).
const CACHE_DIR = join(homedir(), ...process.platform === 'win32'
  ? ['AppData', 'Roaming', 'uc-drive-mcp']
  : process.platform === 'darwin'
    ? ['Library', 'Application Support', 'uc-drive-mcp']
    : ['.local', 'share', 'uc-drive-mcp']);
// Pre-cross-platform macOS-only path; kept as read fallback for old caches.
const LEGACY_DIR = join(homedir(), 'Library', 'Application Support', 'uc-drive-mcp');
const CACHE_FILE = join(CACHE_DIR, 'credentials.json');

async function httpGetJson(path) {
  const res = await fetch(`${CDP_HTTP}${path}`);
  if (!res.ok) throw new Error(`CDP ${path} -> HTTP ${res.status}`);
  return res.json();
}

async function pageSend(ws, id, method, params) {
  return new Promise((resolve, reject) => {
    const onmsg = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id === id) {
        ws.removeEventListener('message', onmsg);
        m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result);
      }
    };
    ws.addEventListener('message', onmsg);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

// Capture one real cloud-drive API request's ExtraInfo headers.
async function captureFromNetwork() {
  await ensure_uc();
  const targets = await httpGetJson('/json');
  const page = targets.find(
    (t) => t.type === 'page' && (t.url || '').startsWith('chrome://cloud-drive'));
  if (!page) throw new Error('NO_CLOUD_DRIVE_PAGE: 打开 UC 网盘页面后重试');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('page ws fail')); });
  try {
    await pageSend(ws, 1, 'Network.enable', {});
    // trigger a listing request via the refresh icon (falls back to hash nav)
    await pageSend(ws, 2, 'Runtime.evaluate', {
      expression: `(() => {
        const el = [...document.querySelectorAll('svg,div,span')].find(e =>
          /fl-refresh/.test((e.className && e.className.baseVal !== undefined ? e.className.baseVal : e.className) || ''));
        if (el) { el.click(); return 'clicked'; }
        location.hash = '#/list/all';
        return 'hash';
      })()`,
      returnByValue: true,
    });
    // listen for ExtraInfo with the WSG headers
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const raw = await Promise.race([
        new Promise((res) => {
          const onmsg = (ev) => {
            const m = JSON.parse(ev.data);
            if (m.method === 'Network.requestWillBeSentExtraInfo') {
              const h = m.params?.headers || {};
              if (h['x-u-sign-wg'] && h['x-u-kps-wg']) {
                ws.removeEventListener('message', onmsg);
                res(h);
              }
            }
          };
          ws.addEventListener('message', onmsg);
          setTimeout(() => { ws.removeEventListener('message', onmsg); res(null); }, 3000);
        }),
        sleep(3200),
      ]);
      if (raw) {
        const cookie = (raw.cookie || Object.entries(raw)
          .find(([k]) => k.toLowerCase() === 'cookie')?.[1] || '');
        const uus = /(?:^|;\s*)__uus=([^;]+)/.exec(cookie)?.[1];
        if (!uus) continue; // a request without __uus; keep listening
        return {
          ut: null, // filled by caller from ucParams (page JS) below
          uus,
          kps_wg: raw['x-u-kps-wg'],
          sign_wg: raw['x-u-sign-wg'],
          vcode: raw['x-u-vcode'],
          captured_at: new Date().toISOString(),
        };
      }
    }
    throw new Error('WSG_HEADERS_TIMEOUT: 15s 内未观察到云盘 API 请求');
  } finally {
    try { ws.close(); } catch { /* noop */ }
  }
}

// Grab ut from the page's JS bridge (needs page ready).
async function captureUt() {
  const { eval_js } = await import('./uc.mjs');
  const raw = await eval_js(`(async () => {
    const p = await chrome.publicParamsPrivate.ucParams('utprfrvech');
    return JSON.stringify({ ut: p.data.ut, ve: p.data.ve, fve: p.data.fve });
  })()`, { timeoutMs: 30000 });
  return JSON.parse(raw);
}

export async function captureCredentials() {
  await ensure_page();
  const [net, utInfo] = await Promise.all([
    captureFromNetwork(),
    captureUt(),
  ]);
  const creds = { ...net, ut: utInfo.ut, ve: utInfo.ve, fve: utInfo.fve };
  saveCache(creds);
  return creds;
}

function saveCache(creds) {
  mkdirSync(CACHE_DIR, { recursive: true });
  writeFileSync(CACHE_FILE, JSON.stringify(creds, null, 1));
  chmodSync(CACHE_FILE, 0o600);
}

export function loadCache() {
  for (const f of [CACHE_FILE, join(LEGACY_DIR, 'credentials.json')]) {
    if (!existsSync(f)) continue;
    try {
      return JSON.parse(readFileSync(f, 'utf8'));
    } catch {
      /* try next */
    }
  }
  return null;
}

export function cachePath() {
  return CACHE_FILE;
}

// One-stop: cached creds, or capture fresh (requires UC running with the
// cloud-drive page). Callers treat 401 as "cache stale → recapture".
export async function getCredentials({ refresh = false } = {}) {
  if (!refresh) {
    const cached = loadCache();
    if (cached?.ut && cached?.uus && cached?.kps_wg) return cached;
  }
  return captureCredentials();
}

export { close_page_socket };
