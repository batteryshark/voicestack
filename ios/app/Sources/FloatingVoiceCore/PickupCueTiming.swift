import Foundation

/// One pickup cycle, started once media is ready. Both cues are synthesized up front;
/// the greeting plays after a short delay and "I'm here" at most once, after the
/// greeting has finished. cancel() drops pending cues and unused tickets only: audio
/// already handed to the speaker plays out (hang-up/pause stop it on their own paths).
@MainActor public final class PickupCueTiming {
    public static let followupText = "I'm here"
    private var generation = 0
    private var pending: Task<Void,Never>?
    private var unused: [SpeechTicket] = []
    private let greetingDelay: UInt64, followupDelay: UInt64
    private let prepare: (String) -> SpeechTicket?
    private let play: (SpeechTicket, @escaping (Bool) -> Void) -> Void
    private let mayFollowUp: () -> Bool
    public init(greetingDelay: UInt64 = 1_000_000_000, followupDelay: UInt64 = 5_000_000_000,
                prepare: @escaping (String) -> SpeechTicket?, play: @escaping (SpeechTicket, @escaping (Bool) -> Void) -> Void,
                mayFollowUp: @escaping () -> Bool) {
        self.greetingDelay = greetingDelay; self.followupDelay = followupDelay
        self.prepare = prepare; self.play = play; self.mayFollowUp = mayFollowUp
    }
    public func begin(greeting: String = "Connected") {
        cancel()
        let owner = generation
        guard let first = prepare(greeting) else { return }
        let second = prepare(Self.followupText)
        unused = [first] + (second.map { [$0] } ?? [])
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds:self?.greetingDelay ?? 0)
            guard let self, !Task.isCancelled, self.generation == owner, self.take(first) else { return }
            self.play(first) { [weak self] _ in self?.greetingEnded(owner, followup: second) }
        }
    }
    private func greetingEnded(_ owner: Int, followup: SpeechTicket?) {
        guard generation == owner, let followup else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds:self?.followupDelay ?? 0)
            guard let self, !Task.isCancelled, self.generation == owner else { return }
            guard self.mayFollowUp(), self.take(followup) else { self.cancel(); return }
            self.play(followup) { _ in }
        }
    }
    private func take(_ ticket: SpeechTicket) -> Bool {
        guard let index = unused.firstIndex(where: { $0 === ticket }) else { return false }
        unused.remove(at: index); return true
    }
    public func cancel() {
        generation += 1; pending?.cancel(); pending = nil
        let tickets = unused; unused = []
        for ticket in tickets { ticket.cancel() }
    }
}
