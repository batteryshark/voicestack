import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PROFILE, LIMITS, DEFAULT_CONFIG, ERROR_CODES, createSession,
  applySessionUpdate, validateClientEvent, validateServerEvent } from './open-voice-profile.mjs';

const vectors = JSON.parse(readFileSync(new URL('./fixtures/open-voice/vectors.json', import.meta.url)));
const clone = v => structuredClone(v);
const session = () => createSession('sess_fixture').value;
const good = vectors.client.find(c => c.name === 'explicit-response');
const compose = text => ({ type: 'conversation.item.create', item: {
  id: 'item_1', type: 'message', role: 'user', content: [{ type: 'input_text', text }] } });
test('streamed whitespace is exact text, not a canonical thought; errors require primitive code', () => {
  for (const type of ['response.output_text.delta', 'response.output_audio_transcript.delta']) {
    const base = { type, event_id: 's', response_id: 'r', item_id: 'i', output_index: 0, content_index: 0 };
    for (const delta of ['', ' ', '\n', '\t', ' \n\t']) {
      const r = validateServerEvent({ ...base, delta }); assert.ok(r.ok); assert.equal(r.value.delta, delta);
      assert.equal(validateClientEvent(compose(delta)).ok, false);
    }
    for (const delta of [null, [], {}, 1, true, '\ud800', '\u0000', 'a'.repeat(LIMITS.maxTextScalars + 1)])
      assert.equal(validateServerEvent({ ...base, delta }).ok, false);
  }
  for (const type of ['error', 'conversation.item.input_audio_transcription.failed']) {
    const base = { type, event_id: 's', ...(type === 'error' ? {} : { item_id: 'i', content_index: 0 }) };
    for (const code of [['local_failure'], {}, null, 1, true, false]) assert.equal(validateServerEvent({ ...base,
      error: { type: 'server_error', code, message: ERROR_CODES.local_failure, param: null } }).ok, false);
  }
});
function expected(result, want) {
  assert.equal(result.ok, want.ok, JSON.stringify(result));
  if (!want.ok) assert.equal(result.error.code, want.code);
  if (want.effect) assert.equal(result.effect.kind, want.effect);
}
test('frozen fixture envelope and named cases', { timeout: 2000 }, () => {
  assert.equal(vectors.profile, PROFILE); assert.equal(vectors.schemaVersion, 1);
  assert.deepEqual(session(), vectors.defaultSession);
  const schema = JSON.parse(readFileSync(new URL('./fixtures/open-voice/vectors.schema.json', import.meta.url)));
  assert.equal(schema.properties.profile.const, PROFILE);
  for (const group of ['client', 'server', 'updates', 'futureState']) {
    assert.equal(new Set(vectors[group].map(v => v.name)).size, vectors[group].length);
    for (const v of vectors[group]) assert.ok(v.name);
  }
  for (const v of vectors.futureState) assert.equal(v.enforcement, 'future-state');
});
for (const c of vectors.client) test(`client: ${c.name}`, { timeout: 2000 }, () => {
  const before = clone(c); expected(validateClientEvent(c.input, c.context), c.expected); assert.deepEqual(c, before);
});
for (const c of vectors.server) test(`server: ${c.name}`, { timeout: 2000 }, () => expected(validateServerEvent(c.input), c.expected));
for (const c of vectors.updates) test(`atomic update: ${c.name}`, { timeout: 2000 }, () => {
  const current = session(), before = clone(current), patch = clone(c.patch);
  const result = applySessionUpdate(current, patch, c.context); expected(result, c.expected);
  assert.deepEqual(current, before); assert.deepEqual(patch, c.patch);
  if (result.ok) {
    assert.deepEqual(result.session.output_modalities, c.expected.output_modalities);
    assert.deepEqual(result.session.audio, DEFAULT_CONFIG.audio);
  }
});
test('session construction, retained omitted values, no aliases and immutable defaults', { timeout: 2000 }, () => {
  assert.equal(createSession(undefined).ok, false); assert.equal(createSession('bad id').ok, false);
  const current = session();
  const a = applySessionUpdate(current, { output_modalities: ['text'] });
  const b = applySessionUpdate(a.session, { audio: { output: { speed: 1 } } });
  assert.deepEqual(b.session.output_modalities, ['text']);
  assert.notEqual(b.session.audio, a.session.audio);
  assert.notEqual(current.audio, DEFAULT_CONFIG.audio);
  assert.throws(() => { DEFAULT_CONFIG.audio.input.format.rate = 16000; }, TypeError);
  assert.throws(() => { b.session.audio.input.format.rate = 16000; }, TypeError);
  const patch = { output_modalities: ['text'] }; const r = applySessionUpdate(current, patch);
  patch.output_modalities[0] = 'audio'; assert.deepEqual(r.session.output_modalities, ['text']);
  assert.deepEqual(current.output_modalities, ['audio']);
  const e = validateClientEvent({ type: 'session.update', session: { type: 'realtime', audio: { input: { turn_detection: null } } } }, { effectiveSession: current });
  assert.ok(e.ok); assert.deepEqual(e.effect.session, current);
  assert.ok(validateServerEvent({ event_id: 's1', type: 'session.created', session: current }).ok);
  assert.ok(validateServerEvent({ event_id: 's2', type: 'session.updated', session: b.session }).ok);
});
test('canonical equality independent of object key order; exact text/id; UUID conflicts; one response', { timeout: 2000 }, () => {
  const input = clone(good.input), context = clone(good.context);
  context.canonicalItem = { content: context.canonicalItem.content, role: 'user', type: 'message', id: 'item_user' };
  assert.ok(validateClientEvent(input, context).ok);
  context.activeResponseId = 'resp_active'; assert.equal(validateClientEvent(input, context).error.code, 'response_in_progress');
  delete context.activeResponseId;
  for (const id of ['not-a-uuid', '00000000-0000-0000-0000-000000000000', 5, null]) {
    const e = clone(input); e.response.metadata.operation_id = id; assert.equal(validateClientEvent(e, context).ok, false);
  }
  for (const field of ['id', 'content']) {
    const c = clone(context); if (field === 'id') c.canonicalItem.id = 'other'; else c.canonicalItem.content[0].text += ' ';
    assert.equal(validateClientEvent(input, c).error.code, 'item_mismatch');
  }
  const c = clone(context); c.priorOperation = { operation_id: input.response.metadata.operation_id, item: clone(c.canonicalItem) };
  assert.ok(validateClientEvent(input, c).ok); // equality only, not authorization to execute again
  const text = clone(input); text.response.output_modalities = ['text']; assert.ok(validateClientEvent(text, context).ok);
  const detached = validateClientEvent(input, context); input.response.input[0].content[0].text = 'changed';
  assert.equal(detached.value.response.input[0].content[0].text, 'Review this.');
});
test('unsupported configuration cannot smuggle instructions, tools, identity, URLs or history', { timeout: 2000 }, () => {
  for (const patch of [null, [], { tools: [{}] }, { tool_choice: 'auto' }, { prompt: {} }, { tracing: 'auto' },
    { reasoning: {} }, { audio: { input: { transcription: { prompt: 'hidden' } } } },
    { audio: { input: { format: { type: 'audio/pcmu' } } } }, { audio: { output: { speed: 1.2 } } },
    { audio: { input: { noise_reduction: {} } } }, { type: 'transcription' }, { user_id: 'fixture' },
    { upstream_url: 'https://example.invalid' }]) assert.equal(applySessionUpdate(session(), patch).ok, false);
  for (const key of ['instructions', 'tools', 'conversation', 'previous_response_id', 'model', 'user']) {
    const input = clone(good.input); input.response[key] = 'forbidden'; assert.equal(validateClientEvent(input, good.context).ok, false);
  }
  for (const value of [[], ['text', 'audio'], ['audio', 'audio'], 'audio', null]) {
    const input = clone(good.input); input.response.output_modalities = value; assert.equal(validateClientEvent(input, good.context).ok, false);
  }
});
test('deterministic PCM frame/sample/segment boundaries', { timeout: 2000 }, () => {
  for (const bytes of [2, 960, 4800]) {
    const b = Buffer.alloc(bytes); for (let i = 0; i < bytes; i += 2) b.writeInt16LE((i % 65536) - 32768, i);
    const e = validateClientEvent({ type: 'input_audio_buffer.append', audio: b.toString('base64') });
    assert.ok(e.ok); assert.equal(e.effect.samples, bytes / 2);
    assert.deepEqual(Buffer.from(e.value.audio, 'base64'), b);
  }
  for (const bytes of [0, 1, 3, 4799, 4801, 4802, 96000])
    assert.equal(validateClientEvent({ type: 'input_audio_buffer.append', audio: Buffer.alloc(bytes).toString('base64') }).ok, false);
  for (const audio of ['AAA_', 'AAA-', 'AAA===', '!!!!', ' AAA=', 'AAA=\r\n', 1, null])
    assert.equal(validateClientEvent({ type: 'input_audio_buffer.append', audio }).ok, false);
  for (const b of [Buffer.from('ID3\0'), Buffer.from([255, 251, 144, 0])])
    assert.equal(validateClientEvent({ type: 'input_audio_buffer.append', audio: b.toString('base64') }).ok, false);
  for (const b of [Buffer.from([255, 255, 255, 255]), Buffer.from([210, 201, 198, 198])])
    assert.ok(validateClientEvent({ type: 'input_audio_buffer.append', audio: b.toString('base64') }).ok);
  assert.ok(validateClientEvent({ type: 'input_audio_buffer.commit' }, { bufferSamples: LIMITS.maxSegmentSamples }).ok);
  for (const bufferSamples of [-1, 0.5, Infinity, LIMITS.maxSegmentSamples + 1])
    assert.equal(validateClientEvent({ type: 'input_audio_buffer.commit' }, { bufferSamples }).ok, false);
  assert.equal(LIMITS.maxFrameBytes, LIMITS.maxFrameSamples * 2);
  assert.equal(LIMITS.maxQueueBytes, LIMITS.windowSamples * 2);
});
test('UTF-8 message boundary, strict JSON, Unicode scalar and text limits', { timeout: 2000 }, () => {
  const plain = JSON.stringify({ type: 'input_audio_buffer.clear' });
  assert.ok(validateClientEvent(plain + ' '.repeat(65536 - Buffer.byteLength(plain))).ok);
  assert.equal(validateClientEvent(plain + ' '.repeat(65537 - Buffer.byteLength(plain))).error.code, 'message_too_large');
  assert.ok(validateClientEvent(compose('a'.repeat(16000))).ok);
  assert.equal(validateClientEvent(compose('a'.repeat(16001))).ok, false);
  assert.ok(validateClientEvent(compose('🐟'.repeat(16000))).ok);
  assert.equal(validateClientEvent(compose('🐟'.repeat(16001))).ok, false);
  for (const text of ['\ud800', '\udfff', 'abc\u0000', '\t\n  ', '\u007f', 1, null]) assert.equal(validateClientEvent(compose(text)).ok, false);
  const text = '  é é 🐟\r\n\t unchanged  ';
  assert.equal(validateClientEvent(compose(text)).value.item.content[0].text, text);
  for (const input of ['', '{', 'null', '[]', '1', '{"type":"input_audio_buffer.clear",}',
    '{"type":"input_audio_buffer.clear","\\u0074ype":"input_audio_buffer.clear"}',
    '{"type":"input_audio_buffer.clear","__proto__":{}}']) assert.equal(validateClientEvent(input).ok, false);
});
test('non-JSON bodies fail closed without mutation or accessor execution', { timeout: 2000 }, () => {
  let called = false;
  const getter = { get type() { called = true; return 'input_audio_buffer.clear'; } };
  const cycle = {}; cycle.self = cycle;
  for (const input of [undefined, 1n, Symbol('x'), () => {}, new Date(), new Map(), Buffer.alloc(2), cycle,
    { type: 'input_audio_buffer.clear', extra: undefined }, { a: NaN }, { a: Infinity }, getter])
    assert.equal(validateClientEvent(input).ok, false);
  assert.equal(called, false);
  const hidden = { type: 'input_audio_buffer.clear' };
  Object.defineProperty(hidden, 'toJSON', { value() { called = true; return {}; } });
  assert.equal(validateClientEvent(hidden).ok, false); assert.equal(called, false);
  const nested = {}; let p = nested; for (let i = 0; i < 20; i++) p = p.next = {};
  assert.equal(validateClientEvent(nested).ok, false);
});
test('positions and identity checks are fail closed', { timeout: 2000 }, () => {
  const t = vectors.client.find(c => c.name === 'truncate-exact-duration');
  for (const [key, values] of Object.entries({ content_index: [-1, 1, '0'], audio_end_ms: [-1, 0.5, Number.MAX_SAFE_INTEGER + 1], item_id: ['other', '', 'https://example.invalid'] }))
    for (const value of values) { const e = clone(t.input); e[key] = value; assert.equal(validateClientEvent(e, t.context).ok, false); }
  assert.equal(validateClientEvent({ type: 'response.cancel', response_id: 'other' }, { activeResponseId: 'r1' }).error.code, 'no_active_response');
});
test('server lifecycle shapes fail closed; generation never asserts playback', { timeout: 2000 }, () => {
  for (const c of vectors.server.filter(v => v.expected.ok)) {
    const extra = clone(c.input); extra.unrecognized = true; assert.equal(validateServerEvent(extra).ok, false);
  }
  for (const kind of ['response.output_audio.done', 'response.output_text.done']) {
    const c = clone(vectors.server.find(v => v.input.type === kind).input); c.output_index = 1; assert.equal(validateServerEvent(c).ok, false);
  }
  const e = clone(vectors.server.find(v => v.name === 'generation-completed-not-heard').input);
  e.response.output = [{ id: 'reply', object: 'realtime.item', type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_audio', transcript: 'Hi' }] }];
  assert.ok(validateServerEvent(e).ok);
  e.response.output[0].content[0].audio = 'AAA='; assert.equal(validateServerEvent(e).ok, false);
});
test('errors are sanitized static taxonomy with only safe event correlation', { timeout: 2000 }, () => {
  const e = validateClientEvent({ type: 'unknown', event_id: 'evt_safe', private_token: 'do-not-reflect' });
  assert.equal(e.error.event_id, 'evt_safe'); assert.equal(e.error.param, null);
  assert.equal(e.error.message, ERROR_CODES.unsupported_feature);
  assert.ok(!JSON.stringify(e).includes('do-not-reflect'));
  assert.equal(validateClientEvent({ type: 'unknown', event_id: 'unsafe id' }).error.event_id, undefined);
});
