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
    /// Held words were dropped (manual send mode, voice stopped without Send).
    case discarded(String)
    /// A reply sentence was received (queued for speech, or dropped while the agent voice is muted).
    case chiefQueued(label: String, text: String)
    case chiefStarted(label: String, text: String)
    case chiefEnded(label: String, text: String, outcome: String)
    /// Audio could not finish; keep the complete reply readable rather than hiding lost speech.
    case chiefUnavailable
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
    public struct SendCountdown: Equatable, Sendable {
        public let totalMs: Double
        public let deadlineMs: Double
        public let hold: Bool
        public func seconds(at unixMs: Double) -> Int { max(0, Int(ceil((deadlineMs - unixMs) / 1000))) }
    }
    public struct Status: Equatable, Sendable {
        public var halfDuplex = false
        /// Tap the chief caption/waveform to call bargeIn(), without interrupting the model.
        public var canBargeIn = false
        public var listeningSuppressed = false
        public var narrationPaused = false
        /// Render with a timeline clock; tap calls `send()`. Nil cancels the cue.
        public var sendCountdown: SendCountdown?
        public var running = false
        /// off | connecting | connected | reconnecting
        public var connection = "off"
        public var target: String?
        /// The target session's title, when the server has one.
        public var targetTitle: String?
        /// starting (self-check running) | ready
        public var phase = "starting"
        public var busy = false
        public var sending = false
        public var hearing = false
        /// Includes capture before words, recognition finalisation and locally deferred (not submitted) posts.
        public var pendingSpeech = false
        public var discardHotkeyEligible: Bool { running && pendingSpeech }
        public var canDiscard: Bool { pendingSpeech }
        public var speaking = false
        public var warmingSpeech = false
        public var micMuted = false
        public var outputMuted = false
        public var lastError: String?
        public var notice: String?
        /// Words held before sending (mid-sentence, merging while the chief is busy, or waiting for Send).
        public var holding: String?
        /// Manual send mode: words wait for the Send button or hotkey.
        public var manualSend = false

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
            if warmingSpeech { return SpeechWarmup.text }
            guard running else { return notice ?? "Voice off" }
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

    var turnTaker: TurnTaker?
    private var blocks: [String: SpeechSegments] = [:]
    private var connectionTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var acceptInput = false
    private var capturePrepared = false
    private var liveAt = 0.0
    private var bargeArmed = false
    public var onEchoActivity: ((Bool) -> Void)? // false = VAD onset; true = actual barge-in, no text
    private var holdOff: TimeInterval?
    private var micStats = MicStats()
    /// Posts in flight (awaited on quit so held words are not lost).
    private var pendingPosts: [Task<Void, Never>] = []
    /// No capture or barge-in while speaking: duplex off in settings, or the mic would hear the speakers.
    public private(set) var halfDuplex = false
    private var runEpoch = 0
    /// Held speech belongs to the session where the thought began, never the current picker value.
    public private(set) var currentLease: TargetLease?
    public private(set) var draftsForReview: [BoundDraft] = []
    public var onReviewDraft: ((BoundDraft) -> Void)?
    private var draftLease: TargetLease?
    private var draftBusy: Bool?
    private var utteranceLease: TargetLease?
    private var utteranceBusy = false
    private var resyncEpoch = 0
    // Distinct from polling/resync: a selection returning to the same lease is a new owner.
    private var ownerEpoch = 0
    private var draftEpoch = 0
    private var callPaused = false
    private var submissionEpoch = 0
    private var speechEpoch = 0
    private var deferredPosts: Set<UUID> = []
    private var playbackWasPlaying = false
    private var lastPlaybackEndedAt = -Double.infinity
    private var playbackQuietUntil = 0.0
    public static let manualBargeQuietMs = 300.0
    private var wasCaptureSuppressed = false
    private var playbackInputLevel: Double?
    private var measuredOutputLevel = 0.0
    private var measuredOutputAt = -Double.infinity
    private var tailMeasureStartedAt: Double?
    private var tailMeasureFrames = 0
    private var tailMeasureFloor = 0.0
    private var voiceProbeTask: Task<Void, Never>?
    public let speechWarmup: SpeechWarmup
    private enum SpeechService { case asr, tts }
    private var speechErrorService: SpeechService?

    public init(settings: LoadedSettings, backend: SessionBackend, synth: SpeechSynthesizer, output: AudioOutput, input: AudioInput?,
                makeRecognition: ((RecognitionCallbacks) -> RecognitionSession)? = nil, micCheck: MicHolderCheck? = nil,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
                chiefPollInterval: TimeInterval = 2, micPollInterval: TimeInterval = 1, reconnectDelay: TimeInterval = 1,
                preflight: [PreflightCheck] = [], partialsProbe: (() async -> Bool)? = nil,
                speechWarmup: SpeechWarmup = SpeechWarmup(), log: @escaping (String) -> Void = { _ in }) {
        self.speechWarmup = speechWarmup
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
        if settings.appFileUnreadable {
            status.lastError = "\((settings.appFile as NSString).lastPathComponent) is unreadable, so its settings are not used. The next settings change saves a copy as .bad and writes a new one."
        }
        let flag = Flag()
        partialsFlag = flag
        let cfg = settings.voice
        let warmup = speechWarmup
        self.makeRecognition = makeRecognition ?? { cbs in
            HealthCheckedRecognition(endpoint: cfg.asrUrl, key: cfg.asrApiKey, callbacks: cbs, warmup: warmup) {
                WebSocketRecognition(url: cfg.asrUrl, apiKey: cfg.asrApiKey, partials: flag.on, callbacks: $0)
            }
        }
        speechWarmup.onChange = { [weak self] on in self?.setSpeechWarming(on) }
        if let levels = output as? LevelReporting {
            levels.onLevel = { [weak self] level in
                guard let self else { return }
                self.measuredOutputLevel = level; self.measuredOutputAt = self.now()
                self.onCaption?(.outputLevel(level))
            }
        }
        if let routes = input as? DuplexReporting {
            routes.onDuplexChange = { [weak self] in self?.refreshDuplexPolicy() }
        }
    }

    private func makeSpeaker() -> Speaker {
        let s = Speaker(synth: synth, output: output) { [weak self] error in
            guard let self else { return }
            self.failSpeech(error, service: .tts)
            self.onCaption?(.chiefUnavailable)
        }
        s.onChange = { [weak self] in
            guard let self else { return }
            self.status.speaking = self.speaker.active
            self.refreshDuplexPolicy()
        }
        s.onSentence = { [weak self] label, text in
            self?.clearSpeechServiceError(service: .tts)
            self?.log("speak start [\(label)] \(text.prefix(80))")
            self?.onCaption?(.chiefStarted(label: label, text: text))
        }
        s.onSentenceEnd = { [weak self] label, text, outcome in
            self?.log("speak end [\(label)] \(outcome): \(text.prefix(40))")
            self?.onCaption?(.chiefEnded(label: label, text: text, outcome: outcome))
        }
        return s
    }

    private func makeComposer() -> UtteranceComposer {
        let c = UtteranceComposer(settings: { [weak self] in self?.app ?? AppSettings() },
                                  isBusy: { [weak self] in self?.draftBusy ?? self?.status.busy ?? false },
                                  send: { [weak self] text, kind, reason in
                                      guard let self, let target = self.draftLease ?? self.currentLease else { return }
                                      self.draftLease = nil; self.draftBusy = nil
                                      self.draftEpoch += 1
                                      guard target == self.currentLease else { self.quarantine(text, target: target); return }
                                      let submission = self.submissionEpoch
                                      let epoch = self.speechEpoch, id = UUID()
                                      self.deferredPosts.insert(id)
                                      self.refreshPendingSpeech()
                                      let task = Task {
                                          guard epoch == self.speechEpoch else { return }
                                          self.deferredPosts.remove(id)
                                          guard self.submissionEpoch == submission else { self.refreshPendingSpeech(); self.quarantine(text, target: target); return }
                                          VoiceTrace.shared.event("composer.posted", ["text": text])
                                          self.onCaption?(.posted(text))
                                          self.refreshPendingSpeech()
                                          await self.post(text, kind: kind, reason: reason, to: target)
                                      }
                                      self.pendingPosts.append(task)
                                      Task { await task.value; self.pendingPosts.removeAll { $0 == task } }
                                  },
                                  log: { [weak self] in self?.log($0) },
                                  pauseMs: { [weak self] in self?.voice.pauseMs ?? 0 })
        c.onHolding = { [weak self] text in
            guard let self else { return }
            if text != nil, self.draftLease == nil, let target = self.currentLease { self.bindDraft(target, busy: self.status.busy) }
            self.status.holding = text
            self.refreshPendingSpeech()
        }
        c.onWait = { [weak self] ms in self?.countdown(total: ms, elapsed: 0, hold: true) }
        return c
    }

    private func countdown(total: Double?, elapsed: Double, hold: Bool) {
        status.sendCountdown = total.map { SendCountdown(totalMs: $0, deadlineMs: now() + $0 - elapsed, hold: hold) }
        onCaption?(total.map { .countdown(totalMs: $0, elapsedMs: elapsed, hold: hold) } ?? .countdownCancelled)
    }

    private func clearSpeechServiceError(service: SpeechService = .asr) {
        if status.lastError?.hasPrefix("Speech service at ") == true, speechErrorService == service {
            status.lastError = nil; speechErrorService = nil
        }
    }

    private func failSpeech(_ error: Error, service: SpeechService) {
        fail(SpeechServiceError.describe(url: service == .asr ? voice.asrUrl : voice.ttsUrl, error: error))
        speechErrorService = service
    }

    private func fail(_ message: String) {
        speechErrorService = nil
        log("error: \(message)")
        status.lastError = message
    }

    private func quarantine(_ text: String, target: TargetLease) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draftsForReview.append(BoundDraft(target: target, text: text))
        status.notice = "Earlier-target words retained for review; never redirected to the new selection."
    }

    private func bindDraft(_ target: TargetLease, busy: Bool?) {
        // Empty/no-word recognition can retire a draft without sending. A later draft under the
        // same lease is still a different owner of async completions.
        if draftLease == nil { draftEpoch += 1 }
        draftLease = target; draftBusy = busy
    }

    private func retireDraft() {
        ownerEpoch += 1
        draftEpoch += 1
        if let target = draftLease, let text = composer.discard(reason: "target/generation changed; retained for review") {
            quarantine(text, target: target)
        }
        composer.reset()
        draftLease = nil; draftBusy = nil
    }

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
        voiceProbeTask?.cancel(); voiceProbeTask = nil
        acceptInput = false; status.phase = "starting"
        resyncEpoch += 1
        if id != currentLease?.sessionID { retireDraft(); currentLease = nil }
        if status.target != nil { silencePlayback(reason: "target changed") }
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
        resyncEpoch += 1
        let epoch = resyncEpoch
        let run = runEpoch
        do {
            let lease = try await backend.targetLease(sessionID: target)
            let active = try await backend.activeSessions()
            guard status.running, run == runEpoch, target == status.target, epoch == resyncEpoch else { return }
            guard lease.sessionID == target else { throw ClientError("Backend lease target mismatch") }
            if currentLease != lease { retireDraft(); currentLease = lease }
            let busy = active.contains(target)
            log("resync (\(reason)): \(target) busy=\(busy)")
            status.busy = busy
            if !busy { status.narrationPaused = false }
            if draftLease == lease { draftBusy = busy }
            if utteranceLease == lease { utteranceBusy = busy }
            status.connection = "connected"
            if status.lastError?.hasPrefix("Could not read session state:") == true { status.lastError = nil }
            refreshReadiness()
        } catch {
            guard run == runEpoch, epoch == resyncEpoch else { return }
            acceptInput = false; status.phase = "starting"
            status.connection = currentLease == nil ? "connecting" : "reconnecting"
            fail("Could not read session state: \(error.localizedDescription)")
        }
    }

    /// Both independently asynchronous gates must belong to this run before PCM is admitted.
    private func refreshReadiness() {
        let ready = status.running && capturePrepared && currentLease?.sessionID == status.target && currentLease != nil && status.connection == "connected"
        acceptInput = ready
        status.phase = ready ? "ready" : "starting"
    }

    // MARK: Voice on/off

    /// Lifecycle loss is NOT Stop/Send. Freeze capture first; all words go only to immutable-owner review.
    public func suspendForReview(finalTimeout: TimeInterval = 2, preservingNarration: Bool = false) {
        submissionEpoch += 1
        guard status.running else { return }
        acceptInput = false; input?.onPCM = nil
        if preservingNarration { speaker.pause() } else { speaker.stop() }
        input?.stop()
        if let target = draftLease, let text = composer.discard(reason: "suspended; review only") {
            let draft = BoundDraft(target: target, text: text)
            draftsForReview.append(draft); onReviewDraft?(draft)
        }
        composer.reset(); draftLease = nil; draftBusy = nil
        let taker = turnTaker; turnTaker = nil
        if let target = utteranceLease {
            let id = UUID()
            taker?.suspendForReview(timeout: finalTimeout) { [self] text, partial in
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let draft = BoundDraft(target: target, text: text, recoveryID: id, nonAuthoritative: partial)
                if let index = draftsForReview.firstIndex(where: { $0.recoveryID == id }) { draftsForReview[index] = draft }
                else { draftsForReview.append(draft) }
                onReviewDraft?(draft)
            }
        } else { taker?.stop() }
        stop(notice: "Suspended · words retained for review", discardUnfinished: true, preservingNarration: preservingNarration)
    }

    /// Hold/interruption is never mute or Send. Quarantine drafts, preserve narration position.
    public func pauseForCall() {
        guard !callPaused else { return }
        callPaused = true
        suspendForReview(preservingNarration: true)
    }

    public func start(micMuted: Bool = false, outputMuted: Bool = false) async {
        guard !status.running else { return }
        // Set gates before connection tasks, capture or narration can be admitted. No mute side effects.
        status.micMuted = micMuted
        status.outputMuted = outputMuted
        status.lastError = nil
        status.notice = nil
        if let micCheck {
            let holders = micCheck.otherCapturers().filter(\.isAgentVoice)
            if !holders.isEmpty {
                log("mic: agent-voice is capturing (pid \(holders.map { String($0.pid) }.joined(separator: ","))); not starting")
                status.lastError = ConversationController.agentVoiceBusyMessage
                return
            }
        }
        runEpoch += 1
        let epoch = runEpoch
        capturePrepared = false; acceptInput = false
        playbackQuietUntil = 0; playbackWasPlaying = false; wasCaptureSuppressed = false
        lastPlaybackEndedAt = -Double.infinity
        playbackInputLevel = nil; tailMeasureStartedAt = nil; tailMeasureFrames = 0
        status.running = true
        status.manualSend = app.sendMode == .manual
        // keepHeld restarts must expose the retained thought throughout startup, not just in apply's tail.
        if !composer.held.isEmpty { status.holding = composer.held }
        refreshPendingSpeech()
        status.phase = "starting"
        status.connection = "connecting"
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
                do { try await check.run(); log("self-check ok: \(check.name)") }
                catch { return error.localizedDescription }
            }
            return nil
        }
        guard let input else {
            let failure = await preflightTask.value
            guard runEpoch == epoch, status.running else { return }
            if let failure { fail(failure); stop(); return }
            await applyPartials(partialsTask, epoch: epoch)
            guard runEpoch == epoch, status.running else { return }
            capturePrepared = true; refreshReadiness()
            return
        }
        var callbacks = TurnCallbacks()
        callbacks.rendering = { [weak self] in
            guard let self else { return false }
            return self.speaker.playing || (self.input as? CaptureOriginReporting)?.lastCaptureRendered == true
        }
        callbacks.muted = { [weak self] in self?.captureSuppressed ?? true }
        callbacks.start = { [weak self] in self?.onset(); self?.onCaption?(.youStarted); self?.composer.speechStarted() }
        callbacks.speaking = { [weak self] in self?.onCaption?(.youSpeaking); self?.bargeIn(trigger: "sustained speech") }
        callbacks.partial = { [weak self] text in
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { self?.bargeIn(trigger: "partial transcript") }
        }
        callbacks.live = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.clearSpeechServiceError()
            self.onCaption?(.youLive(text))
            self.bargeIn(trigger: "live words")
        }
        callbacks.transcript = { [weak self] text in
            guard let self else { return }
            self.clearSpeechServiceError()
            self.log("heard: \(text)")
            guard let target = self.utteranceLease else { return }
            // The native socket reports transcript text through partial before
            // done. Final-only recognizers must have the same barge-in admission.
            // Final-only adapters cannot introduce an asynchronous abort/send
            // race. Native final-as-partial still follows the Mac admission path.
            if !self.voice.bargeInAborts { self.bargeIn(trigger: "final transcript") }
            self.onCaption?(.youFinal(text))
            guard target == self.currentLease else { self.quarantine(text, target: target); return }
            self.bindDraft(target, busy: self.utteranceBusy)
            self.composer.utterance(text)
        }
        callbacks.silence = { [weak self] elapsed in
            guard let self, self.app.sendMode == .auto else { return }
            self.countdown(total: elapsed == nil ? nil : self.voice.pauseMs, elapsed: elapsed ?? 0, hold: false)
        }
        callbacks.noisy = { [weak self] on in
            self?.log(on ? "noise: sound with no gap (10 s) or no words (5 s) inside an utterance; the room may be too loud for the pause to be heard" : "noise: over")
            self?.onCaption?(.noisy(on))
        }
        callbacks.idle = { [weak self] in
            if self?.status.sendCountdown?.hold != true { self?.countdown(total: nil, elapsed: 0, hold: false) }
            self?.bargeArmed = false; self?.status.hearing = false
            self?.refreshPendingSpeech()
            self?.onCaption?(.youIdle)
            self?.composer.speechIdle()
            self?.utteranceLease = nil
            if self?.composer.held.isEmpty == true { self?.draftLease = nil; self?.draftBusy = nil }
        }
        callbacks.error = { [weak self] error in
            guard let self else { return }
            self.failSpeech(error, service: .asr)
        }
        callbacks.review = { [weak self] text in
            guard let self, let target = self.utteranceLease else { return }
            if let held = self.composer.discard(reason: "recognition discontinuity; review only"), let owner = self.draftLease {
                self.quarantine(held, target: owner)
            }
            self.quarantine(text, target: target)
            self.status.notice = "Recognition disconnected · uncertain words retained for review, not sent."
        }
        callbacks.ended = { [weak self] length, voiced in
            guard let self else { return }
            self.log(String(format: "utterance ended after %.0f ms of silence: %.1f s long, %.1f s voiced", self.voice.pauseMs, length / 1000, voiced / 1000))
        }
        turnTaker = TurnTaker(config: voice, callbacks: callbacks, makeRecognition: makeRecognition)
        turnTaker?.now = now
        input.onPCM = { [weak self] pcm in
            guard let self, self.runEpoch == epoch, self.acceptInput, !self.status.micMuted, self.currentLease != nil else { return }
            if ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnProbe"), self.currentLease?.sessionID != "ses_example0000000000000000000" { return }
            self.refreshDuplexPolicy()
            let origin = self.input as? CaptureOriginReporting
            let rms = TurnTaker.rms(pcm)
            if self.speaker.playing || origin?.lastCaptureRendered == true { self.playbackInputLevel = rms }
            let unsafeOrigin = origin?.lastCaptureRendered == true && (origin?.lastCaptureDuplexSafe == false || !self.voice.duplex)
            let ignore = self.hardCaptureSuppressed || unsafeOrigin
            if let began = self.tailMeasureStartedAt, self.tailMeasureFrames < 40 {
                VoiceTrace.shared.event("voiceprobe.tail.sample", ["index": String(self.tailMeasureFrames),
                    "sampleMs": String(self.tailMeasureFrames * 20), "elapsedMs": String(self.now() - began),
                    "rms": String(rms), "noiseFloor": String(self.turnTaker?.noiseFloor ?? 0),
                    "floorAtStop": String(self.tailMeasureFloor), "threshold": String(self.turnTaker?.threshold ?? self.voice.threshold),
                    "renderedOrigin": String(origin?.lastCaptureRendered ?? false)])
                self.tailMeasureFrames += 1
            }
            if ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnProbe") {
                VoiceTrace.shared.event("voiceprobe.capture", ["rms": String(TurnTaker.rms(pcm)),
                    "suppressed": String(ignore), "halfDuplex": String(self.halfDuplex), "rendering": String(self.speaker.playing)])
            }
            self.micStats.add(pcm, threshold: self.turnTaker?.threshold ?? self.voice.threshold, playing: self.speaker.playing, ignored: ignore)
            if ignore { return }
            if let onCaption = self.onCaption { onCaption(.micLevel(TurnTaker.rms(pcm))) }
            self.turnTaker?.push(pcm)
            self.refreshDuplexPolicy() // guard release is driven by the actual 20ms frames
        }
        input.onFailure = { [weak self] error in
            guard let self, self.runEpoch == epoch else { return }
            self.fail("Microphone: \(error.localizedDescription)")
            self.stop()
        }
        do {
            try await input.start()
            guard runEpoch == epoch, status.running else { preflightTask.cancel(); partialsTask?.cancel(); return }
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
        refreshDuplexPolicy()
        if halfDuplex { log("half duplex: \(voice.duplex ? "echo cancellation is off and the output is not headphones" : "duplex is off in settings"); no listening or barge-in while speaking") }
        else { log("full duplex: listening and barge-in stay on while speaking (echo cancellation \(voice.echoCancellation); the mic does not hear the output: echo cancellation or headphones)") }
        micStats = MicStats()
        liveAt = now()
        capturePrepared = true; refreshReadiness()
        if callPaused { callPaused = false; speaker.resume() }
        log(acceptInput ? "ready: mic live" : "preparing: waiting for session authority")
        log("voice policy: pauseMs=\(voice.pauseMs), sensitivity=\(voice.sensitivity), turnEndQuietMs=\(app.turnEndQuietMs), finalTimeout=8s")
        if ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnProbe") {
            voiceProbeTask = Task { @MainActor [weak self] in await self?.runVoiceTurnProbe() }
        }
    }

    private func runVoiceTurnProbe() async {
        // Never speak into or submit a probe to the chief's real session.
        guard status.target == "ses_example0000000000000000000", let probe = input as? VoiceTurnProbeInput else { return }
        do {
            let deadline = Date().addingTimeInterval(15)
            while !acceptInput {
                guard Date() < deadline else { throw ClientError("Probe readiness timeout") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            // Let the real UI publish Listening before the runner observes it;
            // no fixture/playback starts during this observation grace.
            try await Task.sleep(nanoseconds: 3_000_000_000)
            if ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnMidThought") {
                guard voice.pauseMs == 3200 else { throw ClientError("Mid-thought probe requires configured 3200 ms pause") }
                VoiceTrace.shared.event("voiceprobe.thought.begin")
                try probe.probeInterjection()
                try await Task.sleep(nanoseconds: 22_000_000_000)
                VoiceTrace.shared.event("voiceprobe.completed")
                return
            }
            VoiceTrace.shared.event("voiceprobe.quiet.begin")
            speaker.enqueue("Will do. My whole reply explains how we keep the microphone open while the chief is speaking, without sending the chief's words as your own.")
            try await Task.sleep(nanoseconds: 12_000_000_000)
            let playbackDeadline = Date().addingTimeInterval(12)
            while speaker.active {
                guard Date() < playbackDeadline else { throw ClientError("Probe playback timeout") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await Task.sleep(nanoseconds: 4_000_000_000)
            VoiceTrace.shared.event("voiceprobe.quiet.end")
            if halfDuplex {
                // Second real TTS playback, cut through the same public API the
                // caption tap uses. Nobody speaks; do not substitute the mic.
                speaker.enqueue("Will do. My whole reply continues while we measure the real decay of the speaker in this quiet room after a deliberate cut in.")
                let startDeadline = Date().addingTimeInterval(10)
                try await Task.sleep(nanoseconds: 500_000_000)
                while !speaker.playing || measuredOutputLevel <= 0.001 || now() - measuredOutputAt > 200 {
                    guard Date() < startDeadline else { throw ClientError("Tail probe playback timeout") }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                let renderAtStop = measuredOutputLevel
                bargeIn()
                tailMeasureStartedAt = now(); tailMeasureFrames = 0
                tailMeasureFloor = turnTaker?.noiseFloor ?? 0
                VoiceTrace.shared.event("voiceprobe.tail.begin", ["noiseFloor": String(tailMeasureFloor),
                    "renderRMS": String(renderAtStop), "inputRMS": String(playbackInputLevel ?? 0)])
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard tailMeasureFrames == 40 else { throw ClientError("Tail probe needs forty real 20ms input frames") }
                VoiceTrace.shared.event("voiceprobe.tail.end")
                tailMeasureStartedAt = nil
                // Keep the later synthetic interjection OUT of the 800ms room
                // measurement, and past even a capped manual guard extension.
                let remaining = max(0, app.turnEndQuietMs + 100 - 1000)
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000))
                // On speaker, automatic voice interruption is deliberately off.
                // Prove normal listening after the real manual-tail measurement.
                VoiceTrace.shared.event("voiceprobe.resume.begin")
                try probe.probeInterjection()
                try await Task.sleep(nanoseconds: 8_000_000_000)
                VoiceTrace.shared.event("voiceprobe.resume.end")
            }
            // Receiver is a measurement, not an echo-policy acceptance claim:
            // the host reports any quiet-room barge-ins/ASR onsets numerically.
            VoiceTrace.shared.event("voiceprobe.completed")
        } catch { VoiceTrace.shared.event("voiceprobe.failed", ["error": error.localizedDescription]) }
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
    public func stop(notice: String? = nil, keepHeld: Bool = false, discardUnfinished: Bool = false, preservingNarration: Bool = false) {
        voiceProbeTask?.cancel(); voiceProbeTask = nil
        guard status.running else {
            if !preservingNarration { callPaused = false; speaker.stop() }
            return
        }
        if discardUnfinished {
            if let text = composer.discard(reason: "voice stopped without Send") { onCaption?(.discarded(text)) }
            composer.reset()
        } else if keepHeld && composer.manual {
            if !composer.held.isEmpty { log("restart: still holding for Send: \(composer.held)") }
        } else if composer.manual {
            if let text = composer.discard(reason: "voice stopped") { onCaption?(.discarded(text)) }
        } else {
            composer.flushNow(reason: "voice stopped")
            composer.reset()
        }
        runEpoch += 1
        acceptInput = false
        bargeArmed = false
        connectionTask?.cancel(); connectionTask = nil
        streamTask?.cancel(); streamTask = nil
        pollTask?.cancel(); pollTask = nil
        turnTaker?.stop(); turnTaker = nil
        utteranceLease = nil
        if !keepHeld { draftLease = nil; draftBusy = nil; currentLease = nil }
        input?.onPCM = nil
        input?.stop()
        if !preservingNarration { callPaused = false; speaker.stop(); blocks = [:] }
        if preservingNarration {
            status.running = false; status.hearing = false; status.phase = "starting"
            status.notice = "Call paused · words retained for review"
        } else { status = Status(lastError: status.lastError, notice: notice) }
        refreshPendingSpeech()
        log("voice stop\(notice.map { ": \($0)" } ?? "")")
    }

    public func setMicMuted(_ on: Bool) {
        guard status.micMuted != on else { return }
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
        let inProgress = turnTaker?.inUtterance ?? false
        log("send pressed\(inProgress ? " mid-utterance" : "")")
        if inProgress { turnTaker?.endNow() }
        composer.send(utteranceInProgress: inProgress)
    }

    private func refreshPendingSpeech() {
        status.pendingSpeech = status.hearing || !composer.held.isEmpty || !deferredPosts.isEmpty
    }

    /// Abandon only unsent speech. No await: invalidation wins atomically before any old callback or local post.
    public func discardPending() {
        guard status.pendingSpeech || utteranceInProgress || !composer.held.isEmpty || !deferredPosts.isEmpty else { return }
        log("discard stage=unsent droppedCapture=\(utteranceInProgress && turnTaker?.awaitingFinal != true) droppedFinal=\(turnTaker?.awaitingFinal == true) droppedColdPCM=\(turnTaker?.hasBufferedRecognitionAudio == true) droppedHeld=\(!composer.held.isEmpty) droppedCountdown=\(composer.hasWait) droppedSendAfterFinal=\(composer.pendingSendAfterFinal) droppedDeferredPosts=\(deferredPosts.count) micMuted=\(status.micMuted)")
        let hadCountdown = status.sendCountdown != nil
        let held = !composer.held.isEmpty || !deferredPosts.isEmpty
        let live = turnTaker?.inUtterance == true
        speechEpoch += 1
        deferredPosts.removeAll()
        // Reset send-after-final before recognition.cancel can synchronously report idle.
        composer.reset()
        input?.discardPendingAudio()
        turnTaker?.discard()
        draftLease = nil; draftBusy = nil; utteranceLease = nil
        bargeArmed = false
        status.hearing = false
        refreshPendingSpeech()
        status.sendCountdown = nil
        onCaption?(.countdownCancelled)
        onCaption?(.discarded(""))
        log("discarded unsent speech; issued requests and playback unchanged")
        StageDiagnostics.shared.record(.discard, .complete, audio: CaptureSnapshot([
            .discardCountdown: hadCountdown ? 1 : 0, .discardHeld: held ? 1 : 0, .discardLive: live ? 1 : 0]))
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
    public func setSpeechWarming(_ on: Bool) {
        status.warmingSpeech = on
    }

    /// Use these voice settings from now on: the next sentence uses the new voice, the next utterance the new pause
    /// length. Devices and echo cancellation apply when the audio engine next starts (see apply(_:)).
    public func setVoiceConfig(_ v: VoiceConfig) {
        voice = v
        turnTaker?.config = v
    }

    /// Follow "chief" or an explicit session id from now on (switches at once while voice is on).
    public func setTargetSetting(_ t: String) {
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
        Task { await resync(reason: "selection generation refreshed") }
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
            stop(keepHeld: true)
            await start(micMuted: mic, outputMuted: out)
            // The mutes and anything held for Send survive the restart.
            if status.running {
                if !composer.held.isEmpty { status.holding = composer.held }
                refreshPendingSpeech()
            }
        }
    }

    /// The Stop control: stop playback, clear the queue and interrupt the target's turn.
    public func stopReply() async {
        silencePlayback(reason: "stop control")
        guard let target = currentLease else { fail("No selected session lease to stop"); return }
        let owner = ownerEpoch, draft = draftEpoch, run = runEpoch
        let draftOwner = draftLease
        do {
            let interrupted = try await backend.interrupt(target: target)
            guard currentLease == target, ownerEpoch == owner, runEpoch == run else { return }
            log("interrupt \(target) -> interrupted=\(interrupted)")
            // Only an actual interrupt admits buffered words (execution.interrupted does the same when it arrives).
            if interrupted, draftEpoch == draft, draftOwner == target, draftLease == target { composer.interrupted() }
        } catch {
            guard currentLease == target, ownerEpoch == owner, runEpoch == run else { return }
            fail("Stop: \(error.localizedDescription)")
        }
    }

    /// Speak a short sample in `name` (the settings' Preview). Skipped while a reply is playing, so it never cuts
    /// the chief off or plays over it.
    public func previewVoice(_ name: String, text: String = "Hi, this is how I sound. I'll read the chief's replies to you.") async {
        guard !speaker.active else { log("preview skipped: a reply is playing"); return }
        var cfg = voice
        cfg.voice = name
        let ticket = HealthCheckedSynthesizer(config: { cfg }, warmup: speechWarmup).prepare(text)
        defer { ticket.cancel() }
        log("preview voice \(name)")
        do { try await output.play(try await ticket.audio(), label: "preview") {}; clearSpeechServiceError(service: .tts) }
        catch { failSpeech(error, service: .tts) }
    }

    /// Stop what is playing and silence text already received, without touching the agent's turn.
    private func silencePlayback(reason: String) {
        let wasActive = speaker.active
        speaker.stop()
        for b in blocks.values { b.skipToEnd() }
        log("playback silenced (\(reason))\(wasActive ? "" : " — nothing was playing")")
    }

    // MARK: Barge-in

    private func onset() {
        onEchoActivity?(false)
        VoiceTrace.shared.event("voiceprobe.onset")
        utteranceLease = currentLease
        utteranceBusy = status.busy
        if draftLease == nil, let target = currentLease { bindDraft(target, busy: status.busy) }
        bargeArmed = !halfDuplex && now() - liveAt >= voice.onsetGraceMs
        status.hearing = true
        refreshPendingSpeech()
        log("speech onset\(bargeArmed ? "" : " (within onset grace; no barge-in)")")
    }

    private func bargeIn(trigger: String) {
        guard bargeArmed, !halfDuplex else { return }
        bargeArmed = false
        onEchoActivity?(true)
        VoiceTrace.shared.event("barge.trigger", ["trigger": trigger])
        log("barge-in (\(trigger))")
        silencePlayback(reason: "barge-in")
        if voice.bargeInAborts { Task { await stopReply() } }
    }

    private var hardCaptureSuppressed: Bool {
        (input as? DuplexReporting)?.captureGraphReady == false ||
            halfDuplex && (speaker.playing || now() < playbackQuietUntil)
    }
    private var captureSuppressed: Bool { hardCaptureSuppressed || turnTaker?.manualGuardActive == true }

    private func refreshDuplexPolicy() {
        let wasHalfDuplex = halfDuplex
        if let input { halfDuplex = !voice.duplex || !input.duplexSafe }
        else { halfDuplex = !voice.duplex }
        let playing = speaker.playing
        if playbackWasPlaying && !playing {
            lastPlaybackEndedAt = now() // track endings on ALL routes, before a possible route-down
            if halfDuplex { playbackQuietUntil = max(playbackQuietUntil, now() + app.turnEndQuietMs) }
        }
        if !wasHalfDuplex && halfDuplex && !playing {
            let rendered = (input as? CaptureOriginReporting)?.lastCaptureRendered == true
            if now() - lastPlaybackEndedAt < app.turnEndQuietMs || rendered {
                let end = rendered ? now() : lastPlaybackEndedAt
                playbackQuietUntil = max(playbackQuietUntil, end + app.turnEndQuietMs)
            }
        }
        playbackWasPlaying = playing
        status.halfDuplex = halfDuplex
        status.canBargeIn = status.running && speaker.playing
        status.listeningSuppressed = captureSuppressed
        let suppressed = hardCaptureSuppressed
        if suppressed && !wasCaptureSuppressed {
            // Retire identity before late finals/mute/review can admit playback.
            // Also clear stale pre-roll even if recognition had not opened yet.
            turnTaker?.discard()
        }
        wasCaptureSuppressed = suppressed
    }

    /// Deliberate speaker-route interruption: silence narration exactly as a
    /// voice barge-in, but NEVER interrupt the model or admit buffered words.
    /// Busy input remains queued until a real model-turn end/interrupt arrives.
    public func bargeIn() {
        guard status.running, speaker.active else { return }
        bargeArmed = false
        status.narrationPaused = true
        silencePlayback(reason: "manual barge-in")
        // The manual guard retains PCM/onset flags without recognizing it or
        // training the floor. Only a continuing, non-decaying onset can release it.
        if halfDuplex {
            playbackQuietUntil = 0
            turnTaker?.beginManualGuard(now: now(), minimumMs: Self.manualBargeQuietMs,
                maximumMs: app.turnEndQuietMs, playbackInputLevel: playbackInputLevel)
        }
        refreshDuplexPolicy()
        VoiceTrace.shared.event("barge.manual")
    }

    // MARK: Sending

    func post(_ text: String, kind: PostKind, reason: String, to target: TargetLease) async {
        let owner = runEpoch
        if target == currentLease { status.sending = true }
        defer { if runEpoch == owner, target == currentLease { status.sending = false } }
        func send(_ delivery: BusyDelivery?, admit: Bool = false) async throws {
            let transport = VoicePost.transportText(text)
            if admit { try await backend.admit(target: target, text: transport, reviewText: text) }
            else { try await backend.prompt(target: target, text: transport, delivery: delivery, reviewText: text) }
        }
        do {
            switch kind {
            case .normal:
                log("post -> \(target) delivery=none (\(reason)): \(text)")
                if target == currentLease { status.busy = true } // a prompt to an idle session starts a turn
                try await send(nil)
            case .delivery(let d):
                log("post -> \(target) delivery=\(d.rawValue) (\(reason)): \(text)")
                try await send(d)
            case .admitOnly:
                log("post -> \(target) admit without starting a turn (\(reason)): \(text)")
                // A lost response may mean acceptance. Never retry as a new prompt.
                try await send(nil, admit: true)
            }
        } catch {
            fail("Voice delivery unknown; reconcile history before sending again: \(error.localizedDescription)")
            await resync(reason: "send failed")
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
                            if event.type == "remote.disconnected" {
                                synced = false
                                self.status.connection = "reconnecting"
                                self.acceptInput = false; self.status.phase = "starting"
                                continue
                            }
                            if !synced || event.type == "remote.connected" {
                                synced = true
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
            acceptInput = false; status.phase = "starting"
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
                await resync(reason: "chief generation refresh")
            }
            if !app.followsChief && now() - lastChief >= chiefPollInterval * 1000 {
                lastChief = now()
                await resync(reason: "generation refresh")
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
            status.narrationPaused = false
            if draftLease == currentLease { draftBusy = true }
            if utteranceLease == currentLease { utteranceBusy = true }
            log("execution.started")
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            status.busy = false
            status.narrationPaused = false
            if draftLease == currentLease { draftBusy = false }
            if utteranceLease == currentLease { utteranceBusy = false }
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
            if self.status.narrationPaused { return }
            if self.status.outputMuted { self.log("dropped (agent voice muted): \(sentence.prefix(60))"); return }
            self.log("queue [\(key)] \(sentence.prefix(80))")
            self.speaker.enqueue(sentence, label: key)
        }
    }

    /// Native remote lifecycle has already reconciled full source context and history boundaries.
    /// Reuse these segmenters so barge-in/output mute still silence already-received words.
    public func consumeNarration(_ update: NarrationUpdate) {
        guard status.running || callPaused else { return }
        let segment = blocks[update.blockKey] ?? makeSegments(update.blockKey)
        blocks[update.blockKey] = segment
        segment.consume(update)
        if update.final { blocks[update.blockKey] = nil }
    }
}
