import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { once } from 'node:events';
import { createBridge } from './server.mjs';
import { OpenChamberClient } from './oc-client.mjs';

test('2.4.0: 450 sessions page newest-first; direct selection #300 uses own oc-client; test identity remains scoped', async () => {
  const sessions = Array.from({ length: 450 }, (_, i) => ({ id: `ses_${i+1}`, title: `Session ${i+1}`, time: { updated: 450-i }, parentID: i ? 'ses_1' : undefined }));
  const reads = [], clientToken = 'oc_client_synthetic_paging_only';
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-paging-'));
  fs.chmodSync(directory, 0o700);
  const fake = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://fixture');
    if (req.url === '/health') { assert.equal(req.headers.authorization, undefined); return res.end('{"openchamberVersion":"2.4.0"}'); }
    reads.push(req.url);
    if (req.headers.authorization !== `Bearer ${clientToken}`) { res.writeHead(401); return res.end('{}'); }
    if (url.pathname === '/api/system/info') return res.end('{"runtime":"desktop"}');
    if (url.pathname === '/api/session') {
      if (!url.searchParams.has('cursor')) assert.equal(url.searchParams.get('order'), 'desc');
      else assert.equal(url.searchParams.has('order'), false);
      const start = Number(url.searchParams.get('cursor')?.replace('offset_', '') ?? 0);
      const limit = Number(url.searchParams.get('limit'));
      return res.end(JSON.stringify({ data: sessions.slice(start, start+limit), cursor: { previous: null, next: start+limit < 450 ? `offset_${start+limit}` : null } }));
    }
    const session = sessions.find(s => url.pathname === `/api/session/${s.id}`);
    if (session) return res.end(JSON.stringify({ data: session }));
    res.writeHead(404); res.end('{}');
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  const file = path.join(directory, 'client.json');
  fs.writeFileSync(file, JSON.stringify({ version:1, clientId:'synthetic', clientKind:'desktop', label:'Owned paging fixture', clientToken,
    enrolledOrigin:`http://127.0.0.1:${fake.address().port}` }), { mode:0o600 });
  const ordinary = { deviceID:'phone' }, scoped = { deviceID:'test', test:{ sessionID:'ses_300', expires:Date.now()+60000 } };
  const bridge = createBridge({ discover: () => fake.address().port, ocClient:new OpenChamberClient({ file }),
    credentials:{ device: auth => auth === 'Bearer synthetic-test' ? scoped : ordinary, save() {} } });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  const call = (route, body, testIdentity = false) => fetch(`http://127.0.0.1:${bridge.address().port}/floating-voice${route}`, {
    method: body ? 'POST':'GET', headers:{ Authorization:testIdentity ? 'Bearer synthetic-test':'Bearer synthetic-phone',
      ...(body ? {'Content-Type':'application/json'}:{}) }, ...(body ? {body:JSON.stringify(body)}:{}) });
  try {
    const listed = []; let cursor;
    do {
      const response = await call('/v1/sessions'+(cursor ? '?cursor='+cursor:'')); assert.equal(response.status,200);
      const page = await response.json(); listed.push(...page.data); cursor = page.cursor?.next;
    } while (cursor);
    assert.deepEqual(listed.map(s => s.id), sessions.map(s => s.id));
    assert.equal(reads.filter(r => r.startsWith('/api/session?')).length,3);
    const before = reads.length;
    const selection = await call('/v1/selection',{sessionID:'ses_300',mode:'explicit'});
    assert.equal(selection.status,200); assert.ok((await selection.json()).generation);
    assert.deepEqual(reads.slice(before), ['/api/system/info','/api/session/ses_300']);
    assert.equal(ordinary.sessionID,'ses_300');
    const granted = ordinary.generation;
    assert.notEqual((await call('/v1/selection',{sessionID:'ses_missing',mode:'explicit'})).status,200);
    assert.equal(ordinary.generation,granted);
    const count = reads.length;
    for (const query of ['limit=0','limit=201','limit=2&limit=3','cursor=','cursor=a&cursor=b','order=asc','directory=private','cursor=bad.cursor']) {
      assert.equal((await call('/v1/sessions?'+query)).status,400,query);
    }
    assert.equal(reads.length,count,'bad query rejected before desktop lookup');
    for (const query of ['', '?cursor=offset_200']) {
      const response = await call('/v1/sessions'+query,undefined,true); assert.equal(response.status,200);
      assert.deepEqual(await response.json(), {data:[sessions[299]]});
    }
    const restrictedReads = reads.length;
    for (const body of [{sessionID:'ses_1',mode:'explicit'},{sessionID:'ses_300',mode:'chief'}]) {
      assert.equal((await call('/v1/selection',body,true)).status,403);
    }
    assert.equal(reads.length,restrictedReads,'scope rejection precedes direct lookup');
    assert.equal((await call('/v1/selection',{sessionID:'ses_300',mode:'explicit'},true)).status,200);
    assert.equal(scoped.sessionID,'ses_300');
  } finally {
    bridge.shutdown(); fake.closeAllConnections(); await new Promise(resolve => fake.close(resolve));
    fs.rmSync(directory,{recursive:true});
  }
});
