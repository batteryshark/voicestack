// Bounded streaming mono signed-PCM16LE conversion. No relabelled sample rates.
const rates = [16000, 22050, 24000, 44100, 48000];
const check = value => { if (!value) throw new Error('invalid_pcm'); };
export class PCMResampler {
  constructor(from, to) {
    check(rates.includes(from) && rates.includes(to));
    Object.assign(this, { from, to, radius: 16, base: 0, total: 0, output: 0, odd: null,
      samples: new Int16Array(2434), retained: 0, start: 0, weightsBuffer: new Float64Array(32), closed: false });
  }
  push(bytes) {
    check(!this.closed && Buffer.isBuffer(bytes) && bytes.length <= 4800);
    let input = bytes;
    if (this.odd !== null) { input = Buffer.allocUnsafeSlow(bytes.length + 1); input[0] = this.odd; bytes.copy(input, 1); this.odd = null; }
    if (input.length % 2) { this.odd = input[input.length - 1]; input = input.subarray(0, -1); }
    if (this.from === this.to) {
      this.total += input.length / 2; this.output += input.length / 2;
      if (!input.length) return []; const result = Buffer.allocUnsafeSlow(input.length); input.copy(result); return [result];
    }
    for (let i = 0; i < input.length; i += 2) {
      const value = input.readInt16LE(i); if (!this.total) this.first = value;
      check(this.retained < this.samples.length);
      this.last = value; this.samples[(this.start + this.retained++) % this.samples.length] = value; this.total++;
    }
    return this.drain(false);
  }
  weights(remainder) {
    const fraction = remainder / this.to, cutoff = 0.45 * Math.min(1, this.to / this.from), weights = this.weightsBuffer;
    let sum = 0;
    for (let k = -this.radius + 1; k <= this.radius; k++) {
      const distance = fraction - k, x = 2 * cutoff * distance;
      const sinc = Math.abs(x) < 1e-12 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x);
      const window = Math.abs(distance) >= this.radius ? 0 : (1 + Math.cos(Math.PI * distance / this.radius)) / 2;
      const weight = 2 * cutoff * sinc * window; weights[k + this.radius - 1] = weight; sum += weight;
    }
    for (let i = 0; i < weights.length; i++) weights[i] /= sum;
    return weights;
  }
  drain(final) {
    const end = Math.ceil(this.total * this.to / this.from);
    const frames = []; let frame = Buffer.alloc(Math.min(4800, (end - this.output) * 2)), used = 0;
    while (this.total && this.output < end) {
      const numerator = this.output * this.from, center = Math.floor(numerator / this.to);
      if (!final && center + this.radius >= this.total) break;
      const weights = this.weights(numerator % this.to); let value = 0;
      for (let n = 0; n < weights.length; n++) {
        const index = center - this.radius + 1 + n;
        check(index < 0 || index >= this.total || index >= this.base && index - this.base < this.retained);
        const sample = index < 0 ? this.first : index >= this.total ? this.last : this.samples[(this.start + index - this.base) % this.samples.length];
        value += weights[n] * sample;
      }
      frame.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(value))), used); used += 2; this.output++;
      if (used === frame.length) { frames.push(frame); used = 0; frame = Buffer.alloc(Math.min(4800, (end - this.output) * 2)); }
    }
    if (used) frames.push(frame.subarray(0, used));
    const earliest = Math.max(0, Math.floor(this.output * this.from / this.to) - this.radius);
    const remove = Math.min(this.retained, earliest - this.base);
    if (remove > 0) { this.start = (this.start + remove) % this.samples.length; this.retained -= remove; this.base += remove; }
    return frames;
  }
  finish() {
    check(!this.closed); this.closed = true; check(this.odd === null);
    const frames = this.from === this.to ? [] : this.drain(true); this.retained = 0; this.samples = null; this.weightsBuffer = null; return frames;
  }
  discard() { this.closed = true; this.retained = 0; this.odd = null; this.samples = null; this.weightsBuffer = null; }
  stats() { return { inputSamples: this.total, outputSamples: this.output, retainedSamples: this.retained, oddBytes: this.odd === null ? 0 : 1 }; }
}
