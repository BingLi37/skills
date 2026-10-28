// CDP connection management for the UC cloud-drive WebUI page.
//
// The cloud drive page (chrome://cloud-drive) hosts the axios stack with the
// WSG auth/decrypt interceptors, so every drive API call is executed inside
// that page via Runtime.evaluate. This module owns the websocket to the page
// target and re-establishes it when the context is destroyed (reload/nav).
import { setTimeout as sleep } from 'node:timers/promises';
import { accessSync } from 'node:fs';

const CDP_PORT = process.env.UC_CDP_PORT || '9223';
export const CDP_HTTP = `http://127.0.0.1:${CDP_PORT}`;

let pageWs = null;        // websocket to the cloud-drive page target
let pageId = null;
let evalSeq = 0;
const pending = new Map(); // id -> resolve

async function httpGetJson(path) {
  const res = await fetch(`${CDP_HTTP}${path}`);
  if (!res.ok) throw new Error(`CDP ${path} -> HTTP ${res.status}`);
  return res.json();
}

export function cdpPort() {
  return CDP_PORT;
}

// Is any UC listening on the debug port?
export async function ucReachable() {
  try {
    const v = await httpGetJson('/json/version');
    return { ok: true, browser: v.Browser };
  } catch {
    return { ok: false };
  }
}

// Windows/macOS install paths probed in order; first hit wins.
const UC_CANDIDATES = process.platform === 'win32' ? [
  'D:/Program Files (x86)/UC浏览器/uc.exe',
  'C:/Program Files (x86)/UC浏览器/uc.exe',
  'C:/Program Files/UCBrowser/uc.exe',
] : ['/Applications/UC.app/Contents/MacOS/UC'];

function findUcBin() {
  for (const p of UC_CANDIDATES) {
    try { accessSync(p); return p; } catch { /* next */ }
  }
  return null;
}

// Launch UC with the debug port. Returns when the port answers.
export async function launch_uc() {
  const { spawn } = await import('node:child_process');
  const ucBin = findUcBin();
  if (!ucBin) {
    throw new Error('UC_NOT_FOUND: 未找到 UC 浏览器安装路径，请手动以 --remote-debugging-port='
      + CDP_PORT + ' 启动 UC，或设置环境变量 UC_PATH 指向 uc.exe/UC');
  }
  const ucPath = process.env.UC_PATH || ucBin;
  // graceful quit first, so relaunch picks up the flag
  try {
    const killer = process.platform === 'win32'
      ? spawn('taskkill', ['/IM', 'uc.exe'], { shell: true })
      : spawn('osascript', ['-e', 'tell application "UC" to quit']);
    await new Promise((r) => killer.on('close', r));
    await sleep(2500);
  } catch { /* maybe not running */ }
  if (process.platform === 'darwin') {
    spawn('open', ['-a', ucPath, '--args',
      '--remote-debugging-port', CDP_PORT,
      '--remote-allow-origins', '*'], { detached: true, stdio: 'ignore' }).unref();
  } else {
    spawn(ucPath, ['--remote-debugging-port', CDP_PORT,
      '--remote-allow-origins', '*'], { detached: true, stdio: 'ignore' }).unref();
  }
  for (let i = 0; i < 20; i++) {
    await sleep(1000);
    const st = await ucReachable();
    if (st.ok) return st;
  }
  throw new Error('UC did not come up with the CDP port within 20s');
}

export async function ensure_uc() {
  const st = await ucReachable();
  if (st.ok) return st;
  return launch_uc();
}

// Find (or create) the cloud-drive page target.
export async function find_page_target({ create = true } = {}) {
  let targets = await httpGetJson('/json');
  let page = targets.find(
    (t) => t.type === 'page' && (t.url || '').startsWith('chrome://cloud-drive'));
  if (!page && create) {
    // browser-level ws to create the target
    const ver = await httpGetJson('/json/version');
    const ws = new WebSocket(ver.webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
    const id = await new Promise((res) => {
      const mid = Math.floor(Math.random() * 1e9);
      const onmsg = (ev) => {
        const m = JSON.parse(ev.data);
        if (m.id === mid) { ws.removeEventListener('message', onmsg); res(m); }
      };
      ws.addEventListener('message', onmsg);
      ws.send(JSON.stringify({ id: mid, method: 'Target.createTarget',
        params: { url: 'chrome://cloud-drive/#/list/all' } }));
    });
    ws.close();
    if (id.error) throw new Error('Target.createTarget failed: ' + JSON.stringify(id.error));
    // wait for it to appear
    for (let i = 0; i < 15; i++) {
      await sleep(1000);
      targets = await httpGetJson('/json');
      page = targets.find(
        (t) => t.type === 'page' && (t.url || '').startsWith('chrome://cloud-drive'));
      if (page) break;
    }
    if (!page) throw new Error('cloud-drive target created but not listed');
  }
  if (!page) return null;
  return page;
}

function wire(ws) {
  ws.addEventListener('message', (ev) => {
    let m;
    try { m = JSON.parse(ev.data); } catch { return; }
    if (m.id && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id);
      pending.delete(m.id);
      if (m.error) reject(new Error(JSON.stringify(m.error)));
      else resolve(m.result);
    }
  });
  ws.addEventListener('close', () => {
    if (pageWs === ws) pageWs = null;
    for (const [, { reject }] of pending) reject(new Error('PAGE_WS_CLOSED'));
    pending.clear();
  });
}

async function send(method, params) {
  const ws = pageWs;
  const id = ++evalSeq; // CDP requires integer ids
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
}

// Connect to the cloud-drive page target (replacing any old socket).
export async function connect_page() {
  const page = await find_page_target();
  if (!page) throw new Error('NO_CLOUD_DRIVE_PAGE');
  pageId = page.id;
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => {
    ws.onopen = res;
    ws.onerror = () => rej(new Error('page ws connect failed'));
  });
  wire(ws);
  pageWs = ws;
  // prime: wait until the page is loaded enough for webpack to exist
  await eval_js(`(async () => {
    for (let i = 0; i < 100; i++) {
      if (self.webpackChunkuc_cloud_drive) return 'ready';
      await new Promise(r => setTimeout(r, 200));
    }
    throw new Error('webpack chunk not present after 20s — 云盘页面未加载完成或未登录');
  })()`, { timeoutMs: 30000 });
  return pageId;
}

export async function ensure_page() {
  if (pageWs) {
    try {
      // cheap liveness probe
      await send('Runtime.evaluate', { expression: '1', returnByValue: true });
      return pageId;
    } catch { pageWs = null; }
  }
  return connect_page();
}

// Evaluate an async JS expression in the page and return its string result.
// Retries once with a fresh connection when the context was destroyed.
export async function eval_js(expr, { timeoutMs = 60000 } = {}) {
  for (let attempt = 0; attempt < 2; attempt++) {
    await ensure_page();
    try {
      const r = await Promise.race([
        send('Runtime.evaluate', {
          expression: expr, returnByValue: true, awaitPromise: true,
          userGesture: true,
        }),
        sleep(timeoutMs).then(() => { throw new Error(`evaluate timeout after ${timeoutMs}ms`); }),
      ]);
      if (r.exceptionDetails) {
        const ex = r.exceptionDetails.exception || {};
        throw new Error(ex.description || ex.value || 'page evaluate exception');
      }
      const v = r.result.value;
      if (typeof v === 'string') return v;
      return JSON.stringify(v ?? null);
    } catch (e) {
      const msg = String(e && e.message || e);
      pageWs = null; // force reconnect for next attempt
      if (attempt === 1 || !/PAGE_WS_CLOSED|timeout|Target closed|WebSocket/i.test(msg)) {
        throw e;
      }
    }
  }
  throw new Error('unreachable');
}

export async function close_page_socket() {
  if (pageWs) { try { pageWs.close(); } catch { /* noop */ } pageWs = null; }
}
