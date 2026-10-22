// Local transport-only fixture. No model, audio device, or backend prompt endpoint.
import http from 'node:http';
import { createHash } from 'node:crypto';
const stats = [];
const frame = (op, data) => {
  const b = Buffer.from(data);
  if (b.length > 125) throw Error('fixture frame too large');
  return Buffer.concat([Buffer.from([0x80 | op, b.length]), b]);
};
const server = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(stats));
});
server.on('upgrade', (req, socket, head) => {
  const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket.on('error', () => {});
  const mode = req.url.slice(1), record = { bytes: 0, ends: 0 };
  stats.push(record);
  const send = text => socket.write(frame(1, JSON.stringify({ type: 'transcript', text })));
  const close = code => socket.end(frame(8, Buffer.from([code >> 8, code & 255])));
  if (mode === 'early') { send('Early final.'); close(1000); return; }
  let pending = Buffer.alloc(0);
  function receive(bytes) {
    pending = Buffer.concat([pending, bytes]);
    while (pending.length >= 2) {
      const op = pending[0] & 15, masked = !!(pending[1] & 128);
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
      if (op === 2) { if (record.ends) throw Error('PCM after end'); record.bytes += length; }
      else if (op === 9) socket.write(frame(10, payload));
      else if (op === 8) { close(1000); return; }
      else if (op === 1 && JSON.parse(payload).type === 'input_audio.end') {
        record.ends++;
        if (mode === 'slow') setTimeout(() => { send('Whole wire thought.'); close(1000); }, 8250);
        else if (mode === 'delta') { send('First '); setTimeout(() => { send('second.'); close(1000); }, 150); }
        else if (mode === 'empty') close(1000);
        else if (mode === 'abnormal') close(1011);
        else { send('Whole wire thought.'); close(1000); }
      }
    }
  }
  socket.on('data', receive); if (head.length) receive(head);
});
server.listen(0, '127.0.0.1', () => {
  if ([8444, 8446, 8450].includes(server.address().port)) process.exit(2);
  console.log(server.address().port);
});
