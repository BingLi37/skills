#!/usr/bin/env node
// ucdrive — CLI for the UC cloud drive (external mode first, page fallback).
//
// Design: every subcommand prints JSON on stdout, errors on stderr with
// {error:{code,message,hint}}. Modes:
//   external (default) — cached WSG creds, no UC process needed
//   page               — CDP through the cloud-drive page (wg endpoints,
//                        download, credential capture)
// Stale credentials (401) auto-trigger recapture when UC is reachable.
import { getCredentials, captureCredentials, cachePath, close_page_socket } from './cred-cache.mjs';
import * as ex from './external.mjs';
import { StaleCreds } from './external.mjs';

const [, , cmd, ...rest] = process.argv;

function usage() {
  console.error(`ucdrive — UC 网盘命令行

用法: ucdrive <command> [args] [-j key=value ...]

登录/凭证:
  login                  抓取凭证到本地缓存（需 UC 网盘页面开着）
  whoami                 显示当前缓存凭证状态（不打印值）

操作（路径或 fid 均可; 路径以 / 开头，根目录为 /）:
  list [path] [-j page=N size=N sort=S]     列目录
  tree [path] [-j depth=N max=N]            递归目录树
  mkdir <path>                              多级建目录（幂等）
  rename <path|fid> <new_name>              重命名
  move <src,...> <dest_dir>                 批量移动
  delete <path,...> [--purge] [--no-wait]   删除到回收站（--purge 彻底删除）
  search <keyword>                          按名搜索
  upload <local_path> <dest_dir>            上传（<=64MB）
  download <path|fid> <local_path>          下载（页面模式）
  recycle [page]                            回收站列表
  restore <record_id,...>                   回收站恢复
  purge <record_id,...>                     回收站彻底删除
  quota                                     配额
  info <path|fid>                           单条目详情
  page-call <METHOD> <path> [-j k=v ...]    页面模式透传调用（wg 端点逃生门）
`);
  process.exit(2);
}

// parse trailing -j k=v pairs
function parseFlags(args) {
  const out = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '-j') {
      const [k, v] = args[++i].split('=');
      out[k] = isNaN(Number(v)) ? v : Number(v);
    }
  }
  return out;
}

function out(data) {
  console.log(JSON.stringify(data, null, 1));
}

function fail(code, message, hint) {
  console.error(JSON.stringify({ error: { code, message, ...(hint ? { hint } : {}) } }));
  process.exit(1);
}

// resolve "path" or bare fid argument to {fid, ...item}
async function resolve(arg) {
  if (/^[\da-f]{32}$/i.test(arg)) return { fid: arg };
  return ex.resolvePath(arg);
}

async function withExternal(fn) {
  const creds = await getCredentials();
  ex.setCreds(creds);
  try {
    return await fn();
  } catch (e) {
    if (e instanceof StaleCreds) {
      // try one recapture (UC may be running)
      try {
        const fresh = await captureCredentials();
        ex.setCreds(fresh);
        return await fn();
      } catch (e2) {
        fail('STALE_CREDS', e.message,
          `UC 未运行或云盘页面未开。打开 UC 网盘页面后运行: ucdrive login（缓存: ${cachePath()}） [inner: ${e2.message.slice(0, 80)}]`);
      }
    }
    throw e;
  }
}

async function pageEval(expr, timeoutMs = 90000) {
  const { eval_js } = await import('./uc.mjs');
  return eval_js(expr, { timeoutMs });
}

// Wrap a page-axios call for wg endpoints.
async function pageCall(method, path, params = {}, data = null) {
  return withPage(async () => {
    const raw = await pageEval(`(async () => {
      const id = 'ucmcp_' + Math.floor(performance.now());
      let req; (self.webpackChunkuc_cloud_drive = self.webpackChunkuc_cloud_drive || []).push([[id], {}, (r) => { req = r; }]);
      let api = self.__ucMcpShim?.api;
      if (!api) {
        for (let mid = 60000; mid < 90000 && !api; mid++) {
          try { const m = req(mid);
            if (m && typeof m.aS === 'function' && typeof m.Em === 'function' && typeof m.RZ === 'function') { api = m; break; } } catch {}
        }
        if (!api) throw new Error('axios module not found');
        self.__ucMcpShim = self.__ucMcpShim || {}; self.__ucMcpShim.api = api;
      }
      let cfg = self.__ucMcpShim.cfg;
      if (!cfg) {
        for (let mid = 1000; mid < 90000 && !cfg; mid++) {
          try { const m = req(mid);
            if (m && m.A && typeof m.A.cloudDriveUrl === 'string') { cfg = m.A; break; } } catch {}
        }
        self.__ucMcpShim.cfg = cfg;
      }
      const [err, resp] = await api.aS({
        method: ${JSON.stringify(method)},
        url: \`$\{cfg.cloudDriveUrl\}${path}\`,
        ${params && Object.keys(params).length ? `params: ${JSON.stringify(params)},` : ''}
        ${data ? `data: ${JSON.stringify(data)}, headers: {'Content-Type': 'application/json'},` : ''}
      });
      return JSON.stringify({ err: err ? String(err.message || err).slice(0, 300) : null,
        data: resp?.data ?? null, metadata: resp?.metadata ?? null });
    })()`);
    const parsed = JSON.parse(raw);
    if (parsed.err) fail('UC_API', parsed.err);
    out(parsed);
  });
}

import { ensure_uc, ensure_page } from './uc.mjs';
async function withPage(fn) {
  await ensure_uc();
  await ensure_page();
  return fn();
}

// ---------- subcommands ----------
try {
  switch (cmd) {
    case 'login': {
      const c = await captureCredentials();
      out({ ok: true, cached_at: c.captured_at, cache: cachePath(),
        note: '凭证已缓存；ut 稳定，WSG 头过期时调用会报 STALE_CREDS，重新 login 即可' });
      break;
    }
    case 'whoami': {
      const c = await getCredentials().catch(() => null);
      out(c ? { cached: true, captured_at: c.captured_at, ut_len: c.ut?.length,
        uus_len: c.uus?.length, cache: cachePath() }
        : { cached: false, hint: '运行 ucdrive login（需 UC 网盘页面开着）' });
      break;
    }
    case 'list': {
      const [arg] = rest; const f = parseFlags(rest);
      out(await withExternal(async () => {
        const dir = arg ? await resolve(arg) : { fid: '0' };
        return ex.list(dir.fid, { page: f.page || 1, size: f.size || 100, sort: f.sort || 'updated_at:desc' });
      }));
      break;
    }
    case 'tree': {
      const [arg] = rest; const f = parseFlags(rest);
      const depth = f.depth || 3, maxNodes = f.max || 300;
      out(await withExternal(async () => {
        const root = arg ? await resolve(arg) : { fid: '0', name: 'root' };
        let count = 0;
        const walk = async (dirFid, name, d) => {
          if (d > depth || count >= maxNodes) return { name, truncated: true, children: [] };
          const { items } = await ex.list(dirFid, { size: 100 });
          count += items.length;
          const node = { name, children: [] };
          for (const it of items.filter((i) => i.is_dir)) {
            if (count >= maxNodes) { node.children.push({ truncated: true }); break; }
            node.children.push(await walk(it.fid, it.name, d + 1));
          }
          node.files = items.filter((i) => !i.is_dir).map((i) => i.name);
          return node;
        };
        return walk(root.fid, root.name || arg || 'root', 1);
      }));
      break;
    }
    case 'mkdir': {
      const [path] = rest;
      if (!path) usage();
      out(await withExternal(async () => {
        const clean = String(path).replace(/^\/+|\/+$/g, '');
        if (!clean) fail('BAD_PATH', 'path 不能为空');
        let cur = { fid: '0' };
        for (const seg of clean.split('/')) {
          const { items } = await ex.list(cur.fid, { size: 200 });
          const hit = items.find((i) => i.name === seg && i.is_dir);
          if (hit) { cur = hit; continue; }
          const created = await ex.mkdir(cur.fid, seg);
          cur = { fid: created.fid || created.fid };
        }
        return { fid: cur.fid, path: '/' + clean };
      }));
      break;
    }
    case 'rename': {
      const [arg, newName] = rest;
      if (!arg || !newName) usage();
      out(await withExternal(async () => {
        const item = await resolve(arg);
        return ex.rename(item.fid, newName);
      }));
      break;
    }
    case 'move': {
      const [srcs, dest] = rest;
      if (!srcs || !dest) usage();
      out(await withExternal(async () => {
        const destItem = await resolve(dest);
        const fids = [];
        for (const s of srcs.split(',')) fids.push((await resolve(s.trim())).fid);
        const r = await ex.move(fids, destItem.fid);
        if (r?.task_id) await ex.taskPoll(r.task_id);
        return { moved: fids.length, dest_fid: destItem.fid };
      }));
      break;
    }
    case 'delete': {
      const args = rest.filter((a) => a !== '--purge' && a !== '--no-wait');
      const doPurge = rest.includes('--purge');
      const wait = !rest.includes('--no-wait');
      if (!args.length) usage();
      out(await withExternal(async () => {
        const fids = [];
        for (const p of args) fids.push((await resolve(p)).fid);
        const r = await ex.del(fids);
        if (wait && r?.task_id) await ex.taskPoll(r.task_id, { maxMs: 30000 });
        if (doPurge) {
          await new Promise((res) => setTimeout(res, 2500));
          const rc = await ex.recycleList({ size: 200 });
          const mine = rc.items.filter((i) => fids.includes(i.fid));
          if (mine.length) {
            const pr = await ex.recyclePurge(mine.map((i) => i.record_id));
            if (pr?.task_id) await ex.taskPoll(pr.task_id, { maxMs: 60000 });
            return { deleted: fids.length, purged: mine.length };
          }
        }
        return { deleted: fids.length, task_id: r?.task_id ?? null };
      }));
      break;
    }
    case 'search': {
      const [kw] = rest;
      if (!kw) usage();
      out(await withExternal(() => ex.search(kw, { page: parseFlags(rest).page || 1 })));
      break;
    }
    case 'upload': {
      const [local, dest] = rest;
      if (!local || !dest) usage();
      out(await withExternal(async () => {
        const d = await resolve(dest);
        const st = await import('node:fs/promises').then((m) => m.stat(local));
        if (st.size < 8 * 1024 * 1024) {
          // small file: single-request form upload, fully external
          return ex.uploadFile({ localPath: local, destFid: d.fid });
        }
        // >=8MB: chunked. Init (wg-encrypted endpoint) goes through the page;
        // auth-signing, part PUTs and complete are all external.
        const { hashesOf } = await import('./external-hashes.mjs');
        const { sha1, md5, buf } = await hashesOf(local);
        const fileName = rest.find((a) => a.startsWith('--name='))?.slice(7)
          || local.split('/').pop();
        const pre = await withPage(async () => {
          const raw = await pageEval(`(async () => {
            const id = 'ucmcp_' + Math.floor(performance.now());
            let req; (self.webpackChunkuc_cloud_drive = self.webpackChunkuc_cloud_drive || []).push([[id], {}, (r) => { req = r; }]);
            let api = self.__ucMcpShim?.api;
            if (!api) {
              for (let mid = 60000; mid < 90000 && !api; mid++) {
                try { const m = req(mid);
                  if (m && typeof m.aS === 'function' && typeof m.Em === 'function' && typeof m.RZ === 'function') { api = m; break; } } catch {}
              }
              if (!api) throw new Error('axios module not found');
              self.__ucMcpShim = self.__ucMcpShim || {}; self.__ucMcpShim.api = api;
            }
            const [err, resp] = await api.aS({ method: 'POST',
              url: (self.__ucMcpShim.cfg?.cloudDriveUrl || 'https://pc-api.uc.cn') + '/1/clouddrive/file/upload/pre',
              params: { mi: '' },
              data: ${JSON.stringify({
                pdir_fid: d.fid, dir_name: '', size: st.size, file_name: fileName,
                format_type: 'application/octet-stream', same_path_reuse: false,
                ccp_hash_update: false, parallel_upload: false,
                md5, sha1,
                l_created_at: Math.round(st.birthtimeMs) || Date.now(),
                l_updated_at: Math.round(st.mtimeMs) || Date.now(),
                file_local_path: local,
              })},
              headers: { 'Content-Type': 'application/json' } });
            if (err) throw new Error(String(err.message || err).slice(0, 300));
            return JSON.stringify({ data: resp?.data, metadata: resp?.metadata });
          })()`, 60000);
          const parsed = JSON.parse(raw);
          if (!parsed?.data?.upload_id) throw new Error('upload/pre no upload_id: ' + JSON.stringify(parsed).slice(0, 200));
          return parsed;
        });
        const partSize = pre.metadata?.part_size || 4 * 1024 * 1024;
        const etags = await ex.chunkedUploadParts({ pre: pre.data, buf, partSize,
          onProgress: (n, total) => console.error(`[progress] part ${n}/${total}`) });
        await ex.chunkedComplete({ pre: pre.data, etags });
        // confirm via listing (complete's callback is async)
        for (let i = 0; i < 10; i++) {
          await new Promise((r) => setTimeout(r, 1500));
          const { items } = await ex.list(d.fid, { size: 100 });
          const hit = items.find((it) => it.name === fileName && it.size === st.size);
          if (hit) return { fid: hit.fid, name: fileName, size: st.size,
            parts: etags.length, part_size: partSize, mode: 'chunked' };
        }
        fail('UPLOAD_CONFIRM_TIMEOUT', '分片上传已完成但列表未确认到文件，请稍后用 list 检查');
      }));
      break;
    }
    case 'download': {
      const [arg, local] = rest;
      if (!arg || !local) usage();
      // wg endpoint → page mode: file/download for the signed URL, then fetch
      // the bytes inside the page (OSS callback requires UC login context).
      // Large files: ranged fetches (32MB each) so no single eval/ws message
      // carries the whole payload.
      out(await (async () => {
        const item = await withExternal(() => resolve(arg));
        const info = await withExternal(() => ex.fileInfo(item.fid));
        const total = info?.size ?? 0;
        return withPage(async () => {
          const raw = await pageEval(`(async () => {
            const id = 'ucmcp_' + Math.floor(performance.now());
            let req; (self.webpackChunkuc_cloud_drive = self.webpackChunkuc_cloud_drive || []).push([[id], {}, (r) => { req = r; }]);
            let api = self.__ucMcpShim?.api;
            if (!api) {
              for (let mid = 60000; mid < 90000 && !api; mid++) {
                try { const m = req(mid);
                  if (m && typeof m.aS === 'function' && typeof m.Em === 'function' && typeof m.RZ === 'function') { api = m; break; } } catch {}
              }
              if (!api) throw new Error('axios module not found');
              self.__ucMcpShim = self.__ucMcpShim || {}; self.__ucMcpShim.api = api;
            }
            const [err, resp] = await api.aS({ method: 'POST',
              url: \`\${self.__ucMcpShim.cfg?.cloudDriveUrl || 'https://pc-api.uc.cn'}/1/clouddrive/file/download\`,
              data: { fids: [${JSON.stringify(item.fid)}] },
              headers: { 'Content-Type': 'application/json' } });
            if (err) throw new Error(String(err.message || err).slice(0, 200));
            const rec = resp?.data?.[0];
            if (!rec?.download_url) throw new Error('no download_url');
            return rec.download_url;
          })()`, 60000);
          const { mkdir: fsmk, writeFile, appendFile } = await import('node:fs/promises');
          const { dirname } = await import('node:path');
          const { createHash } = await import('node:crypto');
          const { unlinkSync, existsSync } = await import('node:fs');
          await fsmk(dirname(local), { recursive: true });
          if (existsSync(local)) unlinkSync(local);
          const hash = createHash('sha256');
          const RCHUNK = 32 * 1024 * 1024;
          let offset = 0;
          let written = 0;
          while (offset < (total || 1)) {
            const end = Math.min(offset + RCHUNK, total) - 1;
            const rangeHdr = total ? { Range: `bytes=${offset}-${end}` } : {};
            const b64 = await pageEval(`(async () => {
              const r = await fetch(${JSON.stringify(raw)}, { headers: ${JSON.stringify(rangeHdr)} });
              if (!r.ok && r.status !== 206) throw new Error('download HTTP ' + r.status);
              const buf = new Uint8Array(await r.arrayBuffer());
              let s = ''; const CH = 0x8000;
              for (let i = 0; i < buf.length; i += CH) s += String.fromCharCode.apply(null, buf.subarray(i, i + CH));
              return btoa(s);
            })()`, 600000);
            const piece = Buffer.from(b64, 'base64');
            hash.update(piece);
            if (written === 0) await writeFile(local, piece);
            else await appendFile(local, piece);
            written += piece.length;
            offset = total ? end + 1 : written;
            if (!total) break;
            console.error(`[progress] ${written}/${total}`);
          }
          return { local_path: local, bytes: written, sha256: hash.digest('hex') };
        });
      })());
      break;
    }
    case 'recycle': {
      const page = parseFlags(rest).page || Number(rest[0]) || 1;
      out(await withExternal(() => ex.recycleList({ page })));
      break;
    }
    case 'restore': {
      const ids = rest[0]?.split(',').map((s) => s.trim()).filter(Boolean);
      if (!ids?.length) usage();
      out(await withExternal(async () => {
        const r = await ex.recycleRecover(ids);
        if (r?.task_id) await ex.taskPoll(r.task_id, { maxMs: 60000 });
        return { restored: ids.length, note: '恢复位置：/文件恢复/<日期>/' };
      }));
      break;
    }
    case 'purge': {
      const ids = rest[0]?.split(',').map((s) => s.trim()).filter(Boolean);
      if (!ids?.length) usage();
      out(await withExternal(() => ex.recyclePurge(ids)));
      break;
    }
    case 'quota': {
      out(await withExternal(() => ex.quota()));
      break;
    }
    case 'info': {
      const [arg] = rest;
      if (!arg) usage();
      out(await withExternal(async () => {
        const item = await resolve(arg);
        return ex.fileInfo(item.fid);
      }));
      break;
    }
    case 'page-call': {
      const [method, path] = rest;
      if (!method || !path) usage();
      const f = parseFlags(rest);
      await pageCall(method.toUpperCase(), path, f, null);
      break;
    }
    case 'help':
    default:
      usage();
  }
} catch (e) {
  const msg = String(e?.message || e);
  const map = {
    PATH_NOT_FOUND: '路径不存在。用 ucdrive list 确认目录名。',
    NO_CLOUD_DRIVE_PAGE: 'UC 已启动但云盘页面不可用：打开 UC 网盘页面后重试。',
    STALE_CREDS: '凭证失效：打开 UC 网盘页面，运行 ucdrive login 重新抓取。',
  };
  const code = e?.code || 'ERROR';
  console.error(JSON.stringify({ error: { code, message: msg.slice(0, 400),
    ...(map[code] ? { hint: map[code] } : {}) } }));
  process.exit(1);
} finally {
  close_page_socket();
  // the page websocket can keep the event loop alive; CLI output is done
  process.exit(process.exitCode ?? 0);
}
