import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { OpenChamberClient } from '../oc-client.mjs';

// Legacy/unpaired and speech/push-only fixtures must also opt out of ambient auth.
export function unpairedDesktop(t, server) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-unpaired-desktop-'));
  t.after(() => fs.rmSync(directory, { recursive: true }));
  const port = server?.address().port;
  return {
    ocClient: new OpenChamberClient({ file: path.join(directory, 'absent-client.json') }),
    discover: () => {
      assert.ok(Number.isInteger(port), 'this fixture has no desktop listener');
      return port;
    },
  };
}

// Test-only paired desktop: real client verification, never the ambient binding.
export function syntheticDesktop(t, server) {
  const port = server.address().port;
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-synthetic-desktop-'));
  t.after(() => fs.rmSync(directory, { recursive: true }));
  fs.chmodSync(directory, 0o700);
  const file = path.join(directory, 'client.json');
  const authorization = 'Bearer oc_client_SYNTHETIC_RICH_FIXTURE';
  fs.writeFileSync(file, JSON.stringify({ version: 1, clientId: 'synthetic-rich', clientKind: 'desktop',
    label: 'Owned rich fixture', clientToken: authorization.slice(7), enrolledOrigin: `http://127.0.0.1:${port}` }), { mode: 0o600 });
  const ocClient = new OpenChamberClient({ file });
  const prepare = ocClient.prepare.bind(ocClient);
  ocClient.prepare = (target, signal) => {
    assert.equal(target, port, 'only the owned fixture listener may be contacted');
    return prepare(target, signal);
  };
  const requests = [];
  return { ocClient, file, requests,
    accept(req, res) {
      assert.equal(req.socket.localAddress, '127.0.0.1');
      assert.equal(req.socket.localPort, port);
      requests.push(req.url);
      if (req.url === '/health') {
        assert.equal(req.headers.authorization, undefined, 'health must not receive a bearer');
        res.end('{"openchamberVersion":"synthetic-rich-fixture"}');
        return false;
      }
      assert.equal(req.headers.authorization, authorization, 'desktop gets only its synthetic bearer, never the phone bearer');
      if (req.url === '/api/client-auth/clients') {
        res.end('{"clients":[{"id":"synthetic-rich","clientKind":"desktop"}]}');
        return false;
      }
      return true;
    },
  };
}
