import Foundation

public enum SpeechModelState: String, Sendable {
    case loaded, loading, unloaded, unknown
    public var isCold: Bool { self == .loading || self == .unloaded }

    public static func parse(_ body: [String: Any]) -> SpeechModelState {
        let own = (body["model"] as? String).map { Self(rawValue: $0) ?? .loaded } ?? .unknown
        let upstream = (body["upstream"] as? [String: Any]).map(Self.parse) ?? .unknown
        return upstream.isCold ? upstream : own == .unknown ? upstream : own
    }
}

/// A single read-only probe. Unknown/legacy health falls back to the ordinary request; only positive cold
/// evidence earns the longer budget. A refused listener and HTTP failures are never disguised as warm-up.
public enum SpeechHealth {
    public static let coldBudget: TimeInterval = 60
    public typealias Probe = (String, String?) async throws -> SpeechModelState
    public static func probe(_ endpoint: String, _ key: String?) async throws -> SpeechModelState {
        try await inspect(endpoint, key, session: .shared)
    }
    static func inspect(_ endpoint: String, _ key: String?, session: URLSession) async throws -> SpeechModelState {
        guard let url = ServiceChecks.healthURL(endpoint) else { return .unknown }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await withTimeout(2, "Speech health probe timed out") {
                try await session.data(for: request)
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return .unknown } // legacy servers without health
            guard (200..<300).contains(code) else { throw HTTPError.status(code, String(data: data, encoding: .utf8) ?? "") }
            guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown }
            if let upstream = body["upstream"] as? [String: Any], let code = upstream["http_status"] as? Int,
               !(200..<300).contains(code) {
                throw HTTPError.status(code, "upstream health failed")
            }
            if let status = body["status"] as? String, ["error", "unhealthy", "failed"].contains(status) {
                throw ClientError("Health reported \(status)")
            }
            return SpeechModelState.parse(body)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // A bounded health timeout is inconclusive, not proof the listener is down.
            if (error as? URLError)?.code == .timedOut { return .unknown }
            if (error as? ClientError)?.message == "Speech health probe timed out" { return .unknown }
            throw ClientError(SpeechServiceError.describe(url: endpoint, error: error))
        }
    }

    public static func retryMessage(_ url: String) -> String {
        "Speech service at \(SpeechServiceError.hostPort(url)) did not warm up within 60 s. Try again."
    }
}

/// Request-scoped tokens: cancelling one prefetch cannot clear another request's warm-up state.
/// Used on the main actor, like the speaker and recognition factories.
public final class SpeechWarmup {
    public static let text = "Warming up speech…"
    private var requests: Set<UUID> = []
    private let lock = NSLock()
    private var lastNotified = false // main-thread delivery only
    public var onChange: ((Bool) -> Void)?
    public init() {}
    func begin(_ id: UUID) { lock.lock(); requests.insert(id); lock.unlock(); notify() }
    func end(_ id: UUID) { lock.lock(); requests.remove(id); lock.unlock(); notify() }
    public func reset() { lock.lock(); requests.removeAll(); lock.unlock(); notify() }
    private func notify() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.notify() }; return }
        lock.lock(); let active = !requests.isEmpty; lock.unlock()
        guard active != lastNotified else { return }
        lastNotified = active
        onChange?(active)
    }
}

/// Health is inspected only when prepare is called, never while the app is idle.
public final class HealthCheckedSynthesizer: SpeechSynthesizer {
    let config: () -> VoiceConfig
    let warmup: SpeechWarmup
    let probe: SpeechHealth.Probe
    let make: (String, VoiceConfig, Bool) -> SpeechTicket
    let coldBudget: TimeInterval
    public init(config: @escaping () -> VoiceConfig, warmup: SpeechWarmup,
                probe: @escaping SpeechHealth.Probe = SpeechHealth.probe,
                coldBudget: TimeInterval = SpeechHealth.coldBudget,
                make: ((String, VoiceConfig, Bool) -> SpeechTicket)? = nil) {
        self.config = config; self.warmup = warmup; self.probe = probe
        self.coldBudget = coldBudget
        self.make = make ?? { HTTPSpeechTicket(text: $0, config: $1, cold: $2) }
    }
    public func prepare(_ text: String) -> SpeechTicket {
        HealthCheckedTicket(text: text, config: config(), warmup: warmup, probe: probe, coldBudget: coldBudget, make: make)
    }
}

private final class HealthCheckedTicket: SpeechTicket {
    let text: String
    let id = UUID()
    let warmup: SpeechWarmup
    private var inner: SpeechTicket?
    private var work: Task<SpeechAudio, Error>!
    init(text: String, config: VoiceConfig, warmup: SpeechWarmup, probe: @escaping SpeechHealth.Probe, coldBudget: TimeInterval,
         make: @escaping (String, VoiceConfig, Bool) -> SpeechTicket) {
        self.text = text; self.warmup = warmup
        work = Task { @MainActor in
            defer { warmup.end(self.id) }
            let state = try await probe(config.ttsUrl, config.ttsApiKey)
            try Task.checkCancellation()
            if state.isCold { warmup.begin(self.id) }
            let ticket = make(text, config, state.isCold)
            self.inner = ticket
            return try await withTaskCancellationHandler {
                let fetch = {
                    let audio = try await ticket.audio()
                    var iterator = audio.chunks.makeAsyncIterator()
                    let first = try await iterator.next()
                    try Task.checkCancellation()
                    // Warm-up ends at actual audio, not merely eagerly-sent HTTP headers.
                    let chunks = AsyncThrowingStream<Data, Error> { continuation in
                        if let first { continuation.yield(first) }
                        let pump = Task { @MainActor in
                            do {
                                while let chunk = try await iterator.next() { continuation.yield(chunk) }
                                continuation.finish()
                            } catch {
                                // First audio has already succeeded: a later stall is not a warm-up failure,
                                // even when this request began with an unloaded model.
                                let message = SpeechServiceError.describeStream(url: config.ttsUrl, error: error)
                                continuation.finish(throwing: ClientError(message))
                            }
                        }
                        continuation.onTermination = { _ in pump.cancel() }
                    }
                    return SpeechAudio(sampleRate: audio.sampleRate, chunks: chunks)
                }
                if state.isCold {
                    do { return try await withTimeout(coldBudget, SpeechHealth.retryMessage(config.ttsUrl), fetch) }
                    catch { ticket.cancel(); throw error }
                }
                return try await fetch()
            } onCancel: { ticket.cancel() }
        }
    }
    func audio() async throws -> SpeechAudio { try await work.value }
    func cancel() { work.cancel(); inner?.cancel(); warmup.end(id) }
}

/// Buffers the existing PCM/end sequence while the one health probe is in flight. Cancellation prevents the
/// ordinary websocket from being opened, and late probe results cannot resurrect a stopped utterance.
public final class HealthCheckedRecognition: RecognitionSession {
    private let callbacks: RecognitionCallbacks
    private let warmup: SpeechWarmup
    private let id = UUID()
    private var inner: RecognitionSession?
    private var pending: [Data] = []
    // Reviewed phone queue: 90 seconds plus the one-second preroll. Never evict onset PCM.
    static let pendingFrameLimit = 4_550
    static let pendingByteLimit = pendingFrameLimit * 640
    private(set) var pendingBytes = 0
    private var ended = false, cancelled = false, cold = false
    private var allowsColdStart = true
    private var completed = false, heardWords = false
    private var work: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private let endpoint: String
    private let key: String?
    private let probe: SpeechHealth.Probe
    private let make: (RecognitionCallbacks) -> RecognitionSession
    private let coldBudget: TimeInterval
    public init(endpoint: String, key: String?, callbacks: RecognitionCallbacks, warmup: SpeechWarmup,
                probe: @escaping SpeechHealth.Probe = SpeechHealth.probe,
                coldBudget: TimeInterval = SpeechHealth.coldBudget,
                make: @escaping (RecognitionCallbacks) -> RecognitionSession) {
        self.endpoint = endpoint; self.key = key; self.callbacks = callbacks; self.warmup = warmup
        self.probe = probe; self.make = make
        self.coldBudget = coldBudget
    }
    public var isWarming: Bool { !cancelled && !completed && (inner == nil || (cold && !heardWords)) }
    public var hasBufferedAudio: Bool { !pending.isEmpty || drain != nil || inner?.hasBufferedAudio == true }
    public func prepareContinuation() { allowsColdStart = false }
    public func finalBudget(ordinary: TimeInterval) async -> TimeInterval {
        await work?.value
        return cold ? coldBudget : ordinary
    }
    public func start() {
        work = Task { @MainActor [self] in
            do {
                let state = try await probe(endpoint, key)
                guard !cancelled, !Task.isCancelled else { return }
                cold = allowsColdStart && state.isCold
                if cold { warmup.begin(id) }
                var cbs = callbacks
                cbs.partial = { [weak self] text in
                    guard let self, !self.cancelled, !self.completed else { return }
                    self.receivedWords(text); self.callbacks.partial(text)
                }
                cbs.live = { [weak self] text in
                    guard let self, !self.cancelled, !self.completed else { return }
                    self.receivedWords(text); self.callbacks.live(text)
                }
                cbs.error = { [weak self] error in self?.fail(error) }
                cbs.done = { [weak self] text in
                    guard let self, !self.cancelled, !self.completed else { return }
                    self.completed = true; self.pending = []; self.pendingBytes = 0
                    self.warmup.end(self.id); self.callbacks.done(text)
                }
                let session = make(cbs); inner = session; session.setCold(cold); session.start()
                startDrain()
            } catch {
                guard !cancelled, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }
    private func receivedWords(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        heardWords = true; warmup.end(id)
    }
    private func startDrain() {
        guard inner != nil, drain == nil, !cancelled, !completed else { return }
        drain = Task { @MainActor [weak self] in
            guard let self, let inner = self.inner else { return }
            defer { self.drain = nil }
            do {
                while !self.pending.isEmpty, !self.cancelled, !self.completed {
                    try Task.checkCancellation()
                    let pcm = self.pending.removeFirst(); self.pendingBytes -= pcm.count
                    try await inner.writeBuffered(pcm)
                }
                if self.ended && !self.cancelled && !self.completed { inner.end() }
            } catch { self.fail(error) }
        }
    }
    private func fail(_ error: Error) {
        guard !cancelled, !completed else { return }
        completed = true; work?.cancel(); drain?.cancel()
        pending = []; pendingBytes = 0; warmup.end(id)
        callbacks.error(error); callbacks.done(""); inner?.cancel()
    }
    public func write(_ pcm: Data) {
        guard !cancelled, !completed, !ended, !pcm.isEmpty else { return }
        guard pending.count < Self.pendingFrameLimit, pcm.count <= Self.pendingByteLimit - pendingBytes else {
            fail(ClientError("Recognition audio backlog; partial retained for review. Listening resumes after a fresh speech gap.")); return
        }
        pending.append(pcm); pendingBytes += pcm.count; startDrain()
    }
    /// Await transport admission, not enqueue into a second health queue.
    @MainActor public func writeBuffered(_ pcm: Data) async throws {
        await work?.value
        await drain?.value
        try Task.checkCancellation()
        guard let inner, !cancelled, !completed, !ended else { throw ClientError("Recognition buffer retired") }
        try await inner.writeBuffered(pcm)
    }
    public func end() { ended = true; startDrain() }
    public func cancel() {
        cancelled = true; work?.cancel(); drain?.cancel()
        pending = []; pendingBytes = 0; inner?.cancel(); warmup.end(id)
    }
}
