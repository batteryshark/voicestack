import Foundation

/// One HTTP request whose body is delivered chunk by chunk as it arrives (SSE, streamed speech).
/// Bounded eager buffering. Overflow cancels the transport rather than silently dropping audio/events.
public final class HTTPChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public let chunks: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var response: HTTPURLResponse?
    private var responseError: Error?
    private var responseWaiters: [CheckedContinuation<HTTPURLResponse, Error>] = []
    private var session: URLSession!
    private var task: URLSessionDataTask!
    private let started = Date()
    private var diagnosticStage = DiagnosticStage.other
    private let attempt = UUID()
    private let callToken: Int
    private let diagnostics: StageDiagnostics
    public var requestAttempt: UUID { attempt }
    private var transfer = AudioTransferTiming(now: ProcessInfo.processInfo.systemUptime)
    private var ttsStreaming: Bool?
    private var watchdog = StreamIdleWatchdog(now: ProcessInfo.processInfo.systemUptime)
    private var watch: DispatchSourceTimer?
    private var closeReason: NetworkCloseReason?
    private var cancellationCause: StreamCancellationCause?
    private var receivedBytes = 0
    public var liveness: (bytes: Int, idleSeconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (receivedBytes, watchdog.age(now: ProcessInfo.processInfo.systemUptime))
    }

    /// idleTimeout: seconds without any data before the request fails.
    public init(_ request: URLRequest, idleTimeout: TimeInterval, resourceTimeout: TimeInterval = 300, configuration: URLSessionConfiguration = .ephemeral, ttsStreaming: Bool? = nil, diagnostics: StageDiagnostics = .shared) {
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        chunks = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { cont = $0 }
        continuation = cont
        self.diagnostics = diagnostics; callToken = diagnostics.playbackCallToken
        super.init()
        let path = request.url?.path ?? ""
        diagnosticStage = path.hasSuffix("/audio/speech") ? .tts : (path.hasSuffix("/events") ? .events : .other)
        self.ttsStreaming = ttsStreaming
        if diagnosticStage != .other {
            diagnostics.record(diagnosticStage, .begin,
                audio: diagnosticStage == .tts ? CaptureSnapshot([.streaming: ttsStreaming.map { $0 ? 1 : 0 } ?? -1]) : nil,
                attempt: attempt, playbackEvent: diagnosticStage == .tts ? .ttsRequest : nil, callBank: diagnosticStage == .tts ? callToken : nil)
        }
        let config = configuration
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        // URLRequest's explicit timeout wins over URLSessionConfiguration. Bridge requests
        // otherwise retain their 30 s JSON timeout on the long-lived SSE connection.
        var streamingRequest = request
        streamingRequest.setValue(attempt.uuidString, forHTTPHeaderField: "X-FV-Attempt")
        streamingRequest.timeoutInterval = idleTimeout
        task = session.dataTask(with: streamingRequest)
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.cancel(cause: .consumer) }
        }
        task.resume()
        if diagnosticStage == .events {
            let watch = DispatchSource.makeTimerSource()
            watch.schedule(deadline: .now() + 5, repeating: 5)
            watch.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let expired = self.watchdog.expired(now: ProcessInfo.processInfo.systemUptime)
                if expired { self.closeReason = .idleTimeout; self.cancellationCause = self.cancellationCause ?? .watchdog }
                self.lock.unlock()
                if expired { self.task.cancel() }
            }
            self.watch = watch; watch.resume()
        }
        session.finishTasksAndInvalidate()
    }

    /// Response headers, once they arrive.
    public func headers() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let response { lock.unlock(); c.resume(returning: response); return }
            if let responseError { lock.unlock(); c.resume(throwing: responseError); return }
            responseWaiters.append(c)
            lock.unlock()
        }
    }

    /// Read the whole body (for error messages and non-streaming responses).
    public func collect(limit: Int = 64 * 1024 * 1024, onChunk: ((Int) -> Void)? = nil) async throws -> Data {
        var all = Data()
        for try await chunk in chunks {
            onChunk?(chunk.count)
            all.append(chunk)
            if all.count > limit { cancel(); throw HTTPError.tooLarge }
        }
        return all
    }

    /// Attribution only; callers can mark ownership before an existing task cancellation propagates.
    public func markCancellation(_ cause: StreamCancellationCause) { lock.lock(); if cancellationCause == nil { cancellationCause = cause }; lock.unlock() }
    public func cancel(cause: StreamCancellationCause = .explicit) { markCancellation(cause); lock.lock(); if closeReason == nil { closeReason = .cancelled }; lock.unlock(); task?.cancel() }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        lock.lock()
        self.response = http
        let waiters = responseWaiters
        responseWaiters = []
        lock.unlock()
        if diagnosticStage != .other { diagnostics.record(diagnosticStage, .ready, since: started, status: http.statusCode, attempt: attempt, callBank: diagnosticStage == .tts ? callToken : nil) }
        waiters.forEach { $0.resume(returning: http) }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Includes SSE comments: heartbeat is transport liveness, not an event.
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); receivedBytes += data.count; watchdog.received(now: now)
        let first = diagnosticStage == .tts && transfer.receive(bytes: data.count, now: now)
        let timing = first ? transfer.fields(now: now) : nil
        lock.unlock()
        if let timing { diagnostics.record(.tts, .ready, audio: CaptureSnapshot(timing), attempt: attempt, playbackEvent: .ttsFirstByte, callBank: callToken) }
        guard data.count <= 1024 * 1024 else { continuation.finish(throwing: HTTPError.tooLarge); cancel(); return }
        switch continuation.yield(data) {
        case .dropped: continuation.finish(throwing: HTTPError.tooLarge); cancel()
        case .terminated: cancel()
        case .enqueued: break
        @unknown default: continuation.finish(throwing: HTTPError.tooLarge); cancel()
        }
    }

    /// Never forward a device bearer to another origin (or silently redirect a mutation).
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        watch?.cancel()
        lock.lock(); let reason = closeReason ?? (error == nil ? .cleanEnd : ((error as NSError?)?.code == NSURLErrorTimedOut ? .idleTimeout : .transport)); let cause = cancellationCause
        var timing = transfer.fields(now: ProcessInfo.processInfo.systemUptime)
        timing[.streaming] = ttsStreaming.map { $0 ? 1 : 0 } ?? -1
        lock.unlock()
        if diagnosticStage != .other { diagnostics.record(diagnosticStage, error == nil ? .complete : .failed, since: started, status: error.map(StageDiagnostics.code), audio: diagnosticStage == .tts ? CaptureSnapshot(timing) : nil, attempt: attempt, initiator: reason == .cancelled ? .client : (reason == .idleTimeout ? .watchdog : .peer), reason: reason, cancellationCause: cause, playbackEvent: diagnosticStage == .tts ? .ttsComplete : nil, callBank: diagnosticStage == .tts ? callToken : nil) }
        lock.lock()
        let waiters = response == nil ? responseWaiters : []
        if response == nil { responseError = error ?? HTTPError.noResponse; responseWaiters = [] }
        let failure = responseError
        lock.unlock()
        if let failure { waiters.forEach { $0.resume(throwing: failure) } }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}

public enum HTTPError: Error, LocalizedError {
    case noResponse, tooLarge
    case status(Int, String)
    public var errorDescription: String? {
        switch self {
        case .noResponse: return "No response from server"
        case .tooLarge: return "Response exceeds limit"
        case let .status(code, body): return "HTTP \(code): \(body.prefix(200))"
        }
    }
}

/// Parses `text/event-stream` bytes into the `data:` payload of each event.
public struct SSEParser {
    private var buffer = Data()
    public private(set) var exceededLimit = false
    public init() {}

    public mutating func push(_ chunk: Data) -> [String] {
        guard !exceededLimit else { return [] }
        guard buffer.count + chunk.count <= 256 * 1024 else { buffer = Data(); exceededLimit = true; return [] }
        buffer.append(chunk)
        var out: [String] = []
        while let end = Self.blockEnd(buffer) {
            let block = buffer.subdata(in: buffer.startIndex..<end.start)
            buffer = buffer.subdata(in: end.next..<buffer.endIndex)
            guard let text = String(data: block, encoding: .utf8) else { continue }
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            let data = lines.filter { $0.hasPrefix("data:") }.map { line -> String in
                var s = String(line.dropFirst(5))
                if s.hasPrefix(" ") { s.removeFirst() }
                return s
            }
            if !data.isEmpty { out.append(data.joined(separator: "\n")) }
        }
        return out
    }

    private static func blockEnd(_ d: Data) -> (start: Data.Index, next: Data.Index)? {
        let found = [d.range(of: Data([10, 10])), d.range(of: Data([13, 10, 13, 10]))].compactMap { $0 }
        guard let first = found.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        return (first.lowerBound, first.upperBound)
    }
}
