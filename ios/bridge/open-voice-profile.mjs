/** Pure open-voice M1 conformance; no transport, authorization, ledger or media execution.
 * API: validateClientEvent(JSON string | JSON object, context), validateServerEvent(input),
 * applySessionUpdate(effectiveSession, partialSession, context), createSession(id).
 * Results: {ok:true,value,effect?} / {ok:false,error:{type,code,message,param,event_id?}}.
 * Updates return {ok:true,session}; failures never mutate their arguments.
 * Success values are detached, recursively frozen JSON. Text is never normalized/trimmed.
 * Strings count Unicode scalar values (not UTF-16 units); lone surrogates/control bodies fail.
 * JSON depth is limited to 16. Duplicate keys and non-JSON JS properties fail closed.
 * Context is a trusted snapshot, NOT authority: bufferSamples, activeResponseId,
 * canonicalItem, effectiveSession, priorOperation:{operation_id,item},
 * truncateTarget:{item_id,generatedSamples}. Required where a state check is necessary.
 * event_id is correlation only. priorOperation compares payloads, NOT durable deduplication.
 * Extension vs.flow/vs.playback shapes validate only; epochs/credit/time/order are future state.
 */
export const PROFILE = 'open-voice-m1-ga-ws/1';
const freeze = value => {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(freeze);
    Object.freeze(value);
  }
  return value;
};
export const LIMITS = freeze({ sampleRate: 24000, channels: 1, bytesPerSample: 2,
  nominalFrameSamples: 480, maxFrameSamples: 2400, maxFrameBytes: 4800,
  maxMessageBytes: 65536, maxTextScalars: 16000, maxSegmentSamples: 2160000,
  maxQueueBytes: 96000, maxAggregateBytes: 524288, maxWritableBytes: 262144,
  windowSamples: 48000 });
export const DEFAULT_CONFIG = freeze({ type: 'realtime', model: 'local-chain-m1',
  output_modalities: ['audio'], tools: [], tool_choice: 'none', instructions: '',
  audio: { input: { format: { type: 'audio/pcm', rate: 24000 }, noise_reduction: null,
    turn_detection: null, transcription: { model: 'local-stt' } },
  output: { format: { type: 'audio/pcm', rate: 24000 }, voice: 'local-default', speed: 1 } } });
export const ERROR_CODES = freeze({ invalid_json: 'Invalid JSON message.',
  invalid_request: 'Invalid profile request.', unsupported_feature: 'Unsupported profile feature.',
  message_too_large: 'Message exceeds profile limit.', invalid_audio: 'Invalid PCM frame.',
  context_required: 'Required state snapshot is missing.', empty_buffer: 'Input buffer is empty.',
  response_in_progress: 'A response is already active.', no_active_response: 'No matching active response.',
  item_mismatch: 'Input does not match the composed item.', operation_conflict: 'Operation payload conflicts.',
  invalid_position: 'Invalid media position.', local_failure: 'Local processing failed.' });
class Invalid extends Error { constructor(code) { super(code); this.code = code; } }
const fail = (code = 'invalid_request') => { throw new Invalid(code); };
const check = (condition, code) => { if (!condition) fail(code); };
const record = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const keys = (o, allowed, required = allowed) => {
  check(record(o));
  check(Object.keys(o).every(k => allowed.includes(k)), 'unsupported_feature');
  check(required.every(k => Object.hasOwn(o, k)));
};
const id = v => check(typeof v === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(v));
const uint = v => check(Number.isSafeInteger(v) && v >= 0);
const zero = v => check(v === 0, 'invalid_position');
const scalarText = (v, empty = true) => {
  check(typeof v === 'string' && [...v].length <= LIMITS.maxTextScalars);
  check(!/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(v));
  if (!empty) check(/\S/u.test(v));
};
const modalities = v => check(Array.isArray(v) && v.length === 1 && ['audio', 'text'].includes(v[0]), 'unsupported_feature');
const same = (a, b) => {
  if (a === b) return true;
  if (!a || !b || typeof a !== 'object' || typeof b !== 'object') return false;
  return Array.isArray(a) === Array.isArray(b) && Object.keys(a).length === Object.keys(b).length
    && Object.keys(a).every(k => Object.hasOwn(b, k) && same(a[k], b[k]));
};
// Fail closed for non-JSON JS bodies, getters, cycles, prototype keys and lone surrogates.
function jsonTree(v, depth = 0, seen = new Set()) {
  check(depth <= 16);
  if (typeof v === 'string') { check(!/[\uD800-\uDFFF]/u.test(v)); return; }
  if (v === null || typeof v === 'boolean') return;
  if (typeof v === 'number') { check(Number.isFinite(v)); return; }
  check(typeof v === 'object' && (Array.isArray(v) || Object.getPrototypeOf(v) === Object.prototype || Object.getPrototypeOf(v) === null));
  check(!seen.has(v)); seen.add(v);
  check(Reflect.ownKeys(v).every(k => {
    if (typeof k !== 'string') return false;
    const d = Object.getOwnPropertyDescriptor(v, k);
    return (Array.isArray(v) && k === 'length') || (d.enumerable && Object.hasOwn(d, 'value'));
  }));
  for (const k of Object.keys(v)) {
    check(!['__proto__', 'constructor', 'prototype'].includes(k));
    check(!/[\uD800-\uDFFF]/u.test(k));
    const d = Object.getOwnPropertyDescriptor(v, k);
    check(Object.hasOwn(d, 'value')); jsonTree(d.value, depth + 1, seen);
  }
  if (Array.isArray(v)) check(Object.keys(v).length === v.length && Object.keys(v).every((k, i) => k === String(i)));
  seen.delete(v);
}
// JSON.parse accepts duplicate keys; reject them (including escape-equivalent keys).
function uniqueKeys(text) {
  const stack = [];
  for (const match of text.matchAll(/"(?:[^"\\]|\\.)*"|[{}\[\]:,]/gs)) {
    const token = match[0];
    if (token === '{' || token === '[') stack.push({ object: token === '{', expectKey: true, keys: new Set() });
    else if (token === '}' || token === ']') stack.pop();
    else if (token === ',') { if (stack.length) stack.at(-1).expectKey = true; }
    else if (token === ':') { if (stack.length) stack.at(-1).expectKey = false; }
    else if (stack.at(-1)?.object && stack.at(-1).expectKey) {
      const key = JSON.parse(token); check(!stack.at(-1).keys.has(key), 'invalid_json'); stack.at(-1).keys.add(key);
    }
  }
}
function body(input) {
  if (typeof input === 'string') {
    check(Buffer.byteLength(input) <= LIMITS.maxMessageBytes, 'message_too_large');
    try { const parsed = JSON.parse(input); uniqueKeys(input); jsonTree(parsed); return parsed; }
    catch (e) { if (e instanceof Invalid) throw e; fail('invalid_json'); }
  }
  jsonTree(input);
  const text = JSON.stringify(input);
  check(Buffer.byteLength(text) <= LIMITS.maxMessageBytes, 'message_too_large');
  return JSON.parse(text);
}
function result(run, input) {
  let parsed;
  try { parsed = body(input); return freeze({ ok: true, ...run(parsed) }); }
  catch (e) {
    const code = e instanceof Invalid ? e.code : 'invalid_request';
    const error = { type: 'invalid_request_error', code, message: ERROR_CODES[code], param: null };
    if (typeof parsed?.event_id === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(parsed.event_id)) error.event_id = parsed.event_id;
    return freeze({ ok: false, error });
  }
}
function pcm(v) {
  check(typeof v === 'string' && v.length > 0 && v.length <= 6400, 'invalid_audio');
  check(/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(v), 'invalid_audio');
  const bytes = Buffer.from(v, 'base64');
  check(bytes.toString('base64') === v && bytes.length % 2 === 0 && bytes.length <= LIMITS.maxFrameBytes, 'invalid_audio');
  // Detect common containers; arbitrary raw PCM cannot prove its source rate/channels.
  check(!['RIFF', 'RF64', 'OggS', 'fLaC', 'ID3'].some(h => bytes.subarray(0, h.length).toString('latin1') === h), 'invalid_audio');
  const mpegHeader = bytes.length >= 4 && bytes[0] === 255 && (bytes[1] & 224) === 224
    && ((bytes[1] >> 3) & 3) !== 1 && ((bytes[1] >> 1) & 3) !== 0
    && (bytes[2] >> 4) !== 0 && (bytes[2] >> 4) !== 15 && ((bytes[2] >> 2) & 3) !== 3;
  check(!mpegHeader, 'invalid_audio');
  return bytes.length / 2;
}
function userItem(item) {
  keys(item, ['id', 'type', 'role', 'content']); id(item.id);
  check(item.type === 'message' && item.role === 'user', 'unsupported_feature');
  check(Array.isArray(item.content) && item.content.length === 1);
  keys(item.content[0], ['type', 'text']);
  check(item.content[0].type === 'input_text', 'unsupported_feature'); scalarText(item.content[0].text, false);
}
function metadata(m) {
  keys(m, ['operation_id']);
  check(typeof m.operation_id === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(m.operation_id));
}
function configPatch(patch, template = DEFAULT_CONFIG, root = true) {
  keys(patch, Object.keys(template), []);
  for (const [k, v] of Object.entries(patch)) {
    if (root && k === 'model') fail('unsupported_feature');
    if (root && k === 'output_modalities') modalities(v);
    else if (record(template[k])) configPatch(v, template[k], false);
    else check(same(v, template[k]), 'unsupported_feature');
  }
}
function effective(s) {
  keys(s, ['id', 'object', ...Object.keys(DEFAULT_CONFIG)]); id(s.id);
  check(s.object === 'realtime.session' && s.model === DEFAULT_CONFIG.model);
  const expected = { ...DEFAULT_CONFIG, output_modalities: s.output_modalities };
  modalities(s.output_modalities);
  check(same(s, { id: s.id, object: 'realtime.session', ...expected }), 'unsupported_feature');
}
export function createSession(sessionId) {
  return result(v => { id(v.id); return { value: { id: v.id, object: 'realtime.session', ...JSON.parse(JSON.stringify(DEFAULT_CONFIG)) } }; }, { id: sessionId });
}
function merge(a, b) {
  return Object.fromEntries(Object.entries(a).map(([k, v]) => [k, Object.hasOwn(b, k)
    ? (record(v) ? merge(v, b[k]) : b[k]) : v]));
}
export function applySessionUpdate(current, patch, context = {}) {
  return result(p => {
    const original = body(current); effective(original); configPatch(p);
    check(!context.activeResponseId, 'response_in_progress');
    return { session: merge(original, p) };
  }, patch);
}
export function validateClientEvent(input, context = {}) {
  return result(e => {
    keys(e, ['type', 'event_id', 'session', 'audio', 'item', 'response', 'response_id', 'item_id', 'content_index', 'audio_end_ms',
      'media_epoch', 'playback_epoch', 'rendered_samples', 'state'], ['type']);
    if (Object.hasOwn(e, 'event_id')) id(e.event_id);
    let fields = [], effect = { kind: 'validate_only' };
    switch (e.type) {
      case 'session.update': {
        fields = ['session'];
        check(e.session?.type === 'realtime', 'unsupported_feature');
        check(context.effectiveSession, 'context_required');
        const updated = applySessionUpdate(context.effectiveSession, e.session, context);
        if (!updated.ok) fail(updated.error.code);
        effect = { kind: 'session_update', session: updated.session }; break;
      }
      case 'input_audio_buffer.append': fields = ['audio']; effect = { kind: 'append', samples: pcm(e.audio) }; break;
      case 'input_audio_buffer.commit':
        check(Number.isSafeInteger(context.bufferSamples) && context.bufferSamples >= 0 && context.bufferSamples <= LIMITS.maxSegmentSamples, 'context_required');
        check(context.bufferSamples > 0, 'empty_buffer'); effect = { kind: 'commit_input_only', createsResponse: false }; break;
      case 'input_audio_buffer.clear': effect = { kind: 'clear_uncommitted_only' }; break;
      case 'conversation.item.create':
        fields = ['item']; userItem(e.item);
        if (context.canonicalItem?.id === e.item.id) {
          userItem(context.canonicalItem); check(same(context.canonicalItem, e.item), 'item_mismatch');
        }
        effect = { kind: 'compose_only', createsResponse: false }; break;
      case 'response.create':
        fields = ['response']; keys(e.response, ['input', 'metadata', 'output_modalities']);
        check(Array.isArray(e.response.input) && e.response.input.length === 1);
        userItem(e.response.input[0]); metadata(e.response.metadata); modalities(e.response.output_modalities);
        check(context.canonicalItem, 'context_required'); userItem(context.canonicalItem);
        check(same(e.response.input[0], context.canonicalItem), 'item_mismatch');
        if (context.priorOperation?.operation_id?.toLowerCase() === e.response.metadata.operation_id.toLowerCase())
          check(same(context.priorOperation.item, e.response.input[0]), 'operation_conflict');
        check(!context.activeResponseId, 'response_in_progress');
        effect = { kind: 'explicit_response_request', requiresDurableAdmission: true }; break;
      case 'response.cancel':
        fields = Object.hasOwn(e, 'response_id') ? ['response_id'] : [];
        if (e.response_id !== undefined) id(e.response_id);
        check(context.activeResponseId, 'no_active_response');
        check(e.response_id === undefined || e.response_id === context.activeResponseId, 'no_active_response');
        effect = { kind: 'cancel_narration_only' }; break;
      case 'conversation.item.truncate':
        fields = ['item_id', 'content_index', 'audio_end_ms']; id(e.item_id); zero(e.content_index); uint(e.audio_end_ms);
        check(context.truncateTarget && Number.isSafeInteger(context.truncateTarget.generatedSamples) && context.truncateTarget.generatedSamples >= 0, 'context_required');
        check(e.item_id === context.truncateTarget.item_id && e.audio_end_ms <= Math.floor(context.truncateTarget.generatedSamples / 24), 'invalid_position');
        effect = { kind: 'truncate_media_only' }; break;
      case 'vs.playback':
        fields = ['media_epoch', 'response_id', 'item_id', 'content_index', 'playback_epoch', 'rendered_samples', 'state'];
        id(e.media_epoch); id(e.playback_epoch); id(e.response_id); id(e.item_id); zero(e.content_index); uint(e.rendered_samples);
        check(['playing', 'paused', 'stopped', 'completed', 'unknown'].includes(e.state)); break;
      default: fail('unsupported_feature');
    }
    keys(e, ['type', 'event_id', ...fields], ['type', ...fields]);
    return { value: e, effect };
  }, input);
}

function serverItem(item) {
  keys(item, ['id', 'object', 'type', 'role', 'status', 'content']); id(item.id);
  check(item.object === 'realtime.item' && item.type === 'message');
  check(['user', 'assistant'].includes(item.role));
  check(['in_progress', 'completed', 'incomplete'].includes(item.status));
  check(Array.isArray(item.content) && item.content.length <= 1);
  for (const c of item.content) {
    if (c.type === 'input_text' || c.type === 'output_text') {
      keys(c, ['type', 'text']); scalarText(c.text);
      check(c.type === (item.role === 'user' ? 'input_text' : 'output_text'));
    } else {
      keys(c, ['type', 'transcript']); scalarText(c.transcript);
      check(c.type === (item.role === 'user' ? 'input_audio' : 'output_audio'));
    }
  }
}
function wireError(e, correlation = false) {
  keys(e, ['type', 'code', 'message', 'param', ...(correlation ? ['event_id'] : [])], ['type', 'code', 'message', 'param']);
  check(['invalid_request_error', 'server_error'].includes(e.type) && typeof e.code === 'string' && Object.hasOwn(ERROR_CODES, e.code) && e.message === ERROR_CODES[e.code] && e.param === null);
  if (Object.hasOwn(e, 'event_id')) id(e.event_id);
}
function response(r, done) {
  keys(r, ['id', 'object', 'status', 'status_details', 'output', 'metadata']); id(r.id);
  check(r.object === 'realtime.response'); metadata(r.metadata);
  check((done ? ['completed', 'cancelled', 'failed', 'incomplete'] : ['in_progress']).includes(r.status));
  if (['completed', 'in_progress'].includes(r.status)) check(r.status_details === null);
  else if (r.status === 'failed') {
    keys(r.status_details, ['type', 'error']); check(r.status_details.type === 'failed');
    keys(r.status_details.error, ['type', 'code', 'message']);
    check(r.status_details.error.type === 'server_error' && r.status_details.error.code === 'local_failure' && r.status_details.error.message === ERROR_CODES.local_failure);
  } else {
    keys(r.status_details, ['type', 'reason']); check(r.status_details.type === r.status);
    check((r.status === 'cancelled' ? ['client_cancelled'] : ['max_output_tokens', 'content_filter']).includes(r.status_details.reason));
  }
  check(Array.isArray(r.output) && r.output.length <= 1);
  r.output.forEach(i => { serverItem(i); check(i.role === 'assistant'); });
}
/** Shape-only validator. Does not enforce unique IDs, lifecycle order or delivery evidence. */
export function validateServerEvent(input) {
  return result(e => {
    check(record(e)); id(e.event_id);
    let fields;
    const coordinates = ['response_id', 'item_id', 'output_index', 'content_index'];
    if (['session.created', 'session.updated'].includes(e.type)) { fields = ['session']; effective(e.session); }
    else if (['response.created', 'response.done'].includes(e.type)) { fields = ['response']; response(e.response, e.type === 'response.done'); }
    else if (['conversation.item.added', 'conversation.item.done'].includes(e.type)) {
      fields = ['previous_item_id', 'item']; if (e.previous_item_id !== null) id(e.previous_item_id); serverItem(e.item);
    } else if (e.type === 'input_audio_buffer.committed') {
      fields = ['item_id', 'previous_item_id']; id(e.item_id); if (e.previous_item_id !== null) id(e.previous_item_id);
    } else if (e.type === 'input_audio_buffer.cleared') fields = [];
    else if (e.type === 'conversation.item.truncated') {
      fields = ['item_id', 'content_index', 'audio_end_ms']; id(e.item_id); zero(e.content_index); uint(e.audio_end_ms);
    } else if (e.type === 'error') { fields = ['error']; wireError(e.error, true); }
    else if (e.type === 'vs.flow') {
      fields = ['media_epoch', 'input_consumed_samples']; id(e.media_epoch); uint(e.input_consumed_samples);
    } else if (['conversation.item.input_audio_transcription.completed', 'conversation.item.input_audio_transcription.failed'].includes(e.type)) {
      const completed = e.type.endsWith('.completed');
      fields = ['item_id', 'content_index', ...(completed ? ['transcript', 'usage'] : ['error'])];
      id(e.item_id); zero(e.content_index);
      if (completed) { scalarText(e.transcript); keys(e.usage, ['type', 'seconds']); check(e.usage.type === 'duration' && Number.isFinite(e.usage.seconds) && e.usage.seconds >= 0 && e.usage.seconds <= 90); }
      else wireError(e.error);
    } else if (['response.output_item.added', 'response.output_item.done'].includes(e.type)) {
      fields = ['response_id', 'output_index', 'item']; id(e.response_id); zero(e.output_index); serverItem(e.item); check(e.item.role === 'assistant');
    } else if (['response.content_part.added', 'response.content_part.done', 'response.output_audio.delta', 'response.output_audio.done',
      'response.output_audio_transcript.delta', 'response.output_audio_transcript.done', 'response.output_text.delta', 'response.output_text.done'].includes(e.type)) {
      fields = [...coordinates]; id(e.response_id); id(e.item_id); zero(e.output_index); zero(e.content_index);
      if (e.type.startsWith('response.content_part.')) {
        fields.push('part');
        check(['audio', 'text'].includes(e.part?.type));
        const key = e.part.type === 'audio' ? 'transcript' : 'text'; keys(e.part, ['type', key]); scalarText(e.part[key]);
      } else if (e.type.endsWith('.delta')) {
        fields.push('delta'); if (e.type === 'response.output_audio.delta') pcm(e.delta); else scalarText(e.delta);
      } else if (e.type !== 'response.output_audio.done') {
        const key = e.type === 'response.output_text.done' ? 'text' : 'transcript'; fields.push(key); scalarText(e[key]);
      }
    } else fail('unsupported_feature');
    keys(e, ['event_id', 'type', ...fields]);
    return { value: e };
  }, input);
}
