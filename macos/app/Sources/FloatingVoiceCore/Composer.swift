import Foundation

/// How a composed message is posted.
public enum PostKind: Equatable, Sendable {
    /// Idle: starts a turn.
    case normal
    /// Busy: delivered into (steer) or after (queue) the running turn.
    case delivery(BusyDelivery)
    /// Admitted to the thread without starting a turn (`resume: false`), after an interrupt.
    case admitOnly
}

/// Turns recognized utterances into messages so one spoken thought arrives as one message:
/// - an utterance ending mid-sentence (no . ? ! …, or a trailing filler such as "uh", "and", "the") is held for
///   `holdMidSentenceMs`; speech starting again in that window appends to it;
/// - while the chief is busy in queue mode, everything said is buffered and posted as one queued message after
///   `busyMergeQuietMs` of quiet, or as a normal message once the turn has ended and the principal has been quiet
///   for `turnEndQuietMs` since their last utterance (never while they are speaking);
/// - an interrupt posts what is buffered without starting a turn; nothing is dropped;
/// - in manual send mode everything is held until `send()` (the Send button or hotkey); pauses never post.
@MainActor
public final class UtteranceComposer {
    public private(set) var held = ""
    private var merging = false
    private var speaking = false
    /// The turn ended while words were merging: they post as a normal message after `turnEndQuietMs` of quiet.
    private var turnOver = false
    /// When the principal's last utterance ended (ms).
    private var lastHeard = -Double.infinity
    /// Send was pressed mid-utterance: post when its final text arrives (either mode).
    private var sendAfterFinal = false
    private var sendReason = "send"
    public var manual: Bool { settings().sendMode == .manual }
    /// An utterance is in progress (onset seen, final not yet in).
    public var isSpeaking: Bool { speaking }
    public var hasWait: Bool { timer != nil }
    public var pendingSendAfterFinal: Bool { sendAfterFinal }
    private var timer: Task<Void, Never>?
    private var timerEpoch = 0
    let now: () -> Double
    let settings: () -> AppSettings
    let isBusy: () -> Bool
    let send: (String, PostKind, String) -> Void
    let log: (String) -> Void
    /// The end-of-utterance pause length (ms): the mid-sentence hold only applies below `AppSettings.holdBelowPauseMs`.
    let pauseMs: () -> Double
    /// Called when a wait before sending starts (with its length in ms) or ends (nil): for the countdown cue.
    public var onWait: ((Double?) -> Void)?
    /// Called with the held text (nil when nothing is held), for the window's "Holding:" line.
    public var onHolding: ((String?) -> Void)?

    public init(settings: @escaping () -> AppSettings, isBusy: @escaping () -> Bool,
                send: @escaping (String, PostKind, String) -> Void, log: @escaping (String) -> Void,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
                pauseMs: @escaping () -> Double = { 0 }) {
        self.settings = settings; self.isBusy = isBusy; self.send = send; self.log = log; self.now = now; self.pauseMs = pauseMs
    }

    nonisolated static let fillers: Set<String> = [
        "uh", "um", "uhm", "umm", "er", "erm", "ah", "hmm", "mm", "like", "and", "so", "but", "or", "nor", "the", "a", "an",
        "with", "to", "of", "for", "from", "in", "on", "at", "by", "that", "which", "who", "because", "if", "then",
        "i", "my", "your", "our", "is", "are", "was", "were", "it's", "its", "just", "kind", "sort", "maybe", "also",
        "about", "into", "than", "when", "where", "while", "as",
    ]

    /// True when the text ends a sentence: final punctuation and no trailing filler word.
    nonisolated public static func isComplete(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last, ".?!…".contains(last) else { return false }
        let words = t.lowercased().split(whereSeparator: { $0.isWhitespace })
        let lastWord = words.last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".?!…,;:\"'()")) } ?? ""
        return !fillers.contains(lastWord)
    }

    /// The principal started speaking (onset): a pending hold keeps waiting for this utterance.
    public func speechStarted() {
        speaking = true
        if timer != nil { cancelTimer(); log("hold: principal speaking again; waiting for the rest") }
    }

    /// The utterance ended without words (noise): resume waiting.
    public func speechIdle() {
        if speaking { lastHeard = now() }
        speaking = false
        if sendAfterFinal { if !held.isEmpty { flush(reason: sendReason) } else { sendAfterFinal = false }; return }
        if manual { return }
        if !held.isEmpty && timer == nil { startTimer() }
    }

    public func utterance(_ text: String) {
        speaking = false
        lastHeard = now()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { speechIdle(); return }
        held = held.isEmpty ? t : held + " " + t
        if sendAfterFinal { flush(reason: sendReason); return }
        if manual {
            log("hold (manual send): waiting for Send: \(held)")
            onHolding?(held)
            return
        }
        if turnOver {
            log("hold (turn over): waiting for \(Int(settings().turnEndQuietMs)) ms of quiet: \(held)")
            onHolding?(held)
            startTimer()
            return
        }
        if isBusy() && settings().busyDelivery == .queue {
            merging = true
            log("hold (chief busy, queue): merging, post after \(Int(settings().busyMergeQuietMs)) ms quiet or at turn end: \(held)")
            onHolding?(held)
            startTimer()
            return
        }
        if !merging && (Self.isComplete(held) || pauseMs() >= AppSettings.holdBelowPauseMs) {
            flush(reason: Self.isComplete(held) ? "complete sentence" : "pause of \(Int(pauseMs())) ms is long enough; no extra hold")
            return
        }
        log("hold (\(merging ? "merging" : "mid-sentence")): waiting up to \(Int(merging ? settings().busyMergeQuietMs : settings().holdMidSentenceMs)) ms for more: \(held)")
        onHolding?(held)
        startTimer()
    }

    /// The turn ended (succeeded or failed): post buffered words as a normal message, but only once the principal
    /// has been quiet for `turnEndQuietMs` since their last utterance ended, and never while they are speaking.
    public func turnEnded() {
        guard !manual, !held.isEmpty, merging else { return }
        turnOver = true
        let quiet = now() - lastHeard
        if !speaking && quiet >= settings().turnEndQuietMs {
            flush(reason: "turn ended, quiet for \(quiet.isFinite ? "\(Int(quiet)) ms" : "a while")", kind: .normal)
            return
        }
        log("hold (turn ended): \(speaking ? "principal speaking; waiting for them to finish" : "waiting for \(Int(settings().turnEndQuietMs - quiet)) ms more quiet"): \(held)")
        if speaking { cancelTimer() } else { startTimer(ms: settings().turnEndQuietMs - quiet) }
    }

    /// A turn was interrupted (Stop, or from elsewhere): add buffered words to the thread without starting a turn.
    /// Not while the principal is speaking (the thought is still coming; it is sent whole later), and not in manual
    /// mode (only Send sends).
    public func interrupted() {
        guard !held.isEmpty else { return }
        if manual { log("turn interrupted: still holding for Send: \(held)"); return }
        if speaking {
            // The turn is over; the whole thought goes in as a normal message once they have been quiet a while.
            if merging { turnOver = true }
            log("turn interrupted while the principal is speaking: still holding: \(held)")
            return
        }
        flush(reason: "turn interrupted", kind: .admitOnly)
    }

    /// Manual mode, voice stopping or quitting: drop what is held (only Send sends). Returns the dropped text.
    @discardableResult
    public func discard(reason: String) -> String? {
        guard !held.isEmpty else { reset(); return nil }
        let text = held
        log("discarded (\(reason); manual send, Send was not pressed): \(text)")
        reset()
        return text
    }

    /// Send (button or hotkey): post what is held now, or, while an utterance is still being recognized, as soon as
    /// its final text arrives (with it). Works in both modes.
    public func send(utteranceInProgress: Bool, reason: String = "send") {
        if utteranceInProgress { sendAfterFinal = true; sendReason = reason; log("\(reason): waiting for the utterance in progress, then sending it with what is held"); return }
        guard !held.isEmpty else { log("\(reason): nothing held"); return }
        flush(reason: reason)
    }

    /// The send mode changed: switching to auto posts what is held; switching to manual stops the pause timers.
    public func sendModeChanged() {
        if manual {
            cancelTimer(); merging = false; turnOver = false
            if !held.isEmpty { onHolding?(held) }
        } else {
            sendAfterFinal = false
            flushNow(reason: "switched to auto send")
        }
    }

    /// Voice is stopping: post whatever is held now.
    public func flushNow(reason: String) {
        guard !held.isEmpty else { return }
        flush(reason: reason)
    }

    public func reset() { cancelTimer(); held = ""; merging = false; turnOver = false; sendAfterFinal = false; speaking = false; onHolding?(nil) }

    private func cancelTimer() {
        timerEpoch += 1
        let was = timer != nil
        timer?.cancel(); timer = nil
        if was { onWait?(nil) }
    }

    private func startTimer(ms override: Double? = nil) {
        timer?.cancel()
        timerEpoch += 1
        let epoch = timerEpoch
        let ms = override ?? (turnOver ? settings().turnEndQuietMs : merging ? settings().busyMergeQuietMs : settings().holdMidSentenceMs)
        onWait?(max(0, ms))
        let turnOver = self.turnOver
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, ms) * 1_000_000))
            guard let self, !Task.isCancelled, self.timerEpoch == epoch, !self.speaking else { return }
            self.timer = nil
            self.onWait?(nil)
            // Normal message, unless another turn has started meanwhile (then the busy delivery applies).
            if turnOver { self.flush(reason: "turn ended, quiet for \(Int(self.settings().turnEndQuietMs)) ms") }
            else { self.flush(reason: self.merging ? "quiet for \(Int(ms)) ms" : "no more speech within \(Int(ms)) ms") }
        }
    }

    private func flush(reason: String, kind: PostKind? = nil) {
        let text = held
        held = ""
        merging = false
        turnOver = false
        sendAfterFinal = false
        cancelTimer()
        onHolding?(nil)
        let k = kind ?? (isBusy() ? .delivery(settings().busyDelivery) : .normal)
        send(text, k, reason)
    }
}
