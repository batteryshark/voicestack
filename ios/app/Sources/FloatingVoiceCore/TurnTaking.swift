import Foundation

public struct RecognitionCallbacks {
    public var partial: (String) -> Void
    public var error: (Error) -> Void
    /// Final text (empty on failure). Called once.
    public var done: (String) -> Void
    /// Live words while the utterance streams (`transcript.partial`, `?partials=1`): the whole hypothesis so far,
    /// replacing the previous one. Display only; the final text always comes from `done`.
    public var live: (String) -> Void
    public init(partial: @escaping (String) -> Void, error: @escaping (Error) -> Void, done: @escaping (String) -> Void,
                live: @escaping (String) -> Void = { _ in }) {
        self.partial = partial; self.error = error; self.done = done; self.live = live
    }
}

/// One utterance's recognition: binary PCM in, transcript out.
public protocol RecognitionSession: AnyObject {
    var hasBufferedAudio: Bool { get }
    var isWarming: Bool { get }
    func setCold(_ cold: Bool)
    func finalBudget(ordinary: TimeInterval) async -> TimeInterval
    func start()
    func write(_ pcm: Data)
    /// Buffered producers must await transport admission/completion rather than burst synchronous sends.
    @MainActor func writeBuffered(_ pcm: Data) async throws
    func end()
    func cancel()
}

public extension RecognitionSession {
    var hasBufferedAudio: Bool { false }
    var isWarming: Bool { false }
    func setCold(_ cold: Bool) {}
    func finalBudget(ordinary: TimeInterval) async -> TimeInterval { ordinary }
    @MainActor func writeBuffered(_ pcm: Data) async throws { try Task.checkCancellation(); write(pcm) }
}

public struct TurnCallbacks {
    /// Playback frames may drive VAD on duplex-safe routes but never train ambient noise.
    public var rendering: () -> Bool = { false }
    /// True while capture should be ignored (half duplex during playback).
    public var muted: () -> Bool = { false }
    /// Speech onset: an utterance opened.
    public var start: () -> Void = {}
    /// Voiced speech in this utterance reached bargeInMs.
    public var speaking: () -> Void = {}
    public var partial: (String) -> Void = { _ in }
    /// Live words of the utterance in progress (whole hypothesis so far).
    public var live: (String) -> Void = { _ in }
    public var transcript: (String) -> Void = { _ in }
    public var idle: () -> Void = {}
    /// The utterance ended: (length ms, voiced ms), for tuning pauseMs and threshold.
    public var ended: (Double, Double) -> Void = { _, _ in }
    public var error: (Error) -> Void = { _ in }
    /// Uncertain words are review-only, never a successful transcript.
    public var review: (String) -> Void = { _ in }
    /// The words stopped (no voice, or no new live words) for `silenceCueMs`: the wait before sending begins, with this
    /// many ms of it already gone; nil when it is called off (speech resumed).
    public var silence: (Double?) -> Void = { _ in }
    /// No gap in the sound for `noisyCueMs` while an utterance is open (true), or a gap came / the utterance ended
    /// (false): the room is too loud for the pause to be heard.
    public var noisy: (Bool) -> Void = { _ in }
    public init() {}
}

/// Turn-taking, ported from agent-voice voice.mjs VoiceInput: RMS voice activity on 20 ms frames (640 bytes of
/// 16 kHz s16le). Onset when 8 of the last 12 frames are voiced (agent-voice wants 8 in a row, which soft or choppy
/// speech can miss for whole sentences), and the utterance starts with up to 1 s of pre-roll, so words said softly just
/// before the onset are still recognized.
///
/// "Voiced" means above max(threshold, noise floor x sensitivity): the floor follows the room's ambient noise (NoiseFloor),
/// so a fan or a noisy mic cannot hold an utterance open. An utterance ends after `pauseMs` of energy silence, or, once
/// the recognition server has streamed any word, when its live words have not grown for `pauseMs` (the words decide;
/// without live words, energy alone), or after 90 s.
public final class TurnTaker {
    private struct ManualOnsetGuard {
        enum Decision { case hold, continuation, quiet, cap, rise(keepingPrevious: Int) }
        let minimumEnd: Double, maximumEnd: Double
        var envelope: Double?
        private var firstLevels: [Double] = [], recentLevels: [Double] = []
        private var samples = 0, risingFrames = 0
        private var decayEstablished = false, wordRiseConfirmed = false

        init(minimumEnd: Double, maximumEnd: Double, envelope: Double?) {
            self.minimumEnd = minimumEnd; self.maximumEnd = maximumEnd; self.envelope = envelope
        }

        mutating func observe(_ rms: Double, floor: Double, voiced: Bool, now: Double) -> Decision {
            let reference = envelope ?? rms
            samples += 1
            if firstLevels.count < 5 { firstLevels.append(rms) }
            recentLevels.append(rms)
            if recentLevels.count > 5 { recentLevels.removeFirst() }
            if samples >= 10 && !wordRiseConfirmed {
                // Establish a falling post-stop profile from 100ms means, not
                // from a single 20ms fluctuation or the pre-stop anchor alone.
                // A steady word beginning with the tap is not itself a decay.
                let first = firstLevels.reduce(0, +) / Double(firstLevels.count)
                let recent = recentLevels.reduce(0, +) / Double(recentLevels.count)
                if first > floor && recent < first * 0.98 { decayEstablished = true }
            }
            if decayEstablished && !wordRiseConfirmed {
                let clearlyAbove = voiced && rms > max(reference, floor) * 1.4142135623730951 // ~+3dB RMS
                risingFrames = clearlyAbove ? risingFrames + 1 : 0
                if risingFrames >= 3 {
                    wordRiseConfirmed = true
                    return .rise(keepingPrevious: 2)
                }
            }
            // Freeze the comparison envelope during a candidate rise: adapting
            // it upward would swallow a genuine word before its third frame.
            if risingFrames == 0 { envelope = reference + 0.2 * (rms - reference) }
            if now < minimumEnd { return .hold }
            if rms <= floor { return .quiet }
            if wordRiseConfirmed { return voiced ? .continuation : .quiet }
            if now >= maximumEnd && (decayEstablished || samples < 10) { return .cap }
            if decayEstablished || samples < 10 { return .hold }
            return voiced ? .continuation : .quiet
        }
    }
    private var manualGuard: ManualOnsetGuard?
    public var manualGuardActive: Bool { manualGuard != nil }

    /// Preserve post-tap PCM, but do not recognize or train ambient noise until
    /// the normal onset can be distinguished from a noisy acoustic decay.
    public func beginManualGuard(now: Double, minimumMs: Double, maximumMs: Double, playbackInputLevel: Double?) {
        discard()
        manualGuard = ManualOnsetGuard(minimumEnd: now + minimumMs,
            maximumEnd: now + max(minimumMs, maximumMs), envelope: playbackInputLevel)
    }
    public static let frameBytes = 640
    public static let prerollFrames = 50
    /// Silence this long inside an utterance starts the "sending in …" cue (short gaps between words do not).
    public static let silenceCueFrames = 25
    public static let silenceCueMs = Double(silenceCueFrames * 20)
    public static let onsetWindow = 12
    public static let onsetVoiced = 8
    /// No gap of 100 ms in the sound for this long inside an utterance means the room is loud (people breathe).
    public static let noisyCueFrames = 500
    /// After speech resumes from a quiet gap, the live words get this long to show up (the model's latency is ~0.8 s)
    /// before "no new words" counts.
    static let resumeGraceFrames = 50
    /// While the floor is still being calibrated (the first second), only clearly loud sound opens an utterance, so a
    /// noisy room at Start cannot open one before its level is known.
    static let calibrationOnsetLevel = 0.06
    /// With live words expected, an utterance with no word at all after this long was noise: it is dropped.
    static let noWordsFrames = 250
    /// Replaced live by settings changes (pause length, threshold); the next frame uses it.
    var config: VoiceConfig
    let callbacks: TurnCallbacks
    let makeRecognition: (RecognitionCallbacks) -> RecognitionSession
    private var buffer = Data()
    private var preroll: [Data] = []
    /// Voiced flags of the most recent frames before onset (onset window).
    private var recent: [Bool] = []
    private var voiced: Int { recent.filter { $0 }.count }
    private var silent = 0, frames = 0, spoken = 0
    /// The room's noise level, and the level a frame must exceed to be voice.
    public private(set) var floor = NoiseFloor()
    public var noiseFloor: Double { floor.value }
    public var threshold: Double { floor.threshold(base: config.threshold, factor: config.sensitivityLevel.factor) }
    // Live words (`?partials=1`): the end of the utterance follows them when they are there.
    private var liveCount = 0, lastGrowthFrame = 0, resumeFrame = -1000
    private var hasWords = false
    private var cueActive = false, noisyFlag = false
    private var sinceGap = 0
    /// The recognition server is streaming live words, so an utterance without any is noise (set by the controller).
    public var expectLiveWords = false
    /// RMS of the last 5 s of the utterance's frames, to learn the level of sound that turns out to be noise.
    private var utteranceRMS: [Double] = []
    private var waiting = false, sustained = false, closed = false
    private var recognition: RecognitionSession?
    private var epoch = 0
    /// After input_audio.end, a final transcript that does not arrive within this many seconds is given up on, so
    /// listening never stalls (the server's own timeout is 120 s).
    public var finalTimeout: TimeInterval = 8
    private var finalWatch: Task<Void, Never>?
    private var recognized = ""
    private var awaitSpeechGap = false
    private var gapFrames = 0
    private var recovery: ((String, Bool) -> Void)?
    var diagnostics = StageDiagnostics.shared
    private var diagnosticStart = Date()
    /// Injected monotonic-in-practice controller clock (milliseconds), also used in tests.
    public var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }

    private func recordEnd(_ reason: TurnEndReason) {
        let category: DiagnosticCategory = reason == .finalTimeout || reason == .discontinuity ? .failed : reason == .stop ? .cancelled : .complete
        diagnostics.record(.utterance, category, since: diagnosticStart, turnEndReason: reason)
        VoiceTrace.shared.event("voiceprobe.end", ["reason": reason.rawValue])
    }

    public init(config: VoiceConfig, callbacks: TurnCallbacks, makeRecognition: @escaping (RecognitionCallbacks) -> RecognitionSession) {
        self.config = config; self.callbacks = callbacks; self.makeRecognition = makeRecognition
    }

    public var inUtterance: Bool { recognition != nil }
    public var awaitingFinal: Bool { waiting }
    public var hasBufferedRecognitionAudio: Bool { recognition?.hasBufferedAudio == true }

    public func push(_ bytes: Data) {
        if closed { return }
        buffer.append(bytes)
        while buffer.count >= Self.frameBytes {
            let frame = buffer.prefix(Self.frameBytes)
            buffer = Data(buffer.dropFirst(Self.frameBytes))
            self.frame(Data(frame))
        }
    }

    public static func rms(_ frame: Data) -> Double {
        frame.withUnsafeBytes { raw -> Double in
            let s = raw.bindMemory(to: Int16.self)
            var sum = 0.0
            for v in s { let x = Double(Int16(littleEndian: v)) / 32768; sum += x * x }
            return (sum / Double(max(1, s.count))).squareRoot()
        }
    }

    func frame(_ frame: Data) {
        if waiting { return }
        if recognition == nil && callbacks.muted() && !manualGuardActive { preroll = []; recent = []; return }
        let rms = Self.rms(frame)
        // The threshold for this frame comes from the floor as it stood before it, so a loud frame never raises its own bar.
        let calibrating = floor.calibrating && recognition == nil
        let rendering = callbacks.rendering()
        let isVoiced = rms > (calibrating ? max(threshold, Self.calibrationOnsetLevel) : threshold)
        if ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnProbe") {
            VoiceTrace.shared.event("voiceprobe.vad", ["input": String(rms), "threshold": String(threshold),
                "noiseFloor": String(noiseFloor), "rendering": String(rendering), "voiced": String(isVoiced)])
        }
        let guardFrame = manualGuardActive
        if var guardState = manualGuard {
            let decision = guardState.observe(rms, floor: noiseFloor, voiced: isVoiced, now: now())
            manualGuard = guardState
            switch decision {
            case .hold:
                appendGuardFrame(frame, voiced: isVoiced)
                return
            case .quiet:
                // It decayed away: do not turn historical voiced flags into an onset.
                manualGuard = nil; preroll = []; recent = []
                return
            case .cap:
                // Do not hand a whole ring-down to ASR at the cap. Start a fresh
                // normal window with this frame; a new word remains admissible.
                manualGuard = nil; preroll = []; recent = []
            case .continuation:
                manualGuard = nil // normal onset below uses held PCM + this frame
            case .rise(let keep):
                // Only the sustained-rise candidates belong to the new onset.
                // Never replay the preceding acoustic tail into recognition.
                preroll = Array(preroll.suffix(keep)); recent = Array(recent.suffix(keep))
                if now() < guardState.minimumEnd {
                    appendGuardFrame(frame, voiced: isVoiced)
                    return
                }
                manualGuard = nil // normal window starts with the two candidates + this frame
            }
        }
        if awaitSpeechGap {
            gapFrames = isVoiced ? 0 : gapFrames + 1
            if gapFrames >= Self.silenceCueFrames { awaitSpeechGap = false; preroll = []; recent = [] }
            return
        }
        if !rendering && !guardFrame { floor.add(rms, inUtterance: recognition != nil, learnNoise: noisyFlag) }
        if recognition == nil {
            preroll.append(frame)
            if preroll.count > Self.prerollFrames { preroll.removeFirst() }
            recent.append(isVoiced)
            if recent.count > Self.onsetWindow { recent.removeFirst() }
            if !isVoiced || voiced < Self.onsetVoiced { return }
            diagnosticStart = Date()
            callbacks.start()
            spoken = voiced
            sustained = false
            sustain()
            var session: RecognitionSession?
            epoch += 1
            let generation = epoch
            let cbs = RecognitionCallbacks(
                partial: { [weak self] text in if let self, self.epoch == generation, self.recognition === session {
                    guard !self.callbacks.muted() else { return }
                    if !text.isEmpty { self.recognized = text }
                    if !self.closed { self.callbacks.partial(text) }
                } },
                error: { [weak self] e in if let self, !self.closed, self.epoch == generation, self.recognition === session {
                    self.discontinuity(e)
                } },
                done: { [weak self] text in
                    guard let self, self.epoch == generation, self.recognition === session else { return }
                    self.finalWatch?.cancel(); self.finalWatch = nil
                    self.recognition = nil; self.waiting = false; self.recent = []; self.silent = 0
                    self.preroll = []; self.buffer = Data()
                    if let recovery = self.recovery {
                        self.recovery = nil; self.finalWatch?.cancel(); self.finalWatch = nil
                        let safe = self.callbacks.muted() ? "" : text
                        recovery(safe.isEmpty ? self.recognized : safe, safe.isEmpty)
                        return
                    }
                    if !self.closed && !text.isEmpty && !self.callbacks.muted() { self.callbacks.transcript(text) }
                    self.callbacks.idle()
                },
                live: { [weak self] text in
                    guard let self, !self.closed, self.epoch == generation, self.recognition === session else { return }
                    guard !self.callbacks.muted() else { return }
                    if !text.isEmpty { self.recognized = text }
                    self.noteLive(text)
                    self.callbacks.live(text)
                })
            session = makeRecognition(cbs)
            recognition = session
            recognized = ""
            session!.start()
            for pcm in preroll { session!.write(pcm) }
            preroll = []; recent = []; frames = 0; silent = 0
            liveCount = 0; lastGrowthFrame = 0; resumeFrame = -1000; hasWords = false; utteranceRMS = []
            cueActive = false; noisyFlag = false; sinceGap = 0
        } else {
            recognition!.write(frame)
            frames += 1
            // Keep only ambient-source samples. A later discard must not learn
            // old playback samples merely because playback has since ended.
            if !rendering { utteranceRMS.append(rms) }
            if utteranceRMS.count > NoiseFloor.windowFrames { utteranceRMS.removeFirst() }
            let wasSilent = silent
            silent = isVoiced ? 0 : silent + 1
            if isVoiced { spoken += 1; sustain() }
            // Speech resuming after a quiet gap: the words take a moment to show up.
            if isVoiced && wasSilent >= Self.silenceCueFrames { resumeFrame = frames }
            // The wait: the longer of "no voice" and "no new words" (when words are streaming).
            let silentMs = Double(silent * 20)
            let stalledMs = hasWords ? Double(max(0, frames - max(lastGrowthFrame, resumeFrame + Self.resumeGraceFrames)) * 20) : 0
            let waitedMs = max(silentMs, stalledMs)
            if waitedMs >= Self.silenceCueMs && !cueActive { cueActive = true; callbacks.silence(waitedMs) }
            else if waitedMs < Self.silenceCueMs && cueActive { cueActive = false; callbacks.silence(nil) }
            // A room so loud that the sound never dips: say so.
            if silent >= 5 { sinceGap = 0; if noisyFlag { noisyFlag = false; callbacks.noisy(false) } }
            else { sinceGap += 1; if sinceGap == Self.noisyCueFrames && !noisyFlag { noisyFlag = true; callbacks.noisy(true) } }
            if waitedMs >= config.pauseMs || frames >= 4500 {
                // Energy wins ties; wordsStopped means the hypothesis clock alone
                // ended speech while the room/voice energy remained above its rule.
                endUtterance(reason: silentMs >= config.pauseMs ? .pause : stalledMs >= config.pauseMs ? .wordsStopped : .durationLimit)
            } else if expectLiveWords && recognition?.isWarming != true && !hasWords && frames >= Self.noWordsFrames {
                // Sound for 5 s and the recognizer has not heard one word: noise, not speech.
                discardNoise()
            }
        }
    }

    /// Same bounds/flags as the normal onset window; no noise-floor learning and
    /// no recognizer while held. This helper is outside the Mac-owned onset region.
    private func appendGuardFrame(_ frame: Data, voiced: Bool) {
        preroll.append(frame)
        if preroll.count > Self.prerollFrames { preroll.removeFirst() }
        recent.append(voiced)
        if recent.count > Self.onsetWindow { recent.removeFirst() }
    }

    /// Live words from the recognition server: whole hypothesis so far. Growth restarts the "no new words" clock.
    private func noteLive(_ text: String) {
        guard text.count > liveCount else { return }
        liveCount = text.count
        lastGrowthFrame = frames
        if text.contains(where: { !$0.isWhitespace }) { hasWords = true }
    }

    private func endUtterance(reason: TurnEndReason) {
        recordEnd(reason)
        waiting = true
        if cueActive { cueActive = false }
        if noisyFlag { noisyFlag = false; callbacks.noisy(false) }
        callbacks.ended(Double(frames * 20), Double(spoken * 20))
        endRecognition()
    }

    /// Voiced audio in the utterance reached bargeInMs: report it once as sustained speech.
    private func sustain() {
        if !sustained && Double(spoken * 20) >= config.bargeInMs { sustained = true; callbacks.speaking() }
    }

    /// End the utterance in progress now, as if the pause had come (Send in manual mode); its final text follows.
    public func endNow(reason: TurnEndReason = .manualSend) {
        guard recognition != nil, !waiting else { return }
        endUtterance(reason: reason)
    }

    /// Send input_audio.end and watch for the final transcript.
    private func endRecognition() {
        guard let r = recognition else { return }
        r.end()
        let ordinary = finalTimeout
        let endedAt = Date()
        finalWatch?.cancel()
        finalWatch = Task { @MainActor [weak self, weak r] in
            guard let r else { return }
            let seconds = await r.finalBudget(ordinary: ordinary)
            let remaining = max(0, seconds - Date().timeIntervalSince(endedAt))
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled, let self, self.recognition === r else { return }
            self.discontinuity(ClientError("No final transcript within \(Int(seconds)) s; partial retained for review. Listening resumes after a fresh speech gap."), reason: .finalTimeout)
        }
    }

    /// Every uncertain end uses one non-sending recovery path. Retire identity
    /// before cancel: synchronous or late finals cannot submit uncertain words.
    private func discontinuity(_ error: Error, reason: TurnEndReason = .discontinuity) {
        guard !closed, let r = recognition else { return }
        recordEnd(reason)
        recognition = nil; waiting = false; recent = []; silent = 0
        preroll = []; buffer = Data()
        finalWatch?.cancel(); finalWatch = nil
        awaitSpeechGap = true; gapFrames = 0; cueActive = false
        if noisyFlag { noisyFlag = false; callbacks.noisy(false) }
        callbacks.silence(nil)
        callbacks.review(recognized)
        callbacks.error(error)
        r.cancel()
        callbacks.idle()
    }

    /// Drop an utterance that turned out to be noise and keep listening (the floor learns the noise meanwhile).
    private func discardNoise() {
        recordEnd(.noiseDiscard)
        if !utteranceRMS.isEmpty { floor.learn(level: NoiseFloor.lowPercentile(utteranceRMS)) }
        let r = recognition
        recognition = nil; waiting = false; recent = []; silent = 0; frames = 0; preroll = []
        cueActive = false
        if noisyFlag { noisyFlag = false; callbacks.noisy(false) }
        callbacks.noisy(true)   // tell the card: the room is loud (it holds the hint a few seconds)
        callbacks.noisy(false)
        if let r { r.cancel(); callbacks.idle() }
    }

    /// Drop the utterance in progress (mic mute) and keep listening afterwards.
    public func discard() {
        epoch += 1
        manualGuard = nil
        awaitSpeechGap = false; gapFrames = 0
        finalWatch?.cancel(); finalWatch = nil
        let r = recognition
        recognition = nil; waiting = false; recent = []; silent = 0; frames = 0; buffer = Data(); preroll = []
        cueActive = false
        spoken = 0; sustained = false; liveCount = 0; lastGrowthFrame = 0; resumeFrame = -1000
        hasWords = false; utteranceRMS = []; sinceGap = 0
        recognized = ""
        if noisyFlag { noisyFlag = false; callbacks.noisy(false) }
        if let r { r.cancel(); callbacks.idle() }
    }

    public func stop() {
        epoch += 1
        finalWatch?.cancel(); finalWatch = nil
        manualGuard = nil
        if recognition != nil { recordEnd(.stop) }
        closed = true
        recognition?.cancel(); recognition = nil
        buffer = Data(); preroll = []
    }

    /// Seal PCM immediately. Only this already-open recognizer may finish, with no normal send/idle callbacks.
    /// Publish partial now (also safe if iOS freezes timers), then replace it once with final or deadline fallback.
    public func suspendForReview(timeout: TimeInterval, retain: @escaping (String, Bool) -> Void) {
        guard !closed else { return }
        manualGuard = nil
        closed = true; buffer = Data(); preroll = []
        guard let r = recognition else { return }
        recordEnd(.discontinuity)
        recovery = retain
        retain(recognized, true)
        finalWatch?.cancel()
        finalWatch = Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled, recognition === r else { return }
            recognition = nil
            let finish = recovery; recovery = nil; finalWatch = nil
            finish?(recognized, true)
            r.cancel() // identity retired first: even a synchronous/late done cannot duplicate or erase words
        }
        if !waiting { waiting = true; r.end() }
    }
}

/// Recognition over the local websocket (agent-voice README): binary s16le 16 kHz mono frames, then
/// `{"type":"input_audio.end"}`; `{"type":"transcript","text":...}` frames are appended until the server closes.
/// With `partials` it connects with `?partials=1` and reports `transcript.partial` snapshots as live words; the
/// final text still comes only from `transcript` frames. Callbacks run on the main queue.
public final class WebSocketRecognition: NSObject, RecognitionSession, URLSessionWebSocketDelegate {
    private var diagnosticStart = Date()
    let url: URL?
    let apiKey: String?
    let callbacks: RecognitionCallbacks
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var text = ""
    private var failed = false, finished = false, ended = false
    private var timer: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    var pingWatch = PingWatchdog(now: ProcessInfo.processInfo.systemUptime)
    private var sendBudget = PCMSendBudget()
    private var attempt = UUID()
    private var reason: NetworkCloseReason = .cleanEnd
    private var cold = false
    public func setCold(_ cold: Bool) { self.cold = cold }

    public init(url: String, apiKey: String?, partials: Bool = false, callbacks: RecognitionCallbacks) {
        self.url = partials ? Self.withPartials(url) : URL(string: url); self.apiKey = apiKey; self.callbacks = callbacks
    }

    /// The recognition URL with `partials=1` added to its query.
    public static func withPartials(_ url: String) -> URL? {
        guard var c = URLComponents(string: url) else { return nil }
        var items = (c.queryItems ?? []).filter { $0.name != "partials" }
        items.append(URLQueryItem(name: "partials", value: "1"))
        c.queryItems = items
        return c.url
    }

    public func start() {
        diagnosticStart = Date(); StageDiagnostics.shared.record(.asr, .begin, attempt: attempt)
        guard let url, url.scheme == "ws" || url.scheme == "wss" else {
            failed = true
            callbacks.error(ClientError("Set \"asrUrl\" in agent-voice.json (or the app's settings)."))
            finish(); return
        }
        var r = URLRequest(url: url)
        r.timeoutInterval = cold ? SpeechHealth.coldBudget : 10
        if let apiKey { r.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        r.setValue(attempt.uuidString, forHTTPHeaderField: "X-FV-Attempt")
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        session = s
        let t = s.webSocketTask(with: r)
        t.maximumMessageSize = 1024 * 1024
        task = t
        t.resume()
        receive()
        let w = DispatchWorkItem { [weak self] in self?.reason = .utteranceTimeout; self?.fail(ClientError("Recognition timed out; partial retained for review.")) }
        timer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (cold ? 180 : 120), execute: w)
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                switch result {
                case .failure(let error):
                    self.receiveFailed(error)
                case .success(let message):
                    var string: String?
                    switch message {
                    case .string(let s): string = s
                    case .data(let d): string = String(data: d, encoding: .utf8)
                    @unknown default: break
                    }
                    if let string, let obj = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any] {
                        if obj["type"] as? String == "transcript", let t = obj["text"] as? String {
                            self.text += t
                            self.callbacks.partial(self.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else if obj["type"] as? String == "transcript.partial", let t = obj["text"] as? String {
                            self.callbacks.live(t.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else if obj["type"] as? String == "error" {
                            self.cancel(ClientError(obj["message"] as? String ?? "Recognition failed."))
                            return
                        }
                    }
                    self.receive()
                }
            }
        }
    }

    public func write(_ pcm: Data) {
        guard !finished, !ended else { return }
        guard sendBudget.reserve(pcm.count) else {
            reason = .sendLimit; fail(ClientError("Recognition send backlog; partial retained for review.")); return
        }
        task?.send(.data(pcm)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sendBudget.release(pcm.count)
                if let error { self.reason = .transport; self.fail(error) }
            }
        }
    }

    @MainActor public func writeBuffered(_ pcm: Data) async throws {
        try Task.checkCancellation()
        guard !finished, !ended, let task else { throw CancellationError() }
        guard sendBudget.reserve(pcm.count) else {
            let error = ClientError("Recognition send backlog; partial retained for review.")
            reason = .sendLimit; fail(error); throw error
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.data(pcm)) { [weak self] error in
                DispatchQueue.main.async {
                    self?.sendBudget.release(pcm.count)
                    if let error {
                        self?.reason = .transport; self?.fail(error)
                        continuation.resume(throwing: error)
                    }
                    else { continuation.resume() }
                }
            }
        }
    }

    public func end() {
        guard !finished, !ended else { return }
        ended = true
        task?.send(.string("{\"type\":\"input_audio.end\"}")) { [weak self] error in
            if let error { DispatchQueue.main.async { self?.fail(error) } }
        }
    }

    private func fail(_ error: Error) {
        guard !finished, !failed else { return }
        if reason == .cleanEnd { reason = .transport }
        StageDiagnostics.shared.record(.asr, .failed, since: diagnosticStart, status: StageDiagnostics.code(error), attempt: attempt, initiator: [.pingTimeout, .sendLimit, .utteranceTimeout].contains(reason) ? .watchdog : .peer, reason: reason)
        failed = true
        // URLSessionWebSocketTask does not expose an HTTP refusal body. The bridge
        // mirrors its closed envelope in optional headers for this upgrade race.
        if let response = task?.response as? HTTPURLResponse, response.statusCode == 503,
           response.value(forHTTPHeaderField: "X-FV-Speech-Service") == "asr",
           let endpoint = response.value(forHTTPHeaderField: "X-FV-Speech-Endpoint"),
           endpoint.range(of: #"^[a-zA-Z0-9.\-]+:[0-9]{1,5}$"#, options: .regularExpression) != nil {
            callbacks.error(ClientError("Speech service at \(endpoint) isn't running"))
        } else { callbacks.error(error) }
        finish()
    }

    public func cancel() { cancel(nil) }

    func receiveFailed(_ error: Error) {
        if ended && task?.closeCode == .normalClosure { finish() }
        else { reason = .transport; fail(error) }
    }

    func cancel(_ error: Error?) {
        guard !finished else { return }
        failed = true
        reason = .cancelled
        if let error { callbacks.error(error) }
        finish()
    }

    private func finish() {
        guard !finished else { return }
        StageDiagnostics.shared.record(.asr, failed ? .cancelled : .complete, since: diagnosticStart, attempt: attempt, initiator: reason == .cancelled ? .client : ([.pingTimeout, .sendLimit, .utteranceTimeout].contains(reason) ? .watchdog : .peer), reason: reason)
        finished = true
        timer?.cancel()
        pingTimer?.cancel(); pingTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        callbacks.done(failed ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard !finished else { return }
        StageDiagnostics.shared.record(.asr, .ready, since: diagnosticStart, status: 101, attempt: attempt)
        pingWatch = PingWatchdog(now: ProcessInfo.processInfo.systemUptime)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            self.checkPing(now: ProcessInfo.processInfo.systemUptime)
        }
        pingTimer = timer; timer.resume()
    }

    func checkPing(now: TimeInterval) {
        guard !finished else { return }
        if cold && Date().timeIntervalSince(diagnosticStart) < SpeechHealth.coldBudget { return }
        switch pingWatch.tick(now: now) {
        case .none: break
        case .timeout:
            reason = .pingTimeout
            fail(ClientError("Recognition ping timed out; partial retained for review."))
        case .ping:
            task?.sendPing { [weak self] error in DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                if let error { self.reason = .transport; self.fail(error) }
                else { self.pingWatch.pong() }
            } }
        }
    }
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard !finished else { return }
        if ended && closeCode == .normalClosure { finish() }
        else { self.reason = .abnormalClose; fail(ClientError("Recognition disconnected; partial retained for review.")) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // After input_audio.end the server closing the socket is the normal end of the transcript.
        guard !finished else { return }
        if let error { reason = .transport; fail(error) }
        else if ended && self.task?.closeCode == .normalClosure { finish() }
        else { reason = .abnormalClose; fail(ClientError("Recognition disconnected; partial retained for review.")) }
    }
}
