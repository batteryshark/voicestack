import Foundation
import Combine

/// The pill's state, driven by the controller's status and caption events, with no UI code so it runs headless in
/// tests and the harness. The window draws it; `tick()` (about 20 times a second in the app) advances the
/// visualizer and the shrink timer.
@MainActor
public final class PillModel: ObservableObject {
    public enum Phase: String, Sendable { case off, starting, connecting, ready }
    /// Whose voice the visualizer shows.
    public enum Voice: String, Sendable { case none, you, chief }

    /// The principal's side. `final` is drawn white and `tail` grey.
    public struct You: Equatable, Sendable {
        public var final = ""
        public var tail = ""
        /// The words are held before sending (mid-sentence, or merging while the chief is busy): "Holding: …".
        public var holding = false
        /// Unsent words were dropped; only "Discarded" is shown, never the abandoned text.
        public var discarded = false
        public var isEmpty: Bool { final.isEmpty && tail.isEmpty }
        public var text: String { [final, tail].filter { !$0.isEmpty }.joined(separator: " ") }
    }

    /// The chief's side. While a reply plays, `current` is the sentence being spoken and `earlier` the one before
    /// it; otherwise `current` is the recent reply text and `speaking` is false.
    public struct Chief: Equatable, Sendable {
        public var earlier = ""
        public var current = ""
        public var speaking = false
        public var isEmpty: Bool { earlier.isEmpty && current.isEmpty }
    }

    /// What the pill is waiting for between you finishing and the chief answering, so the wait never feels dead.
    public enum Wait: Equatable, Sendable {
        case none
        /// Silence after speech (or a hold): your words go in `seconds` (whole seconds left, counting down to 1);
        /// `fraction` of the wait is left, for a ring. Any new speech cancels it; Send (or the hotkey) sends now.
        case countdown(seconds: Int, fraction: Double)
        /// The wait is over; the final words are on their way.
        case sending
        /// Your words were sent (shown briefly).
        case sent
        /// Sent, and the chief is working before its first words.
        case thinking
    }

    // Tunables (ms).
    /// The card shrinks back to the pill after this much quiet.
    public var shrinkAfterMs = 4000.0
    /// "Sent" shows this long, then "<name> is thinking…" while the chief is busy.
    public var sentMs = 900.0
    /// The last words of a live hypothesis stay grey until a newer hypothesis confirms them.
    public static let tailWords = 2
    public static let barCount = 15

    @Published public private(set) var status = ConversationController.Status()
    @Published public private(set) var expanded = false
    @Published public private(set) var you = You()
    @Published public private(set) var chief = Chief()
    /// Latest inbound update: separate from principal speech, held words and countdown state.
    public struct External: Equatable, Sendable {
        public let sender: SenderAttribution
        public let text: String
        public var displayText: String { SenderAttribution.displayText(text, sender: sender) }
    }
    @Published public private(set) var external: External?
    /// Visualizer bars, oldest first, 0...1.
    @Published public private(set) var levels = [Double](repeating: 0, count: PillModel.barCount)
    @Published public private(set) var voice: Voice = .none
    /// The assistant's turn label and thinking text; see `AssistantLabel` (a name may come from elsewhere later).
    public var assistantName: String { AssistantLabel.name }
    /// The caption label for its turns, in small caps.
    public var assistantLabel: String { AssistantLabel.name.uppercased() }
    @Published public private(set) var wait: Wait = .none
    /// "Background noise: try Low sensitivity": the room is too loud for the pause to be heard.
    @Published public private(set) var noiseHint = false
    public static let noiseHintText = "Background noise: try Low sensitivity"
    /// The hint stays this long after the sound dips again, so it can be read.
    public var noiseHintHoldMs = 6000.0
    private var noisyNow = false
    private var noiseHintUntil = 0.0
    /// The settings view is open (keeps the card open).
    @Published public var settingsOpen = false { didSet { if settingsOpen { expand("settings") } } }
    /// The error details are open (keeps the card open).
    @Published public var errorDetailsOpen = false { didSet { if errorDetailsOpen { expand("error details") } } }
    /// The pointer is over the card: it does not shrink while you read it.
    public var hovering = false

    /// Notable changes, for logs and the harness: (time ms, description).
    public private(set) var history: [(Double, String)] = []
    public var onHistory: ((String) -> Void)?
    /// App-only accessibility delivery; headless rendering/testing never posts system announcements.
    public var onDiscardAnnouncement: (() -> Void)?

    let now: () -> Double
    private var lastActive = 0.0
    // You
    private var thought: [String] = []
    private var sent = false
    private var liveWords: [String] = []
    private var settledCount = 0
    private var discardedText: String?
    private var discardedUntil: Double?
    // Wait before sending, and what follows
    private var countdown: (total: Double, start: Double, hold: Bool)?
    private var postedAt: Double?
    private var chiefSeen = false
    // Chief
    private var replyLabel: String?
    private var received: [String] = []
    private var spokenLabel: String?
    private var spoken: [String] = []
    private var playing = false
    // Levels
    private var micPeak = 0.0
    private var outPeak = 0.0
    private var outAt = -1e12

    public init(now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) { self.now = now }

    /// Feed the controller's status and caption events into this model.
    public func attach(_ controller: ConversationController) {
        update(status: controller.status)
        controller.onCaption = { [weak self] in self?.handle($0) }
    }

    // MARK: Derived state

    public var phase: Phase {
        guard status.running else { return .off }
        if status.phase == "starting" { return .starting }
        return status.connection == "connected" ? .ready : .connecting
    }

    /// Dimmed when voice is off or not connected.
    public var dimmed: Bool { phase != .ready }
    public var errorText: String? { status.lastError }
    public var hasError: Bool { status.lastError != nil }
    public var micMuted: Bool { status.micMuted }
    public var outputMuted: Bool { status.outputMuted }
    /// One line for the pill's tooltip and the menu.
    public var stateLine: String {
        if let e = status.lastError, !status.running { return e }
        return status.line
    }

    // MARK: Input

    public func update(status s: ConversationController.Status) {
        let old = status
        status = s
        if old.target != s.target || (old.running && !s.running) { external = nil }
        if s.warmingSpeech && !old.warmingSpeech { note(SpeechWarmup.text); expand("speech warm-up") }
        if s.holding != old.holding {
            refreshYou()
            if let h = s.holding { note("holding: \(h)"); expand("holding") }
        }
        if s.lastError != old.lastError, let e = s.lastError { note("error: \(e)") }
        if s.lastError == nil { errorDetailsOpen = false }
        if s.running != old.running { note(s.running ? "voice on" : "voice off") }
        if !s.running { countdown = nil; postedAt = nil }
        if old.busy && !s.busy { postedAt = nil } // the turn is over
        if !s.speaking && old.speaking { playing = false; refreshChief() }
        if s.speaking && !old.speaking { refreshChief() }
        refreshWait()
    }

    public func handle(_ event: CaptionEvent) {
        switch event {
        case .inbound(let sender, let text):
            external = External(sender: sender, text: text)
            note("inbound \(sender.label) [\(sender.provenance)]")
            expand("inbound update")
        case .youStarted:
            if discardedUntil != nil { clearDiscardConfirmation() }
            expand("you started")
        case .youSpeaking:
            expand("you speaking")
        case .discarded:
            thought = []; sent = true; liveWords = []; settledCount = 0
            countdown = nil
            discardedText = "Discarded"
            discardedUntil = now() + 1500
            refreshYou()
            note("discarded unsent speech")
            onDiscardAnnouncement?()
            expand("discarded words")
        case .youLive(let text):
            startThoughtIfSent()
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            // Words confirmed by this newer hypothesis turn white, except the newest few.
            var common = 0
            while common < min(words.count, liveWords.count) && words[common] == liveWords[common] { common += 1 }
            settledCount = max(0, min(common, words.count - PillModel.tailWords))
            liveWords = words
            refreshYou()
            note("you live: \(you.final) | \(you.tail)")
            expand("live words")
        case .countdown(let total, let elapsed, let hold):
            countdown = (total, now() - elapsed, hold)
            refreshWait()
            if !hold { expand("silence; sending soon") }
        case .countdownCancelled:
            countdown = nil
            refreshWait()
        case .noisy(let on):
            noisyNow = on
            if on { noiseHintUntil = now() + noiseHintHoldMs; noiseHint = true; note("noise hint"); expand("background noise") }
            else { noiseHintUntil = now() + noiseHintHoldMs }
        case .youFinal(let text):
            if countdown?.hold == false { countdown = nil }
            startThoughtIfSent()
            thought.append(text)
            liveWords = []; settledCount = 0
            refreshYou()
            note("you final: \(text)")
            expand("final words")
        case .youIdle:
            if !liveWords.isEmpty { liveWords = []; settledCount = 0; refreshYou() }
            if countdown?.hold == false { countdown = nil; refreshWait() }
        case .posted(let text):
            sent = true
            countdown = nil
            postedAt = now(); chiefSeen = false
            note("posted: \(text)")
            expand("sent")
            refreshWait()
        case .chiefQueued(let label, let text):
            if label != replyLabel { replyLabel = label; received = [] }
            received.append(text)
            chiefSeen = true
            refreshChief()
            refreshWait()
            if status.outputMuted { expand("reply text (agent voice muted)") }
        case .chiefStarted(let label, let text):
            if label != spokenLabel { spokenLabel = label; spoken = [] }
            spoken.append(text)
            playing = true
            chiefSeen = true
            refreshChief()
            refreshWait()
            note("chief speaking: \(text)")
            expand("chief speaking")
        case .chiefEnded(_, _, let outcome):
            playing = false
            if outcome != "played" { note("chief sentence \(outcome)") }
            refreshChief()
        case .micLevel(let rms):
            micPeak = max(micPeak, rms)
        case .outputLevel(let rms):
            outPeak = max(outPeak, rms)
            if rms > 0.002 { outAt = now() }
        }
        refreshWait()
    }

    /// Advance the visualizer one step and shrink the card after quiet. Call regularly (the app: every 50 ms).
    public func tick() {
        let t = now()
        if let until = discardedUntil, t >= until { clearDiscardConfirmation() }
        // Whoever is talking: the principal while an utterance is open (they win over the chief, as in barge-in),
        // else the chief while its audio is heard, else the live mic (quiet room noise).
        refreshWait()
        if noiseHint && !noisyNow && t >= noiseHintUntil { noiseHint = false }
        let next: Voice
        var level = 0.0
        var direct: Double?
        if status.running && !status.micMuted && status.hearing { next = .you; level = micPeak }
        else if wait == .thinking && !status.speaking {
            // The chief is working: a slow, low swell in its colour instead of a dead bar.
            next = .chief; direct = 0.30 + 0.20 * sin(t / 260) + 0.08 * sin(t / 95)
        }
        else if status.speaking && t - outAt < 300 { next = .chief; level = outPeak }
        else if status.running && status.phase == "ready" && !status.micMuted { next = .you; level = micPeak }
        else { next = .none }
        if next != voice { voice = next }
        micPeak = 0; outPeak = 0
        var bars = levels
        bars.removeFirst()
        bars.append(direct ?? PillModel.normalize(level))
        if bars != levels { levels = bars } // a silent, idle pill does not redraw

        if isActive { lastActive = t }
        else if expanded && t - lastActive >= shrinkAfterMs {
            expanded = false
            note("shrink after \(Int(t - lastActive)) ms quiet")
        }
    }

    /// RMS to a 0...1 bar height on a log scale: -50 dBFS and below is flat, -10 dBFS is full.
    public static func normalize(_ rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 50) / 40))
    }

    // MARK: Private

    /// Something on screen still matters: speech being heard or played, words held, settings or details open.
    private var isActive: Bool {
        status.pendingSpeech || discardedUntil != nil || status.hearing || status.speaking || status.holding != nil || !liveWords.isEmpty || settingsOpen || errorDetailsOpen || (hovering && expanded)
            || wait != .none || noiseHint || status.warmingSpeech
    }

    /// Where the wait stands now: counting down, sending, sent, or the chief thinking.
    private func computeWait() -> Wait {
        let t = now()
        if let c = countdown {
            let remaining = c.total - (t - c.start)
            if remaining > 0 { return .countdown(seconds: max(1, Int(ceil(remaining / 1000))), fraction: (remaining / max(1, c.total) * 50).rounded() / 50) }
            if remaining > -3000 { return .sending }
            countdown = nil
        }
        if let p = postedAt, !chiefSeen {
            if t - p < sentMs { return .sent }
            if status.busy { return .thinking }
        }
        return .none
    }

    private func refreshWait() {
        let w = computeWait()
        guard w != wait else { return }
        let old = wait
        wait = w
        switch w {
        case .countdown(let s, _):
            if case .countdown(let o, _) = old, o == s { break }
            note("countdown \(s)")
        case .sending: note("sending")
        case .sent: note("sent")
        case .thinking: note("thinking")
        case .none: if old != .none { note("wait over") }
        }
    }

    private func expand(_ why: String) {
        lastActive = now()
        guard !expanded else { return }
        expanded = true
        note("grow (\(why))")
    }

    private func note(_ s: String) {
        history.append((now(), s))
        onHistory?(s)
    }

    private func startThoughtIfSent() {
        if sent { thought = []; sent = false }
        discardedText = nil
        discardedUntil = nil
    }

    private func clearDiscardConfirmation() {
        discardedUntil = nil; discardedText = nil
        refreshYou()
    }

    private var settledText: String { liveWords.prefix(settledCount).joined(separator: " ") }
    private var tailText: String { liveWords.dropFirst(settledCount).joined(separator: " ") }

    private func refreshYou() {
        if let d = discardedText {
            you = You(final: d, tail: "", holding: false, discarded: true)
            return
        }
        let base = status.holding ?? thought.joined(separator: " ")
        you.final = [base, settledText].filter { !$0.isEmpty }.joined(separator: " ")
        you.tail = tailText
        you.holding = status.holding != nil
        you.discarded = false
    }

    private func refreshChief() {
        var c = Chief()
        if status.speaking && !status.outputMuted {
            // In step with playback: only sentences that have started playing are shown, never queued ones.
            c.speaking = playing
            c.current = spoken.last ?? ""
            c.earlier = spoken.count > 1 ? spoken[spoken.count - 2] : ""
        } else {
            // Quiet (or muted): the recent reply text.
            c.current = (received.isEmpty ? spoken : received).joined(separator: " ")
        }
        if c != chief { chief = c }
    }
}
