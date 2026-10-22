import Foundation

/// Authoritative execution state only, including work begun before pickup.
/// Reply suppression persists across repeated active projections until a new turn.
@MainActor public final class ProcessingHoldMusic {
    private var active = false, suppressed = false
    private var timer: Task<Void, Never>?
    private var generation = 0
    private var cancelling = false
    public var playbackGeneration: Int { generation }
    private let delay: UInt64
    private let start: () -> Void, stop: () -> Void
    public var enabled = true { didSet { if !enabled { cancelPlayback() } else { schedule() } } }
    public init(delay: UInt64 = 3_500_000_000, start: @escaping () -> Void, stop: @escaping () -> Void) {
        self.delay = delay; self.start = start; self.stop = stop
    }
    public func posted() { suppressed = false; cancelPlayback(); schedule() }
    public func replyStarted() { suppressed = true; cancelPlayback() }
    public func caption(_ event: CaptionEvent) {
        switch event {
        case .posted: posted()
        case .youStarted, .youSpeaking, .youLive, .youFinal, .discarded, .chiefQueued, .chiefFinalReceived, .chiefStarted, .chiefUnavailable: replyStarted()
        default: break
        }
    }
    public func processing(_ value: Bool) {
        guard !cancelling else { return }
        if !value { end(); return }
        if !active { suppressed = false }
        active = value
        schedule()
    }
    public func end() { active = false; suppressed = false; cancelPlayback() }
    public func clipEnded(_ success: Bool, generation owner: Int) {
        guard owner == generation, enabled, active, !suppressed else { return }
        guard success else { end(); return }
        generation += 1
        timer = nil
        schedule(delay:0)
    }
    private func cancelPlayback() {
        generation += 1; timer?.cancel(); timer = nil
        let previous = cancelling; cancelling = true; stop(); cancelling = previous
    }
    private func schedule(delay override: UInt64? = nil) {
        guard enabled, active, !suppressed, timer == nil else { return }
        let owner = generation
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds:override ?? self?.delay ?? 0)
            guard let self, !Task.isCancelled, owner == self.generation, self.enabled, self.active, !self.suppressed else { return }
            // Remain armed until clipEnded so repeated active projections cannot restart.
            self.start()
        }
    }
}
