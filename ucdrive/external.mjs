// External-mode UC cloud drive client: direct HTTPS to pc-api.uc.cn using the
// cached WSG credential set. No UC process required at call time.
//
// Endpoint classes (measured 2026-10-28):
//   plaintext externally — mkdir/rename/move/delete/recycle/search/quota/
//     member/behavior/formupload-pre/upload-finish*/general_search
//   wg-encrypted externally — file/sort, file/category, file/download,
//     upload/finish → routed to page mode by the CLI (or avoided via
//     general_search for listing).
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { basename, extname } from 'node:path';

const MIME = {
  '.txt': 'text/plain', '.md': 'text/markdown', '.json': 'application/json',
  '.pdf': 'application/pdf', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp',
  '.svg': 'image/svg+xml', '.mp4': 'video/mp4', '.mp3': 'audio/mpeg',
  '.zip': 'application/zip', '.gz': 'application/gzip', '.tar': 'application/x-tar',
  '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
};

export const WG_ENDPOINTS = ['/1/clouddrive/file/sort', '/1/clouddrive/file/category',
  '/1/clouddrive/file/download', '/1/clouddrive/file/upload/finish'];

let creds = null;

export function setCreds(c) {
  creds = c;
}

function q(extra = {}) {
  return new URLSearchParams({
    ve: creds.ve || '1.1.0.22', fve: creds.fve || '1.8.8',
    pr: 'UCBrowser', fr: 'mac', sys: 'darwin',
    ut: creds.ut, ch: 'pcuc@default', ...extra,
  }).toString();
}

function headers(extra = {}) {
  return {
    Accept: 'application/json, text/plain, */*',
    Cookie: `__uus=${creds.uus}`,
    'x-u-kps-wg': creds.kps_wg,
    'x-u-sign-wg': creds.sign_wg,
    'x-u-vcode': creds.vcode,
    ...extra,
  };
}

// Raw call; returns {status, json?, wgBody?}. Throws StaleCreds on 401.
export class StaleCreds extends Error {
  constructor(body) {
    super('凭证已失效（401），需要重新从 UC 抓取：ucdrive login');
    this.code = 'STALE_CREDS';
    this.body = body;
  }
}

export async function call(method, path, { params, data } = {}) {
  const url = `https://pc-api.uc.cn${path}${params ? '?' + q(params) : '?' + q()}`;
  const res = await fetch(url, {
    method,
    headers: headers(data ? { 'Content-Type': 'application/json' } : {}),
    body: data ? JSON.stringify(data) : undefined,
  });
  const text = await res.text();
  if (res.status === 401) throw new StaleCreds(text.slice(0, 200));
  if (text.startsWith('OW')) return { status: res.status, wgBody: text };
  return { status: res.status, json: JSON.parse(text) };
}

function unwrap(j) {
  // aS-style: business data may sit at .data directly or nested envelope
  const env = j?.data;
  if (env && typeof env === 'object' && env.status === 200 && env.code === 0 && 'data' in env) {
    return env.data;
  }
  return env ?? j;
}

function mapItem(f) {
  return {
    fid: f.fid, name: f.file_name, is_dir: !!f.dir,
    size: f.size ?? 0, category: f.category, format_type: f.format_type,
    updated_at: f.updated_at, pdir_fid: f.pdir_fid,
    ...(f.record_id ? { record_id: f.record_id } : {}),
  };
}

// general_search doubles as the plaintext directory listing:
//   q='' + pdir_fid=<dir> lists children; q=<kw> searches by name.
export async function list(fid = '0', { page = 1, size = 100, sort = 'updated_at:desc' } = {}) {
  const { json } = await call('GET', '/1/clouddrive/file/general_search', {
    params: { q: '', pdir_fid: String(fid), _page: page, _size: size,
      _fetch_total: 1, _sort: sort },
  });
  const data = unwrap(json);
  const items = (data?.list || []).map(mapItem);
  return { items, total: data?.total ?? items.length, page, size,
    has_more: page * size < (data?.total ?? items.length) };
}

export async function search(keyword, { page = 1, size = 50 } = {}) {
  const { json } = await call('GET', '/1/clouddrive/file/general_search', {
    params: { q: keyword, _page: page, _size: size, _fetch_total: 1,
      _sort: 'updated_at:desc' },
  });
  const data = unwrap(json);
  const items = (data?.list || []).map(mapItem);
  return { items, total: data?.total ?? items.length, page, size };
}

export async function mkdir(parentFid, name) {
  const { json } = await call('POST', '/1/clouddrive/file', {
    data: { pdir_fid: String(parentFid), file_name: name, dir_path: '', dir_init_lock: false },
  });
  return unwrap(json);
}

export async function rename(fid, newName) {
  const { json } = await call('POST', '/1/clouddrive/file/rename', {
    data: { fid: String(fid), file_name: newName },
  });
  return unwrap(json);
}

export async function move(fids, toPdirFid) {
  const { json } = await call('POST', '/1/clouddrive/file/move', {
    data: { action_type: 1, to_pdir_fid: String(toPdirFid),
      filelist: fids.map(String), exclude_fids: [] },
  });
  return unwrap(json);
}

export async function del(fids) {
  const { json } = await call('POST', '/1/clouddrive/file/delete', {
    data: { action_type: 2, filelist: fids.map(String), exclude_fids: [] },
  });
  return unwrap(json);
}

export async function taskPoll(taskId, { maxMs = 60000 } = {}) {
  // status enum: 0 todo, 1 running, 2 finish, 3 fail, 4 pause
  const deadline = Date.now() + maxMs;
  for (let i = 0; Date.now() < deadline; i++) {
    const { json } = await call('GET', '/1/clouddrive/task', {
      params: { task_id: taskId, retry_index: i },
    });
    const d = unwrap(json);
    if (d?.status === 2 || d?.finish === true || d?.finish === 1) return d;
    if (d?.status === 3) throw new Error('task failed: ' + JSON.stringify(d).slice(0, 200));
    await new Promise((r) => setTimeout(r, 1500));
  }
  throw new Error(`task ${taskId} timeout after ${maxMs}ms`);
}

export async function recycleList({ page = 1, size = 50 } = {}) {
  const { json } = await call('GET', '/1/clouddrive/file/recycle/list', {
    params: { _page: page, _size: size, _sort: 'move_recycle_at:desc' },
  });
  const data = unwrap(json);
  return { total: data?.total ?? 0, page, size,
    items: (data?.list || []).map(mapItem) };
}

export async function recycleRecover(recordIds) {
  const { json } = await call('POST', '/1/clouddrive/file/recycle/recover', {
    data: { select_mode: 2, only_recycle: false, record_list: recordIds.map(String) },
  });
  return unwrap(json);
}

export async function recyclePurge(recordIds) {
  const { json } = await call('POST', '/1/clouddrive/file/recycle/remove', {
    data: { select_mode: 2, record_list: recordIds.map(String) },
  });
  return unwrap(json);
}

export async function quota() {
  const { json } = await call('POST', '/1/clouddrive/quota/info', {
    data: { dlt_keys: ['uc_nor_dlt'] },
  });
  return unwrap(json);
}

export async function fileInfo(fid) {
  const { json } = await call('GET', '/1/clouddrive/file/info', {
    params: { fid: String(fid), _fetch_full_path: 1 },
  });
  return unwrap(json);
}

export async function resolvePath(path) {
  const clean = String(path || '').replace(/^\/+|\/+$/g, '');
  if (!clean) return { fid: '0', name: 'root', is_dir: true };
  let cur = { fid: '0', name: 'root', is_dir: true };
  for (const seg of clean.split('/')) {
    const { items } = await list(cur.fid, { size: 200 });
    const hit = items.find((i) => i.name === seg);
    if (!hit) {
      const e = new Error(`path not found: ${clean} (missing "${seg}")`);
      e.code = 'PATH_NOT_FOUND';
      throw e;
    }
    cur = hit;
  }
  return cur;
}

// ---------- upload (3-step, fully external) ----------
export async function hashesOf(filePath) {
  const buf = readFileSync(filePath);
  return {
    sha1: createHash('sha1').update(buf).digest('hex'),
    md5: createHash('md5').update(buf).digest('hex'),
    size: buf.length,
    buf,
  };
}

export async function uploadFile({ localPath, destFid, name }) {
  const { sha1, md5, size, buf } = await hashesOf(localPath);
  if (size > 64 * 1024 * 1024) throw new Error(`file ${size}B exceeds 64MB simple-upload limit`);
  const fileName = name || basename(localPath);
  const formatType = MIME[extname(fileName).toLowerCase()] || 'application/octet-stream';
  const st = await import('node:fs/promises').then((m) => m.stat(localPath));
  const { json } = await call('POST', '/1/clouddrive/file/formupload/pre', {
    data: {
      sha1, md5, size, pdir_fid: String(destFid), file_name: fileName,
      format_type: formatType, dir_name: '', same_path_reuse: false,
      l_created_at: Math.round(st.birthtimeMs) || Date.now(),
      l_updated_at: Math.round(st.mtimeMs) || Date.now(),
      file_local_path: localPath,
    },
  });
  const pre = unwrap(json);
  if (pre?.finish) return { fid: pre.fid, rapid: true };

  if (!pre?.upload_auth) {
    const e = new Error('formupload/pre returned no upload_auth (wg body?)');
    e.code = 'WG_BODY';
    throw e;
  }
  const fd = new FormData();
  fd.append('key', pre.obj_key);
  fd.append('policy', pre.upload_auth.policy);
  fd.append('OSSAccessKeyId', pre.upload_auth.key_id);
  fd.append('success_action_status', '200');
  fd.append('signature', pre.upload_auth.auth_key);
  if (pre.callback) {
    fd.append('callback', Buffer.from(JSON.stringify(pre.callback)).toString('base64'));
  }
  fd.append('file', new Blob([buf], { type: formatType }), fileName);
  const ul = await fetch(pre.upload_url, { method: 'POST', body: fd });
  if (!ul.ok) throw new Error(`UL upload HTTP ${ul.status}: ${(await ul.text()).slice(0, 200)}`);
  // upload/finish response is wg externally; the UL 200 already persists the
  // object. Confirm via listing; call finish only if the file is absent.
  await new Promise((r) => setTimeout(r, 1000));
  const check = await list(destFid, { size: 50 });
  const landed = check.items.find((i) => i.name === fileName);
  if (landed) return { fid: landed.fid, rapid: false };
  // not listed yet — try finish (wg response → page fallback needed)
  const e = new Error('UPFINISH_CONFIRM: UL 已 200 但列表未见到文件，需页面模式确认 finish');
  e.code = 'UPFINISH_CONFIRM';
  throw e;
}

// ---------- chunked upload (>=8MB): init via page, parts+complete external ----------
// Protocol (reverse-engineered from UC bundle, verified live):
//   POST /1/clouddrive/file/upload/pre {pdir_fid, dir_name, size, file_name,
//     format_type, same_path_reuse:false, ccp_hash_update:false,
//     parallel_upload:false, md5, sha1, l_created_at, l_updated_at,
//     file_local_path} → wg-encrypted externally → done via page mode.
//     Response: {upload_id, obj_key, upload_url, bucket, task_id, auth_info,
//     callback}, metadata: {part_size, part_thread}.
//   Per part: canonical "PUT\n\ncontent-type\nx-oss-date\nx-oss-*...\n/bucket/obj_key?query"
//     → POST /1/clouddrive/file/upload/auth {task_id, auth_info, auth_meta}
//     → auth_key (PLAINTEXT externally, verified).
//   PUT https://<bucket>.<host>/<obj_key>?partNumber=N&uploadId=X
//     headers: authorization, x-oss-date, x-oss-user-agent, Content-Type.
//     (x-oss-hash-ctx only needed when init used ccp_hash_update:true.)
//   Complete: POST ...?uploadId=X, body=CompleteMultipartUpload XML,
//     headers Content-MD5(b64 of xml), x-oss-callback(b64 json), authorization.
//     Canonical line 2 MUST be the xml md5. Real file md5/sha1 in init are
//     validated by UC's callback — placeholders fail with CallbackFailed.

export function buildOssUrl(pre, params = {}) {
  const url = new URL(pre.obj_key, pre.upload_url.replace('http:', 'https:'));
  url.hostname = `${pre.bucket}.${url.hostname}`;
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  url.searchParams.sort();
  return url;
}

export async function ossAuth(method, url, pre, { contentType = '', contentMd5 = '', extraXoss = {} } = {}) {
  const xoss = { 'x-oss-date': new Date().toUTCString(),
    'x-oss-user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
    ...extraXoss };
  const lines = [method, contentMd5, contentType, xoss['x-oss-date']];
  for (const k of Object.keys(xoss).sort()) lines.push(`${k}:${xoss[k]}`);
  lines.push(`/${pre.bucket}${url.pathname}${url.search}`);
  const { json } = await call('POST', '/1/clouddrive/file/upload/auth', {
    data: { task_id: pre.task_id, auth_info: pre.auth_info, auth_meta: lines.join('\n') },
  });
  const key = unwrap(json)?.auth_key;
  if (!key) throw new Error('upload/auth returned no auth_key');
  return { authKey: key, xoss };
}

export async function chunkedUploadParts({ pre, buf, partSize, onProgress }) {
  const parts = Math.ceil(buf.length / partSize);
  const etags = [];
  for (let n = 1; n <= parts; n++) {
    const start = (n - 1) * partSize;
    const chunk = buf.subarray(start, Math.min(start + partSize, buf.length));
    const url = buildOssUrl(pre, { partNumber: String(n), uploadId: pre.upload_id });
    const { authKey, xoss } = await ossAuth('PUT', url, pre, { contentType: 'application/octet-stream' });
    const resp = await fetch(url, { method: 'PUT', headers: {
      'Content-Type': 'application/octet-stream',
      'x-oss-date': xoss['x-oss-date'],
      'x-oss-user-agent': xoss['x-oss-user-agent'],
      authorization: authKey,
    }, body: chunk });
    const etag = resp.headers.get('etag');
    if (!etag) throw new Error(`part ${n} PUT ${resp.status}: ${(await resp.text()).slice(0, 150)}`);
    etags.push({ number: n, etag });
    onProgress?.(n, parts);
  }
  return etags;
}

export async function chunkedComplete({ pre, etags }) {
  const xml = '<?xml version="1.0" encoding="UTF-8"?>\n<CompleteMultipartUpload>\n' +
    etags.map((p) => `<Part>\n<PartNumber>${p.number}</PartNumber>\n<ETag>${p.etag}</ETag>\n</Part>\n`).join('') +
    '</CompleteMultipartUpload>';
  const url = buildOssUrl(pre, { uploadId: pre.upload_id });
  const xmlMd5 = createHash('md5').update(xml, 'utf8').digest('base64');
  const callbackB64 = Buffer.from(JSON.stringify(pre.callback), 'utf8').toString('base64');
  const { authKey, xoss } = await ossAuth('POST', url, pre, {
    contentType: 'application/xml', contentMd5: xmlMd5,
    extraXoss: { 'x-oss-callback': callbackB64 },
  });
  const resp = await fetch(url, { method: 'POST', headers: {
    'Content-Type': 'application/xml', 'Content-MD5': xmlMd5,
    'x-oss-callback': callbackB64, 'x-oss-date': xoss['x-oss-date'],
    'x-oss-user-agent': xoss['x-oss-user-agent'],
    authorization: authKey,
  }, body: xml });
  const text = await resp.text();
  if (resp.status !== 200) {
    throw new Error(`complete ${resp.status}: ${text.slice(0, 200)}`);
  }
  return text;
}
