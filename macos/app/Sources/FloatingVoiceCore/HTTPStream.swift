import Foundation

/// One HTTP request whose body is delivered chunk by chunk as it arrives (SSE, streamed speech).
/// The body is read eagerly into the stream's buffer, so a slow consumer never holds up the server.
public final class HTTPChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public let chunks: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var response: HTTPURLResponse?
    private var responseError: Error?
    private var responseWaiters: [CheckedContinuation<HTTPURLResponse, Error>] = []
    private var session: URLSession!
    private var task: URLSessionDataTask!
    private let streamIdleTimeout: TimeInterval?
    private var idleWatch: DispatchWorkItem?
    private var idleGeneration = 0
    private var completed = false

    /// idleTimeout: seconds without any data before the request fails.
    /// streamIdleTimeout: optional shorter inactivity limit once body data starts arriving. Unlike a resource
    /// timeout this is reset on every chunk, so active streams may run for longer than the startup budget.
    public init(_ request: URLRequest, idleTimeout: TimeInterval, resourceTimeout: TimeInterval = 7 * 24 * 3600,
                streamIdleTimeout: TimeInterval? = nil, configuration: URLSessionConfiguration? = nil) {
        self.streamIdleTimeout = streamIdleTimeout
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        chunks = AsyncThrowingStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        super.init()
        let config = configuration?.copy() as? URLSessionConfiguration ?? .ephemeral
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        task = session.dataTask(with: request)
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.cancel() }
        }
        task.resume()
        session.finishTasksAndInvalidate()
    }

    /// Response headers, once they arrive.
    public func headers() async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler { try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let response { lock.unlock(); c.resume(returning: response); return }
            if let responseError { lock.unlock(); c.resume(throwing: responseError); return }
            responseWaiters.append(c)
            lock.unlock()
        } } onCancel: { self.cancel() }
    }

    /// Read the whole body (for error messages and non-streaming responses).
    public func collect(limit: Int = 64 * 1024 * 1024) async throws -> Data {
        var all = Data()
        for try await chunk in chunks {
            all.append(chunk)
            if all.count > limit { cancel(); throw HTTPError.tooLarge }
        }
        return all
    }

    public func cancel() {
        stopIdleWatch()
        task?.cancel()
    }

    private func stopIdleWatch() {
        lock.lock()
        completed = true
        idleGeneration += 1
        idleWatch?.cancel(); idleWatch = nil
        lock.unlock()
    }

    private func noteData() {
        guard let seconds = streamIdleTimeout else { return }
        lock.lock()
        guard !completed else { lock.unlock(); return }
        idleGeneration += 1
        let generation = idleGeneration
        idleWatch?.cancel()
        let watch = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.completed, self.idleGeneration == generation else { self.lock.unlock(); return }
            self.completed = true
            self.idleWatch = nil
            self.lock.unlock()
            self.continuation.finish(throwing: HTTPError.streamIdleTimeout(seconds))
            self.task.cancel()
        }
        idleWatch = watch
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: watch)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        lock.lock()
        self.response = http
        let waiters = responseWaiters
        responseWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume(returning: http) }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !data.isEmpty { noteData() }
        continuation.yield(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stopIdleWatch()
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
    case streamIdleTimeout(TimeInterval)
    public var errorDescription: String? {
        switch self {
        case .noResponse: return "No response from server"
        case .tooLarge: return "Response exceeds limit"
        case let .status(code, body): return "HTTP \(code): \(body.prefix(200))"
        case let .streamIdleTimeout(seconds): return "Audio stream stalled: no data for \(seconds) s. Try again."
        }
    }
}

/// Parses `text/event-stream` bytes into the `data:` payload of each event.
public struct SSEParser {
    private var buffer = Data()
    public init() {}

    public mutating func push(_ chunk: Data) -> [String] {
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
