// Narrow message-bound capabilities. No filesystem/URL proxy and no viewer keys on the wire.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { inflateSync } from 'node:zlib';
import { senderProjection } from './sender.mjs';

export const limit = 8 * 1024 * 1024;
const canvasOrigins = new Set();
const canvasHosts = new Set();
export function learnCanvasOrigin(publicUrl) {
  try {
    const url = new URL(publicUrl);
    if (['http:', 'https:'].includes(url.protocol) && !url.username && !url.password) { canvasOrigins.add(url.origin); canvasHosts.add(url.hostname.toLowerCase().replace(/\.$/, '')); }
  } catch { /* A missing /connect never authorizes an origin or releases a credential. */ }
}
const webURLs = /https?:\/\/[^\s<>"'\\)]+/gi;
function canvasSelector(raw) {
  let decoded = raw; try { decoded = decodeURIComponent(raw); } catch {}
  return /key=|(?:[?#&]|&amp;)view=/i.test(decoded);
}
export function learnCanvasMessageOrigins(value) {
  if (typeof value === 'string') {
    for (const [raw] of value.matchAll(webURLs)) {
      if (canvasSelector(raw)) {
        learnCanvasOrigin(raw);
      }
    }
  } else if (value && typeof value === 'object') for (const item of Object.values(value)) learnCanvasMessageOrigins(item);
}
/// The canonical desktop record stays untouched. Viewer capabilities in tool results/links
/// must not ride the otherwise lossless phone history/SSE projection.
export function phoneProjection(value, senderOptions) {
  // Inspect the entire envelope first: prose may precede the tool carrying the viewing URL.
  learnCanvasMessageOrigins(value);
  const projected = senderProjection(projectPhone(value), senderOptions);
  // Sender projection can introduce cached source titles not present in the
  // original envelope. Treat every generated label as untrusted content too,
  // including SSE cache hits and detached/encoded capability tokens.
  learnCanvasMessageOrigins(projected);
  return projectPhone(projected);
}
function projectPhone(value) {
  if (typeof value === 'string') {
    // Remove the credential token before removing its URL: Markdown/line wrapping
    // may put the token outside the URL match entirely.
    const safe = value.replace(/((?:[#?&]|%(?:23|3f|26)|\b|(?<![A-Za-z0-9_%]))(?:k|%(?:6b|4b))(?:e|%(?:65|45))(?:y|%(?:79|59))(?:=|%3d))[\s)\]`*_]*(?:\[)?[A-Za-z0-9_%.-]+(?:\])?/gi, '$1[removed]');
    return safe.replace(webURLs, (url, offset) => {
      const context = safe.slice(Math.max(0, offset - 80), offset);
      let canvas = canvasSelector(url) || /canvas/i.test(url) || /\bcanvas(?:\s+(?:at|here))?[\s\]\[(:=-]*$/i.test(context);
      try {
        const host = new URL(url).hostname.toLowerCase().replace(/\.$/, '');
        canvas ||= canvasHosts.has(host) || host.includes('canvas') || host === 'ts.net' || host.endsWith('.ts.net') || host === 'localhost' || host.endsWith('.localhost') || host.includes(':') || /^[0-9.]+$/.test(host);
      } catch { canvas = true; }
      return canvas ? '[Canvas panel]' : url;
    }).replace(/(?:[#?&]|\b)(?:key|view)=[^\s<>"'\\)]*/gi, '[Canvas panel]').replace(/itms-services:[^\s<>"'\\)]+/gi, '[Install available in build details]');
  }
  if (Array.isArray(value)) return value.map(projectPhone);
  if (value?.type === 'tool' && /(?:^|[._])canvas_show$/.test(value.name)) {
    const { content, input, ...state } = value.state ?? {};
    return Object.fromEntries(Object.entries({ ...value, state }).map(([key, item]) => [key, projectPhone(item)])); // No source or privileged tool-result prose in history/SSE.
  }
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, /^(viewerKey|sessionKey|outsideFileGrant)$/i.test(key) ? '[redacted]' : projectPhone(item)]));
  return value;
}
export function check(ok, status = 403, message = 'content refused') {
  if (!ok) throw Object.assign(new Error(message), { status });
}
export function validateBytes(bytes, mime) {
  check(bytes.length > 0 && bytes.length <= limit, 413);
  if (mime === undefined) mime = bytes.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex')) ? 'image/png' : bytes[0] === 0xff && bytes[1] === 0xd8 ? 'image/jpeg' : undefined;
  let width, height;
  if (mime === 'image/png') {
    check(bytes.length >= 33 && bytes.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex')) && bytes.toString('ascii', 12, 16) === 'IHDR');
    width = bytes.readUInt32BE(16); height = bytes.readUInt32BE(20);
    check(width > 0 && height > 0 && width <= 8192 && height <= 8192 && width * height <= 16000000, 413);
    let offset = 8, ended = false; const compressed = [];
    while (offset + 12 <= bytes.length) {
      const size = bytes.readUInt32BE(offset); check(size <= limit && offset + size + 12 <= bytes.length);
      const type = bytes.toString('ascii', offset + 4, offset + 8);
      let crc = 0xffffffff;
      for (const byte of bytes.subarray(offset + 4, offset + 8 + size)) {
        crc ^= byte;
        for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
      }
      check(((crc ^ 0xffffffff) >>> 0) === bytes.readUInt32BE(offset + 8 + size));
      if (type === 'IDAT') compressed.push(bytes.subarray(offset + 8, offset + 8 + size));
      offset += size + 12;
      if (type === 'IEND') { ended = true; break; }
    }
    check(ended && offset === bytes.length && compressed.length > 0);
    const depth = bytes[24], color = bytes[25], channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[color];
    check(channels && bytes[26] === 0 && bytes[27] === 0 && bytes[28] === 0, 415); // Interlaced previews fail closed.
    check(([0, 3].includes(color) ? [1, 2, 4, 8, ...(color === 0 ? [16] : [])] : [8, 16]).includes(depth));
    const stride = 1 + Math.ceil(width * channels * depth / 8), decodedLength = stride * height;
    let decoded;
    try { decoded = inflateSync(Buffer.concat(compressed), { maxOutputLength: decodedLength }); } catch { check(false); }
    check(decoded.length === decodedLength);
    for (let row = 0; row < height; row++) check(decoded[row * stride] <= 4);
  } else if (mime === 'image/jpeg') {
    check(bytes[0] === 0xff && bytes[1] === 0xd8 && bytes.at(-2) === 0xff && bytes.at(-1) === 0xd9);
    let offset = 2;
    while (offset + 4 < bytes.length) {
      check(bytes[offset++] === 0xff);
      while (bytes[offset] === 0xff) offset++;
      const marker = bytes[offset++];
      if (marker === 0xda || marker === 0xd9) break;
      const length = bytes.readUInt16BE(offset); check(length >= 2 && offset + length <= bytes.length);
      if ([0xc0, 0xc1, 0xc2].includes(marker)) {
        check(length >= 8); height = bytes.readUInt16BE(offset + 3); width = bytes.readUInt16BE(offset + 5); break;
      }
      offset += length;
    }
    check(width !== undefined);
  } else { check(false, 415, 'unsupported preview MIME'); }
  if (width !== undefined) check(width > 0 && height > 0 && width <= 8192 && height <= 8192 && width * height <= 16000000, 413);
  return { mime, length: bytes.length, ...(width ? { width, height } : {}) };
}
export function assetDescription(file, bytes) {
  // PDF is metadata only: never parse/decompress it or grant a byte-delivery capability.
  check(bytes.length > 0 && bytes.length <= limit, 413);
  if (file.mime === 'application/pdf') return { mime: file.mime, name: file.name || 'Attachment.pdf', length: bytes.length, preview: false };
  return { ...validateBytes(bytes, file.mime), preview: true };
}
export function base64(value) {
  check(typeof value === 'string' && value.length <= Math.ceil(limit / 3) * 4 && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value), 413);
  const bytes = Buffer.from(value, 'base64'); check(bytes.toString('base64') === value); return bytes;
}
export function exactReference(record, ref) {
  check(ref && ['userFile', 'toolFile', 'markdownImage'].includes(ref.kind));
  check(Object.keys(ref).every(k => ['kind', 'blockOrdinal', 'itemOrdinal', 'source'].includes(k)) && Number.isInteger(ref.blockOrdinal) && ref.blockOrdinal >= 0);
  if (ref.kind === 'userFile') {
    check(record.type === 'user'); const file = record.files?.[ref.blockOrdinal]; check(file);
    // source.uri is descriptive, never authority, when data is embedded.
    return { mime: file.mime, data: file.data, name: file.name };
  }
  check(record.type === 'assistant'); const block = record.content?.[ref.blockOrdinal]; check(block);
  if (ref.kind === 'toolFile') {
    check(block.type === 'tool' && Number.isInteger(ref.itemOrdinal) && ref.itemOrdinal >= 0);
    const file = block.state?.content?.[ref.itemOrdinal]; check(file?.type === 'file'); return file;
  }
  check(block.type === 'text' && typeof ref.source === 'string');
  // Same deliberately bounded image syntax as native projection; code fences excluded.
  let fenced = false; const sources = [];
  for (const line of block.text.split('\n')) {
    if (/^\s*(?:```|~~~)/.test(line)) fenced = !fenced;
    if (!fenced) for (const match of line.matchAll(/!\[([^\]]*)\]\(([^\s)]+)\)/g)) sources.push(match[2]);
  }
  check(sources.includes(ref.source));
  return { uri: ref.source, mime: /^data:([^;,]+);base64,/.exec(ref.source)?.[1] ?? (/\.png$/i.test(ref.source) ? 'image/png' : /\.jpe?g$/i.test(ref.source) ? 'image/jpeg' : undefined) };
}
export function readAsset(file, directory) {
  if (file.data !== undefined) return base64(file.data);
  check(typeof file.uri === 'string');
  if (file.uri.startsWith('data:')) {
    const match = /^data:([^;,]+);base64,(.*)$/s.exec(file.uri); check(match && match[1] === file.mime); return base64(match[2]);
  }
  check(!file.uri.includes('\0'));
  const candidate = file.uri.startsWith('file:') ? fileURLToPath(file.uri) : file.uri;
  check(!/^[a-z][\w+.-]*:/i.test(candidate) && !candidate.split(/[\\/]/).includes('..'));
  directory = fs.realpathSync(directory);
  const absolute = path.resolve(directory, candidate);
  const roots = [directory, path.join(os.tmpdir(), 'opencode')].filter(p => fs.existsSync(p)).map(p => fs.realpathSync(p));
  const canonical = fs.realpathSync(absolute);
  check(roots.some(root => canonical.startsWith(root + path.sep)));
  const root = roots.find(root => absolute.startsWith(root + path.sep)); check(root);
  const result = spawnSync('/usr/bin/python3', ['-I', fileURLToPath(new URL('./read-asset.py', import.meta.url)), root, path.relative(root, absolute)], { timeout: 5000, maxBuffer: limit + 65536, env: { PATH: '/usr/bin:/bin' } });
  check(result.status === 0 && !result.error, 403); return result.stdout;
}
export function canvasAssociation(record, ordinal) {
  check(record.type === 'assistant' && Number.isInteger(ordinal) && ordinal >= 0);
  const tool = record.content?.[ordinal];
  check(tool?.type === 'tool' && /(?:^|[._])canvas_present$/.test(tool.name) && tool.state?.status === 'completed');
  for (const item of tool.state.content ?? []) {
    if (item.type !== 'text') continue;
    let result; try { result = JSON.parse(item.text); } catch { continue; }
    if (typeof result.id === 'string' && /^[a-zA-Z0-9_-]{1,100}$/.test(result.id) && Number.isInteger(result.revision) && result.revision > 0) return { artifactID: result.id, revision: result.revision, toolID: tool.id };
  }
  check(false);
}
export class Capabilities {
  constructor(now = () => Date.now()) { this.entries = new Map(); this.now = now; }
  grant(binding, value, lifetime = 60000) {
    for (const [id, entry] of this.entries) if (entry.expires <= this.now()) this.entries.delete(id);
    check(this.entries.size < 256, 429);
    const id = crypto.randomBytes(24).toString('base64url'); this.entries.set(id, { binding: JSON.stringify(binding), value, expires: this.now() + lifetime }); return id;
  }
  get(id, binding) { const entry = this.entries.get(id); check(entry && entry.expires > this.now() && entry.binding === JSON.stringify(binding), 409); return entry.value; }
}
export function canvasShowAssociation(record, ordinal) {
  check(record.type === 'assistant' && Number.isInteger(ordinal) && ordinal >= 0);
  const tool = record.content?.[ordinal], meta = tool?.state?.metadata;
  check(tool?.type === 'tool' && /(?:^|[._])canvas_show$/.test(tool.name) && tool.state?.status === 'completed' && meta?.truncated !== true);
  check(typeof tool.id === 'string' && typeof meta?.viewId === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(meta.viewId));
  check(Number.isSafeInteger(meta.revision) && meta.revision > 0 && ['openui', 'html'].includes(tool.state.input?.format));
  return { viewId: meta.viewId, revision: meta.revision, toolID: tool.id, format: tool.state.input.format };
}
export function showRevision(revision, panel) {
  check(revision.sessionKey === panel.sessionKey && revision.number === panel.revision, 403);
  const { format, source } = revision.content ?? {};
  check(format === panel.format && typeof source === 'string' && source.length > 0 && source.length <= (format === 'html' ? 400000 : 200000), 502);
  const exposed = source + '\n' + (revision.title ?? '') + '\n' + (revision.summary ?? '');
  for (const secret of [panel.key, panel.sessionKey, ...canvasOrigins]) if (typeof secret === 'string' && secret) check(!exposed.includes(secret), 403);
  return { format, source, title: revision.title, summary: revision.summary };
}
export function byteRange(value, length) {
  if (!value) return [0, length - 1];
  const match = /^bytes=(\d+)-(\d*)$/.exec(value); check(match, 416);
  const start = Number(match[1]), end = match[2] ? Number(match[2]) : length - 1;
  check(Number.isSafeInteger(start) && Number.isSafeInteger(end) && start <= end && end < length, 416); return [start, end];
}
