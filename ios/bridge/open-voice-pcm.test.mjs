import test from 'node:test';
import assert from 'node:assert/strict';
import { PCMResampler } from './open-voice-pcm.mjs';
import { cleanSpeech, speechSegments } from './open-voice-speech-text.mjs';

const pcm = samples => { const b = Buffer.alloc(samples.length * 2); samples.forEach((v, i) => b.writeInt16LE(v, i * 2)); return b; };
function convert(input, from, to, size) {
  const c = new PCMResampler(from, to), frames = [];
  for (let i = 0; i < input.length; i += size) { frames.push(...c.push(input.subarray(i, i + size))); assert.ok(c.stats().retainedSamples <= 34); }
  frames.push(...c.finish()); assert.ok(frames.every(b => b.length <= 4800 && b.buffer.byteLength <= 4800 && b.length % 2 === 0));
  assert.equal(c.stats().retainedSamples, 0); return Buffer.concat(frames);
}
test('streaming PCM continuity, exact counts and odd-byte preservation at every supported rate', () => {
  const input = pcm(Array.from({ length: 6001 }, (_, i) => Math.round(12000 * Math.sin(i / 7))));
  for (const [from, to] of [[24000, 16000], ...[16000, 22050, 24000, 44100, 48000].map(r => [r, 24000])]) {
    const whole = convert(input, from, to, 4800);
    assert.equal(whole.length, Math.ceil(6001 * to / from) * 2);
    for (const size of [1, 7, 4799]) assert.deepEqual(convert(input, from, to, size), whole);
    if (from === to) assert.deepEqual(whole, input);
  }
});
test('DC endpoints, empty streams, bounded frames, invalid rates and incomplete samples', () => {
  for (const rate of [16000, 22050, 24000, 44100, 48000]) {
    const data = convert(pcm(Array(241).fill(-12345)), rate, 24000, 13);
    for (let i = 0; i < data.length; i += 2) assert.equal(data.readInt16LE(i), -12345);
  }
  assert.equal(convert(Buffer.alloc(0), 24000, 16000, 1).length, 0);
  assert.throws(() => new PCMResampler(12345, 24000));
  const c = new PCMResampler(24000, 16000);
  assert.throws(() => c.push(Buffer.alloc(4801))); c.push(Buffer.from([1])); assert.throws(() => c.finish());
  assert.throws(() => c.push(Buffer.alloc(2))); c.discard(); assert.equal(c.stats().oddBytes, 0);
});
test('24 to 16 kHz lowpass suppresses above-Nyquist energy, not sample dropping', () => {
  const tone = hz => convert(pcm(Array.from({ length: 24000 }, (_, i) => Math.round(10000 * Math.sin(2 * Math.PI * hz * i / 24000)))), 24000, 16000, 960);
  const rms = b => Math.sqrt(Array.from({ length: b.length / 2 - 200 }, (_, i) => b.readInt16LE((i + 100) * 2) ** 2).reduce((a, n) => a + n, 0) / (b.length / 2 - 200));
  assert.ok(rms(tone(1000)) > 6900); assert.ok(rms(tone(10000)) < 150);
});
test('final-text-only speech projection strips fences and segments Unicode safely', () => {
  const text = cleanSpeech('# Hi **there** [friend](https://example.test)!\n````md\n```inner\nsecret\n```\n````\nVisit https://example.test/page and `smile` 🙂.');
  assert.equal(text, 'Hi there friend! Visit the linked page and smile 🙂.');
  assert.equal(cleanSpeech('before\n~~~code\nnever say this'), 'before');
  assert.throws(() => cleanSpeech('\ud800')); assert.throws(() => cleanSpeech('x'.repeat(16001)));
  const long = '🙂'.repeat(300); const chunks = speechSegments(long);
  assert.equal(chunks.join(''), long); assert.ok(chunks.every(s => !/[\uD800-\uDFFF]/u.test(s) && s.length <= 260));
});
