import fs from 'node:fs';
import crypto from 'node:crypto';
import { check } from './rich-content.mjs';
import { verifyResources } from './renderer/resources.mjs';
import path from 'node:path';
function verified(name, library = false) {
  let resources;
  try { resources = verifyResources(); } catch { check(false, 503, 'Canvas resources missing or stale; rebuild pinned source resources'); }
  const rel = library ? 'lib/' + name + '.js' : name;
  const bytes = fs.readFileSync(path.join(resources.root, rel));
  check(crypto.createHash('sha256').update(bytes).digest('hex') === resources.manifest.files[rel], 503, 'Renderer hash changed');
  return bytes.toString('utf8');
}
export function canvasLibrary(name, source, format) {
  check(format === 'html' && ['tailwind', 'chart.js', 'd3', 'mermaid'].includes(name) && source.includes('canvas:lib/' + name), 403);
  return verified(name, true);
}
// Keep each native response below the existing per-chunk transport safety bound, even on a very fast LAN.
export function canvasChunk(source, offset = 0) {
  const bytes = Buffer.from(source, 'utf8');
  check(Number.isSafeInteger(offset) && offset >= 0 && offset < bytes.length && bytes.length <= 8 * 1024 * 1024, 400);
  const end = Math.min(bytes.length, offset + 96 * 1024);
  return { chunk: bytes.subarray(offset, end).toString('base64'), nextOffset: end < bytes.length ? end : null, total: bytes.length };
}
export function canvasPage(revision) {
  const json = JSON.stringify(revision).replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
  const script = verified('renderer.js').replace(/<\/script/gi, '<\\/script');
  const css = verified('renderer.css').replace(/<\/style/gi, '<\\/style');
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"><style>${css}\nbody{margin:0;background:#111827;color:#f1f5f9;font:16px system-ui}</style></head><body><div id="root"></div><script>window.canvasRevision=${json};</script><script>${script}</script></body></html>`;
}
