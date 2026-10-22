// Only this owned child loads SDK code; the bridge keeps its own environment.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { syncBuiltinESMExports } from 'node:module';
import { createExchange } from './exchange.mjs';

const root = process.env.VOICE_HARNESS_ROOT;
// Provider initialization is an explicit owner step, never automatic startup.
// Device authorization alone may contact its native auth origin. Ordinary
// runtime outbound is enabled only by observed completion or explicit owner
// reconciliation of the normal saved own OAuth connection and exact pins.
const nativeFetch = globalThis.fetch;
const nativeConnect = net.Socket.prototype.connect;
let networkPhase = 'closed';
const denyNetwork = () => { throw new Error('provider_initialization_required'); };
globalThis.fetch = (input, init) => {
  const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
  if (networkPhase === 'provider' || networkPhase === 'auth' && url.origin === 'https://auth.openai.com') return nativeFetch(input, init);
  return denyNetwork();
};
net.Socket.prototype.connect = function (...args) {
  if (networkPhase === 'closed') return denyNetwork();
  return nativeConnect.apply(this, args);
};
net.Server.prototype.listen = denyNetwork;
syncBuiltinESMExports();
let exchange, pending = 0, closing;
const send = value => new Promise(resolve => {
  if (!process.connected) return resolve();
  process.send(JSON.stringify(value), () => resolve());
});
const cleanup = () => closing ??= (async () => {
  await exchange?.close();
  // fd4 is the parent's exact exclusive lock file, not a discovered PID/token.
  try {
    const ours = fs.fstatSync(4), current = fs.lstatSync(path.join(root, 'owner.lock'));
    if (ours.dev === current.dev && ours.ino === current.ino) fs.unlinkSync(path.join(root, 'owner.lock'));
  } catch { /* Parent also releases only its exact lock inode after child exit. */ }
})();
const drainAndClose = async () => { await exchange?.waitUntilLocalQuiet(); await cleanup(); };
process.on('disconnect', () => { drainAndClose().finally(() => { process.exitCode = 0; }); });
process.on('SIGTERM', () => { drainAndClose().finally(() => { if (process.connected) process.disconnect(); }); });
try {
  exchange = await createExchange({ root, bundledModels: true, onProviderPhase: phase => { networkPhase = phase; } });
  process.on('message', async wire => {
    let message;
    try {
      if (typeof wire !== 'string' || Buffer.byteLength(wire) > 131072 || pending >= 4 || closing) throw new Error();
      message = JSON.parse(wire);
      if (!Number.isSafeInteger(message.id) || message.id < 1 || !['prepare', 'advanceUnused', 'verify', 'submit', 'appendEnd', 'read', 'capability', 'providerSetup', 'reconcileProvider', 'beginSignIn', 'signInStatus', 'stats', 'close'].includes(message.action)) throw new Error();
    } catch { await send({ id: message?.id, ok: false, error: 'harness_refused' }); return; }
    pending++;
    try {
      if (message.action === 'close') {
        const local = await exchange.runtimeStats();
        if (!local.localWorkKnown || local.localWorkPending) throw new Error('local_sdk_work_pending');
        await cleanup(); await send({ id: message.id, ok: true, value: { closed: true } });
        process.disconnect();
      } else {
        if (message.action === 'submit' && (networkPhase !== 'provider' || !(await exchange.capability()).ready)) throw new Error('provider_initialization_required');
        const value = message.action === 'stats' ? await exchange.runtimeStats() : await exchange[message.action](message.input);
        if (message.action === 'capability') {
          value.outboundEnabled = networkPhase === 'provider';
          value.ready &&= value.outboundEnabled;
          if (!value.outboundEnabled && value.reason !== 'unprepared' && value.reason !== 'single_use_unavailable') value.reason = 'provider_initialization_required';
        }
        await send({ id: message.id, ok: true, value });
      }
    } catch { await send({ id: message.id, ok: false, error: 'harness_refused' }); }
    finally { pending--; }
  });
  await send({ ready: true }); // Process initialized, NOT speech/provider readiness.
} catch { await cleanup(); await send({ ready: false }); process.disconnect?.(); process.exitCode = 1; }
