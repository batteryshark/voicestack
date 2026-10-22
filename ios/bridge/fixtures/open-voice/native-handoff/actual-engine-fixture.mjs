import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import https from 'node:https';
import http from 'node:http';
import { WebSocketServer } from './production/bridge/node_modules/ws/wrapper.mjs';
import { createLocalSpeechAdapter } from './production/bridge/open-voice-speech.mjs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { EventEmitter } from 'node:events';
import { createBridge } from './production/bridge/server.mjs';
import { PushStore } from './production/bridge/push-store.mjs';
import { PushService } from './production/bridge/push-service.mjs';
import { CONFIG } from './production/bridge/reachout-policy.mjs';

export const NODE_REF = '757782eac430924aee459319385f5011d8b8a2ee';
const home = path.dirname(fileURLToPath(import.meta.url));
const prefix = '/floating-voice/voice/v1';
const turn = () => new Promise(r => setImmediate(r));
const random = () => crypto.randomBytes(32).toString('base64url');

// Test transport wrapper ONLY. Every request/upgrade is handled by the unchanged
// exact-ref production createBridge listeners. No scripted server event producer.
export async function startFixture({ scenario = 'normal' } = {}) {
  assert.ok(['normal', 'real-stt'].includes(scenario));
  const root = fs.mkdtempSync(path.join(home, 'run-')); fs.chmodSync(root, 0o700);
  let base, tls, stopped = false, stopPromise, call, releaseResult, forceEmpty = false;
  const sockets = new Set(), clients = new Set();
  const observations = [], tlsErrors = []; let requestCount = 0, secureConnections = 0;
  const routeClass = url => url === prefix + '/device-capability' ? 'capability'
    : url === prefix + '/calls' ? 'caller-request'
    : new RegExp('^' + prefix + '/calls/[0-9a-f-]{36}/accept$').test(url) ? 'accept'
    : new RegExp('^' + prefix + '/calls/[0-9a-f-]{36}/media$').test(url) ? 'media-lease'
    : new RegExp('^' + prefix + '/calls/[0-9a-f-]{36}/media-ready$').test(url) ? 'media-ready'
    : new RegExp('^' + prefix + '/calls/[0-9a-f-]{36}/end$').test(url) ? 'owner-end'
    : new RegExp('^' + prefix + '/calls/[0-9a-f-]{36}/operations/[0-9a-f-]{36}$').test(url) ? 'operation-read'
    : new RegExp('^' + prefix + '/calls/[0-9a-f-]{36}$').test(url) ? 'invitation-get' : 'other';
  const events = new EventEmitter(); let closedOwners = 0;
  const boundary = (name, reached) => reached() ? Promise.resolve() : new Promise((resolve, reject) => {
    const done = () => { clearTimeout(timer); events.off(name, done); resolve(); };
    const timer = setTimeout(() => { events.off(name, done); reject(Error('fixture boundary timeout')); }, 3000);
    events.once(name, done);
  });
  const device = { deviceID: 'synthetic-interop-phone' }, deviceToken = random();
  const counters = { apns: 0, segments: 0, writes: 0, samples: 0, finishes: 0,
    submits: 0, synthesisPulls: 0, synthesisReturns: 0, lastThought: null };
  const build = 'synthetic-interop-build';
  const owner = c => Object.fromEntries(['call_uuid', 'owner_epoch', 'binding_revision', 'target_id'].map(k => [k, c[k]]));
  const speechServer = http.createServer();
  const speechWS = new WebSocketServer({ noServer: true, perMessageDeflate: false });
  const speechSockets = new Set();
  let adapter;
  let observedSegment;
  const speechEvents = { stable: 0, partial: 0, error: 0, other: 0, closeCode: null };
  try {
    // Exact public native test leaf profile (16d6ea8 OpenVoiceTLSPeerTests:38-41).
    // This fixes the owned fixture certificate, not any pin/SSL/host decision.
    const config = path.join(root, 'req.cnf');
    fs.writeFileSync(config, '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=fixture.invalid\n[ext]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n', { mode: 0o600 });
    execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-days', '1', '-config', config,
      '-keyout', path.join(root, 'key.pem'), '-out', path.join(root, 'cert.pem')],
      { timeout: 5000, stdio: 'ignore', env: { PATH: '/usr/bin:/bin', HOME: root, TMPDIR: root, OPENSSL_CONF: config } });
    fs.chmodSync(path.join(root, 'key.pem'), 0o600);
    fs.chmodSync(path.join(root, 'cert.pem'), 0o600);
    const cert = fs.readFileSync(path.join(root, 'cert.pem'));
    const decodedCertificate = new crypto.X509Certificate(cert);
    const certificateDER = decodedCertificate.raw.toString('base64');
    const store = new PushStore(path.join(root, 'store'));
    const push = new PushService({ store, apns: async () => { counters.apns++; return { status: 200 }; },
      chief: () => { throw Error('legacy discovery forbidden'); }, activeDevices: () => [device], config: CONFIG });
    push.update(device, 'settings', { callsEnabled: true, quietHoursEnabled: false,
      quietStart: '22:00', quietEnd: '09:00', timeZone: 'UTC', policyVersion: 1, revision: 1 });
    push.update(device, 'enrollment', { alertToken: 'a'.repeat(64), voipToken: 'b'.repeat(64),
      environment: 'sandbox', build, revision: 1 });
    // Public stt_server.py:736–868 grammar. No ready event, no fake native or
    // media sink. Only the remote speech peer is synthetic in this case.
    speechServer.on('connection', s => { speechSockets.add(s); s.on('close', () => speechSockets.delete(s)); });
    speechServer.on('upgrade', (req, socket, head) => speechWS.handleUpgrade(req, socket, head, peer => {
      assert.equal(req.url, '/v1/transcribe?partials=1'); counters.segments++;
      peer.on('error', () => {});
      peer.on('message', (pcm, binary) => {
        if (binary) {
          assert.ok(pcm.length > 0 && pcm.length % 2 === 0);
          counters.writes++; counters.samples += pcm.length / 2;
          peer.send(JSON.stringify({ type: 'transcript.partial', text: 'neutral fixture', seq: counters.writes, audio_ms: counters.samples / 16 }));
        } else {
          assert.deepEqual(JSON.parse(pcm), { type: 'input_audio.end' }); counters.finishes++;
          peer.send(JSON.stringify({ type: 'transcript', text: 'neutral fixture' })); peer.close(1000);
        }
      });
    }));
    await new Promise(r => speechServer.listen(0, '127.0.0.1', r));
    const speechBase = '127.0.0.1:' + speechServer.address().port;
    const speech = createLocalSpeechAdapter({ sttURL: scenario === 'real-stt' ? 'ws://127.0.0.1:8446/v1/transcribe' : `ws://${speechBase}/v1/transcribe`,
      ttsURL: `http://${speechBase}/v1/audio/speech`, model: 'synthetic', voice: 'synthetic',
      submit() { counters.submits++; throw Error('ASR-only submission forbidden'); } });
    adapter = Object.freeze({ ...speech, async openSegment(args) {
      const sink = await speech.openSegment(args); observedSegment = sink;
      // Observe the actual production-owned socket without changing its grammar,
      // sends, callbacks or terminal decisions. Never retain text/error bodies.
      sink.ws.on('message', (data, binary) => {
        let category = 'other';
        if (!binary) {
          try { const type = JSON.parse(data).type;
            category = type === 'transcript' ? 'stable' : type === 'transcript.partial' ? 'partial' : type === 'error' ? 'error' : 'other';
          } catch {}
        }
        speechEvents[category]++;
      });
      sink.ws.on('close', code => { speechEvents.closeCode = code; });
      return sink;
    } });
    base = createBridge({ push, credentials: { device(auth) {
      if (auth !== 'Bearer ' + deviceToken) throw Object.assign(Error('synthetic refusal'), { status: 403 });
      return device;
    } }, ocClient: { check: async () => {}, note() {} }, discover: () => { throw Error('ambient discovery forbidden'); },
    openVoiceCandidate: { enabled: true, principal_id: 'synthetic-principal', audience: 'synthetic-bridge',
      device_id: device.deviceID, resolveTarget: async b => ({ ...b, authenticated: true, paired: true, available: true, idle: true }) },
    openVoiceMedia: { enabled: true, adapter, onSessionClosed: () => { closedOwners++; events.emit('owner-closed'); } } });
    const control = push.openVoice;
    control.configureMapping({ caller_id: 'synthetic-caller', project_id: 'synthetic-project', target_session: 'ses_syntheticfixture',
      directory: '/synthetic/never-opened', binding_revision: 1, expires_at: Date.now() + 300000 });
    const grant = control.issue({ caller_id: 'synthetic-caller', project_ids: ['synthetic-project'],
      scopes: ['call:request', 'call:status:own'], expires_at: Date.now() + 300000 });
    tls = https.createServer({ key: fs.readFileSync(path.join(root, 'key.pem')), cert }, (req, res) => {
      requestCount++;
      const end = res.end;
      res.end = function (...args) {
        let keys = [], errorCode = null;
        const body = args[0];
        if ((typeof body === 'string' || Buffer.isBuffer(body)) && Buffer.byteLength(body) <= 4096) {
          try { const obj = JSON.parse(body.toString()); keys = Object.keys(obj).sort().slice(0, 20);
            if (Object.hasOwn(obj, 'error')) errorCode = obj.error === 'control_refused' ? 'control_refused' : 'other';
          } catch { errorCode = 'non_json'; }
        }
        if (observations.length < 16) observations.push({ method: ['GET', 'PUT', 'POST'].includes(req.method) ? req.method : 'other',
          route_class: routeClass(req.url), status: res.statusCode, response_keys: keys, error_code: errorCode });
        return end.apply(this, args);
      };
      base.emit('request', req, res);
    });
    tls.on('upgrade', (req, socket, head) => base.emit('upgrade', req, socket, head));
    // Preserve the production connection guard, without installing HTTP's raw
    // parser a second time on the TLS stream.
    const guards = base.listeners('connection').slice(1); assert.equal(guards.length, 1);
    tls.on('secureConnection', guards[0]);
    tls.on('secureConnection', () => { secureConnections++; });
    tls.on('connection', s => { sockets.add(s); s.on('close', () => sockets.delete(s)); });
    tls.on('tlsClientError', error => {
      const known = ['ECONNRESET', 'ERR_SSL_SSLV3_ALERT_CERTIFICATE_UNKNOWN', 'ERR_SSL_TLSV1_ALERT_UNKNOWN_CA', 'ERR_SSL_SSLV3_ALERT_BAD_CERTIFICATE'];
      if (tlsErrors.length < 8) tlsErrors.push(known.includes(error.code) ? error.code : 'tls_error');
    });
    tls.requestTimeout = base.requestTimeout; tls.headersTimeout = base.headersTimeout; tls.keepAliveTimeout = base.keepAliveTimeout;
    await new Promise(r => tls.listen(0, '127.0.0.1', r)); base.emit('listening');
    const origin = 'https://127.0.0.1:' + tls.address().port;
    const request = (method, route, body, token = deviceToken) => new Promise((resolve, reject) => {
      const bytes = body === undefined ? null : Buffer.from(JSON.stringify(body));
      const req = https.request(origin + prefix + route, { method, ca: cert, agent: false,
        headers: { Authorization: 'Bearer ' + token, ...(bytes ? { 'content-type': 'application/json', 'content-length': bytes.length } : {}) } }, res => {
        let length = 0; const chunks = []; res.on('data', b => { length += b.length; if (length > 65536) res.destroy(); else chunks.push(b); });
        res.on('error', reject); res.on('end', () => { try { resolve({ status: res.statusCode, value: JSON.parse(Buffer.concat(chunks)) }); } catch (e) { reject(e); } });
      });
      clients.add(req); req.setTimeout(3000, () => req.destroy(Error('fixture deadline')));
      req.on('close', () => clients.delete(req)); req.on('error', reject); req.end(bytes);
    });
    const capability = () => request('PUT', '/device-capability', { enabled: true, profile: 'open-voice-m1-ga-ws/1', build, expires_in: 300 });
    const invite = async () => {
      assert.ok(!call); const r = await request('POST', '/calls', { operation_id: crypto.randomUUID(), project_id: 'synthetic-project',
        reason: 'decision', summary: 'Synthetic interop decision', expires_in: 300 }, grant.token);
      assert.equal(r.status, 200); await push.drain(); call = r.value.call_id; return { call_id: call };
    };
    const snapshot = () => ({ ...counters, speechEvents, adapterInputSamples: observedSegment?.input ?? 0,
      speech: adapter.stats(), engine: base.openVoiceStats(), ...(call ? { call: control.status(control.state.calls['v:' + call]),
      operations: Object.values(control.state.calls['v:' + call].operations).map(o => ({ operation_id: o.operation_id, state: o.state,
        response_status: o.response_status, delivery: o.delivery })) } : {}) });
    const stop = () => stopPromise ||= (async () => {
      stopped = true; releaseResult?.();
      for (const req of clients) req.destroy();
      const socketCloses = [...sockets].map(s => new Promise(r => { s.once('close', r); s.destroy(); }));
      const baseClosed = new Promise(r => base.once('close', r)); base.shutdown();
      await Promise.all([baseClosed, new Promise(r => tls.close(r)), ...socketCloses]);
      await push.drain(); await turn(); await turn();
      speechWS.clients.forEach(p => p.terminate());
      const speechCloses = [...speechSockets].map(s => new Promise(r => { s.once('close', r); s.destroy(); }));
      await Promise.all([...speechCloses, new Promise(r => speechWS.close(r)), new Promise(r => speechServer.close(r))]);
      await turn();
      assert.deepEqual(adapter.stats(), { stt: 0, tts: 0 }); assert.equal(speechSockets.size, 0);
      const stats = base.openVoiceStats();
      for (const k of ['sessions', 'pendingJobs', 'pendingUpgrades', 'inputPCMBytes', 'rawBytes']) assert.equal(stats[k], 0, k);
      assert.equal(sockets.size, 0); assert.equal(clients.size, 0);
      fs.rmSync(root, { recursive: true, force: true }); return snapshot();
    })();
    return { origin, cert, certificateDER, deviceToken, callerToken: grant.token, build, owner, request, capability, invite,
      diagnostics: () => ({ request_count: requestCount, secure_connections: secureConnections, public_leaf_is_ca: decodedCertificate.ca,
        observations, tls_error_categories: tlsErrors }),
      waitSubmitted: () => boundary('submitted', () => counters.submits > 0),
      waitClosed: () => boundary('owner-closed', () => closedOwners > 0),
      waitCreditEdge: () => boundary('credit-edge', () => counters.synthesisPulls >= 21),
      emptyNext: () => { assert.ok(!forceEmpty); forceEmpty = true; },
      snapshot, releaseResult: async () => { assert.ok(releaseResult); releaseResult(); await turn(); await turn(); return snapshot(); }, stop };
  } catch (e) {
    speechWS.clients.forEach(p => p.terminate()); for (const s of speechSockets) s.destroy(); speechWS.close(); speechServer.close();
    base?.shutdown(); for (const s of sockets) s.destroy(); tls?.close(); fs.rmSync(root, { recursive: true, force: true }); throw e;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  let fixture, bytes = '', total = 0, commands = 0, queue = Promise.resolve();
  const send = value => { const s = JSON.stringify(value); assert.ok(Buffer.byteLength(s) <= 8192); process.stdout.write(s + '\n'); };
  const watchdog = setTimeout(() => { fixture?.stop().finally(() => process.stdin.destroy()); }, 45000);
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => {
    total += Buffer.byteLength(chunk); bytes += chunk;
    if (total > 65536 || Buffer.byteLength(bytes) > 8192) { process.stdin.destroy(); return; }
    while (bytes.includes('\n')) {
      const i = bytes.indexOf('\n'), line = bytes.slice(0, i); bytes = bytes.slice(i + 1);
      queue = queue.then(async () => {
        assert.ok(++commands <= 48); const q = JSON.parse(line);
        if (q.command === 'start') { assert.ok(!fixture); fixture = await startFixture({ scenario: q.scenario });
          send({ event: 'ready', origin: fixture.origin, certificate_der: fixture.certificateDER, device_token: fixture.deviceToken,
            build: fixture.build, node_ref: NODE_REF }); return; }
        assert.ok(fixture);
        if (q.command === 'invite') send({ event: 'invitation', request_id: q.request_id, ...await fixture.invite() });
        else if (q.command === 'snapshot') send({ event: 'snapshot', request_id: q.request_id, ...fixture.snapshot() });
        else if (q.command === 'diagnostics') send({ event: 'diagnostics', request_id: q.request_id, ...fixture.diagnostics() });
        else if (q.command === 'await-submission') { await fixture.waitSubmitted(); send({ event: 'snapshot', request_id: q.request_id, ...fixture.snapshot() }); }
        else if (q.command === 'await-owner-closed') { await fixture.waitClosed(); send({ event: 'snapshot', request_id: q.request_id, ...fixture.snapshot() }); }
        else if (q.command === 'await-credit-edge') { await fixture.waitCreditEdge(); send({ event: 'snapshot', request_id: q.request_id, ...fixture.snapshot() }); }
        else if (q.command === 'empty-next') { fixture.emptyNext(); send({ event: 'snapshot', request_id: q.request_id, ...fixture.snapshot() }); }
        else if (q.command === 'release-result') send({ event: 'snapshot', request_id: q.request_id, ...await fixture.releaseResult() });
        else if (q.command === 'shutdown') { const value = await fixture.stop(); clearTimeout(watchdog); send({ event: 'stopped', ...value }); process.stdin.destroy(); }
        else throw Error('unknown fixture command');
      }).catch(async () => { send({ event: 'error', code: 'fixture_failure' }); await fixture?.stop(); clearTimeout(watchdog); process.stdin.destroy(); process.exitCode = 1; });
    }
  });
  process.stdin.on('close', () => { clearTimeout(watchdog); queue.finally(() => fixture?.stop()).catch(() => { process.exitCode = 1; }); });
}
