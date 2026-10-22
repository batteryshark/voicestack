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
    /// Sticky positive cold-start eligibility, available synchronously even after words/completion.
    var hasColdStartBudget: Bool { get }
    func finalBudget(ordinary: TimeInterval) async -> TimeInterval
    func allowColdStart()
    func setCold(_ cold: Bool)
    func prepareContinuation()
    func start()
    func write(_ pcm: Data)
    @MainActor func writeBuffered(_ pcm: Data) async throws
    func end()
    /// After end(): pending PCM and the end frame have completed transport writes.
    /// Not a server acknowledgement or a final transcript. Async transports must implement this.
    @MainActor func waitForEndTransmission() async throws -> ContinuousClock.Instant
    func cancel()
}

public extension RecognitionSession {
    var hasBufferedAudio: Bool { false }
    var isWarming: Bool { false }
    var hasColdStartBudget: Bool { false }
    func finalBudget(ordinary: TimeInterval) async -> TimeInterval { ordinary }
    func allowColdStart() {}
    func setCold(_ cold: Bool) { if cold { allowColdStart() } }
    func prepareContinuation() { setCold(false) }
    @MainActor func writeBuffered(_ pcm: Data) async throws { try Task.checkCancellation(); write(pcm) }
    /// Only for synchronous recognizers, including existing in-memory fixtures.
    @MainActor func waitForEndTransmission() async throws -> ContinuousClock.Instant { try Task.checkCancellation(); return .now }
}

public struct TurnCallbacks {
    /// True while capture should be ignored (half duplex during playback).
    public var muted: () -> Bool = { false }
    /// Speech onset: an utterance opened.
    public var start: () -> Void = {}
    /// Voiced speech in this utterance reached bargeInMs.
    public var speaking: () -> Void = {}
    public var voicedProgress: (Double) -> Void = { _ in }
    public var outcomeObserver: () -> TurnOutcomeObserver = { TurnOutcomeObserver() }
    public var partial: (String) -> Void = { _ in }
    /// Live words of the utterance in progress (whole hypothesis so far).
    public var live: (String) -> Void = { _ in }
    public var transcript: (String) -> Void = { _ in }
    public var idle: () -> Void = {}
    /// The utterance ended: (length ms, voiced ms), for tuning pauseMs and threshold.
    public var ended: (Double, Double) -> Void = { _, _ in }
    public var error: (Error) -> Void = { _ in }
    public var review: (String) -> Void = { _ in }
    /// Owned soft-response feedback, never a transcript or assistant-thinking state.
    public var transcribing: (Bool) -> Void = { _ in }
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
/// without live words, energy alone). The 90 s ASR cap rolls an internal segment,
/// never the logical thought. Only one transport is started at a time.
public final class TurnTaker {
    public static let frameBytes = 640
    public static let prerollFrames = 50
    public static let segmentFrameLimit = 4_500
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
    /// Ordinary response soft limit; one fixed equal grace follows, without progress resets.
    public var finalTimeout: TimeInterval = 8
    var finalSendTimeout: TimeInterval = 8
    var warmWholeTimeout: TimeInterval = 120, coldWholeTimeout: TimeInterval = 180
    private var finalWatch: Task<Void, Never>?
    private var finalLimit: Task<Void, Never>?
    private var finalDeadline: ContinuousClock.Instant?
    private var finalDeadlineMessage = ""
    private var segmentStartedAt = ContinuousClock.now
    private var showingTranscribing = false
    private var epoch = 0
    private var observedOutcome = TurnOutcomeObserver()
    private var recognized = ""
    private var awaitSpeechGap = false
    private var gapFrames = 0
    private var segmentPrefix = ""
    private var segmentFrames = 0, segmentRollovers = 0
    private var continuation: RecognitionSession?
    private var continuationEnd: TurnEndReason?
    private var segmentHasLiveWords = false
    private func recordEnd(_ reason: TurnEndReason) { observedOutcome.logicalEnd(reason) }

    public init(config: VoiceConfig, callbacks: TurnCallbacks, makeRecognition: @escaping (RecognitionCallbacks) -> RecognitionSession) {
        self.config = config; self.callbacks = callbacks; self.makeRecognition = makeRecognition
    }

    public var inUtterance: Bool { recognition != nil }
    public var awaitingFinal: Bool { waiting }
    /// Mac hard ownership retirement retains only known text, never promises PCM recovery.
    public var knownRecognitionText: String { recognized }
    public var hasBufferedRecognitionAudio: Bool { continuation?.hasBufferedAudio == true || recognition?.hasBufferedAudio == true }

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
        if waiting && (continuation == nil || continuationEnd != nil) { return }
        if recognition == nil && callbacks.muted() { preroll = []; recent = []; return }
        let rms = Self.rms(frame)
        // The threshold for this frame comes from the floor as it stood before it, so a loud frame never raises its own bar.
        let calibrating = floor.calibrating && recognition == nil
        let isVoiced = rms > (calibrating ? max(threshold, Self.calibrationOnsetLevel) : threshold)
        if awaitSpeechGap {
            gapFrames = isVoiced ? 0 : gapFrames + 1
            if gapFrames >= Self.silenceCueFrames { awaitSpeechGap = false; preroll = []; recent = [] }
            return
        }
        floor.add(rms, inUtterance: recognition != nil, learnNoise: noisyFlag)
        if recognition == nil {
            preroll.append(frame)
            if preroll.count > Self.prerollFrames { preroll.removeFirst() }
            recent.append(isVoiced)
            if recent.count > Self.onsetWindow { recent.removeFirst() }
            if !isVoiced || voiced < Self.onsetVoiced { return }
            clearSegments()
            callbacks.start()
            spoken = voiced
            sustained = false
            sustain()
            epoch += 1
            let generation = epoch
            let outcome = callbacks.outcomeObserver()
            observedOutcome = outcome
            let session = makeSegment(generation: generation, buffered: false)
            recognition = session
            recognized = ""
            segmentStartedAt = .now
            session.start()
            for pcm in preroll { session.write(pcm) }
            preroll = []; recent = []; frames = 0; silent = 0
            liveCount = 0; lastGrowthFrame = 0; resumeFrame = -1000; hasWords = false; utteranceRMS = []
            cueActive = false; noisyFlag = false; sinceGap = 0
        } else {
            // Only work predating this frame suppresses the continuation clock;
            // this live frame's ordinary asynchronous send is not catch-up.
            let catchingUp = continuation != nil || (segmentRollovers > 0 && recognition?.hasBufferedAudio == true)
            (continuation ?? recognition)!.write(frame)
            guard recognition != nil else { return } // A bounded-buffer failure may retire synchronously.
            frames += 1; segmentFrames += 1
            utteranceRMS.append(rms)
            if utteranceRMS.count > NoiseFloor.windowFrames { utteranceRMS.removeFirst() }
            let wasSilent = silent
            silent = isVoiced ? 0 : silent + 1
            if isVoiced { spoken += 1; sustain() }
            // Speech resuming after a quiet gap: the words take a moment to show up.
            if isVoiced && wasSilent >= Self.silenceCueFrames { resumeFrame = frames }
            // The wait: the longer of "no voice" and "no new words" (when words are streaming).
            let silentMs = Double(silent * 20)
            if catchingUp { lastGrowthFrame = frames } // Do not charge backlog time when the clock re-arms.
            let stalledMs = hasWords && !catchingUp && (segmentRollovers == 0 || segmentHasLiveWords) ? Double(max(0, frames - max(lastGrowthFrame, resumeFrame + Self.resumeGraceFrames)) * 20) : 0
            let waitedMs = max(silentMs, stalledMs)
            if waitedMs >= Self.silenceCueMs && !cueActive { cueActive = true; callbacks.silence(waitedMs) }
            else if waitedMs < Self.silenceCueMs && cueActive { cueActive = false; callbacks.silence(nil) }
            // A room so loud that the sound never dips: say so.
            if silent >= 5 { sinceGap = 0; if noisyFlag { noisyFlag = false; callbacks.noisy(false) } }
            else { sinceGap += 1; if sinceGap == Self.noisyCueFrames && !noisyFlag { noisyFlag = true; callbacks.noisy(true) } }
            if waitedMs >= config.pauseMs {
                endUtterance(reason: silentMs >= config.pauseMs ? .pause : .wordsStopped)
            } else if segmentFrames >= Self.segmentFrameLimit {
                if continuation != nil { discontinuity(ClientError("Recognition continuation backlog; words retained for review.")) }
                else { rolloverSegment() }
            } else if segmentRollovers == 0 && expectLiveWords && recognition?.isWarming != true && !hasWords && frames >= Self.noWordsFrames {
                // Sound for 5 s and the recognizer has not heard one word: noise, not speech.
                discardNoise()
            }
        }
    }

    private static func joined(_ first: String, _ second: String) -> String {
        [first, second].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The existing recognizer identity fences also own each sequential segment.
    private func makeSegment(generation: Int, buffered: Bool) -> RecognitionSession {
        var session: RecognitionSession?
        let cbs = RecognitionCallbacks(
            partial: { [weak self] text in if let self, self.epoch == generation, self.recognition === session {
                guard !self.callbacks.muted() else { return }
                let joined = Self.joined(self.segmentPrefix, text)
                if !joined.isEmpty { self.recognized = joined }
                if !self.closed { self.callbacks.partial(joined) }
            } },
            error: { [weak self] e in if let self, !self.closed,
                (self.epoch == generation && self.recognition === session) || self.continuation === session {
                self.discontinuity(e)
            } },
            done: { [weak self] text in
                guard let self, self.epoch == generation, self.recognition === session else { return }
                if self.expireFinalIfNeeded() { return }
                if self.continuation != nil && !self.closed { self.continueSegment(text); return }
                let joined = Self.joined(self.segmentPrefix, text)
                let deliverFinal = self.observedOutcome.final(joined, !self.closed && !self.callbacks.muted())
                self.cancelFinalWatch()
                self.recognition = nil; self.waiting = false; self.recent = []; self.silent = 0
                self.preroll = []; self.buffer = Data(); self.clearSegments()
                if !self.closed && !joined.isEmpty && !self.callbacks.muted() && deliverFinal { self.callbacks.transcript(joined) }
                self.callbacks.idle()
            },
            live: { [weak self] text in
                guard let self, !self.closed, self.epoch == generation, self.recognition === session else { return }
                guard !self.callbacks.muted() else { return }
                let joined = Self.joined(self.segmentPrefix, text)
                if !joined.isEmpty { self.recognized = joined }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.segmentHasLiveWords = true }
                self.noteLive(joined); self.callbacks.live(joined)
            })
        if buffered {
            // Reuse the existing bounded PCM queue and paced drain. A standby
            // starts NO socket: its start() waits for the old segment's final.
            session = HealthCheckedRecognition(endpoint: config.asrUrl, key: nil, callbacks: cbs,
                warmup: SpeechWarmup(), probe: { _, _ in .loaded }) { [makeRecognition] callbacks in
                    let next = makeRecognition(callbacks); next.prepareContinuation(); return next
                }
        } else { session = makeRecognition(cbs) }
        return session!
    }

    private func rolloverSegment() {
        segmentRollovers += 1; segmentFrames = 0; segmentHasLiveWords = false
        observedOutcome.segmentRollover(segmentRollovers)
        continuation = makeSegment(generation: epoch + 1, buffered: true)
        waiting = true
        endRecognition()
    }

    private func continueSegment(_ text: String) {
        guard let next = continuation else { return }
        cancelFinalWatch()
        segmentPrefix = Self.joined(segmentPrefix, text); recognized = segmentPrefix
        liveCount = segmentPrefix.count; lastGrowthFrame = frames; resumeFrame = frames
        segmentHasLiveWords = false
        continuation = nil; epoch += 1; recognition = next
        let ending = continuationEnd != nil
        continuationEnd = nil; waiting = ending
        segmentStartedAt = .now
        next.start()
        if !segmentPrefix.isEmpty { callbacks.live(segmentPrefix) }
        if ending && recognition === next { endRecognition() }
    }

    private func clearSegments() {
        let pending = continuation; continuation = nil
        continuationEnd = nil; segmentPrefix = ""; segmentFrames = 0; segmentRollovers = 0; segmentHasLiveWords = false
        pending?.cancel()
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
        if let continuation { continuationEnd = reason; continuation.end() }
        else { endRecognition() }
    }

    /// Voiced audio in the utterance reached bargeInMs: report it once as sustained speech.
    private func sustain() {
        callbacks.voicedProgress(Double(spoken * 20))
        if !sustained && Double(spoken * 20) >= config.bargeInMs { sustained = true; callbacks.speaking() }
    }

    /// End the utterance in progress now, as if the pause had come (Send in manual mode); its final text follows.
    public func endNow(reason: TurnEndReason = .manualSend) {
        guard recognition != nil, !waiting || (continuation != nil && continuationEnd == nil) else { return }
        endUtterance(reason: reason)
    }

    private func cancelFinalWatch() {
        finalWatch?.cancel(); finalWatch = nil
        finalLimit?.cancel(); finalLimit = nil
        finalDeadline = nil
        if showingTranscribing { showingTranscribing = false; callbacks.transcribing(false) }
    }

    private func wholeDeadline(for session: RecognitionSession) -> ContinuousClock.Instant {
        segmentStartedAt + .seconds(session.hasColdStartBudget ? coldWholeTimeout : warmWholeTimeout)
    }

    @discardableResult private func expireFinalIfNeeded() -> Bool {
        // Authoritative early normal closure can precede logical end and its final watchdog.
        // Check synchronously, before any completion can post or activate a standby socket.
        if let recognition, ContinuousClock.now >= wholeDeadline(for: recognition) {
            discontinuity(ClientError("Recognition whole-segment deadline exceeded; partial retained for review. Listening resumes after a fresh speech gap."), reason: .finalTimeout)
            return true
        }
        guard let deadline = finalDeadline, ContinuousClock.now >= deadline else { return false }
        discontinuity(ClientError(finalDeadlineMessage), reason: .finalTimeout)
        return true
    }

    /// Independent watchdog: never joins an uncooperative health probe or transport await.
    private func limitFinal(_ r: RecognitionSession, until deadline: ContinuousClock.Instant, message: String) {
        finalLimit?.cancel()
        finalDeadline = deadline; finalDeadlineMessage = message
        finalLimit = Task { @MainActor [weak self, weak r] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self, let r, self.recognition === r else { return }
            self.discontinuity(ClientError(message), reason: .finalTimeout)
        }
    }

    /// Bound health/drain/end transmission separately from final response, and never extend the whole session.
    private func endRecognition() {
        guard let r = recognition else { return }
        r.end()
        guard recognition === r else { return }
        let ordinary = finalTimeout
        let endedAt = ContinuousClock.now
        let sendTimeout = finalSendTimeout
        cancelFinalWatch()
        let sendMessage = "Recognition end transmission timed out; partial retained for review. Listening resumes after a fresh speech gap."
        // Even a health/budget computation that never returns cannot disable retirement.
        limitFinal(r, until: min(endedAt + .seconds(sendTimeout), wholeDeadline(for: r)), message: sendMessage)
        finalWatch = Task { @MainActor [weak self, weak r] in
            guard let r else { return }
            let seconds = await r.finalBudget(ordinary: ordinary)
            guard !Task.isCancelled, self?.recognition === r else { return }
            if self?.expireFinalIfNeeded() == true { return }
            let cold = seconds != ordinary
            guard let wholeEnd = self?.wholeDeadline(for: r) else { return }
            self?.limitFinal(r, until: min(endedAt + .seconds(cold ? seconds : sendTimeout), wholeEnd), message: sendMessage)
            do {
                let transmittedAt = try await r.waitForEndTransmission()
                guard !Task.isCancelled, self?.recognition === r else { return }
                if self?.expireFinalIfNeeded() == true { return }
                let hard = cold ? seconds : ordinary * 2
                self?.limitFinal(r, until: min(transmittedAt + .seconds(hard), wholeEnd),
                    message: "No final transcript within \(Int(hard)) s; partial retained for review. Listening resumes after a fresh speech gap.")
                if !cold {
                    try await Task.sleep(until: transmittedAt + .seconds(ordinary), clock: .continuous)
                    guard !Task.isCancelled, let self, self.recognition === r, self.continuation == nil else { return }
                    if self.expireFinalIfNeeded() { return }
                    self.showingTranscribing = true; self.callbacks.transcribing(true)
                }
            } catch {
                guard !Task.isCancelled, let self, self.recognition === r else { return }
                self.discontinuity(error)
            }
        }
    }

    /// Retire identity before cancel so uncertain finals cannot become posts.
    private func discontinuity(_ error: Error, reason: TurnEndReason = .discontinuity) {
        guard !closed, let r = recognition else { return }
        recordEnd(reason)
        observedOutcome.failed()
        recognition = nil; waiting = false; recent = []; silent = 0
        preroll = []; buffer = Data()
        cancelFinalWatch()
        awaitSpeechGap = true; gapFrames = 0; cueActive = false
        if noisyFlag { noisyFlag = false; callbacks.noisy(false) }
        callbacks.silence(nil)
        callbacks.review(recognized)
        clearSegments()
        callbacks.error(error)
        r.cancel()
        callbacks.idle()
    }

    /// Drop an utterance that turned out to be noise and keep listening (the floor learns the noise meanwhile).
    private func discardNoise() {
        recordEnd(.noiseDiscard)
        observedOutcome.noise()
        floor.learn(level: NoiseFloor.lowPercentile(utteranceRMS))
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
        clearSegments()
        awaitSpeechGap = false; gapFrames = 0
        cancelFinalWatch()
        let r = recognition
        recognition = nil; waiting = false; recent = []; silent = 0; frames = 0; buffer = Data(); preroll = []
        if r != nil { observedOutcome.cancelled() }
        cueActive = false
        spoken = 0; sustained = false; liveCount = 0; lastGrowthFrame = 0; resumeFrame = -1000
        hasWords = false; utteranceRMS = []; sinceGap = 0
        recognized = ""
        if noisyFlag { noisyFlag = false; callbacks.noisy(false) }
        if let r { r.cancel(); callbacks.idle() }
    }

    public func stop() {
        epoch += 1
        if segmentRollovers > 0 && !recognized.isEmpty { callbacks.review(recognized) }
        clearSegments()
        cancelFinalWatch()
        closed = true
        if recognition != nil { recordEnd(.stop); observedOutcome.cancelled() }
        recognition?.cancel(); recognition = nil
        buffer = Data(); preroll = []
    }
}

/// Recognition over the local websocket (agent-voice README): binary s16le 16 kHz mono frames, then
/// `{"type":"input_audio.end"}`; `{"type":"transcript","text":...}` frames are appended until the server closes.
/// With `partials` it connects with `?partials=1` and reports `transcript.partial` snapshots as live words; the
/// final text still comes only from `transcript` frames. Callbacks run on the main queue.
public final class WebSocketRecognition: NSObject, RecognitionSession, URLSessionWebSocketDelegate {
    let url: URL?
    let apiKey: String?
    let callbacks: RecognitionCallbacks
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var text = ""
    private var failed = false, finished = false, ended = false
    private var timer: DispatchWorkItem?
    private var totalTimeout: TimeInterval = 120
    private var sendBudget = PCMSendBudget()
    private var pendingWrites = 0, endSent = false
    private let endTransmission = RecognitionEndTransmission()
    public var hasColdStartBudget: Bool { totalTimeout == 180 }

    public func allowColdStart() { totalTimeout = 180 } // 90 s input plus a full 60 s cold final, with margin
    public func setCold(_ cold: Bool) { totalTimeout = cold ? 180 : 120 }

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
        guard let url, url.scheme == "ws" || url.scheme == "wss" else {
            failed = true
            callbacks.error(ClientError("Set \"asrUrl\" in agent-voice.json (or the app's settings)."))
            finish(); return
        }
        var r = URLRequest(url: url)
        r.timeoutInterval = 10
        if let apiKey { r.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        session = s
        let t = s.webSocketTask(with: r)
        t.maximumMessageSize = 1024 * 1024
        task = t
        t.resume()
        receive()
        let w = DispatchWorkItem { [weak self] in self?.cancel(ClientError("Recognition timed out.")) }
        timer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + totalTimeout, execute: w)
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                switch result {
                case .failure(let error):
                    if self.task?.closeCode == .normalClosure { self.finish() }
                    else { self.fail(error) }
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
            fail(ClientError("Recognition send backlog; partial retained for review.")); return
        }
        pendingWrites += 1
        task?.send(.data(pcm)) { [weak self] error in
            DispatchQueue.main.async {
                self?.sendBudget.release(pcm.count)
                self?.pendingWrites -= 1
                if let error { self?.fail(error) }
                else { self?.sendEndIfReady() }
            }
        }
    }

    @MainActor public func writeBuffered(_ pcm: Data) async throws {
        try Task.checkCancellation()
        guard !finished, !ended, let task else { throw CancellationError() }
        guard sendBudget.reserve(pcm.count) else {
            let error = ClientError("Recognition send backlog; partial retained for review.")
            fail(error); throw error
        }
        pendingWrites += 1
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.data(pcm)) { [weak self] error in
                DispatchQueue.main.async {
                    self?.sendBudget.release(pcm.count)
                    self?.pendingWrites -= 1
                    if let error { self?.fail(error); continuation.resume(throwing: error) }
                    else { self?.sendEndIfReady(); continuation.resume() }
                }
            }
        }
    }

    public func end() {
        guard !finished, !ended else { return }
        ended = true
        sendEndIfReady()
    }

    private func sendEndIfReady() {
        guard ended, !finished, !endSent, pendingWrites == 0, let task else { return }
        endSent = true
        task.send(.string("{\"type\":\"input_audio.end\"}")) { [weak self] error in
            let completedAt = ContinuousClock.now
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                if let error { self.endTransmission.resolve(.failure(error)); self.fail(error) }
                else { self.endTransmission.resolve(.success(completedAt)) }
            }
        }
    }

    @MainActor public func waitForEndTransmission() async throws -> ContinuousClock.Instant {
        try await endTransmission.value()
    }

    private func fail(_ error: Error) {
        guard !finished, !failed else { return }
        failed = true
        callbacks.error(error)
        finish()
    }

    public func cancel() { cancel(nil) }

    func cancel(_ error: Error?) {
        guard !finished else { return }
        failed = true
        if let error { callbacks.error(error) }
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        endTransmission.resolve(.failure(CancellationError()))
        timer?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        callbacks.done(failed ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if closeCode == .normalClosure { finish() }
        else { cancel(ClientError("Recognition closed unexpectedly (\(closeCode.rawValue)). Try again.")) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // After input_audio.end the server closing the socket is the normal end of the transcript.
        if let error, !finished, task is URLSessionWebSocketTask,
           (task as? URLSessionWebSocketTask)?.closeCode != .normalClosure { fail(error) } else { finish() }
    }
}
