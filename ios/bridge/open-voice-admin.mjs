import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { owned } from './push-store.mjs';
import { exact, requireThat as check } from './reachout-policy.mjs';

// Separate socket; no claimed legacy session, HTTP actor, or device token is admin.
// Owner UID is trusted, not isolated from other processes with that UID.
export async function startOpenVoiceAdmin(control, directory, { speechStatus, prepareOutreach, prepareTarget, advanceUnusedTarget, mutationAllowed = () => true, readiness, status, providerSetup, reconcileProvider, beginSignIn, signInStatus } = {}) {
  owned(directory, 'directory', 0o700);
  const socketPath = path.join(directory, 'open-voice-admin.sock');
  if (fs.existsSync(socketPath)) {
    owned(socketPath, 'socket', 0o600);
    const stale = await new Promise(resolve => {
      const p = net.connect(socketPath); p.setTimeout(1000);
      p.on('connect', () => { p.destroy(); resolve(false); });
      p.on('timeout', () => { p.destroy(); resolve(false); });
      p.on('error', e => resolve(e.code === 'ECONNREFUSED'));
    });
    check(stale, 503); fs.unlinkSync(socketPath);
  }
  const sockets = new Set();
  const server = net.createServer(socket => {
    if (sockets.size >= 8) { socket.destroy(); return; }
    sockets.add(socket); socket.on('error', () => {});
    const timer = setTimeout(() => socket.destroy(), 5000);
    socket.once('close', () => { clearTimeout(timer); sockets.delete(socket); });
    let bytes = Buffer.alloc(0), handled = false;
    socket.on('data', chunk => {
      if (handled) return;
      if (bytes.length + chunk.length > 8192) { socket.destroy(); return; }
      bytes = Buffer.concat([bytes, chunk]); if (!bytes.includes(10)) return;
      handled = true;
      Promise.resolve().then(() => {
        const o = JSON.parse(bytes.toString()); exact(o, ['command', 'value', 'grant_id']);
         if (!['speech-status', 'readiness', 'target-status', 'provider-setup', 'sign-in-status', 'list'].includes(o.command)) check(mutationAllowed(), 409);
         if (o.command === 'speech-status') {
           check(o.grant_id === undefined && o.value === undefined && typeof speechStatus === 'function', 400);
           return speechStatus();
         }
         if (o.command === 'readiness') {
          check(o.grant_id === undefined && o.value === undefined && typeof readiness === 'function', 400);
           return readiness();
         }
         if (o.command === 'prepare') {
           check(o.grant_id === undefined && o.value === undefined && typeof prepareOutreach === 'function', 400);
           return prepareOutreach();
         }
        if (o.command === 'advance-unused-target') {
          check(o.grant_id === undefined && typeof advanceUnusedTarget === 'function', 503); return advanceUnusedTarget(o.value);
        }
        if (o.command === 'prepare-target') {
          check(o.grant_id === undefined && typeof prepareTarget === 'function', 503);
          return prepareTarget(o.value);
        }
        if (o.command === 'target-status') {
          check(o.grant_id === undefined && o.value === undefined && typeof status === 'function', 503);
          return status();
        }
        if (['provider-setup', 'reconcile-provider', 'begin-sign-in', 'sign-in-status'].includes(o.command)) {
          check(o.grant_id === undefined && o.value === undefined);
          const action = { 'provider-setup': providerSetup, 'reconcile-provider': reconcileProvider, 'begin-sign-in': beginSignIn, 'sign-in-status': signInStatus }[o.command];
          check(typeof action === 'function', 503); return action();
        }
        return control.push.serial(() => {
          if (o.command !== 'list') check(mutationAllowed(), 409);
          if (o.command === 'issue') { check(o.grant_id === undefined); return control.issue(o.value); }
          if (o.command === 'configure-mapping') { check(o.grant_id === undefined); return control.configureMapping(o.value); }
          check(o.value === undefined);
          if (o.command === 'revoke') return control.revoke(o.grant_id);
          check(o.command === 'list' && o.grant_id === undefined); return { grants: control.list() };
        });
      }).then(result => socket.end(JSON.stringify(result) + '\n'), e => socket.end(JSON.stringify({ error: 'control_refused', status: e.status || 400 }) + '\n'));
    });
  });
  try {
    await new Promise((resolve, reject) => {
      const failed = e => reject(e);
      server.once('error', failed); server.listen(socketPath, () => {
        try { fs.chmodSync(socketPath, 0o600); owned(socketPath, 'socket', 0o600); }
        catch (e) { reject(e); return; }
        server.removeListener('error', failed); resolve();
      });
    });
  } catch (error) {
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve)); throw error;
  }
  server.on('error', () => {});
  return { server, socketPath, close: () => { for (const s of sockets) s.destroy(); return new Promise(resolve => server.close(resolve)); } };
}
