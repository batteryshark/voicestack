import Foundation

/// Another process capturing microphone input right now.
public struct MicHolder: Equatable, Sendable {
    public let pid: Int32
    public let path: String
    /// agent-voice's native audio helper (`bin/audio-macos`).
    public let isAgentVoice: Bool
    public init(pid: Int32, path: String, isAgentVoice: Bool) { self.pid = pid; self.path = path; self.isAgentVoice = isAgentVoice }
}

public protocol MicHolderCheck: AnyObject {
    /// Processes other than this one that are capturing input now.
    func otherCapturers() -> [MicHolder]
}

/// An audio output that reports its playback level (RMS of what is being heard, 0...1) for the visualizer.
@MainActor
public protocol LevelReporting: AnyObject {
    var onLevel: ((Double) -> Void)? { get set }
}

/// What the pill shows, as it happens: the principal's words (live and final), the chief's sentences as they are
/// queued and played, and audio levels. Display only; nothing here affects what is sent or played.
public enum CaptionEvent: Equatable, Sendable {
    case inbound(sender: SenderAttribution, text: String)
    /// Speech onset (an utterance opened).
    case youStarted
    /// Sustained speech in this utterance (bargeInMs of voice).
    case youSpeaking
    /// Live words of the utterance in progress: the whole hypothesis so far (`transcript.partial`).
    case youLive(String)
    /// The utterance's final text (the recognition server's final `transcript`).
    case youFinal(String)
    /// The utterance ended (after its final text, or without words).
    case youIdle
    /// Words were posted to the session.
    case posted(String)
    /// Unsent words were dropped. The pill shows only a private-text-free confirmation.
    case discarded(String)
    /// A reply sentence was received (queued for speech, or dropped while the agent voice is muted).
    case chiefQueued(label: String, text: String)
    case chiefStarted(label: String, text: String)
    case chiefEnded(label: String, text: String, outcome: String)
    /// The room is too loud for a pause to be heard (the sound has not dipped for 10 s inside an utterance), or no longer.
    case noisy(Bool)
    /// A wait before sending begins: `totalMs` long, `elapsedMs` of it already gone. `hold` is a hold or merge wait in the
    /// composer (not silence in the utterance).
    case countdown(totalMs: Double, elapsedMs: Double, hold: Bool)
    case countdownCancelled
    /// Microphone RMS of a frame that was listened to.
    case micLevel(Double)
    /// Playback RMS.
    case outputLevel(Double)
}

/// Microphone level over one second, for the run log: what reached voice-activity detection, how much of it counted
/// as voice, and whether the chief was speaking meanwhile.
public struct MicStats: Equatable, Sendable {
    public var frames = 0, voiced = 0, duringPlayback = 0, ignored = 0
    public var sumSquares = 0.0, peak = 0.0
    /// The partial frame left over from the last chunk: the capture path delivers chunks of any size, not whole
    /// 20 ms frames.
    private var carry = Data()
    public init() {}

    /// Add 16 kHz s16le audio of any chunk size; it is counted in whole 20 ms frames, like the voice-activity detector.
    public mutating func add(_ chunk: Data, threshold: Double, playing: Bool, ignored skip: Bool) {
        let pcm = carry + chunk
        carry = Data()
        var i = 0
        defer { if i < pcm.count { carry = pcm.subdata(in: i..<pcm.count) } }
        while i + TurnTaker.frameBytes <= pcm.count {
            let r = TurnTaker.rms(pcm.subdata(in: i..<i + TurnTaker.frameBytes))
            frames += 1
            sumSquares += r * r
            peak = max(peak, r)
            if r > threshold { voiced += 1 }
            if playing { duringPlayback += 1 }
            if skip { ignored += 1 }
            i += TurnTaker.frameBytes
        }
    }

    /// The once-a-second run-log line: levels against the voiced threshold, and the noise floor it came from.
    public func line(threshold: Double, floor: Double? = nil, sensitivity: String? = nil) -> String {
        guard frames > 0 else { return "mic: no audio in the last second" }
        var s = String(format: "mic: rms avg %.4f peak %.4f (voiced threshold %.4f", (sumSquares / Double(frames)).squareRoot(), peak, threshold)
        if let floor, let sensitivity { s += String(format: " = max(base, noise floor %.4f x %@)", floor, sensitivity) }
        s += String(format: "), %d/%d frames voiced", voiced, frames)
        if duringPlayback > 0 { s += ", \(duringPlayback) during playback" }
        if ignored > 0 { s += ", \(ignored) ignored (half duplex)" }
        return s
    }
}

/// Reference box for the recognition factory's live-partials switch (set per start from /health).
final class Flag { var on = false }

/// A settings change made from the window. Each is written to the app's own settings file and applied live.
public enum SettingChange: Equatable, Sendable {
    case voice(String)
    case inputDevice(String)
    case outputDevice(String)
    /// "auto" | "on" | "off"
    case echoCancellation(String)
    case pauseMs(Double)
    case busyDelivery(BusyDelivery)
    /// "chief" or a session id
    case target(String)
    case sendMode(SendMode)
    /// e.g. "ctrl+option+space"
    case sendHotkey(String)
    /// "low" | "normal" | "high"
    case sensitivity(String)

    public var key: String {
        switch self {
        case .voice: return "voice"
        case .inputDevice: return "inputDevice"
        case .outputDevice: return "outputDevice"
        case .echoCancellation: return "echoCancellation"
        case .pauseMs: return "pauseMs"
        case .busyDelivery: return "busyDelivery"
        case .target: return "target"
        case .sendMode: return "sendMode"
        case .sendHotkey: return "sendHotkey"
        case .sensitivity: return "sensitivity"
        }
    }

    public var value: Any {
        switch self {
        case .voice(let v), .inputDevice(let v), .outputDevice(let v), .echoCancellation(let v), .target(let v), .sendHotkey(let v), .sensitivity(let v): return v
        case .sendMode(let m): return m.rawValue
        case .pauseMs(let v): return v
        case .busyDelivery(let d): return d.rawValue
        }
    }

    /// Device and echo changes rebuild the audio engine: voice restarts if it is on.
    public var needsAudioRestart: Bool {
        switch self {
        case .inputDevice, .outputDevice, .echoCancellation: return true
        default: return false
        }
    }
}

/// The voice loop for one target session: follows its replies and speaks them, listens and sends utterances in,
/// and lets only the principal cut the voice off (barge-in, Stop, mute). Runs headless; audio, recognition,
/// speech and the server are injected.
@MainActor
public final class ConversationController {
    public struct Status: Equatable, Sendable {
        public var running = false
        /// off | connecting | connected | reconnecting
        public var connection = "off"
        public var target: String?
        /// The target session's title, when the server has one.
        public var targetTitle: String?
        /// starting (self-check running) | ready
        public var phase = "starting"
        public var busy = false
        public var hearing = false
        public var speaking = false
        public var micMuted = false
        public var outputMuted = false
        public var warmingSpeech = false
        public var lastError: String?
        public var notice: String?
        /// Words held before sending (mid-sentence, merging while the chief is busy, or waiting for Send).
        public var holding: String?
        /// Manual send mode: words wait for the Send button or hotkey.
        public var manualSend = false
        /// Includes capture before words, recognition finalisation and locally deferred (not submitted) posts.
        public var pendingSpeech = false
        public var discardHotkeyEligible: Bool { running && pendingSpeech }

        public init() {}
        init(lastError: String?, notice: String?) { self.lastError = lastError; self.notice = notice }

        /// "Chief of staff · a10001": the title and a short id, so the header never just says "Chief".
        public var targetLabel: String? {
            guard let target else { return nil }
            let title = (targetTitle?.isEmpty == false) ? targetTitle! : "Session"
            return "\(title) · \(SessionSummary.shortID(target))"
        }

        /// "Title (ses_…)" or the id.
        public var targetName: String? {
            guard let target else { return nil }
            if let t = targetTitle, !t.isEmpty { return "\(t) (\(target))" }
            return target
        }

        public var line: String {
            guard running else { return notice ?? "Voice off" }
            if warmingSpeech { return SpeechWarmup.text }
            if phase == "starting" { return "Starting: checking the microphone and speech servers…" }
            var parts: [String] = []
            if let name = targetName { parts.append(connection == "connected" ? "Connected to \(name)" : "\(connection.capitalized) \(name)") }
            else { parts.append(connection.capitalized) }
            parts.append(busy ? "busy" : "idle")
            parts.append(micMuted ? "mic muted" : hearing ? "hearing you" : "listening")
            if outputMuted { parts.append("agent voice muted") } else if speaking { parts.append("speaking") }
            return parts.joined(separator: " · ")
        }
    }

    public static let agentVoiceBusyMessage = "agent-voice is using the microphone. Turn voice off there (/voice off, or Stop voice in its Voice panel), then press Start voice."
    public static let agentVoiceTookMicMessage = "Paused: agent-voice started using the microphone. Turn voice off there (/voice off, or Stop voice in its Voice panel), then press Start voice."

    public private(set) var status = Status() { didSet { if status != oldValue { onStatus?(status) } } }
    public var onStatus: ((Status) -> Void)?
    public var onPrivateNotice: ((PrivateVoiceNotice) -> Void)?
    public var outcomeDiagnostics = UtteranceOutcomeLog.shared
    /// Captions and levels for the pill (PillModel).
    public var onCaption: ((CaptionEvent) -> Void)?
    public var app: AppSettings
    public private(set) var voice: VoiceConfig
    public let chiefFile: String
    /// The app's own settings file (the only file settings changes write) and agent-voice's file (read only).
    public let appFile: String
    public let voiceFile: String?
    /// This run asked the recognition server for live words (`?partials=1`), because /health advertises them.
    public var livePartials: Bool { partialsFlag.on }
    private let partialsFlag: Flag
    private let partialsProbe: (() async -> Bool)?

    let backend: SessionBackend
    let output: AudioOutput
    let input: AudioInput?
    let micCheck: MicHolderCheck?
    let makeRecognition: (RecognitionCallbacks) -> RecognitionSession
    let now: () -> Double
    let log: (String) -> Void
    let chiefPollInterval: TimeInterval
    let micPollInterval: TimeInterval
    let reconnectDelay: TimeInterval
    let preflight: [PreflightCheck]
    public private(set) lazy var speaker: Speaker = makeSpeaker()
    public private(set) lazy var composer: UtteranceComposer = makeComposer()
    private let synth: SpeechSynthesizer
    public let speechWarmup: SpeechWarmup
    private var preflightTask: Task<String?, Never>?
    private var previewTicket: SpeechTicket?

    var turnTaker: TurnTaker?
    private var blocks: [String: SpeechSegments] = [:]
    private var connectionTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var acceptInput = false
    private var liveAt = 0.0
    private var bargeArmed = false
    private var holdOff: TimeInterval?
    private var micStats = MicStats()
    /// Posts in flight (awaited on quit so held words are not lost).
    private var pendingPosts: [Task<Void, Never>] = []
    private var speechEpoch = 0 { didSet { discardUtteranceOutcomes() } }
    private var inputOutcomeOrdinal = 0
    private var utteranceOutcome: UtteranceOutcomeRecord?
    private var heldOutcome: UtteranceOutcomeRecord?
    private var deferredOutcomes: [UUID: UtteranceOutcomeRecord] = [:]
    private var privateNoticeTask: Task<Void, Never>?
    private var privateNoticeGeneration = 0
    private var currentLease: String? { status.target }
    private var utteranceLease: String?
    private var ownerEpoch = 0
    public private(set) var draftsForReview: [String] = []
    private var deferredPosts: Set<UUID> = []
    /// No capture or barge-in while speaking: duplex off in settings, or the mic would hear the speakers.
    public private(set) var halfDuplex = false
    private var runEpoch = 0
    // Separate from the audio/connection epoch: device restarts retain ownership, target changes invalidate it.
    private var voiceGeneration = 0
    private var voiceLease: (generation: Int, target: String)?
    private var voiceLeaseArmed = false

    public init(settings: LoadedSettings, backend: SessionBackend, synth: SpeechSynthesizer, output: AudioOutput, input: AudioInput?,
                makeRecognition: ((RecognitionCallbacks) -> RecognitionSession)? = nil, micCheck: MicHolderCheck? = nil,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
                chiefPollInterval: TimeInterval = 2, micPollInterval: TimeInterval = 1, reconnectDelay: TimeInterval = 1,
                preflight: [PreflightCheck] = [], partialsProbe: (() async -> Bool)? = nil,
                speechWarmup: SpeechWarmup = SpeechWarmup(), log: @escaping (String) -> Void = { _ in }) {
        app = settings.app
        voice = settings.voice
        chiefFile = settings.chiefFile
        appFile = settings.appFile
        voiceFile = settings.voiceFile
        self.backend = backend; self.synth = synth; self.output = output; self.input = input; self.micCheck = micCheck
        self.now = now; self.log = log
        self.chiefPollInterval = chiefPollInterval; self.micPollInterval = micPollInterval; self.reconnectDelay = reconnectDelay
        self.preflight = preflight
        self.partialsProbe = partialsProbe
        self.speechWarmup = speechWarmup
        if settings.appFileUnreadable {
            status.lastError = "\((settings.appFile as NSString).lastPathComponent) is unreadable, so its settings are not used. The next settings change saves a copy as .bad and writes a new one."
        }
        let flag = Flag()
        partialsFlag = flag
        let cfg = settings.voice
        self.makeRecognition = makeRecognition ?? { cbs in
            HealthCheckedRecognition(endpoint: cfg.asrUrl, key: cfg.asrApiKey, callbacks: cbs, warmup: speechWarmup) {
                WebSocketRecognition(url: cfg.asrUrl, apiKey: cfg.asrApiKey, partials: flag.on, callbacks: $0)
            }
        }
        speechWarmup.onChange = { [weak self] on in
            guard let self else { return }
            // Positive, healthy cold-state evidence supersedes a stale speech-service outage. A failure of
            // the ordinary request still reports its own error; warm-up itself is never an error/notice.
            if on { self.clearSpeechServiceError() }
            self.status.warmingSpeech = on
        }
        if let levels = output as? LevelReporting {
            levels.onLevel = { [weak self] level in self?.onCaption?(.outputLevel(level)) }
        }
    }

    private func makeSpeaker() -> Speaker {
        let s = Speaker(synth: synth, output: output) { [weak self] error in
            guard let self else { return }
            self.fail(self.speechMessage(error, fallbackPrefix: "Speech"))
        }
        s.onChange = { [weak self] in
            guard let self else { return }
            self.status.speaking = self.speaker.active
        }
        s.onSentence = { [weak self] label, text in
            guard let self else { return }
            self.clearSpeechServiceError()
            self.log("speak start [\(label)] \(text.prefix(80))")
            self.onCaption?(.chiefStarted(label: label, text: text))
        }
        s.onSentenceEnd = { [weak self] label, text, outcome in
            self?.log("speak end [\(label)] \(outcome): \(text.prefix(40))")
            self?.onCaption?(.chiefEnded(label: label, text: text, outcome: outcome))
        }
        return s
    }

    private func makeComposer() -> UtteranceComposer {
        let c = UtteranceComposer(settings: { [weak self] in self?.app ?? AppSettings() },
                                  isBusy: { [weak self] in self?.status.busy ?? false },
                                  send: { [weak self] text, kind, reason in
                                      guard let self, let target = self.status.target else { return }
                                      let outcome = self.heldOutcome ?? self.utteranceOutcome
                                      self.heldOutcome = nil
                                      let owner = self.ownerEpoch
                                      let epoch = self.speechEpoch, id = UUID()
                                      self.deferredPosts.insert(id)
                                      if let outcome { self.deferredOutcomes[id] = outcome }
                                      self.refreshPendingSpeech()
                                      let task = Task {
                                          guard !Task.isCancelled, epoch == self.speechEpoch else { outcome?.record(.discardedByUser); return }
                                          self.deferredPosts.remove(id)
                                          self.deferredOutcomes[id] = nil
                                          guard self.ownerEpoch == owner else {
                                              outcome?.record(.staleLease); self.draftsForReview.append(text)
                                              self.refreshPendingSpeech(); return
                                          }
                                          // Commitment boundary: no suspension between this check and issuing post.
                                          self.onCaption?(.posted(text))
                                          self.refreshPendingSpeech()
                                          await self.post(text, kind: kind, reason: reason, to: target, outcome: outcome)
                                      }
                                      self.pendingPosts.append(task)
                                      Task { await task.value; self.pendingPosts.removeAll { $0 == task } }
                                  },
                                  log: { [weak self] in self?.log($0) },
                                  pauseMs: { [weak self] in self?.voice.pauseMs ?? 0 })
        c.onHolding = { [weak self] text in
            guard let self else { return }
            self.status.holding = text
            if text != nil, let outcome = self.heldOutcome {
                outcome.record(self.composer.manual ? .heldForSend : self.status.busy && self.app.busyDelivery == .queue ? .heldForBusy : .heldForPause)
            }
            self.refreshPendingSpeech()
        }
        c.onWait = { [weak self] ms in self?.onCaption?(ms.map { .countdown(totalMs: $0, elapsedMs: 0, hold: true) } ?? .countdownCancelled) }
        return c
    }

    private func beginUtteranceOutcome() {
        utteranceLease = currentLease // Mac immutable target capture; keep shared onset region strict.
        inputOutcomeOrdinal += 1
        let record = UtteranceOutcomeRecord(ordinal: inputOutcomeOrdinal, call: outcomeDiagnostics.callToken(),
            diagnostics: outcomeDiagnostics, beganDuringPlayback: speaker.playing && !halfDuplex)
        utteranceOutcome = record
        if record.policy.onset == .duck { speaker.duckForAutomaticCutIn(true) }
    }
    private func makeUtteranceOutcomeObserver() -> TurnOutcomeObserver {
        guard let record = utteranceOutcome else { return TurnOutcomeObserver() }
        var observer = TurnOutcomeObserver()
        observer.segmentRollover = { record.segmentRollover = $0; record.diagnostics.segment($0, record.call) }
        observer.logicalEnd = { record.turnEndReason = $0 }
        observer.final = { [weak self] text, eligible in self?.observeUtteranceFinal(text, eligible: eligible, record: record) ?? false }
        observer.noise = { [weak self] in self?.finishNonwordOutcome(record, kind: .noiseDiscarded) }
        observer.cancelled = { [weak self] in self?.finishNonwordOutcome(record, kind: .staleLease, notice: false) }
        observer.failed = { [weak self] in self?.finishNonwordOutcome(record, kind: .quarantined) }
        return observer
    }
    private func observeAutomaticInterim(_ text: String) {
        guard let record = utteranceOutcome, !record.resolved, !halfDuplex else { return }
        let action = record.policy.interim(text, playbackActive: speaker.playing)
        applyAutomaticCutIn(action, record: record)
    }
    private func observeAutomaticVoice(_ milliseconds: Double) {
        guard let record = utteranceOutcome, !record.resolved, !halfDuplex else { return }
        let action = record.policy.voiced(milliseconds, playbackActive: speaker.playing)
        applyAutomaticCutIn(action, record: record)
    }
    private func applyAutomaticCutIn(_ action: AutomaticCutInDecision.Action, record: UtteranceOutcomeRecord) {
        switch action {
        case .none: break
        case .duck: speaker.duckForAutomaticCutIn(true)
        case .commit:
            record.cutStopped = speaker.commitAutomaticCutIn() || record.cutStopped
            log("automatic cut-in committed; awaiting final")
        case .restoreDucked: speaker.restoreAutomaticCutIn(ducked: true)
        }
    }
    private func observeUtteranceFinal(_ text: String, eligible: Bool, record: UtteranceOutcomeRecord) -> Bool {
        record.finalMetadata(text)
        guard utteranceOutcome === record, !record.resolved, status.running, eligible else {
            record.record(.staleLease)
            return false
        }
        record.resolved = true
        let decision = record.explicitSend && !record.empty ? AutomaticCutInDecision.Final.realSpeech : record.policy.final(text)
        switch decision {
        case .empty:
            record.record(.emptyDiscarded)
            speaker.restoreAutomaticCutIn()
            if record.cutStopped { showDidntCatchThat() }
            return false
        case .backchannel:
            record.record(.backchannel)
            speaker.restoreAutomaticCutIn()
            return false
        case .realSpeech:
            guard utteranceLease != nil, utteranceLease == currentLease else { record.record(.staleLease); return false }
            if !halfDuplex && (record.policy.beganDuringPlayback || record.policy.committed) {
                record.cutStopped = speaker.playing || record.cutStopped
                silencePlayback(reason: "barge-in")
                if voice.bargeInAborts {
                    let target = currentLease, owner = ownerEpoch, run = runEpoch
                    Task { [weak self] in
                        guard let self, self.currentLease == target, self.ownerEpoch == owner, self.runEpoch == run else { return }
                        await self.stopReply()
                    }
                }
            } else { speaker.duckForAutomaticCutIn(false) }
            if let previous = heldOutcome, !composer.held.isEmpty, previous !== record {
                previous.record(.mergedIntoNext, mergedInto: record.ordinal)
            }
            heldOutcome = record
            return true
        }
    }
    private func finishNonwordOutcome(_ record: UtteranceOutcomeRecord, kind: UtteranceOutcomeKind, notice: Bool = true) {
        guard utteranceOutcome === record, !record.resolved else { return }
        record.resolved = true; record.record(kind)
        speaker.restoreAutomaticCutIn()
        if notice && record.cutStopped { showDidntCatchThat() }
    }
    private func finishUtteranceOutcomeIdle() {
        if let record = utteranceOutcome, !record.resolved { finishNonwordOutcome(record, kind: .staleLease, notice: false) }
        utteranceOutcome = nil
    }
    /// The ONLY empty-cut-in cue: local status + accessibility, never a post/caption.
    private func showDidntCatchThat() {
        privateNoticeGeneration += 1
        let generation = privateNoticeGeneration, run = runEpoch
        status.notice = PrivateVoiceNotice.didntCatchThat.rawValue
        onPrivateNotice?(.didntCatchThat)
        privateNoticeTask?.cancel()
        privateNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.privateNoticeGeneration == generation, self.runEpoch == run,
                  self.status.notice == PrivateVoiceNotice.didntCatchThat.rawValue else { return }
            self.status.notice = nil
        }
    }
    private func discardUtteranceOutcomes() {
        speaker.restoreAutomaticCutIn()
        utteranceOutcome?.record(.discardedByUser); utteranceOutcome?.resolved = true
        heldOutcome?.record(.discardedByUser)
        for record in deferredOutcomes.values { record.record(.discardedByUser) }
        utteranceOutcome = nil; heldOutcome = nil; deferredOutcomes = [:]
    }
    private func retireUtteranceOutcomeOwnership(preservingNarration: Bool = false) {
        bargeArmed = false
        let committed = utteranceOutcome?.policy.committed == true
        utteranceOutcome?.record(.staleLease); utteranceOutcome?.resolved = true
        heldOutcome?.record(.quarantined)
        for record in deferredOutcomes.values { record.record(.staleLease) }
        utteranceOutcome = nil; heldOutcome = nil
        if committed && !preservingNarration { speaker.stop() }
        else { speaker.cancelAutomaticCutIn() }
    }

    private func fail(_ message: String) {
        log("error: \(message)")
        status.lastError = message
    }

    /// The user-facing message for a failed speech (TTS) request: the plain wording when the service cannot be
    /// reached, a message that already names it, or the given prefix for anything else (an audio device failure).
    private func speechMessage(_ error: Error, fallbackPrefix: String) -> String {
        if let e = error as? ClientError, SpeechServiceError.isFinal(e.message) { return e.message }
        if SpeechServiceError.isUnreachable(error) { return SpeechServiceError.notRunning(voice.ttsUrl) }
        return "\(fallbackPrefix): \(error.localizedDescription)"
    }

    /// The user-facing message for a failed recognition request. Held words are kept: the error is shown, not silently
    /// dropped, and the next utterance tries the service again.
    private func recognitionMessage(_ error: Error) -> String {
        SpeechServiceError.describe(url: voice.asrUrl, error: error)
    }

    /// A later request to the speech service succeeded: clear the error so the pill stops showing it.
    private func clearSpeechServiceError() {
        if status.lastError?.hasPrefix("Speech service at ") == true {
            log("speech service reachable again; clearing the error")
            status.lastError = nil
        }
    }

    /// Message a failed voice-list request in Settings (the app calls this): the pill shows it. A later success clears
    /// it via `speechServiceReached()`.
    public func speechServiceFailed(_ error: Error) {
        fail(speechMessage(error, fallbackPrefix: "Voices"))
    }

    /// A later request to the speech service succeeded: clear a stale service error from the pill.
    public func speechServiceReached() { clearSpeechServiceError() }

    // MARK: Target

    /// The most recent session titled "Chief of staff", used when there is no chief file (found when voice starts).
    public private(set) var fallbackChief: String?

    /// The session to follow, in this order: an explicit session id (the target setting); chief.json's `session`;
    /// the most recent session titled "Chief of staff".
    public func resolveTarget() -> String? {
        guard app.followsChief else { return app.target }
        return ChiefFile.session(at: chiefFile) ?? fallbackChief
    }

    /// Where "the chief" comes from now, for Settings.
    public var chiefSource: String {
        if ChiefFile.session(at: chiefFile) != nil { return "chief.json" }
        return fallbackChief != nil ? "latest \"\(ChiefDiscovery.title)\" session" : "none found"
    }

    /// With no chief file, look up the most recent "Chief of staff" session on the server.
    public func discoverFallbackChief() async {
        guard app.followsChief, ChiefFile.session(at: chiefFile) == nil else { return }
        do {
            _ = try await backend.connect()
            let found = ChiefDiscovery.pick(from: try await backend.listSessions())
            if found != fallbackChief { log("no chief file (\(chiefFile)); most recent \"\(ChiefDiscovery.title)\" session: \(found ?? "none")") }
            fallbackChief = found
        } catch { log("looking for a \"\(ChiefDiscovery.title)\" session failed: \(error.localizedDescription)") }
    }

    /// An utterance is open or waiting for its final text (for the harness).
    public var utteranceInProgress: Bool { turnTaker?.inUtterance ?? false }

    /// The room's noise floor now (for tests and logs).
    public var noiseFloorForLog: Double { turnTaker?.noiseFloor ?? 0 }

    /// The server's sessions, most recently updated first, for the Settings picker.
    public func sessionChoices(limit: Int = 40) async -> [SessionSummary] {
        _ = try? await backend.connect()
        let list = (try? await backend.listSessions()) ?? []
        return Array(list.sorted { $0.updated > $1.updated }.prefix(limit))
    }

    private func setTarget(_ id: String?, reason: String) {
        guard id != status.target else { return }
        if status.target != nil {
            retireUtteranceOutcomeOwnership()
            if turnTaker?.inUtterance == true, let text = turnTaker?.knownRecognitionText, !text.isEmpty { draftsForReview.append(text) }
            input?.discardPendingAudio()
            turnTaker?.discard() // A retired target must never open its standby socket.
            ownerEpoch += 1
            if let text = composer.discard(reason: "target changed; review only") { draftsForReview.append(text) }
            composer.reset()
            silencePlayback(reason: "target changed")
        }
        if let lease = voiceLease, lease.target != id {
            voiceLease = nil; voiceLeaseArmed = false; voiceGeneration += 1
        }
        inboundRevision += 1 // invalidate pending presentation lookups even for A -> B -> A
        // Manual mode keeps holding for Send (which then goes to the new target).
        if status.target != nil && !composer.manual { composer.flushNow(reason: "target changed") }
        log("target \(status.target ?? "none") -> \(id ?? "none") (\(reason))")
        status.target = id
        status.targetTitle = nil
        blocks = [:]
        status.busy = false
        if let id {
            Task { [weak self] in
                let title = await self?.backend.sessionTitle(id)
                guard let self, self.status.target == id else { return }
                self.status.targetTitle = title
                self.log("target \(id) title: \(title ?? "(none)")")
            }
        }
        if id != nil, status.connection == "connected" { Task { await resync(reason: "target changed") } }
    }

    private func resync(reason: String) async {
        guard let target = status.target else { return }
        do {
            let active = try await backend.activeSessions()
            guard target == status.target else { return }
            let busy = active.contains(target)
            log("resync (\(reason)): \(target) busy=\(busy)")
            status.busy = busy
        } catch { fail("Could not read session state: \(error.localizedDescription)") }
    }

    // MARK: Voice on/off

    public func start() async { await start(preservingLogicalSession: false) }

    private func start(preservingLogicalSession: Bool) async {
        guard !status.running else { return }
        if !preservingLogicalSession { voiceGeneration += 1; voiceLease = nil; voiceLeaseArmed = true }
        status.lastError = nil
        status.notice = nil
        if let micCheck {
            let holders = micCheck.otherCapturers().filter(\.isAgentVoice)
            if !holders.isEmpty {
                log("mic: agent-voice is capturing (pid \(holders.map { String($0.pid) }.joined(separator: ","))); not starting")
                status.lastError = ConversationController.agentVoiceBusyMessage
                voiceLease = nil; voiceLeaseArmed = false
                return
            }
        }
        runEpoch += 1
        let epoch = runEpoch
        status.running = true
        status.manualSend = app.sendMode == .manual
        // keepHeld restarts must expose the retained thought throughout startup, not just in apply's tail.
        if !composer.held.isEmpty { status.holding = composer.held }
        refreshPendingSpeech()
        status.phase = "starting"
        status.connection = "connecting"
        setTarget(resolveTarget(), reason: "start")
        log("voice start: target setting=\(app.target) chiefFile=\(chiefFile) busyDelivery=\(app.busyDelivery.rawValue) voice=\(voice.voice)")
        connectionTask = Task { [weak self] in await self?.connectionLoop(epoch: epoch) }
        pollTask = Task { [weak self] in await self?.pollLoop(epoch: epoch) }
        // Live words: ask for `?partials=1` only when the recognition server advertises them (checked alongside
        // the self-check; applied before the mic goes live).
        partialsFlag.on = false
        let partialsTask: Task<Bool, Never>? = partialsProbe.flatMap { probe in app.livePartials ? Task { await probe() } : nil }
        // Self-check (speech and recognition servers) runs while the microphone warms up.
        let checks = preflight
        let log = self.log
        let preflightTask = Task { () -> String? in
            for check in checks {
                if Task.isCancelled { return nil }
                do { try await check.run(); log("self-check ok: \(check.name)") }
                catch { return error.localizedDescription }
            }
            return nil
        }
        self.preflightTask = preflightTask
        guard let input else {
            let failure = await preflightTask.value
            guard runEpoch == epoch, status.running else { return }
            if let failure { fail(failure); stop(); return }
            await applyPartials(partialsTask, epoch: epoch)
            guard runEpoch == epoch, status.running else { return }
            status.phase = "ready"
            activateVoiceLease()
            return
        }
        var callbacks = TurnCallbacks()
        callbacks.muted = { [weak self] in guard let self else { return true }; return self.halfDuplex && self.speaker.playing }
        callbacks.start = { [weak self] in self?.onset(); self?.beginUtteranceOutcome(); self?.onCaption?(.youStarted); self?.composer.speechStarted() }
        callbacks.outcomeObserver = { [weak self] in self?.makeUtteranceOutcomeObserver() ?? TurnOutcomeObserver() }
        callbacks.voicedProgress = { [weak self] ms in self?.observeAutomaticVoice(ms) }
        callbacks.speaking = { [weak self] in self?.onCaption?(.youSpeaking); self?.bargeIn(trigger: "sustained speech") }
        callbacks.partial = { [weak self] text in
            self?.observeAutomaticInterim(text)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { self?.bargeIn(trigger: "partial transcript") }
        }
        callbacks.live = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.clearSpeechServiceError()
            self.onCaption?(.youLive(text))
            self.observeAutomaticInterim(text)
            self.bargeIn(trigger: "live words")
        }
        callbacks.transcript = { [weak self] text in
            guard let self else { return }
            self.clearSpeechServiceError()
            self.log("heard: \(text)")
            self.onCaption?(.youFinal(text))
            self.composer.utterance(text)
        }
        callbacks.silence = { [weak self] elapsed in
            guard let self, self.app.sendMode == .auto else { return }
            self.onCaption?(elapsed.map { .countdown(totalMs: self.voice.pauseMs, elapsedMs: $0, hold: false) } ?? .countdownCancelled)
        }
        callbacks.noisy = { [weak self] on in
            self?.log(on ? "noise: sound with no gap (10 s) or no words (5 s) inside an utterance; the room may be too loud for the pause to be heard" : "noise: over")
            self?.onCaption?(.noisy(on))
        }
        callbacks.idle = { [weak self] in
            self?.bargeArmed = false; self?.status.hearing = false
            self?.onCaption?(.youIdle)
            self?.composer.speechIdle()
            self?.utteranceLease = nil
            self?.finishUtteranceOutcomeIdle()
            self?.refreshPendingSpeech()
        }
        callbacks.error = { [weak self] error in
            guard let self else { return }
            self.fail(self.recognitionMessage(error))
        }
        callbacks.review = { [weak self] text in
            guard let self, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.draftsForReview.append(text)
            self.status.notice = "Recognition interrupted · known words retained locally for review, not sent."
        }
        callbacks.ended = { [weak self] length, voiced in
            guard let self else { return }
            self.log(String(format: "utterance ended after %.0f ms of silence: %.1f s long, %.1f s voiced", self.voice.pauseMs, length / 1000, voiced / 1000))
        }
        turnTaker = TurnTaker(config: voice, callbacks: callbacks, makeRecognition: makeRecognition)
        input.onPCM = { [weak self] pcm in
            guard let self, self.acceptInput, !self.status.micMuted else { return }
            let ignore = self.halfDuplex && self.speaker.playing
            self.micStats.add(pcm, threshold: self.turnTaker?.threshold ?? self.voice.threshold, playing: self.speaker.playing, ignored: ignore)
            if ignore { return }
            if let onCaption = self.onCaption { onCaption(.micLevel(TurnTaker.rms(pcm))) }
            self.turnTaker?.push(pcm)
        }
        input.onFailure = { [weak self] error in
            guard let self, self.runEpoch == epoch else { return }
            self.fail("Microphone: \(error.localizedDescription)")
            self.stop()
        }
        do {
            try await input.start()
            log("self-check ok: microphone open and sending audio")
        } catch {
            preflightTask.cancel()
            guard runEpoch == epoch else { return }
            fail("Microphone: \(error.localizedDescription)")
            stop()
            return
        }
        if let failure = await preflightTask.value {
            guard runEpoch == epoch else { return }
            fail(failure)
            stop()
            return
        }
        guard runEpoch == epoch, status.running else { return }
        await applyPartials(partialsTask, epoch: epoch)
        guard runEpoch == epoch, status.running else { return }
        halfDuplex = !voice.duplex || !input.duplexSafe
        if halfDuplex { log("half duplex: \(voice.duplex ? "echo cancellation is off and the output is not headphones" : "duplex is off in settings"); no listening or barge-in while speaking") }
        else { log("full duplex: listening and barge-in stay on while speaking (echo cancellation \(voice.echoCancellation); the mic does not hear the output: echo cancellation or headphones)") }
        micStats = MicStats()
        liveAt = now()
        acceptInput = true
        status.phase = "ready"
        activateVoiceLease()
        log("ready: mic live")
    }

    private func activateVoiceLease() {
        guard voiceLeaseArmed, voiceLease == nil, let target = status.target else { return }
        voiceLease = (voiceGeneration, target)
    }

    /// Only Stop voice and Quit call this. Microphone release is synchronous; admission follows prior posts.
    public func endVoice() {
        let lease = voiceLease
        voiceLease = nil // consume before any suspension, including duplicate Stop/Quit callbacks
        stop()
        guard let lease else { return }
        let words = pendingPosts
        let task = Task { [self] in
            for word in words { await word.value }
            guard !Task.isCancelled, voiceGeneration == lease.generation, resolveTarget() == lease.target else {
                log("voice end suppressed: stale lease")
                return
            }
            pendingReceiptCount += 1
            defer { receiptFinished() }
            do {
                if let id = try await backend.admitVoiceEnd(sessionID: lease.target) {
                    localInboundIDs.insert(lease.target + ":" + id)
                }
                log("voice end admitted -> \(lease.target): \(VoiceEnd.text)")
            } catch {
                log("voice end admission failed (not retried): \(error.localizedDescription)")
            }
        }
        pendingPosts.append(task)
        Task { await task.value; self.pendingPosts.removeAll { $0 == task } }
    }

    /// OS termination still releases audio and flushes/discards words, but carries no deliberate end note.
    public func stopForTermination(deliberateQuit: Bool) {
        if deliberateQuit { endVoice() } else { stop() }
    }

    /// The app's termination seam. Budget expiry retires unsent work and cancels in-flight requests; it cannot
    /// retract an admission the server may already have accepted, so cancellation never leads to a retry.
    public func shutdown(deliberateQuit: Bool, timeout: Double = 2) async -> Bool {
        stopForTermination(deliberateQuit: deliberateQuit)
        let tasks = pendingPosts
        let generation = voiceGeneration, epoch = runEpoch
        let done = await waitForPosts(timeout: min(2, max(0, timeout)))
        if !done {
            // Retire only this shutdown's work, never a newer Start or its pending posts/lease/mutes.
            if voiceGeneration == generation, runEpoch == epoch {
                voiceGeneration += 1; voiceLease = nil; voiceLeaseArmed = false
                speechEpoch += 1; deferredPosts.removeAll()
                refreshPendingSpeech()
            }
            for task in tasks { task.cancel() }
            log("quit post budget expired: retired unsent work; cancelled pending requests (no retry)")
        }
        return done
    }

    private func applyPartials(_ task: Task<Bool, Never>?, epoch: Int) async {
        guard let task else { log("recognition: live words off\(app.livePartials ? "" : " (livePartials is false)")"); return }
        let on = await task.value
        guard runEpoch == epoch else { return }
        partialsFlag.on = on
        turnTaker?.expectLiveWords = on
        log("recognition: live words \(on ? "on (?partials=1)" : "off (the server does not advertise them)")")
    }

    /// Stop voice: release the microphone, stop speech, disconnect. Held words are posted (auto send), or dropped and
    /// logged (manual send: only Send sends). `keepHeld` keeps them held across a restart (device or echo change).
    public func stop(notice: String? = nil, keepHeld: Bool = false) {
        if !keepHeld { voiceLease = nil; voiceLeaseArmed = false }
        guard status.running else { return }
        if keepHeld && composer.manual {
            if !composer.held.isEmpty { log("restart: still holding for Send: \(composer.held)") }
        } else if composer.manual {
            if let text = composer.discard(reason: "voice stopped") { onCaption?(.discarded(text)) }
        } else {
            composer.flushNow(reason: "voice stopped")
            composer.reset()
        }
        if !(keepHeld && composer.manual) { heldOutcome?.record(.discardedByUser); heldOutcome = nil }
        utteranceOutcome?.turnEndReason = .stop
        utteranceOutcome?.record(.discardedByUser); utteranceOutcome?.resolved = true; utteranceOutcome = nil
        speaker.cancelAutomaticCutIn()
        runEpoch += 1
        preflightTask?.cancel(); preflightTask = nil
        speechWarmup.reset()
        acceptInput = false
        bargeArmed = false
        connectionTask?.cancel(); connectionTask = nil
        streamTask?.cancel(); streamTask = nil
        pollTask?.cancel(); pollTask = nil
        turnTaker?.stop(); turnTaker = nil
        input?.onPCM = nil
        input?.stop()
        speaker.stop()
        previewTicket?.cancel(); previewTicket = nil
        blocks = [:]
        status = Status(lastError: status.lastError, notice: notice)
        refreshPendingSpeech()
        log("voice stop\(notice.map { ": \($0)" } ?? "")")
    }

    public func setMicMuted(_ on: Bool) {
        status.micMuted = on
        if on {
            // No new audio is taken from here on (the capture callback checks micMuted). Words already in motion are
            // not thrown away: the utterance in progress ends now and its final text is waited for (8 s at most).
            let inProgress = turnTaker?.inUtterance ?? false
            if inProgress { turnTaker?.endNow(reason: .muteSend) }
            if app.sendMode == .auto {
                // Merged with what is held or counting down and sent at once: a normal message when the chief is idle,
                // the queue (or steer) delivery when it is busy, without the 3 s quiet (no more speech is coming).
                composer.send(utteranceInProgress: inProgress, reason: "mic muted")
            } else if inProgress || !composer.held.isEmpty {
                // Manual mode never sends without Send: the final text goes into Holding.
                log("mic muted: manual send; \(inProgress ? "the utterance in progress ends and its words are held for Send" : "held words stay held for Send")")
            }
        }
        log("mic muted=\(on)")
    }

    /// Mute agent voice: stop playback now and drop speech until unmuted.
    public func setOutputMuted(_ on: Bool) {
        status.outputMuted = on
        if on { silencePlayback(reason: "agent voice muted") }
        log("agent voice muted=\(on)")
    }

    public func setBusyDelivery(_ d: BusyDelivery) { app.busyDelivery = d; log("busyDelivery=\(d.rawValue)") }

    /// Wait (up to `timeout` seconds) for posts in flight to finish, e.g. before the app quits. True if all finished.
    public func waitForPosts(timeout: Double) async -> Bool {
        let tasks = pendingPosts
        guard !tasks.isEmpty else { return true }
        log("waiting for \(tasks.count) post(s) to finish")
        final class Once { var c: CheckedContinuation<Bool, Never>?; func resume(_ v: Bool) { c?.resume(returning: v); c = nil } }
        let once = Once()
        let done = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            once.c = c
            Task { @MainActor in for t in tasks { await t.value }; once.resume(true) }
            Task { @MainActor in try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); once.resume(false) }
        }
        log(done ? "posts finished" : "posts did not finish within \(timeout) s")
        return done
    }

    /// Send (manual mode's button or hotkey): post the held words now. Mid-utterance, the utterance ends at once and
    /// its words go with them. In auto mode it posts anything held without waiting for the pause timers.
    public func send() {
        utteranceOutcome?.explicitSend = true
        let inProgress = turnTaker?.inUtterance ?? false
        log("send pressed\(inProgress ? " mid-utterance" : "")")
        if inProgress { turnTaker?.endNow() }
        composer.send(utteranceInProgress: inProgress)
    }

    private func refreshPendingSpeech() {
        status.pendingSpeech = status.hearing || !composer.held.isEmpty || !deferredPosts.isEmpty
    }

    /// Atomic on the main actor: only unsent speech is abandoned. Issued backend requests, the agent's
    /// turn, playback, connection and mute/off state are deliberately untouched.
    public func discardPending() {
        guard status.pendingSpeech || utteranceInProgress || !composer.held.isEmpty || !deferredPosts.isEmpty else { return }
        log("discard stage=unsent droppedCapture=\(utteranceInProgress && turnTaker?.awaitingFinal != true) droppedFinal=\(turnTaker?.awaitingFinal == true) droppedColdPCM=\(turnTaker?.hasBufferedRecognitionAudio == true) droppedHeld=\(!composer.held.isEmpty) droppedCountdown=\(composer.hasWait) droppedSendAfterFinal=\(composer.pendingSendAfterFinal) droppedDeferredPosts=\(deferredPosts.count) micMuted=\(status.micMuted)")
        speechEpoch += 1
        deferredPosts.removeAll()
        // Reset send-after-final BEFORE cancelling ASR (cancel may synchronously report idle/done).
        composer.reset()
        input?.discardPendingAudio()
        turnTaker?.discard()
        bargeArmed = false
        status.hearing = false
        refreshPendingSpeech()
        onCaption?(.countdownCancelled)
        onCaption?(.discarded(""))
        log("discarded unsent speech; issued requests and playback unchanged")
    }

    /// Auto (send after a pause) or manual (send only on Send). Switching to auto posts what is held.
    public func setSendMode(_ m: SendMode) {
        guard m != app.sendMode else { return }
        app.sendMode = m
        status.manualSend = m == .manual && status.running
        log("sendMode=\(m.rawValue)")
        composer.sendModeChanged()
    }

    /// Clear the error shown in the window.
    public func clearError() { status.lastError = nil }
    public func reportShortcutError(_ message: String) { fail(message) }

    /// Use these voice settings from now on: the next sentence uses the new voice, the next utterance the new pause
    /// length. Devices and echo cancellation apply when the audio engine next starts (see apply(_:)).
    public func setVoiceConfig(_ v: VoiceConfig) {
        voice = v
        turnTaker?.config = v
    }

    /// Follow "chief" or an explicit session id from now on (switches at once while voice is on).
    public func setTargetSetting(_ t: String) {
        if app.target != (t.isEmpty ? "chief" : t) {
            voiceGeneration += 1; voiceLease = nil; voiceLeaseArmed = false
            if !status.running {
                ownerEpoch += 1
                retireUtteranceOutcomeOwnership()
                if let text = composer.discard(reason: "target changed while off; review only") { draftsForReview.append(text) }
                composer.reset(); refreshPendingSpeech()
            }
        }
        app.target = t.isEmpty ? "chief" : t
        log("target setting=\(app.target)")
        guard status.running else { return }
        if resolveTarget() == nil && app.followsChief {
            Task { [weak self] in
                await self?.discoverFallbackChief()
                guard let self, self.app.followsChief else { return }
                self.setTarget(self.resolveTarget(), reason: "target setting changed")
            }
            return
        }
        setTarget(resolveTarget(), reason: "target setting changed")
    }

    /// A change from the settings menu: write it to the app's own settings file (never agent-voice's), then apply
    /// it now. Device and echo changes restart voice if it is on, so the engine reopens with them.
    public func apply(_ change: SettingChange) async throws {
        if case .sendHotkey(let h) = change, Hotkey.parse(h) == nil { throw ClientError("Not a hotkey: \(h) (use e.g. ctrl+option+space)") }
        if case .sensitivity(let level) = change, Sensitivity(rawValue: level) == nil { throw ClientError("Sensitivity is low, normal or high") }
        if let warning = try SettingsStore.saveAppSetting([change.key: change.value], appFile: appFile, voiceFile: voiceFile) {
            fail(warning)
        }
        log("setting \(change.key)=\(change.value) saved to \(appFile)")
        var v = voice
        switch change {
        case .voice(let name): v.voice = name
        case .inputDevice(let uid): v.inputDevice = uid
        case .outputDevice(let uid): v.outputDevice = uid
        case .echoCancellation(let e): v.echoCancellation = VoiceConfig.echoSetting(e)
        case .pauseMs(let ms): v.pauseMs = ms
        case .busyDelivery(let d): setBusyDelivery(d)
        case .target(let t): setTargetSetting(t)
        case .sendMode(let m): setSendMode(m)
        case .sendHotkey(let h): app.sendHotkey = h
        case .sensitivity(let level): v.sensitivity = level
        }
        setVoiceConfig(v)
        if change.needsAudioRestart && status.running {
            log("restarting voice to apply \(change.key)")
            let mic = status.micMuted, out = status.outputMuted
            let lease = voiceLease
            let generation = voiceGeneration
            stop(keepHeld: true)
            // Restore before startup suspends or capture becomes live, independent of end-note ownership.
            status.micMuted = mic; status.outputMuted = out
            let restartEpoch = runEpoch + 1
            await start(preservingLogicalSession: true)
            // A restart is the same logical voice session, never a new lease.
            guard runEpoch == restartEpoch else { return }
            if status.running, voiceGeneration == generation { voiceLease = lease }
            // The mutes and anything held for Send survive the restart.
            if status.running {
                if mic { setMicMuted(true) }
                if out { setOutputMuted(true) }
                if !composer.held.isEmpty { status.holding = composer.held }
                refreshPendingSpeech()
            }
        }
    }

    /// The Stop control: stop playback, clear the queue and interrupt the target's turn.
    public func stopReply() async {
        silencePlayback(reason: "stop control")
        guard let target = status.target ?? resolveTarget() else { fail("No session to stop"); return }
        do {
            let interrupted = try await backend.interrupt(sessionID: target)
            log("interrupt \(target) -> interrupted=\(interrupted)")
            // Only an actual interrupt admits buffered words (execution.interrupted does the same when it arrives).
            if interrupted { composer.interrupted() }
        } catch { fail("Stop: \(error.localizedDescription)") }
    }

    /// Speak a short sample in `name` (the settings' Preview). Skipped while a reply is playing, so it never cuts
    /// the chief off or plays over it.
    public func previewVoice(_ name: String, text: String? = nil) async {
        guard !speaker.active else { log("preview skipped: a reply is playing"); return }
        var cfg = voice
        cfg.voice = name
        let sample = text ?? "Hi, this is how I sound. I'll read \(AssistantLabel.name)'s replies to you."
        let ticket = HealthCheckedSynthesizer(config: { cfg }, warmup: speechWarmup).prepare(sample)
        previewTicket = ticket
        defer { ticket.cancel(); if previewTicket === ticket { previewTicket = nil } }
        log("preview voice \(name)")
        do {
            let audio = try await ticket.audio()
            guard previewTicket === ticket else { return }
            try await output.play(audio, label: "preview") {}
        } catch {
            if previewTicket === ticket, !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                fail(speechMessage(error, fallbackPrefix: "Preview"))
            }
        }
    }

    /// Stop what is playing and silence text already received, without touching the agent's turn.
    private func silencePlayback(reason: String) {
        speaker.cancelAutomaticCutIn()
        previewTicket?.cancel(); previewTicket = nil
        let wasActive = speaker.active
        speaker.stop()
        for b in blocks.values { b.skipToEnd() }
        log("playback silenced (\(reason))\(wasActive ? "" : " — nothing was playing")")
    }

    // MARK: Barge-in

    private func onset() {
        bargeArmed = now() - liveAt >= voice.onsetGraceMs
        status.hearing = true
        refreshPendingSpeech()
        log("speech onset\(bargeArmed ? "" : " (within onset grace; no barge-in)")")
    }

    private func bargeIn(trigger: String) {
        if utteranceOutcome != nil { return } // Shared automatic decision owns this utterance.
        guard bargeArmed, !halfDuplex else { return }
        bargeArmed = false
        log("barge-in (\(trigger))")
        silencePlayback(reason: "barge-in")
        if voice.bargeInAborts { Task { await stopReply() } }
    }

    // MARK: Sending

    private var localInboundIDs = Set<String>()
    private var seenInboundIDs = Set<String>()
    private var pendingReceiptCount = 0
    private var pendingInbound: [ServerEvent] = []
    private var senderTitles: [String: String] = [:]
    private var titleReads = Set<String>()
    private var inboundRevision = 0

    func post(_ text: String, kind: PostKind, reason: String, to target: String, outcome: UtteranceOutcomeRecord? = nil) async {
        pendingReceiptCount += 1
        defer { receiptFinished() }
        func send(_ delivery: BusyDelivery?, admit: Bool = false) async throws {
            if let id = try await backend.postWithReceipt(sessionID: target, text: VoicePost.transportText(text), delivery: delivery, admit: admit) {
                localInboundIDs.insert(target + ":" + id)
            }
        }
        do {
            switch kind {
            case .normal:
                log("post -> \(target) delivery=none (\(reason)): \(text)")
                if target == status.target { status.busy = true } // a prompt to an idle session starts a turn
                try await send(nil)
            case .delivery(let d):
                log("post -> \(target) delivery=\(d.rawValue) (\(reason)): \(text)")
                try await send(d)
            case .admitOnly:
                log("post -> \(target) admit without starting a turn (\(reason)): \(text)")
                do { try await send(nil, admit: true) }
                catch {
                    guard !Task.isCancelled else { throw error }
                    log("admit failed (\(error.localizedDescription)); posting as a normal message instead")
                    try await send(nil)
                }
            }
            outcome?.record(.posted, mode: UtteranceDeliveryMode(kind))
        } catch {
            outcome?.record(.postFailed, mode: UtteranceDeliveryMode(kind))
            guard !Task.isCancelled else { log("post cancelled during shutdown (not retried)"); return }
            fail("Voice instruction was not sent: \(error.localizedDescription) — \"\(text)\"")
            await resync(reason: "send failed")
        }
    }

    private func receiptFinished() {
        pendingReceiptCount -= 1
        if pendingReceiptCount == 0 {
            let pending = pendingInbound; pendingInbound = []
            for event in pending { handle(event) }
        }
    }

    // MARK: Events

    private func connectionLoop(epoch: Int) async {
        while runEpoch == epoch && !Task.isCancelled {
            if app.followsChief && ChiefFile.session(at: chiefFile) == nil { await discoverFallbackChief() }
            guard runEpoch == epoch else { return }
            if let target = resolveTarget() { setTarget(target, reason: "connect") }
            guard status.target != nil else {
                fail(app.followsChief ? "No chief session: \(chiefFile) is missing and no session is titled \"\(ChiefDiscovery.title)\". Pick a session in Settings."
                                       : "No target session set")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            do {
                let desc = try await backend.connect()
                guard runEpoch == epoch else { return }
                log("connected \(desc)")
                let stream = backend.events()
                let task = Task { [weak self] in
                    var synced = false
                    do {
                        for try await event in stream {
                            guard let self, self.runEpoch == epoch else { return }
                            if !synced {
                                synced = true
                                self.status.connection = "connected"
                                if self.status.lastError?.hasPrefix("Connection") == true { self.status.lastError = nil }
                                await self.resync(reason: "connected")
                            }
                            self.handle(event)
                        }
                        self?.log("event stream ended")
                    } catch {
                        if !(error is CancellationError) { self?.log("event stream error: \(error.localizedDescription)") }
                    }
                }
                streamTask = task
                await task.value
            } catch {
                if runEpoch == epoch { fail("Connection: \(error.localizedDescription)") }
            }
            guard runEpoch == epoch else { return }
            status.connection = "reconnecting"
            let delay = holdOff ?? reconnectDelay
            holdOff = nil
            log("reconnecting in \(delay)s")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Re-read chief.json every few seconds (switch when it changes), and watch for agent-voice taking the mic.
    private func pollLoop(epoch: Int) async {
        var lastChief = now(), lastMic = now(), lastLevel = now()
        while runEpoch == epoch && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard runEpoch == epoch else { return }
            if now() - lastLevel >= 1000 {
                lastLevel = now()
                if acceptInput && !status.micMuted {
                    log(micStats.line(threshold: turnTaker?.threshold ?? voice.threshold, floor: turnTaker?.noiseFloor,
                                      sensitivity: voice.sensitivity))
                }
                micStats = MicStats()
            }
            if app.followsChief && now() - lastChief >= chiefPollInterval * 1000 {
                lastChief = now()
                if let id = ChiefFile.session(at: chiefFile), id != status.target { setTarget(id, reason: "chief.json changed") }
            }
            if let micCheck, now() - lastMic >= micPollInterval * 1000 {
                lastMic = now()
                let holders = micCheck.otherCapturers().filter(\.isAgentVoice)
                if !holders.isEmpty {
                    log("mic: agent-voice started capturing (pid \(holders.map { String($0.pid) }.joined(separator: ","))); pausing")
                    stop(notice: ConversationController.agentVoiceTookMicMessage)
                    status.lastError = ConversationController.agentVoiceTookMicMessage
                    return
                }
            }
        }
    }

    /// Test hook: drop the event stream and wait `holdOff` seconds before reconnecting.
    public func dropConnection(holdOff: TimeInterval) {
        log("debug: dropping event stream for \(holdOff)s")
        self.holdOff = holdOff
        streamTask?.cancel()
    }

    /// One event from the shared stream. Only the target's text and execution events matter; reasoning, tools,
    /// inbox items (which include messages from other sessions) and everything else never touch playback.
    public func handle(_ event: ServerEvent) {
        guard let sid = event.sessionID, sid == status.target else { return }
        switch event.type {
        case "session.execution.started":
            status.busy = true
            log("execution.started")
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            status.busy = false
            log(event.type.replacingOccurrences(of: "session.", with: ""))
            // Only the principal interrupts a turn (leads only send messages), so an interrupt from anywhere, such as
            // OpenChamber's stop button, also stops playback. A failed turn drops unfinished text; queued speech plays.
            if event.type == "session.execution.interrupted" { silencePlayback(reason: "turn interrupted") }
            if event.type != "session.execution.succeeded" { blocks = [:] }
            if event.type == "session.execution.interrupted" { composer.interrupted() } else { composer.turnEnded() }
        case "session.text.started":
            blocks[event.blockKey] = makeSegments(event.blockKey)
            log("text.started [\(event.blockKey)]")
        case "session.text.delta":
            let seg = blocks[event.blockKey] ?? { let s = makeSegments(event.blockKey); blocks[event.blockKey] = s; return s }()
            log("text.delta [\(event.blockKey)] +\((event.delta ?? "").count) chars")
            seg.push(event.delta ?? "")
        case "session.text.ended":
            let seg = blocks[event.blockKey] ?? makeSegments(event.blockKey)
            if let text = event.text, text != seg.raw {
                log("text.ended [\(event.blockKey)] repaired \(seg.raw.count) -> \(text.count) chars")
                seg.update(text)
            } else { log("text.ended [\(event.blockKey)] \(seg.raw.count) chars") }
            seg.flush(final: true)
            blocks[event.blockKey] = nil
        case "session.inbox.enqueued":
            let item = event.data["item"] as? [String: Any]
            log("inbox.enqueued delivery=\(item?["delivery"] as? String ?? "?") (playback untouched)")
            if pendingReceiptCount > 0 { pendingInbound.append(event); return }
            guard let item, let caption = InboundCaption(item) else { return }
            let key = ((event.data["inboxID"] as? String) ?? caption.id).map { sid + ":" + $0 }
            if let key {
                guard seenInboundIDs.insert(key).inserted else { return }
                // Ordinary dictation was displayed locally. Exact end-note presentation is the frozen exception.
                if localInboundIDs.contains(key), caption.text != VoiceEnd.text { return }
            }
            let local = key.map { localInboundIDs.contains($0) } ?? false
            let sender = SenderAttribution.classify(text: caption.text, metadata: caption.metadata, local: local, titles: senderTitles)
            inboundRevision += 1
            let revision = inboundRevision
            let epoch = runEpoch
            onCaption?(.inbound(sender: sender, text: caption.text))
            // Only a proven sender address, never the target or session creation provenance.
            // Local server only; remote addresses must not be resolved against our local sessions.
            if let address = sender.senderSession, titleReads.count < 200,
               titleReads.insert(address).inserted {
                Task { [weak self] in
                    guard let self, let title = await self.backend.senderSessionTitle(address) else { return }
                    self.senderTitles[address] = title
                    // Refresh only this slot, not a newer arrival or a different target.
                    guard self.status.target == sid, self.inboundRevision == revision, self.runEpoch == epoch else { return }
                    self.onCaption?(.inbound(sender: SenderAttribution.classify(text: caption.text, metadata: caption.metadata, local: local,
                                                                            titles: self.senderTitles), text: caption.text))
                }
            }
        case "session.inbox.delivered":
            log("inbox.delivered")
        default:
            if !event.type.hasSuffix(".delta") { log(event.type.replacingOccurrences(of: "session.", with: "")) }
        }
    }

    private func makeSegments(_ key: String) -> SpeechSegments {
        SpeechSegments { [weak self] sentence in
            guard let self else { return }
            self.onCaption?(.chiefQueued(label: key, text: sentence))
            if self.status.outputMuted { self.log("dropped (agent voice muted): \(sentence.prefix(60))"); return }
            self.log("queue [\(key)] \(sentence.prefix(80))")
            self.speaker.enqueue(sentence, label: key)
        }
    }
}
