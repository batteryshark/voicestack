import Foundation

public enum SpeechModelState: String, Sendable {
    case loaded, loading, unloaded, unknown
    public var isCold: Bool { self == .loading || self == .unloaded }
    public static func parse(_ body: [String: Any]) -> Self {
        let own = (body["model"] as? String).flatMap(Self.init(rawValue:)) ?? .unknown
        let upstream = (body["upstream"] as? [String: Any]).map(Self.parse) ?? .unknown
        return upstream.isCold ? upstream : own == .unknown ? upstream : own
    }
}

/// Pure health reads only. Legacy servers need no new fields or endpoint.
public enum SpeechHealth {
    public static let coldBudget: TimeInterval = 60
    public typealias Probe = (String, String?) async throws -> SpeechModelState
    public static func probe(_ endpoint: String, _ key: String?) async throws -> SpeechModelState {
        guard let url = ServiceChecks.healthURL(endpoint) else { return .unknown }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2; request.cachePolicy = .reloadIgnoringLocalCacheData
        if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return .unknown }
            guard (200..<300).contains(code) else {
                throw HTTPError.status(code, String(data: data, encoding: .utf8) ?? "")
            }
            return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).map(SpeechModelState.parse) ?? .unknown
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut { return .unknown }
            throw ClientError(SpeechServiceError.describe(url: endpoint, error: error))
        }
    }
    public static func retryMessage(_ url: String) -> String {
        "Speech service at \(SpeechServiceError.hostPort(url)) did not warm up within 60 s. Try again."
    }
}

/// Request tokens prevent one cancelled prefetch from clearing another request's indicator.
public final class SpeechWarmup {
    public static let text = "Warming up speech…"
    private var requests: Set<UUID> = []
    private let lock = NSLock()
    private var lastNotified = false
    public var onChange: ((Bool) -> Void)?
    public init() {}
    func begin(_ id: UUID) { lock.lock(); requests.insert(id); lock.unlock(); notify() }
    func end(_ id: UUID) { lock.lock(); requests.remove(id); lock.unlock(); notify() }
    public func reset() { lock.lock(); requests.removeAll(); lock.unlock(); notify() }
    private func notify() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.notify() }; return }
        lock.lock()
        let active = !requests.isEmpty, changed = active != lastNotified
        lastNotified = active
        lock.unlock()
        if changed { onChange?(active) }
    }
}

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
        self.config = config; self.warmup = warmup; self.probe = probe; self.coldBudget = coldBudget
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
    init(text: String, config: VoiceConfig, warmup: SpeechWarmup, probe: @escaping SpeechHealth.Probe,
         coldBudget: TimeInterval, make: @escaping (String, VoiceConfig, Bool) -> SpeechTicket) {
        self.text = text; self.warmup = warmup
        work = Task { @MainActor in
            defer { warmup.end(self.id) }
            let state = try await probe(config.ttsUrl, config.ttsApiKey)
            try Task.checkCancellation()
            if state.isCold { warmup.begin(self.id) }
            let ticket = make(text, config, state.isCold); self.inner = ticket
            return try await withTaskCancellationHandler {
                let fetch = {
                    try await withTaskCancellationHandler(operation: {
                    let audio = try await ticket.audio()
                    var iterator = audio.chunks.makeAsyncIterator()
                    let first = try await iterator.next()
                    try Task.checkCancellation()
                    let chunks = AsyncThrowingStream<Data, Error> { continuation in
                        if let first { continuation.yield(first) }
                        let pump = Task { @MainActor in
                            do {
                                while let chunk = try await iterator.next() { continuation.yield(chunk) }
                                continuation.finish()
                            } catch { continuation.finish(throwing: error) }
                        }
                        continuation.onTermination = { _ in pump.cancel() }
                    }
                    return SpeechAudio(sampleRate: audio.sampleRate, chunks: chunks)
                    }, onCancel: { ticket.cancel() })
                }
                if state.isCold {
                    do { return try await withTimeout(coldBudget, SpeechHealth.retryMessage(config.ttsUrl), fetch) }
                    catch {
                        ticket.cancel()
                        if (error as? URLError)?.code == .timedOut { throw ClientError(SpeechHealth.retryMessage(config.ttsUrl)) }
                        throw error
                    }
                }
                return try await fetch()
            } onCancel: { ticket.cancel() }
        }
    }
    func audio() async throws -> SpeechAudio { try await work.value }
    func cancel() { work.cancel(); inner?.cancel(); warmup.end(id) }
}

public final class HealthCheckedRecognition: RecognitionSession {
    private let callbacks: RecognitionCallbacks
    private let warmup: SpeechWarmup
    private let id = UUID()
    private var inner: RecognitionSession?
    private var pending: [Data] = []
    // At most the existing 90-second utterance cap plus its one-second preroll
    // (16 kHz s16 PCM). This also tolerates a cold handshake stalling sends.
    // Never evict the onset to make room: overflow is an explicit discontinuity,
    // so a truncated utterance cannot silently become an apparently valid final.
    static let pendingFrameLimit = 4_550
    static let pendingByteLimit = pendingFrameLimit * 640
    private(set) var pendingBytes = 0
    private var ended = false, cancelled = false, cold = false
    private var completed = false, heardWords = false
    private var work: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private let endpoint: String
    private let key: String?
    private let probe: SpeechHealth.Probe
    private let make: (RecognitionCallbacks) -> RecognitionSession
    public init(endpoint: String, key: String?, callbacks: RecognitionCallbacks, warmup: SpeechWarmup,
                probe: @escaping SpeechHealth.Probe = SpeechHealth.probe,
                make: @escaping (RecognitionCallbacks) -> RecognitionSession) {
        self.endpoint = endpoint; self.key = key; self.callbacks = callbacks; self.warmup = warmup
        self.probe = probe; self.make = make
    }
    public var isWarming: Bool { !cancelled && !completed && (inner == nil || (cold && !heardWords)) }
    public var hasBufferedAudio: Bool { !pending.isEmpty }
    public func finalBudget(ordinary: TimeInterval) async -> TimeInterval {
        await work?.value
        return cold ? SpeechHealth.coldBudget : ordinary
    }
    public func start() {
        work = Task { @MainActor [self] in
            do {
                let state = try await probe(endpoint, key)
                guard !cancelled, !Task.isCancelled else { return }
                cold = state.isCold
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
        heardWords = true; warmup.end(id) // cold eligibility is deliberately unchanged
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
    public func end() { ended = true; startDrain() }
    public func cancel() {
        cancelled = true; work?.cancel(); drain?.cancel()
        pending = []; pendingBytes = 0; inner?.cancel(); warmup.end(id)
    }
}
