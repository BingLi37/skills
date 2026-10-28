// UC cloud drive API surface, executed inside the chrome://cloud-drive page.
//
// Every call runs through the page's own webpack axios module (module id
// probed at runtime) so the request interceptor injects ve/fve/pr/fr/sys/ut/ch
// and the response interceptor decrypts "wg" bodies. See
// .trellis/tasks/10-27-uc-cloud-disk-api-analysis/research/api-reference.md
import { eval_js } from './uc.mjs';

// JS source that (re)acquires the webpack require and resolves the axios
// wrapper module by scanning chunks for the module exporting `aS` + `Em`
// (ids change between versions; the export shape is the stable contract).
const SHIM = `
  (self.__ucMcpShim = self.__ucMcpShim || {})._find = () => {
    if (self.__ucMcpShim.api) return self.__ucMcpShim;
    let req;
    const probe = 'ucmcp_' + Math.floor(performance.now());
    (self.webpackChunkuc_cloud_drive = self.webpackChunkuc_cloud_drive || []).push([[probe], {}, (r) => { req = r; }]);
    if (!req) throw new Error('webpack require unavailable');
    let api = null, cfg = null;
    // axios wrapper module exports: Em/aS/RZ/fw/r9
    for (let id = 60000; id < 90000 && !api; id++) {
      try {
        const m = req(id);
        if (m && typeof m.aS === 'function' && typeof m.Em === 'function' &&
            typeof m.RZ === 'function') { api = m; break; }
      } catch { /* module id gaps are normal */ }
    }
    if (!api) throw new Error('axios wrapper module not found');
    // config module exporting A.cloudDriveUrl
    for (let id = 1000; id < 90000 && !cfg; id++) {
      try {
        const m = req(id);
        if (m && m.A && typeof m.A.cloudDriveUrl === 'string') { cfg = m.A; break; }
      } catch { /* skip */ }
    }
    if (!cfg) throw new Error('cloudDriveUrl config module not found');
    self.__ucMcpShim.api = api;
    self.__ucMcpShim.cfg = cfg;
    return self.__ucMcpShim;
  };
`;

function wrap(body) {
  return `(async () => {
    ${SHIM}
    const { api, cfg } = self.__ucMcpShim._find();
    ${body}
  })()`;
}

// Raw call: [err, resp] tuple via aS. Returns the parsed JSON envelope.
export async function call(method, pathOrUrl, { params, data, headers, retry, timeoutMs } = {}) {
  const body = wrap(`
    const opts = { method: ${JSON.stringify(method)} };
    opts.url = ${JSON.stringify(pathOrUrl)}.startsWith('http')
      ? ${JSON.stringify(pathOrUrl)}
      : \`$\{cfg.cloudDriveUrl\}${pathOrUrl}\`;
    if (${JSON.stringify(params ?? null)}) opts.params = ${JSON.stringify(params ?? null)};
    if (${JSON.stringify(data ?? null)}) {
      opts.data = (typeof ${JSON.stringify(data ?? null)} === 'string')
        ? JSON.parse(${JSON.stringify(data ?? null)})
        : ${JSON.stringify(data ?? null)};
      opts.headers = { 'Content-Type': 'application/json', ...(opts.headers||{}) };
    }
    ${headers ? `opts.headers = { ...opts.headers, ...${JSON.stringify(headers)} };` : ''}
    ${retry ? `opts.retry = ${retry}; opts.interval = 500;` : ''}
    const [err, resp] = await api.aS(opts);
    return JSON.stringify({
      err: err ? { message: String(err.message || err).slice(0, 500) } : null,
      status: resp?.status ?? null,
      data: resp?.data ?? null,
      metadata: resp?.metadata ?? null,
    });
  `);
  const raw = await eval_js(body, { timeoutMs: timeoutMs ?? 60000 });
  const parsed = JSON.parse(raw);
  if (parsed.err) {
    const e = new Error(parsed.err.message);
    e.ucError = true;
    throw e;
  }
  return parsed;
}

export function unwrap(parsed) {
  // aS already unwraps the UC envelope for most endpoints (resp.data ===
  // business data). Some still return a nested {status, code, data} envelope;
  // unwrap only that shape.
  const env = parsed.data;
  if (env && typeof env === 'object' && env.status === 200 && env.code === 0
    && 'data' in env) {
    return env.data;
  }
  return env;
}

export async function list(fid = '0', { page = 1, size = 100, sort = 'updated_at:desc' } = {}) {
  const parsed = await call('GET', '/1/clouddrive/file/sort', {
    params: { pdir_fid: String(fid), _page: page, _size: size,
      _fetch_total: 1, _fetch_sub_dirs: 0, _sort: sort },
    timeoutMs: 45000,
  });
  const data = unwrap(parsed);
  const items = (data?.list || []).map((f) => ({
    fid: f.fid,
    name: f.file_name,
    is_dir: !!f.dir || f.category === 0 && f.file_type === 0 || f.file_type === 0 && f.size === 0 && !!f.include_items,
    size: f.size ?? 0,
    category: f.category,
    format_type: f.format_type,
    updated_at: f.updated_at,
    created_at: f.created_at ?? f.l_created_at,
    pdir_fid: f.pdir_fid,
  }));
  // dirs in UC: file_type 0 + include_items present, or explicit flag
  for (const it of items) {
    it.is_dir = it.is_dir === true;
  }
  return { items, total: data?.total ?? parsed.metadata?.total ?? items.length,
    page, size, has_more: page * size < (data?.total ?? items.length) };
}

export async function mkdir(parentFid, name) {
  const parsed = await call('POST', '/1/clouddrive/file', {
    data: { pdir_fid: String(parentFid), file_name: name, dir_path: '', dir_init_lock: false },
    retry: 1,
  });
  return unwrap(parsed); // { fid, finish }
}

export async function rename(fid, newName) {
  const parsed = await call('POST', '/1/clouddrive/file/rename', {
    data: { fid: String(fid), file_name: newName },
  });
  return unwrap(parsed);
}

export async function move(fids, toPdirFid) {
  const parsed = await call('POST', '/1/clouddrive/file/move', {
    data: { action_type: 1, to_pdir_fid: String(toPdirFid),
      filelist: fids.map(String), exclude_fids: [] },
  });
  return unwrap(parsed);
}

export async function del(fids) {
  const parsed = await call('POST', '/1/clouddrive/file/delete', {
    data: { action_type: 2, filelist: fids.map(String), exclude_fids: [] },
  });
  return unwrap(parsed);
}

export async function search(q, { page = 1, size = 50 } = {}) {
  const parsed = await call('GET', '/2/clouddrive/file/search', {
    params: { q, _page: page, _size: size, _fetch_total: 1,
      _sort: 'updated_at:desc', _is_hl: 1 },
    timeoutMs: 45000,
  });
  const data = unwrap(parsed);
  return {
    total: data?.total ?? parsed.metadata?.total ?? data?.list?.length ?? 0,
    page, size,
    items: (data?.list || data?.file_list || []).map(mapItem) };
}

function mapItem(f) {
  return {
    fid: f.fid, name: f.file_name, is_dir: !!f.dir,
    size: f.size ?? 0, category: f.category, format_type: f.format_type,
    updated_at: f.updated_at, pdir_fid: f.pdir_fid,
  };
}

export async function taskPoll(taskId, { intervalMs = 1000, maxMs = 60000 } = {}) {
  // task status enum (bundle): 0 todo, 1 running, 2 finish, 3 fail, 4 pause
  const FINISH = 2, FAIL = 3;
  const deadline = Date.now() + maxMs;
  let retry = 0;
  while (Date.now() < deadline) {
    const parsed = await call('GET', '/1/clouddrive/task', {
      params: { task_id: taskId, retry_index: retry++ }, timeoutMs: 30000,
    });
    const data = unwrap(parsed);
    const st = data?.status;
    if (st === FINISH || data?.finish === true || data?.finish === 1) return data;
    if (st === FAIL || data?.fail === true) {
      throw new Error('task failed: ' + JSON.stringify(data).slice(0, 300));
    }
    await new Promise((r) => setTimeout(r, parsed.metadata?.tq_gap ?? intervalMs));
  }
  throw new Error(`task ${taskId} did not finish within ${maxMs}ms`);
}

export async function recycleList({ page = 1, size = 50 } = {}) {
  const parsed = await call('GET', '/1/clouddrive/file/recycle/list', {
    params: { _page: page, _size: size, _sort: 'move_recycle_at:desc' },
    timeoutMs: 45000,
  });
  const data = unwrap(parsed);
  return { total: data?.total ?? 0, page, size,
    items: (data?.list || []).map((f) => ({ ...mapItem(f),
      record_id: f.record_id, obj_key: f.obj_key,
      move_recycle_at: f.move_recycle_at })) };
}

// Recycle operate bodies follow the bundle contract:
//   recover: {select_mode:2, only_recycle:false, record_list:[...]}
//   remove:  {select_mode:2, record_list:[...]}
// record ids come from recycleList items (record_id field).
export async function recycleRecover(recordIds) {
  const parsed = await call('POST', '/1/clouddrive/file/recycle/recover', {
    data: { select_mode: 2, only_recycle: false,
      record_list: recordIds.map(String) },
    timeoutMs: 60000,
  });
  return unwrap(parsed);
}

export async function recyclePurge(recordIds) {
  const parsed = await call('POST', '/1/clouddrive/file/recycle/remove', {
    data: { select_mode: 2, record_list: recordIds.map(String) },
    timeoutMs: 60000,
  });
  return unwrap(parsed);
}

export async function quota() {
  const parsed = await call('POST', '/1/clouddrive/quota/info', {
    data: { dlt_keys: ['uc_nor_dlt'] }, timeoutMs: 30000,
  });
  return unwrap(parsed);
}

export async function fileInfo(fid, { fetchFullPath = 1 } = {}) {
  const parsed = await call('GET', '/1/clouddrive/file/info', {
    params: { fid: String(fid), _fetch_full_path: fetchFullPath },
    timeoutMs: 30000,
  });
  return unwrap(parsed);
}

// Resolve a slash path ("/a/b/c") to a fid by walking list(). "" or "/" -> "0".
export async function resolvePath(path) {
  const clean = String(path || '').replace(/^\/+|\/+$/g, '');
  if (!clean) return { fid: '0', name: 'root' };
  let cur = '0';
  let curItem = { fid: '0', name: 'root', is_dir: true };
  for (const seg of clean.split('/')) {
    const { items } = await list(cur, { size: 200 });
    const hit = items.find((i) => i.name === seg);
    if (!hit) {
      const e = new Error(`path not found: ${clean} (missing "${seg}")`);
      e.ucCode = 'PATH_NOT_FOUND';
      throw e;
    }
    curItem = hit;
    cur = hit.fid;
  }
  return curItem;
}

// Download: fetch signed URL then return it (body fetched separately by caller,
// or inline below for small files). file/download returns array of URL records.
export async function downloadUrls(fids) {
  const parsed = await call('POST', '/1/clouddrive/file/download', {
    data: { fids: fids.map(String) }, timeoutMs: 60000,
  });
  return unwrap(parsed);
}
