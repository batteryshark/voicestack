// Read-only installed-backend probe: output contains ONLY counts, timing and classifications.
// Raw records remain in memory, never exported or logged. No bridge/lease mutation.
import fs from 'node:fs';
import http from 'node:http';
const port = JSON.parse(fs.readFileSync(process.env.HOME + '/.config/openchamber/settings.json')).desktopLocalPort;
const sid = JSON.parse(fs.readFileSync(process.env.HOME + '/.chief-of-staff/chief.json')).session;
if (!/^ses_[A-Za-z0-9]+$/.test(sid) || !Number.isInteger(port)) throw new Error('discovery invalid');
function get(path) {
  return new Promise((resolve, reject) => {
    const start = performance.now();
    const req = http.get({ host: '127.0.0.1', port, path }, res => {
      let size = 0; const chunks = [];
      res.on('data', b => { size += b.length; if (size > 8 * 1024 * 1024) req.destroy(); else chunks.push(b); });
      res.on('end', () => {
        try { if (res.statusCode !== 200) throw new Error('read refused'); resolve({ obj: JSON.parse(Buffer.concat(chunks)), bytes: size, ms: Math.round(performance.now() - start) }); }
        catch { reject(new Error('read failed')); }
      });
    });
    req.setTimeout(7500, () => req.destroy()); req.on('error', () => reject(new Error('bounded read failed')));
  });
}
let cursor, total = 0, bytes = 0, pages = 0, previousMinimum = Infinity, descendingPageWindows = true, ascendingWithinPages = true;
const seen = new Set(), ids = new Set(), counts = { text: 0, toolOnly: 0, structural: 0, detailOnly: 0 }, started = performance.now();
do {
  const query = cursor ? 'limit=40&cursor=' + cursor : 'limit=40&order=desc';
  const page = await get(`/api/session/${sid}/message?${query}`);
  if (!Array.isArray(page.obj.data)) throw new Error('unexpected DTO');
  const times = page.obj.data.map(r => r.time?.created ?? 0);
  if (times.some((time, index) => index > 0 && time < times[index-1])) ascendingWithinPages = false;
  if (times.length) {
    if (Math.max(...times) > previousMinimum) descendingPageWindows = false;
    previousMinimum = Math.min(...times);
  }
  for (const r of page.obj.data) {
    if (ids.has(r.id)) throw new Error('overlapping page'); ids.add(r.id);
    const content = r.content || [];
    if (['idle', 'execution', 'lifecycle', 'session'].includes(r.type)) counts.structural++;
    else if ((r.text || '').trim() || content.some(b => b.type === 'text' && (b.text || '').trim())) counts.text++;
    else if (content.some(b => b.type === 'tool')) counts.toolOnly++;
    else counts.detailOnly++;
  }
  total += page.obj.data.length; bytes += page.bytes; pages++;
  console.log(JSON.stringify({ stage: pages === 1 ? 'latest-first' : 'older-cursor', page: pages, records: page.obj.data.length, bytes: page.bytes, elapsedMs: page.ms }));
  cursor = page.obj.cursor?.next;
  if (cursor && (!/^[A-Za-z0-9_-]{1,1024}$/.test(cursor) || seen.has(cursor))) throw new Error('invalid/repeated cursor');
  seen.add(cursor);
  if (pages > 100) throw new Error('page bound');
} while (cursor);
console.log(JSON.stringify({ stage: 'history-summary', total, pages, bytes, descendingPageWindows, ascendingWithinPages, counts, elapsedMs: Math.round(performance.now() - started) }));
