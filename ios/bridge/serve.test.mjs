import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { fileURLToPath } from 'node:url';

for (const signal of ['SIGTERM', 'SIGINT']) {
  test(`serve starts privately and exits cleanly on ${signal}`, { timeout: 10000 }, async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-serve-'));
    const file = path.join(dir, 'store.json');
    fs.writeFileSync(file, JSON.stringify({ bootstrap: '', expires: 0, devices: {} }), { mode: 0o600 });
    const probe = net.createServer();
    probe.listen(0, '127.0.0.1');
    await once(probe, 'listening');
    const port = probe.address().port;
    await new Promise(resolve => probe.close(resolve));
    const child = spawn(process.execPath, [fileURLToPath(new URL('./server.mjs', import.meta.url)), 'serve', file, String(port)]);
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
