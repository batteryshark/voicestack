// Simulator-only loopback fake desktop + real project broker. Never discovers or contacts a live service.
import http from 'node:http';
import fs from 'node:fs';
import { once } from 'node:events';
import { createBridge } from './server.mjs';
import { sources, viewIds, showRecord } from './fixtures/canvas-show.mjs';
const interactions = [], submissions = [];
const polls = new Map(), pendingForever = process.env.FV_CANVAS_FIXTURE_PENDING_FOREVER === '1';
const output = new URL(process.env.FV_CANVAS_FIXTURE_OUTPUT || '../output/canvas-show/', import.meta.url);
fs.mkdirSync(output, { recursive: true });
const fake = http.createServer(async (req, res) => {
  req.on('error', () => {}); res.on('error', () => {});
  try {
  const send = value => { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(value)); };
  if (req.url === '/api/system/info') return send({ runtime: 'desktop' });
  if (req.url === '/api/session?limit=200') return send({ data: ['openui', 'html'].map(format => ({ id: 'ses_' + format, title: 'Synthetic ' + format })) });
  if (req.url === '/api/session/active') return send({ data: {} });
  if (req.url === '/api/event') { res.writeHead(200, { 'Content-Type': 'text/event-stream' }); res.write(': fixture\n\n'); return; }
  const match = /^\/api\/session\/ses_(openui|html)(.*)$/.exec(req.url);
  if (match) {
    const [, format, suffix] = match, sid = 'ses_' + format;
    if (!suffix) return send({ data: { id: sid, location: { directory: '/synthetic-canvas-fixture' } } });
    if (suffix === '/message/msg_' + format) return send({ data: showRecord(format) });
    if (suffix.startsWith('/message/msg_canvas')) {
      const messageId = suffix.slice('/message/'.length);
      const interaction = interactions.find(i => i.sessionKey === 'SYNTHETIC_SESSION_' + sid && i.messageId === messageId);
      if (!interaction) { res.writeHead(404); return send({ error: 'Synthetic receipt missing' }); }
      const count = polls.get(interaction.id) ?? 0, available = !pendingForever && count >= 4;
      fs.appendFileSync(new URL('receipt-reads.jsonl', output), JSON.stringify({ id: interaction.id, poll: count, available }) + '\n');
      if (!available) { res.writeHead(count === 2 ? 503 : 404); return send({ error: 'Synthetic receipt not persisted yet' }); }
      fs.appendFileSync(new URL('receipt-confirmations.jsonl', output), JSON.stringify({ session: sid, messageId, proof: 'exact scoped user message' }) + '\n');
      return send({ data: { id: messageId, type: 'user', text: interaction.prompt } });
    }
    if (suffix.startsWith('/message?')) return send({ data: [{ id: 'user_' + format, type: 'user', text: 'Show me the decision panel.' }, showRecord(format)], cursor: {} });
  }
  if (req.url === '/api/guests/agent-canvas/service/request') {
    const chunks = []; for await (const c of req) chunks.push(c);
    const outer = JSON.parse(Buffer.concat(chunks)), inner = JSON.parse(outer.body);
    let value;
    if (outer.path === '/connect') value = { key: 'SYNTHETIC_VIEWER_' + inner.sessionId, publicUrl: 'https://canvas.fixture.invalid' };
    else {
      const format = inner.key.endsWith('ses_html') ? 'html' : 'openui', sid = 'ses_' + format;
      if (inner.path === '/api/snapshot') {
        const owned = interactions.filter(i => i.sessionKey === 'SYNTHETIC_SESSION_' + sid);
        for (const interaction of owned) {
          const previous = polls.get(interaction.id) ?? 0;
          if (!pendingForever && previous >= 4) continue;
          const poll = previous + 1; polls.set(interaction.id, poll);
          interaction.status = poll === 1 ? 'queued' : pendingForever || poll < 4 ? 'sending' : format === 'html' ? 'uncertain' : 'delivered';
          fs.appendFileSync(new URL('delivery-polls.jsonl', output), JSON.stringify({ id: interaction.id, poll, status: interaction.status, receiptAvailable: !pendingForever && poll >= 4 }) + '\n');
        }
        value = { session: { key: 'SYNTHETIC_SESSION_' + sid, sessionId: sid, directory: '/synthetic-canvas-fixture' }, views: [{ id: viewIds[format], latest: 1 }, { id: 'DO_NOT_PROJECT_OTHER_VIEW', latest: 9 }], interactions: owned };
      }
      else if (inner.path === `/api/revision?id=${viewIds[format]}&revision=1`) value = { number: 1, sessionKey: 'SYNTHETIC_SESSION_' + sid, title: format === 'html' ? 'HTML decision panel' : 'Release decision', summary: 'Synthetic fixture · build 24', content: { format, source: sources[format] } };
      else if (inner.path === '/api/submit') {
        const submission = { ...inner.body, action: inner.body.action.trim() };
        if (!submissions.some(s => s.id === submission.id)) {
          submissions.push(submission);
          // Neither ack nor durable receipt exists for the first three status polls.
          // HTML later proves the uncertain-host receipt path; OpenUI receives an ack.
          interactions.push({ ...submission, messageId: 'msg_canvas' + submission.id.replaceAll('-', ''), prompt: 'Synthetic Canvas receipt: ' + submission.action,
            status: 'queued', detail: 'Synthetic worker is busy' });
          // Evidence contains only synthetic session/UUID/action, never a viewer key.
          fs.appendFileSync(new URL('submissions.jsonl', output), JSON.stringify({ id: submission.id, viewId: submission.viewId, action: submission.action, data: submission.data, notes: submission.notes, status: 'queued' }) + '\n');
        }
        // Real host returns queued on submit; its worker later acknowledges via snapshot.
        value = { ...submission, status: 'queued', detail: 'Waiting for the agent to pick this up.' };
      } else { res.writeHead(404); return res.end('{}'); }
    }
    return send({ status: 200, body: JSON.stringify(value) });
  }
  res.writeHead(404); res.end('{}');
  } catch {
    // Simulator teardown cancels in-flight authority reads. A cancelled fake request must
    // not terminate the fixture process and make the next UI case lose its backend.
    if (!res.destroyed && !res.writableEnded) { if (!res.headersSent) res.writeHead(503); res.end('{}'); }
  }
});
fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
const device = { deviceID: 'synthetic-simulator', sessionID: '', generation: '', mode: 'explicit' };
const bridge = createBridge({ credentials: { device: auth => { if (auth !== 'Bearer synthetic-phone') throw Object.assign(Error('fixture only'), { status: 401 }); return device; }, save() {} }, discover: () => fake.address().port });
bridge.listen(18424, '127.0.0.1'); await once(bridge, 'listening');
console.log('Synthetic Canvas broker ready on loopback port 18424');
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { bridge.shutdown(); fake.closeAllConnections(); fake.close(() => process.exit(0)); });
