import Foundation

/// Hardware AND graph-side I/O signatures, not route labels or preferred rates.
public struct RouteIOFormat: Equatable, Sendable {
    public let rate: Double, channels: UInt32, common: UInt, interleaved: Bool
    public init(rate: Double, channels: UInt32, common: UInt, interleaved: Bool) {
        self.rate = rate; self.channels = channels; self.common = common; self.interleaved = interleaved
    }
}
public enum RouteContinuity {
    /// A built-in port switch with unchanged I/O does not invalidate any graph.
    public static func needsRebuild(before: [RouteIOFormat], after: [RouteIOFormat],
        previous: PhoneAudioRoute, current: PhoneAudioRoute, reason: UInt,
        configurationChanged: Bool, running: Bool, active: Bool) -> Bool {
        guard active else { return false }
        if configurationChanged || !running || before != after { return true }
        if previous != current && (!previous.isBuiltIn || !current.isBuiltIn) { return true }
        return [1, 2].contains(reason) && (!previous.isBuiltIn || !current.isBuiltIn)
    }
}

/// Audio-callback proof, independent of MainActor delivery. Only registered
/// tokens in the active run may advance the source-frame high-water mark.
fileprivate final class PlaybackCompletionProof: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0, through = 0
    private var ends: [PlaybackBufferScheduler.Token: Int] = [:]
    func register(_ token: PlaybackBufferScheduler.Token, end: Int, revision: Int) {
        lock.lock(); defer { lock.unlock() }
        precondition(self.revision == revision)
        ends[token] = end
    }
    @discardableResult func record(_ token: PlaybackBufferScheduler.Token, revision: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.revision == revision, let end = ends.removeValue(forKey: token) else { return false }
        through = max(through, end); return true
    }
    /// Capture and seal the OLD run atomically, before stop() can flush callbacks
    /// for buffers that were never played. Late old-run proof cannot enter next.
    func retire(revision: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        precondition(self.revision == revision)
        self.revision += 1; ends.removeAll(keepingCapacity: true)
        return through
    }
}

/// Bounded ledger for the <=4 scheduled PCM buffers. The producer retains carry
/// and its existing HTTP iterator; repairing never asks Speaker for a new ticket.
@MainActor public final class PlaybackContinuity {
    public struct CompletionReceipt: Sendable {
        fileprivate let proof: PlaybackCompletionProof
        fileprivate let token: PlaybackBufferScheduler.Token
        fileprivate let revision: Int
        /// Call directly in AVAudioPlayerNode's callback, BEFORE any actor hop.
        @discardableResult nonisolated public func record() -> Bool { proof.record(token, revision: revision) }
    }
    public struct Segment {
        public let token: PlaybackBufferScheduler.Token
        public var first: Int, pcm: Data
        public var end: Int { first + pcm.count / 2 }
    }
    public let queue: PlaybackBufferScheduler
    public private(set) var segments: [Segment] = []
    public private(set) var submitted = 0, position = 0, renderBase = 0, revision = 0
    public private(set) var suspended = false
    public private(set) var positionKnown = true
    public private(set) var skippedFrames = 0
    private var ready: [CheckedContinuation<Void, Never>] = []
    private let completionProof = PlaybackCompletionProof()
    public init(queue: PlaybackBufferScheduler) { self.queue = queue }
    public func append(_ pcm: Data, token: PlaybackBufferScheduler.Token) {
        precondition(!suspended && segments.count < PlaybackBufferScheduler.highWater)
        segments.append(Segment(token: token, first: submitted, pcm: pcm)); submitted += pcm.count / 2
    }
    public func completionReceipt(for segment: Segment) -> CompletionReceipt {
        completionProof.register(segment.token, end: segment.end, revision: revision)
        return CompletionReceipt(proof: completionProof, token: segment.token, revision: revision)
    }
    /// Repair must never start an idle pre-first-chunk player/source clock.
    @discardableResult public func startRetainedRun(_ start: () -> Void) -> Bool {
        guard !suspended, !segments.isEmpty, queue.depth > 0 else { return false }
        start(); return true
    }
    @discardableResult public func completed(_ token: PlaybackBufferScheduler.Token, revision: Int) -> Bool {
        guard !suspended, self.revision == revision,
              let index = segments.firstIndex(where: { $0.token == token }) else { return false }
        position = max(position, segments[index].end); segments.remove(at: index)
        return queue.played(token)
    }
    /// Render sample time is relative to the current player run, in source frames.
    /// With no clock, retire only the first unproven buffer: never repeat an
    /// unknown partial buffer or abandon the rest of the current utterance.
    public func suspend(renderedFrames: Int?) -> [PlaybackBufferScheduler.Token] {
        guard !suspended else { return [] }
        let completedThrough = completionProof.retire(revision: revision)
        suspended = true; revision += 1
        position = max(position, min(submitted, completedThrough))
        skippedFrames = 0
        positionKnown = renderedFrames != nil || !segments.contains { $0.end > position }
        if let renderedFrames { position = max(position, min(submitted, renderBase + max(0, renderedFrames))) }
        else if let unknown = segments.first(where: { $0.end > position }) {
            skippedFrames = unknown.end - max(position, unknown.first)
            position = unknown.end
        }
        var consumed: [PlaybackBufferScheduler.Token] = []
        segments = segments.compactMap { segment in
            if segment.end <= position { consumed.append(segment.token); return nil }
            var remainder = segment
            let skip = max(0, position - segment.first)
            remainder.pcm = Data(segment.pcm.dropFirst(skip * 2)); remainder.first += skip
            return remainder
        }
        for token in consumed { queue.played(token) }
        return consumed
    }
    public func resume() {
        renderBase = position; suspended = false
        let waits = ready; ready = []; waits.forEach { $0.resume() }
    }
    public func restartEmptyRun() {
        precondition(segments.isEmpty && queue.depth == 0)
        _ = completionProof.retire(revision: revision)
        renderBase = position; revision += 1
    }
    public func cancel() {
        _ = completionProof.retire(revision: revision)
        revision += 1; suspended = false; segments = []
        let waits = ready; ready = []; waits.forEach { $0.resume() }
    }
    public func waitUntilResumed() async throws {
        try Task.checkCancellation()
        if suspended {
            await withTaskCancellationHandler {
                await withCheckedContinuation { ready.append($0) }
            } onCancel: { Task { @MainActor in self.cancel(); self.queue.cancel() } }
        }
        try Task.checkCancellation()
    }
}
