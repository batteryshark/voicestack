import Foundation

/// Closed observation codes only. Never carries a sentence, voice, URL or error text.
public enum PlaybackEvent: String, Codable, Sendable {
    case ttsRequest, ttsFirstByte, ttsComplete
    case utteranceBegin, utteranceEnd, scheduled, starvationBegin, starvationEnd
    case engineStart, engineStop, interruptPlayback, stopPlayback, routeDuringPlayback
    case voiceProcessingState, playbackFormat
    case suspendForRepair, resumeFromPosition, routeHandoff
    case sourceClockReset
    case cutInPause, cutInResume
}
public enum PlaybackStopCause: Int, Sendable {
    case unspecified, outputStop, sentenceBoundary, routeRecovery, callPause, graphClose, probe
}

/// Arrival-side timing, NOT consumer iteration timing. Fixed 5ms histogram;
/// p95 is an upper bucket bound (10s cap); max retains the actual largest gap.
public struct AudioTransferTiming: Sendable {
    public static let bucketMs = 5, ceilingMs = 10_000
    private let began: Double
    private var first: Double?, last: Double?
    private var buckets = [Int](repeating: 0, count: 2001)
    public private(set) var bytes = 0, chunks = 0, gaps = 0, clipped = 0
    public private(set) var maxGapMs = 0.0
    public init(now: Double) { began = now }
    @discardableResult public mutating func receive(bytes count: Int, now: Double) -> Bool {
        guard count > 0, now.isFinite else { return false }
        let isFirst = first == nil
        if first == nil { first = now }
        if let last {
            let gap = max(0, (now - last) * 1000)
            maxGapMs = max(maxGapMs, gap); gaps += 1
            if gap > Double(Self.ceilingMs) { clipped += 1 }
            let bucket = Int(ceil(min(Double(Self.ceilingMs), gap) / Double(Self.bucketMs)))
            buckets[bucket] += 1
        }
        last = now; bytes += count; chunks += 1
        return isFirst
    }
    public func fields(now: Double) -> [CaptureField: Double] {
        var p95 = 0, cumulative = 0
        let target = Int(ceil(Double(gaps) * 0.95))
        if target > 0 {
            for (index, count) in buckets.enumerated() {
                cumulative += count
                if cumulative >= target { p95 = index * Self.bucketMs; break }
            }
        }
        return [.bytesReceived: Double(bytes), .chunksReceived: Double(chunks),
            .firstByteMs: first.map { max(0, ($0 - began) * 1000) } ?? -1,
            .requestTotalMs: max(0, (now - began) * 1000), .chunkGapMaxMs: maxGapMs,
            .chunkGapP95Ms: Double(p95), .chunkGapSamples: Double(gaps), .chunkGapClipped: Double(clipped),
            .chunkGapBucketMs: Double(Self.bucketMs)]
    }
}

/// Observation only: never controls scheduling or resumes a continuation.
public struct PlaybackQueueCounter {
    public private(set) var depth = 0, starvationCount = 0
    public private(set) var starvationMaxMs = 0.0
    private var emptySince: Double?
    public init() {}
    public mutating func schedule(now: Double) -> Double? {
        let gap = closeGap(now: now)
        depth += 1
        return gap
    }
    @discardableResult public mutating func played(now: Double, moreExpected: Bool) -> Bool {
        depth = max(0, depth - 1)
        guard depth == 0, moreExpected, emptySince == nil else { return false }
        emptySince = now; return true
    }
    public mutating func closeGap(now: Double, count: Bool = true) -> Double? {
        guard let began = emptySince else { return nil }
        emptySince = nil
        let duration = max(0, (now - began) * 1000)
        if count { starvationCount += 1; starvationMaxMs = max(starvationMaxMs, duration) }
        return duration
    }
}

/// Tap-side, numeric-only aggregation. No file IO, logging, Tasks, PCM copies or
/// unbounded storage in consume(). Counts only signal-bounded low-level periods:
/// initial attack and trailing silence are not mid-utterance dropout evidence.
public final class RenderDropoutMeter: @unchecked Sendable {
    public struct Counts: Sendable { public var count = 0, maxMs = 0.0, invalidBuffers = 0 }
    public static let floor = 0.001, thresholdMs = 80.0
    private let lock = NSLock()
    private var token = 0, graph = 0, active = false, signal = false
    private var lowMs = 0.0, counts = Counts()
    public init() {}
    public func begin(token: Int, graph: Int) {
        lock.lock(); defer { lock.unlock() }
        self.token = token; self.graph = graph; active = true; signal = false; lowMs = 0; counts = Counts()
    }
    public func consume(rms: Double, frames: Int, rate: Double, graph: Int, valid: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        guard active, self.graph == graph else { return }
        guard valid, rms.isFinite, frames > 0, rate.isFinite, rate > 0 else {
            counts.invalidBuffers += 1; lowMs = 0; signal = false; return
        }
        if rms < Self.floor {
            if signal { lowMs += Double(frames) / rate * 1000 }
        } else {
            if signal, lowMs > Self.thresholdMs { counts.count += 1; counts.maxMs = max(counts.maxMs, lowMs) }
            lowMs = 0; signal = true
        }
    }
    public func end(token: Int) -> Counts {
        lock.lock(); defer { lock.unlock() }
        guard self.token == token else { return Counts() }
        active = false; lowMs = 0
        return counts
    }
    public func suspend() { lock.lock(); active = false; lowMs = 0; lock.unlock() }
    public func resume(token: Int, graph: Int) {
        lock.lock(); defer { lock.unlock() }
        guard self.token == token else { return }
        self.graph = graph; active = true; signal = false; lowMs = 0
    }
}
