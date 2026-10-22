import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';

for (const signal of ['SIGTERM', 'SIGINT']) {
  test(`serve starts privately and exits cleanly on ${signal}`, { timeout: 10000 }, async t => {
    const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fv-serve-')));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    // Exact production sources in an owned layout: defaultBinding resolves here,
    // not into the real checkout. No private/config/output/renderer corpus copied.
    for (const name of ['server', 'event-lifetime', 'push-store', 'push-service', 'apns', 'push-socket',
      'rich-content', 'canvas-page', 'oc-client', 'sender', 'speech-timing', 'reachout-policy',
      'open-voice-control', 'open-voice-end-policy', 'open-voice-media', 'open-voice-profile', 'maintenance', 'deployment-preflight']) {
      copySource(`bridge/${name}.mjs`);
    }
    copySource('shared/presentation.json');
    copySource('bridge/renderer/resources.mjs');
    copySource('bridge/package.json'); copySource('bridge/package-lock.json');
    // Stage only the pinned public library, including its notice; no npm/config reads or installs.
    for (const name of ['package.json', 'index.js', 'wrapper.mjs', 'browser.js', 'LICENSE', 'README.md']) copySource('bridge/node_modules/ws/' + name);
    for (const entry of fs.readdirSync(new URL('./node_modules/ws/lib/', import.meta.url), { withFileTypes: true })) {
      assert.ok(entry.isFile() && /^[a-z-]+\.js$/.test(entry.name));
      copySource('bridge/node_modules/ws/lib/' + entry.name);
    }
    function copySource(relative) {
      const source = new URL('../' + relative, import.meta.url);
      const fd = fs.openSync(source, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      try {
        assert.ok(fs.fstatSync(fd).isFile(), 'only regular production source files');
        const bytes = fs.readFileSync(fd), target = path.join(dir, relative);
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, bytes);
        assert.deepEqual(fs.readFileSync(target), bytes);
      } finally { fs.closeSync(fd); }
    }
    assert.equal(fs.existsSync(path.join(dir, 'private/openchamber/client.json')), false);
    const binding = path.join(dir, 'private/openchamber');
    fs.mkdirSync(binding, {recursive: true, mode: 0o700});
    const dedupeKey = 'voicestack:' + '0'.repeat(32);
    fs.writeFileSync(path.join(binding, 'identity.json'), JSON.stringify({dedupeKey}), {mode: 0o600});
    fs.writeFileSync(path.join(binding, 'client.json'), JSON.stringify({version: 1, clientId: 'synthetic-client', clientKind: 'desktop', label: 'Synthetic Voicestack',
      clientToken: 'oc_client_SYNTHETIC_FIXTURE_ONLY', dedupeKey, fingerprint: 'synthetic-fingerprint', enrolledOrigin: 'http://127.0.0.1:1'}), {mode: 0o600});
    const file = path.join(dir, 'store.json');
    fs.writeFileSync(file, JSON.stringify({ bootstrap: '', expires: 0, devices: {} }), { mode: 0o600 });
    const probe = net.createServer();
    probe.listen(0, '127.0.0.1');
    await once(probe, 'listening');
    const port = probe.address().port;
    await new Promise(resolve => probe.close(resolve));
    const child = spawn(process.execPath, [path.join(dir, 'bridge/server.mjs'), 'serve', file, String(port)],
      { cwd: dir, env: { ...process.env, HOME: dir, FV_PUSH_ENABLED: '0' } });
    const exited = once(child, 'exit');
    try {
      const [line] = await once(child.stderr, 'data');
      assert.equal(line.toString(), `Bridge listening on port ${port}\n`);
      const response = await fetch(`http://127.0.0.1:${port}/floating-voice/v1/health`);
      assert.equal(response.status, 401);
      child.kill(signal);
      assert.deepEqual(await exited, [0, null]);
    } finally {
      if (child.exitCode === null) child.kill('SIGKILL');
      await exited;
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
}
