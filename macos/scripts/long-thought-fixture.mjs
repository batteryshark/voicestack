// Reviewed 152a394 long-thought WS fixture, with isolated Mac HTTP/SSE adapter.
import http from 'node:http';
import { createHash } from 'node:crypto';

const segments = [], posts = [];
let active = 0, maxActive = 0;
const server = http.createServer((req, res) => {
  if (req.url === '/api/event') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    res.write('data: {"type":"server.connected"}\n\n'); return;
  }
  res.setHeader('Content-Type', 'application/json');
  if (req.url === '/api/system/info') { res.end(JSON.stringify({ runtime: 'desktop' })); return; }
  if (req.url === '/api/session/active') { res.end(JSON.stringify({ data: {} })); return; }
  if (req.url === '/api/session/ses_fixture') { res.end(JSON.stringify({ data: { title: 'Fixture', location: { directory: '/fixture' } } })); return; }
  if (req.url === '/api/session/ses_fixture/prompt' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => { posts.push(JSON.parse(body)); res.end(JSON.stringify({ data: { id: 'fixture-receipt' } })); });
    return;
  }
  if (req.url !== '/stats') { res.statusCode = 404; res.end('{}'); return; }
  res.end(JSON.stringify({ posts, maxActive, segments: segments.map(s => ({ frames: s.frames, ended: s.ended, digest: s.hash.copy().digest('hex') })) }));
});
function frame(opcode, payload) {
  payload = Buffer.from(payload);
  if (payload.length > 125) throw new Error('fixture response too large');
  return Buffer.concat([Buffer.from([0x80 | opcode, payload.length]), payload]);
}
server.on('upgrade', (req, socket, head) => {
  const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
  const index = segments.length;
  const segment = { frames: 0, hash: createHash('sha256'), ended: false };
  segments.push(segment); active++; maxActive = Math.max(maxActive, active);
  socket.on('close', () => active--);
  socket.on('error', () => {});
  let pending = Buffer.alloc(0);
  function receive(bytes) {
    pending = Buffer.concat([pending, bytes]);
    while (pending.length >= 2) {
      const opcode = pending[0] & 15, masked = !!(pending[1] & 128);
      let length = pending[1] & 127, offset = 2;
      if (length === 126) {
        if (pending.length < 4) return;
        length = pending.readUInt16BE(2); offset = 4;
      } else if (length === 127) {
        if (pending.length < 10) return;
        length = Number(pending.readBigUInt64BE(2)); offset = 10;
      }
      if (pending.length < offset + (masked ? 4 : 0) + length) return;
      const mask = masked ? pending.subarray(offset, offset + 4) : null;
      offset += masked ? 4 : 0;
      const payload = Buffer.from(pending.subarray(offset, offset + length));
      pending = pending.subarray(offset + length);
      if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
      if (opcode === 2) { segment.frames++; segment.hash.update(payload); }
      else if (opcode === 9) socket.write(frame(10, payload));
      else if (opcode === 8) { socket.end(frame(8, payload)); return; }
      else if (opcode === 1 && JSON.parse(payload.toString()).type === 'input_audio.end') {
        segment.ended = true;
        // Deliberately no successor partials; only finals are reliable.
        setTimeout(() => {
          socket.write(frame(1, JSON.stringify({ type: 'transcript', text: ['First segment', 'second segment', 'last segment.'][index] })));
          socket.end(frame(8, Buffer.from([3, 232])));
        }, 30);
      }
    }
  }
  socket.on('data', receive);
  if (head.length) receive(head);
});
server.listen(0, '127.0.0.1', () => {
  if ([8444, 8446, 8450].includes(server.address().port)) { server.close(); process.exit(2); }
  console.log(server.address().port);
});
