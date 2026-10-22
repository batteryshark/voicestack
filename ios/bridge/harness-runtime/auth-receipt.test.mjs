import test from 'node:test';
import assert from 'node:assert/strict';
import { observeAuthReceipt } from './auth-receipt.mjs';

test('terminal receipt survives native pruning without another native read', async () => {
  const attempts = new Map([['exact', { status: 'complete', time: { created: 1, expires: 2 } }]]);
  let reads = 0, cancels = 0;
  const receipt = observeAuthReceipt({ expires: Date.now() + 1000,
    read: async () => { reads++; return attempts.get('exact') ?? { status: 'receipt_unavailable' }; },
    cancel: async () => { cancels++; },
  });
  await receipt.done; attempts.clear();
  assert.deepEqual(receipt.snapshot(), { status: 'complete', time: { created: 1, expires: 2 } });
  assert.equal(reads, 1); assert.equal(cancels, 0); assert.deepEqual(receipt.work(), { busy: false, known: true });
});

test('native expired and not-found stay distinct; cleanup remains work until it settles', async () => {
  for (const status of ['expired', 'receipt_unavailable']) {
    const gate = Promise.withResolvers(); let cancel = false;
    const receipt = observeAuthReceipt({ expires: Date.now() + 1000,
      read: async () => ({ status }), cancel: async () => { cancel = true; await gate.promise; },
    });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(receipt.snapshot().status, status);
    assert.equal(receipt.work().busy, status !== 'expired');
    assert.equal(cancel, status !== 'expired');
    gate.resolve(); await receipt.done;
    assert.deepEqual(receipt.work(), { busy: false, known: true });
  }
});

test('finite deadline and read failure clean up once; cleanup failure stays unknown, never success', async () => {
  for (const mode of ['deadline', 'read-error', 'cleanup-error']) {
    let cancels = 0;
    const receipt = observeAuthReceipt({ expires: Date.now() + 1000, maxMs: 15, pollMs: 2,
      read: async () => { if (mode === 'read-error') throw Error('synthetic'); return { status: cancels ? 'receipt_unavailable' : 'pending' }; },
      cancel: async () => { cancels++; if (mode === 'cleanup-error') throw Error('synthetic'); },
    });
    assert.equal(receipt.work().busy, true); await receipt.done;
    assert.equal(cancels, 1); assert.equal(receipt.snapshot().status, 'receipt_unavailable');
    assert.deepEqual(receipt.work(), { busy: false, known: mode === 'deadline' });
  }
});
