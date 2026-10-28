// File hashing shared by external upload paths.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

export function hashesOf(filePath) {
  const buf = readFileSync(filePath);
  return {
    buf,
    size: buf.length,
    sha1: createHash('sha1').update(buf).digest('hex'),
    md5: createHash('md5').update(buf).digest('hex'),
  };
}
