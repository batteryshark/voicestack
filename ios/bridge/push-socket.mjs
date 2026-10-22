import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { owned } from './push-store.mjs';
import { exact, requireThat, stableID } from './reachout-policy.mjs';

export async function startSender(service) {
  const socketPath = path.join(service.store.directory, 'sender.sock');
  owned(service.store.directory, 'directory', 0o700);
  if (fs.existsSync(socketPath)) {
    owned(socketPath, 'socket', 0o600);
    const stale = await new Promise(resolve => {
      const probe = net.connect(socketPath); probe.setTimeout(1000);
      probe.on('connect', () => { probe.destroy(); resolve(false); });
      probe.on('timeout', () => { probe.destroy(); resolve(false); });
      probe.on('error', e => resolve(e.code === 'ECONNREFUSED'));
    });
    requireThat(stale, 503, 'sender already running'); fs.unlinkSync(socketPath);
  }
  const sockets = new Set();
  const server = net.createServer(socket => {
    if (sockets.size >= 8) { socket.destroy(); return; }
    sockets.add(socket); socket.on('close', () => sockets.delete(socket)); socket.on('error', () => {});
    const deadline = setTimeout(() => socket.destroy(), 15000);
    socket.on('close', () => clearTimeout(deadline));
    let bytes = Buffer.alloc(0), handled = false;
    socket.on('data', chunk => {
      if (handled) return;
      bytes = Buffer.concat([bytes, chunk]);
      if (bytes.length > 8192) { socket.destroy(); return; }
      if (!bytes.includes(10)) return;
      handled = true;
      (async () => {
        try {
          const o = JSON.parse(bytes.toString()); exact(o, ['command', 'request', 'id', 'dryRun', 'action']);
          if (o.command === 'maintenance') {
            exact(o, ['command', 'action']); requireThat(service.maintenance, 503);
            socket.end(JSON.stringify(await service.maintenance.command(o.action)) + '\n'); return;
          }
          requireThat(o.action === undefined);
          requireThat(o.dryRun === undefined || typeof o.dryRun === 'boolean');
          let result;
          if (o.command === 'reconcile-ended') {
            exact(o,['command','request']); requireThat(service.maintenance,503);
            await service.maintenance.refresh?.();
            result = service.reconcileEnded(o.request);
          }
          else if (o.command === 'send') { requireThat(o.id === undefined); result = await service.send(o.request, o.dryRun === true); }
          else { requireThat(o.command === 'status' && stableID(o.id) && o.request === undefined); result = service.status(o.id); }
          socket.end(JSON.stringify(result) + '\n');
        } catch (e) { socket.end(JSON.stringify({ error: e.status ? e.message : 'sender unavailable', status: e.status || 503 }) + '\n'); }
      })().catch(() => { socket.end(JSON.stringify({ error: 'push work limit', status: 429 }) + '\n'); });
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, () => { fs.chmodSync(socketPath, 0o600); resolve(); }); });
  await service.serial(() => service.recover());
  const timer = setInterval(() => { service.serial(() => service.recover()).catch(() => {}); }, 1000); timer.unref();
  return { server, socketPath, close: () => { clearInterval(timer); for (const s of sockets) s.destroy(); return new Promise(resolve => server.close(resolve)); } };
}
