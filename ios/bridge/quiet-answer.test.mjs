import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PushService } from './push-service.mjs';
import { main, callAnswer, awaitCallAnswer } from './reachout.mjs';

const callUUID = '0b7f2c55-1f0e-4f4a-9d2e-5d4a1b2c3d4e';
function service(now = 1_800_000_000_000) {
  const target = { deviceID: 'D', reason: 'urgent-eligible', state: 'apns-accepted', callAttemptAt: now, voipAttemptedAt: now, ringDeadline: now + 30000, fallbackDeadline: now + 60000, reservedFallback: true };
  const store = { data: { records: { 'r:call-q': { request: { kind: 'urgent-call', id: 'call-q' }, callUUID, targets: { 'd:D': target } } }, devices: {} }, save() {} };
  const alerts = [];
  const push = new PushService({ store, apns: () => null, chief: () => 'ses_A', activeDevices: () => [{ deviceID: 'D' }], now: () => now, speechKeepalive: async () => {} });
  push.deliver = (...a) => alerts.push(a); // any APNs alert would pass here
  return { push, target, alerts, now };
}
// Exactly the body PushReceiptOutbox sends for a phone-declared quiet decline (CallReceipt Codable + ids).
const reported = { reachoutID: 'call-q', callUUID, event: 'reported', reportedRinging: false };
const quiet = (now, end = '08:00') => ({ reachoutID: 'call-q', callUUID, event: 'ended', endReason: 'admissionRejected', endInitiator: 'app',
  reportedRinging: false, ...(end === 'all-day' ? { quietEnd: 'all-day' } : { quietUntil: now + 3 * 3600000, quietEnd: end }) });

test('phone quiet decline is recorded once, suppresses the fallback alert, and reads as the window', async () => {
  const { push, target, alerts, now } = service();
  await push.event({ deviceID: 'D' }, reported);
  assert.equal(callAnswer(push.status('call-q')), 'no answer from the phone yet (not retried)');
  await push.event({ deviceID: 'D' }, quiet(now));
  assert.equal(target.receipt, 'declined'); assert.equal(target.reason, 'phone-quiet-hours');
  assert.equal(push.status('call-q').targets[0].message, 'in quiet hours until 08:00');
  assert.equal(callAnswer(push.status('call-q')), 'declined: in quiet hours until 08:00');
  assert.equal(alerts.length, 0); assert.ok(target.quietEnd && !target.fallback); // no fallback notification
});
test('all-day window and calls-off decline read plainly', async () => {
  const a = service(); await a.push.event({ deviceID: 'D' }, quiet(a.now, 'all-day'));
  assert.equal(callAnswer(a.push.status('call-q')), 'declined: in quiet hours all day');
  const b = service(); await b.push.event({ deviceID: 'D' }, { reachoutID: 'call-q', callUUID, event: 'ended', endReason: 'admissionRejected', endInitiator: 'app', reportedRinging: false });
  assert.equal(b.push.status('call-q').targets[0].endReason, 'admissionRejected');
  assert.match(callAnswer(b.push.status('call-q')), /^declined by the phone: calls are off on the phone/);
  const c = service(); await c.push.event({ deviceID: 'D' }, { ...reported, event: 'ringing', reportedRinging: true });
  assert.equal(callAnswer(c.push.status('call-q')), 'ringing');
  assert.equal(callAnswer({ targets: [{ policyReason: 'call-outstanding', delivery: 'notification-intent' }] }), 'not called: call-outstanding');
});
test('bounded wait polls status only, never resends, and stops at the first settled receipt', async () => {
  const seen = [];
  const states = [{ receipt: undefined }, { receipt: 'reported' }, { receipt: 'ringing' }];
  const sender = async input => { seen.push(input.command); return { targets: [{ policyReason: 'urgent-eligible', delivery: 'apns-accepted', ...states[Math.min(seen.length - 1, 2)] }] }; };
  assert.equal(await awaitCallAnswer('x', sender, { sleep: async () => {} }), 'ringing');
  assert.deepEqual(seen, ['status', 'status', 'status']);
  let polls = 0;
  const silent = async () => { polls++; return { targets: [{ policyReason: 'urgent-eligible', delivery: 'apns-accepted' }] }; };
  assert.equal(await awaitCallAnswer('x', silent, { timeoutMs: 40, intervalMs: 10 }), 'no answer from the phone yet (not retried)');
  assert.ok(polls >= 2 && polls <= 6);
});
test('send keeps its JSON and adds the answer line; one send only', async () => {
  const commands = [];
  const sender = async input => {
    commands.push(input.command);
    if (input.command === 'send') return { id: input.request.id, disposition: 'call-intent', policyReason: 'urgent-eligible', targets: [] };
    return { targets: [{ policyReason: 'urgent-eligible', delivery: 'apns-accepted', receipt: 'declined', message: 'in quiet hours until 08:00' }] };
  };
  const args = ['send', '--kind', 'urgent-call', '--reason', 'decision', '--session', 'ses_A', '--id', 'quiet-cli-1', '--title', 'T', '--body', 'B'];
  const result = await main(args, { sender, ensureSpeech: async () => ({ ready: true }), answerWait: { sleep: async () => {} } });
  assert.equal(result.disposition, 'call-intent'); assert.equal(result.answer, 'declined: in quiet hours until 08:00');
  assert.deepEqual(commands, ['send', 'status']);
});
