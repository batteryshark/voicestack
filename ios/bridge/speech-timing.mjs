// Numeric, bounded observations only. Arrival means Node readable data, not a
// TCP packet or pure server compute time (downstream backpressure can contribute).
export class SpeechTransferTiming {
  constructor(now = performance.now()) {
    this.began = now; this.first = null; this.last = null;
    this.bytes = 0; this.chunks = 0; this.gaps = 0; this.clipped = 0; this.maxGap = 0;
    this.buckets = new Uint32Array(2001); // 5ms upper bounds through 10 seconds
  }
  receive(bytes, now = performance.now()) {
    if (!(bytes > 0) || !Number.isFinite(now)) return false;
    const first = this.first === null;
    if (first) this.first = now;
    if (this.last !== null) {
      const gap = Math.max(0, now - this.last);
      this.maxGap = Math.max(this.maxGap, gap); this.gaps++;
      if (gap > 10000) this.clipped++;
      this.buckets[Math.ceil(Math.min(10000, gap) / 5)]++;
    }
    this.last = now; this.bytes += bytes; this.chunks++;
    return first;
  }
  snapshot(now = performance.now()) {
    const target = Math.ceil(this.gaps * 0.95);
    let p95 = 0, count = 0;
    if (target) for (let i = 0; i < this.buckets.length; i++) {
      count += this.buckets[i];
      if (count >= target) { p95 = i * 5; break; }
    }
    return { bytesReceived: this.bytes, chunksReceived: this.chunks,
      firstByteMs: this.first === null ? -1 : Math.max(0, this.first - this.began),
      requestTotalMs: Math.max(0, now - this.began), chunkGapMaxMs: this.maxGap,
      chunkGapP95Ms: p95, chunkGapSamples: this.gaps, chunkGapClipped: this.clipped, chunkGapBucketMs: 5 };
  }
}
