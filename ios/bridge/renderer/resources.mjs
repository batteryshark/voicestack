import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const base = path.resolve(here, '../../output');
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
export function checkedPath(raw, fresh) {
  if (typeof raw !== 'string' || !raw.startsWith('/') || raw.includes('\0') || raw.split('/').slice(1).some(p => !p || p === '.' || p === '..')) throw Error('Raw resource path refused');
  const parts = raw.split('/').slice(1); let p = '';
  for (let i=0; i<parts.length; i++) {
    p += '/'+parts[i];
    if (fresh && i === parts.length-1) { if (fs.existsSync(p) || (() => { try { fs.lstatSync(p); return true; } catch { return false; } })()) throw Error('Existing output refused'); break; }
    const st = fs.lstatSync(p);
    if (st.isSymbolicLink() || (i < parts.length-1 && !st.isDirectory())) throw Error('Resource alias refused');
  }
  return raw;
}
export function resourceRoot(fresh=false) {
  const raw = process.env.FV_CANVAS_RESOURCES || base+'/canvas';
  checkedPath(raw, fresh);
  if (path.dirname(raw) !== base || !/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(path.basename(raw))) throw Error('Resources must be a direct owned ios/output child');
  const st = fs.statSync(base);
  if (st.uid !== process.getuid() || (st.mode & 0o022)) throw Error('Unsafe output parent');
  return raw;
}
export function sourceHashes() {
  const lock = JSON.parse(fs.readFileSync(path.join(here,'source-lock.json')));
  const names = ['build.mjs','resources.mjs','source-lock.json','package.json','package-lock.json','entry.tsx', ...Object.keys(lock.inputs).filter(n => n.startsWith('src/'))];
  return Object.fromEntries(names.map(n => [n,sha(fs.readFileSync(path.join(here,n)))]));
}
export function verifyResources() {
  try {
    const root = resourceRoot();
    const m = JSON.parse(fs.readFileSync(checkedPath(root+'/manifest.json',false)));
    if (JSON.stringify(m.sources) !== JSON.stringify(sourceHashes())) throw Error('Stale sources');
    const names = ['renderer.js','renderer.css','lib/tailwind.js','lib/chart.js.js','lib/d3.js','lib/mermaid.js'];
    if (JSON.stringify(Object.keys(m.files).sort()) !== JSON.stringify(names.sort())) throw Error('Incomplete resources');
    const lock = JSON.parse(fs.readFileSync(path.join(here,'source-lock.json')));
    for (const [n, pin] of Object.entries(lock.libraries)) if (m.files['lib/'+n+'.js'] !== pin.sha256) throw Error('Library pin mismatch');
    for (const n of names) if (sha(fs.readFileSync(checkedPath(root+'/'+n,false))) !== m.files[n]) throw Error('Resource hash mismatch');
    return { root, manifest:m };
  } catch { throw Error('Canvas resources missing, stale, or unsafe. Run the pinned renderer source build into a FRESH ios/output child; set FV_CANVAS_RESOURCES consistently.'); }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) { verifyResources(); console.log('Canvas resources verified'); }
