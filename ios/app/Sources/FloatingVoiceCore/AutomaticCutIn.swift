import Foundation

/// Shared phone/Mac policy. These are deliberately named feel parameters.
public enum AutomaticCutInTuning {
    public static let duckGain: Float = 0.25
    public static let sustainedFallbackMs = 900.0
    public static let acknowledgementPhrases: Set<String> = [
        "yeah", "yes", "yep", "mm-hm", "mhm", "uh-huh", "okay", "ok", "right", "sure", "got it", "alright", "I see"
    ]
    public static func normalized(_ text: String) -> String {
        let plain = text.lowercased().unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        return String(String.UnicodeScalarView(plain)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    public static func acknowledgement(_ text: String) -> Bool {
        let text = normalized(text)
        return !text.isEmpty && acknowledgementPhrases.contains { normalized($0) == text }
    }
}

public struct AutomaticCutInDecision {
    public enum Action: Equatable { case none, duck, commit, restoreDucked }
    public enum Final: Equatable { case realSpeech, backchannel, empty }
    public let beganDuringPlayback: Bool
    public private(set) var committed = false
    private var hasInterimWords = false, wordCommit = false
    public init(beganDuringPlayback: Bool) { self.beganDuringPlayback = beganDuringPlayback }
    public var onset: Action { beganDuringPlayback ? .duck : .none }
    public mutating func interim(_ text: String, playbackActive: Bool) -> Action {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return .none }
        hasInterimWords = true
        if beganDuringPlayback && AutomaticCutInTuning.acknowledgement(text) {
            if committed && !wordCommit { committed = false; return .restoreDucked }
            return .none
        }
        guard !committed, playbackActive else { return .none }
        committed = true; wordCommit = true; return .commit
    }
    public mutating func voiced(_ milliseconds: Double, playbackActive: Bool) -> Action {
        guard beganDuringPlayback, playbackActive, !committed, !hasInterimWords,
              milliseconds >= AutomaticCutInTuning.sustainedFallbackMs else { return .none }
        committed = true; return .commit
    }
    public func final(_ text: String) -> Final {
        if !text.contains(where: { $0.isLetter || $0.isNumber }) { return .empty }
        if beganDuringPlayback && AutomaticCutInTuning.acknowledgement(text) { return .backchannel }
        return .realSpeech
    }
}

/// A buffer/stream producer stays alive during the reversible, audible cut.
/// Platform adapters must preserve position; an empty final must not re-synthesize.
@MainActor public protocol AutomaticCutInOutput: AudioOutput {
    func setCutInGain(_ gain: Float)
    func pauseForAutomaticCutIn() -> Bool
    func resumeAfterAutomaticCutIn() throws
}

public enum PrivateVoiceNotice: String, Sendable { case didntCatchThat = "Didn't catch that" }

/// Captured per recognizer, so late finals cannot mutate a newer utterance.
public struct TurnOutcomeObserver {
    public var segmentRollover: (Int) -> Void = { _ in }
    public var logicalEnd: (TurnEndReason) -> Void = { _ in }
    public var final: (String, Bool) -> Bool = { _, _ in true }
    public var noise: () -> Void = {}
    public var cancelled: () -> Void = {}
    public var failed: () -> Void = {}
    public init() {}
}
