import Foundation

/// Shared closed logical-end codes. durationLimit is retained only for decoding
/// older diagnostics; new duration caps end a segment, not a logical utterance.
public enum TurnEndReason: String, Codable, Sendable {
    case pause, wordsStopped, finalTimeout, manualSend, muteSend, discontinuity, stop
    case durationLimit, noiseDiscard
}
public enum RecognitionSegmentEndReason: String, Codable, Sendable { case durationLimit }

public enum UtteranceOutcomeKind: String, Codable, Sendable {
    case posted, heldForBusy, mergedIntoNext, emptyDiscarded, noiseDiscarded
    case quarantined, staleLease, discardedByUser, backchannel
    case heldForSend, heldForPause, postFailed
}
public enum UtteranceDeliveryMode: String, Codable, Sendable {
    case notPosted, normal, queue, steer, admitOnly
    public init(_ kind: PostKind) {
        switch kind {
        case .normal: self = .normal
        case .admitOnly: self = .admitOnly
        case .delivery(.queue): self = .queue
        case .delivery(.steer): self = .steer
        }
    }
}
/// No transcript, session ID, URL, error description or free-form reason.
public struct UtteranceOutcomeDiagnostic: Codable, Sendable {
    public let ordinal: Int, sequence: Int, finalWordCount: Int
    public let finalEmpty: Bool, finalReceived: Bool, cutInStoppedPlayback: Bool
    public let outcome: UtteranceOutcomeKind, delivery: UtteranceDeliveryMode
    public let mergedIntoOrdinal: Int?
    public var segmentRollover: Int? = nil
    public var turnEndReason: TurnEndReason? = nil
}

/// Shared-core sink: platforms bind storage; the turn policy knows no filesystem
/// or platform logger. Capture ownership at onset, not at delayed delivery.
@MainActor public final class UtteranceOutcomeLog {
    public static let shared = UtteranceOutcomeLog()
    let callToken: () -> Int
    let write: (UtteranceOutcomeDiagnostic, Int) -> Void
    let segment: (Int, Int) -> Void
    public init(callToken: @escaping () -> Int = { 0 }, write: @escaping (UtteranceOutcomeDiagnostic, Int) -> Void = { _, _ in }, segment: @escaping (Int, Int) -> Void = { _, _ in }) {
        self.callToken = callToken; self.write = write; self.segment = segment
    }
}

@MainActor final class UtteranceOutcomeRecord {
    let ordinal: Int, call: Int, diagnostics: UtteranceOutcomeLog
    var policy: AutomaticCutInDecision
    var words = 0, empty = true, finalReceived = false, cutStopped = false
    var resolved = false
    var explicitSend = false
    var segmentRollover = 0
    var turnEndReason: TurnEndReason?
    private var sequence = 0
    private(set) var last: UtteranceOutcomeKind?
    init(ordinal: Int, call: Int, diagnostics: UtteranceOutcomeLog, beganDuringPlayback: Bool) {
        self.ordinal = ordinal; self.call = call; self.diagnostics = diagnostics
        policy = AutomaticCutInDecision(beganDuringPlayback: beganDuringPlayback)
    }
    func finalMetadata(_ text: String) {
        words = text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
        empty = words == 0; finalReceived = true
    }
    func record(_ outcome: UtteranceOutcomeKind, mode: UtteranceDeliveryMode = .notPosted, mergedInto: Int? = nil) {
        // Discard/retirement wins over already-enqueued old recognizer callbacks.
        if last == .discardedByUser || last == .posted { return }
        sequence += 1; last = outcome
        let value = UtteranceOutcomeDiagnostic(ordinal: ordinal, sequence: sequence, finalWordCount: words,
            finalEmpty: empty, finalReceived: finalReceived, cutInStoppedPlayback: cutStopped,
            outcome: outcome, delivery: mode, mergedIntoOrdinal: mergedInto,
            segmentRollover: segmentRollover, turnEndReason: turnEndReason)
        diagnostics.write(value, call)
    }
}
