// Upload pipeline: sha1/md5 -> formupload/pre -> (rapid hit | multipart POST
// to upload_url) -> upload/finish. All hashing happens locally in Node; the
// multipart body is executed inside the page via FormData + Blob.
import { createHash } from 'node:crypto';
import { createReadStream, readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { stat } from 'node:fs/promises';
import { eval_js } from './uc.mjs';
import { call, unwrap, taskPoll } from './drive.mjs';

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

export async function hashesOf(filePath) {
  return new Promise((resolve, reject) => {
    const sha1 = createHash('sha1');
    const md5 = createHash('md5');
    const stream = createReadStream(filePath);
    stream.on('data', (c) => { sha1.update(c); md5.update(c); });
    stream.on('end', () => resolve({ sha1: sha1.digest('hex'), md5: md5.digest('hex') }));
    stream.on('error', reject);
  });
}

export async function uploadFile({ localPath, destFid, name }) {
  const st = await stat(localPath);
  if (!st.isFile()) throw new Error(`not a file: ${localPath}`);
  if (st.size > 64 * 1024 * 1024) {
    throw new Error(`file ${st.size} bytes exceeds the 64MB simple-upload limit`);
  }
  const fileName = name || basename(localPath);
  const ext = fileName.slice(fileName.lastIndexOf('.')).toLowerCase();
  const formatType = MIME[ext] || 'application/octet-stream';
  const { sha1, md5 } = await hashesOf(localPath);

  // step 1: pre (rapid-upload when hashes known server-side)
  const preParsed = await call('POST', '/1/clouddrive/file/formupload/pre', {
    data: {
      sha1, md5, size: st.size, pdir_fid: String(destFid), file_name: fileName,
      format_type: formatType, dir_name: '', same_path_reuse: false,
      l_created_at: Math.round(st.birthtimeMs) || Date.now(),
      l_updated_at: Math.round(st.mtimeMs) || Date.now(),
      file_local_path: localPath,
    },
    retry: 2, timeoutMs: 60000,
  });
  const pre = unwrap(preParsed, 'formuploadPre');

  // rapid upload: finish=true means the server already has the bytes
  if (pre.finish) {
    return { fid: pre.fid, rapid: true, task_id: pre.task_id, obj_key: pre.obj_key };
  }

  if (!pre.upload_url || !pre.obj_key || !pre.upload_auth) {
    // some accounts get a plain upload_url without OSS-style auth; surface it
    throw new Error('formupload/pre returned no upload_auth: ' +
      JSON.stringify(pre).slice(0, 400));
  }

  // step 2: multipart POST executed inside the page (fields per bundle:
  // key/policy/OSSAccessKeyId/success_action_status/signature/callback/file)
  const bodyB64 = readFileSync(localPath).toString('base64');
  const uploadJs = wrapUpload({ pre, bodyB64, fileName, formatType });
  const upRaw = await eval_js(uploadJs, { timeoutMs: 10 * 60 * 1000 });
  const up = JSON.parse(upRaw);
  if (!up.ok) throw new Error('UL upload failed: ' + (up.err || up.status));

  // step 3: finish
  const finParsed = await call('POST', '/1/clouddrive/file/upload/finish', {
    data: { obj_key: pre.obj_key, task_id: pre.task_id },
    retry: 2, timeoutMs: 60000,
  });
  const fin = unwrap(finParsed, 'uploadFinish');
  // finish may be async -> poll if a task handle comes back
  if (fin && fin.task_id && !fin.fid) {
    await taskPoll(fin.task_id, { maxMs: 60000 });
  }
  return { fid: fin?.fid ?? pre.fid, rapid: false, task_id: pre.task_id };
}

function wrapUpload({ pre, bodyB64, fileName, formatType }) {
  const payload = JSON.stringify({
    obj_key: pre.obj_key,
    policy: pre.upload_auth.policy,
    key_id: pre.upload_auth.key_id,
    auth_key: pre.upload_auth.auth_key,
    callback: pre.callback ?? null,
    upload_url: pre.upload_url,
    bodyB64,
    fileName,
    formatType,
  });
  return `(async () => {
    const p = ${payload};
    const bin = Uint8Array.from(atob(p.bodyB64), c => c.charCodeAt(0));
    const fd = new FormData();
    fd.append('key', p.obj_key);
    fd.append('policy', p.policy);
    fd.append('OSSAccessKeyId', p.key_id);
    fd.append('success_action_status', '200');
    fd.append('signature', p.auth_key);
    if (p.callback) fd.append('callback', window.btoa(JSON.stringify(p.callback)));
    fd.append('file', new Blob([bin], { type: p.formatType }), p.fileName);
    const r = await fetch(p.upload_url, { method: 'POST', body: fd });
    const text = await r.text().catch(() => '');
    return JSON.stringify({ ok: r.ok, status: r.status, err: r.ok ? null : text.slice(0, 300) });
  })()`;
}
