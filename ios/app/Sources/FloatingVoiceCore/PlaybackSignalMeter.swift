import Foundation

/// Source-aligned, bounded numeric telemetry. No PCM leaves the producer; the tap
/// only compares window energies under a lock and returns closed measurements.
public final class PlaybackSignalMeter: @unchecked Sendable {
    public struct Counts: Sendable {
        public var sourceSilenceCount = 0, dropoutCount = 0, dropoutMaxMs = 0.0, alignmentUnknown = 0
        public var handoffsDropped = 0
        public var startLatencyMs = 0.0
    }
    public struct Handoff: Sendable {
        public let generation: Int, ordinal: Int, callToken: Int
        public let gapMs: Double
        public let positionKnown: Bool, skippedUpToMs: Double
        public let attempt: UUID?
    }
    private struct PendingHandoff {
        var began: Double
        var positionKnown = true, skippedUpToMs = 0.0
    }
    private struct Window { let first: Int, end: Int; let audible: Bool }
    private let lock = NSLock()
    private var windows: [Window] = []
    private var rate = 1.0, sourceFrame = 0, windowFirst = 0, windowFrames = 1, windowCount = 0
    private var energy = 0.0, sourceLow = 0.0, outputLow = 0.0
    private var sourceRunCounted = false, outputRunCounted = false, active = false, paused = false
    private var token = 0, graph = 0, base = 0
    private var version = 0, started = false
    private var callToken = 0
    private var attempt: UUID?
    private var position: Int?
    private var counts = Counts()
    private var lastRenderEnd: Double?
    private var runStartedAt = 0.0, runHasRendered = false, expectedGain = 1.0
    private struct InitialLow {
        let first: Int, end: Int
        let observedAt: Double
    }
    private var initialLow: InitialLow?
    private var handoffs: [Int: PendingHandoff] = [:]
    public init() {}
    public func begin(token: Int, graph: Int, rate: Double, attempt: UUID? = nil, callToken: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        self.token = token; self.graph = graph; self.rate = rate
        version += 1; started = false; initialLow = nil
        self.attempt = attempt; self.callToken = callToken
        windows = []; sourceFrame = 0; windowFirst = 0; windowCount = 0; windowFrames = max(1, Int(rate / 100))
        energy = 0; sourceLow = 0; outputLow = 0; sourceRunCounted = false; outputRunCounted = false
        base = 0; position = nil; counts = Counts(); active = true; paused = false; handoffs = [:]; lastRenderEnd = nil
    }
    /// Exactly once for each NEW source buffer, never again for retained replay.
    /// One serial producer. Decode/RMS work stays OUTSIDE the tap's lock.
    public func source(_ pcm: Data) {
        lock.lock()
        guard active else { lock.unlock(); return }
        let owner = token, size = windowFrames
        var frame = sourceFrame, first = windowFirst, count = windowCount, sum = energy
        lock.unlock()
        var completed: [(Int, Int, Bool, Int)] = []
        pcm.withUnsafeBytes { raw in
            for i in stride(from: 0, to: raw.count - (raw.count % 2), by: 2) {
                let value = Double(Int16(bitPattern: UInt16(raw[i]) | UInt16(raw[i+1]) << 8)) / 32768
                sum += value * value; frame += 1; count += 1
                if count == size {
                    completed.append((first, frame, sqrt(sum / Double(count)) >= RenderDropoutMeter.floor, count))
                    first = frame; count = 0; sum = 0
                }
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard active, token == owner else { return }
        sourceFrame = frame; windowFirst = first; windowCount = count; energy = sum
        for (first, end, audible, count) in completed { appendWindow(first: first, end: end, audible: audible, count: count) }
    }
    public func sourceFinished() { lock.lock(); defer { lock.unlock() }; if windowCount > 0 { finishWindow() } }
    private func finishWindow() {
        let audible = sqrt(energy / Double(windowCount)) >= RenderDropoutMeter.floor
        appendWindow(first: windowFirst, end: sourceFrame, audible: audible, count: windowCount)
        windowFirst = sourceFrame; windowCount = 0; energy = 0
    }
    private func appendWindow(first: Int, end: Int, audible: Bool, count: Int) {
        windows.append(Window(first: first, end: end, audible: audible))
        if windows.count > 512 { windows.removeFirst(windows.count - 512) }
        if audible { sourceLow = 0; sourceRunCounted = false }
        else {
            sourceLow += Double(count) / rate * 1000
            if sourceLow > RenderDropoutMeter.thresholdMs && !sourceRunCounted {
                counts.sourceSilenceCount += 1; sourceRunCounted = true
            }
        }
    }
    public var renderedPosition: Int? { lock.lock(); defer { lock.unlock() }; return position }
    public var renderRevision: Int { lock.lock(); defer { lock.unlock() }; return version }
    public func setExpectedGain(_ gain: Double) {
        lock.lock(); defer { lock.unlock() }; expectedGain = max(0, gain)
    }
    public func start(token: Int, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard self.token == token else { return }
        version += 1; started = true; runStartedAt = now; runHasRendered = false; initialLow = nil
    }
    public func beginHandoff(generation: Int, now: Double) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        // Include an I/O gap that began BEFORE iOS delivered its notification.
        if var previous = handoffs[generation] {
            previous.began = min(previous.began, lastRenderEnd ?? now); handoffs[generation] = previous
        }
        else if handoffs.count < 16 { handoffs[generation] = PendingHandoff(began: lastRenderEnd ?? now) }
        else { counts.handoffsDropped += 1 }
    }
    /// Associate the conservative skip with this repair/switch only. Gap timing
    /// still completes at the first resumed render block, exactly as before.
    @discardableResult public func noteHandoffPosition(generation: Int, positionKnown: Bool, skippedFrames: Int) -> Double {
        lock.lock(); defer { lock.unlock() }
        let skippedMs = Double(skippedFrames) / rate * 1000
        if var pending = handoffs[generation] {
            pending.positionKnown = positionKnown; pending.skippedUpToMs = skippedMs
            handoffs[generation] = pending
        }
        return skippedMs
    }
    public func suspend() {
        lock.lock(); defer { lock.unlock() }; version += 1; paused = true; outputLow = 0; outputRunCounted = false
        if initialLow != nil { counts.alignmentUnknown += 1; initialLow = nil }
    }
    public func resume(graph: Int, base: Int) {
        lock.lock(); defer { lock.unlock() }
        self.graph = graph; self.base = base; paused = false; started = false; version += 1
        outputLow = 0; outputRunCounted = false
    }
    /// Independent, revision-validated playback-completion evidence. In
    /// particular, a wholly missing one-buffer utterance has no next tap cursor.
    public func confirmRendered(through end: Int, token: Int) {
        lock.lock(); defer { lock.unlock() }
        guard active, started, !paused, self.token == token else { return }
        resolveInitialLow(through: end)
    }
    private func resolveInitialLow(through end: Int) {
        guard let pending = initialLow, end > pending.first else { return }
        initialLow = nil
        let confirmedEnd = min(end, pending.end)
        counts.startLatencyMs = max(counts.startLatencyMs, max(0, (pending.observedAt - runStartedAt) * 1000))
        runHasRendered = true
        position = max(position ?? 0, confirmedEnd)
        countOutputLow(sourceFrames: confirmedEnd - pending.first)
    }
    private func countOutputLow(sourceFrames: Int) {
        outputLow += Double(sourceFrames) / rate * 1000
        if outputLow > RenderDropoutMeter.thresholdMs {
            if !outputRunCounted { counts.dropoutCount += 1; outputRunCounted = true }
            counts.dropoutMaxMs = max(counts.dropoutMaxMs, outputLow)
        }
    }
    /// sourceFrame is the player's relative render clock at this buffer's START.
    public func render(rms: Double, frames: Int, renderRate: Double, sourceFrame: Int?, graph: Int,
        now: Double, revision: Int? = nil) -> [Handoff] {
        lock.lock(); defer { lock.unlock() }
        guard active, started, !paused, self.graph == graph, revision == nil || revision == version,
              frames > 0, renderRate > 0, rms.isFinite else { return [] }
        guard let sourceFrame else { counts.alignmentUnknown += 1; outputLow = 0; outputRunCounted = false; return [] }
        // START cursor zero does not prove this nonempty tap interval was idle.
        // The next timestamp (even an EOF/tail cursor), or a validated playback
        // completion, proves whether the provisional source interval advanced.
        resolveInitialLow(through: base + sourceFrame)
        let first = base + sourceFrame, end = first + Int(Double(frames) * rate / renderRate)
        guard first >= 0, first < self.sourceFrame else {
            counts.alignmentUnknown += 1; outputLow = 0; outputRunCounted = false; return []
        }
        // The final tap may extend beyond EOF. Never count post-drain tail.
        let alignedEnd = min(end, self.sourceFrame)
        var covered = first, expectedAudible = true
        for window in windows where window.end > first && window.first < alignedEnd {
            if window.first > covered || !window.audible { expectedAudible = false }
            covered = max(covered, window.end)
        }
        if covered < alignedEnd { expectedAudible = false; counts.alignmentUnknown += 1 }
        if !runHasRendered && sourceFrame == 0 && expectedAudible && rms < RenderDropoutMeter.floor * expectedGain {
            // Repeated zero cursors replace (rather than add) the pending low:
            // earlier blocks were pre-start, but this last block may be real PCM.
            initialLow = InitialLow(first: first, end: alignedEnd, observedAt: now)
            return []
        }
        initialLow = nil // An audible block at the SAME cursor proves pre-start latency.
        if !runHasRendered {
            counts.startLatencyMs = max(counts.startLatencyMs, max(0, (now - runStartedAt) * 1000))
            runHasRendered = true
        }
        position = max(position ?? 0, alignedEnd)
        let completed = handoffs.map { Handoff(generation: $0.key, ordinal: token, callToken: callToken,
            gapMs: max(0, (now - $0.value.began) * 1000), positionKnown: $0.value.positionKnown,
            skippedUpToMs: $0.value.skippedUpToMs, attempt: attempt) }
        handoffs = [:]; lastRenderEnd = now + Double(frames) / renderRate
        if rms < RenderDropoutMeter.floor * expectedGain {
            if expectedAudible {
                countOutputLow(sourceFrames: alignedEnd - first)
            } else {
                outputLow = 0; outputRunCounted = false
            }
        } else {
            outputLow = 0; outputRunCounted = false
        }
        return completed
    }
    public func end(token: Int) -> Counts {
        lock.lock(); defer { lock.unlock() }
        guard self.token == token else { return Counts() }
        if initialLow != nil { counts.alignmentUnknown += 1; initialLow = nil }
        active = false; handoffs = [:]
        return counts
    }
}
