import Foundation

#if DEBUG
// No pin, anchor, hostname policy or runtime switch exists in the production module.
// Tests supply policy through @testable access; public factories never populate it.
typealias OpenVoiceTestTLSChallenge = (URLAuthenticationChallenge, @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void
#endif

/// Internal callback seam for deterministic adapter tests, not a TLS/trust override.
@MainActor protocol OpenVoiceSocketTask: AnyObject {
    func resume()
    func send(_ text: String, completion: @escaping (Error?) -> Void)
    func receive(completion: @escaping (Result<Data, Error>) -> Void)
    func ping(completion: @escaping (Error?) -> Void)
    func cancel()
}

@MainActor final class OpenVoiceSocketLifecycle: NSObject, URLSessionWebSocketDelegate {
    var opened: (() -> Void)?
    var ended: (() -> Void)?
#if DEBUG
    var testTLSChallenge: OpenVoiceTestTLSChallenge?
#endif
    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
#if DEBUG
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let handler = testTLSChallenge else { return false }
                handler(challenge, completionHandler); return true
            }
            if handled { return }
        }
#endif
        completionHandler(.performDefaultHandling, nil)
    }
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated { if `protocol` == nil { opened?() } else { ended?() } }
    }
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        MainActor.assumeIsolated { ended?() }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { ended?() }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward Authorization, even to another same-origin URL.
        MainActor.assumeIsolated { ended?() }
    }
}

@MainActor private final class OpenVoiceSystemSocketTask: OpenVoiceSocketTask {
    let task: URLSessionWebSocketTask
    let session: URLSession
    init(request: URLRequest, configuration: URLSessionConfiguration, lifecycle: OpenVoiceSocketLifecycle) {
        session = URLSession(configuration: configuration, delegate: lifecycle, delegateQueue: .main)
        task = session.webSocketTask(with: request); task.maximumMessageSize = OpenVoiceWire.maxMessageBytes
    }
    func resume() { task.resume() }
    func send(_ text: String, completion: @escaping (Error?) -> Void) {
        task.send(.string(text), completionHandler: completion)
    }
    func receive(completion: @escaping (Result<Data, Error>) -> Void) {
        task.receive { result in
            completion(result.flatMap { message in
                switch message {
                case .string(let s): return .success(Data(s.utf8))
                // The profile is JSON text frames only, never binary frames.
                case .data: return .failure(OpenVoiceFailure("invalid_request"))
                @unknown default: return .failure(OpenVoiceFailure("unsupported_feature"))
                }
            })
        }
    }
    func ping(completion: @escaping (Error?) -> Void) { task.sendPing(pongReceiveHandler: completion) }
    func cancel() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}

#if DEBUG
/// Returns the actual system task/delegate path, not a fake; a test-target decorator
/// may delay only delivery of its real send completion. Absent from Release.
@MainActor func openVoiceTestSystemTask(request: URLRequest, configuration: URLSessionConfiguration,
                                       lifecycle: OpenVoiceSocketLifecycle) -> OpenVoiceSocketTask {
    OpenVoiceSystemSocketTask(request: request, configuration: configuration, lifecycle: lifecycle)
}
#endif

enum OpenVoiceURLSessionPolicy {
    static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCredentialStorage = nil
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = timeout; c.timeoutIntervalForResource = timeout
        c.httpMaximumConnectionsPerHost = 1
        return c
    }
    static func origin(_ url: URL) throws -> URL {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw OpenVoiceFailure() }
        try OpenVoiceWire.check(c.scheme == "https" && c.host != nil && c.user == nil && c.password == nil && c.query == nil && c.fragment == nil && (c.path.isEmpty || c.path == "/"))
        return url
    }
}

/// Explicit open only. Dedicated ephemeral URLSession, system TLS only, no redirects,
/// cookies, shared credentials, reconnect or retries. One send and one receive at most.
@MainActor public final class OpenVoiceURLSessionSocket: OpenVoiceWebSocket {
    public private(set) var writableBytes = 0
    public private(set) var isOpen = false
    private var closed = false, opening = false
    private let task: OpenVoiceSocketTask
    private let lifecycle: OpenVoiceSocketLifecycle
    private let timeout: TimeInterval
    private let attachmentExpiresAt: Date
    private let attachmentClock: () -> Date
    private let leaseOwner: OpenVoiceRecipientOwner
    private let mediaEpoch: String
    private let attachmentOrigin: URL
    private var openWaiter: CheckedContinuation<Void, Error>?
    private var sendWaiter: CheckedContinuation<Void, Error>?
    private var receiveWaiter: CheckedContinuation<Data, Error>?
    private var openTimer: DispatchWorkItem?, sendTimer: DispatchWorkItem?
    private var heartbeat: DispatchSourceTimer?, pongTimer: DispatchWorkItem?
    private var pingID: UUID?
    private var sendID: UUID?, receiveID: UUID?
    private let heartbeatInterval: TimeInterval, pongDeadline: TimeInterval

    public convenience init(origin: URL, lease: OpenVoiceMediaLease, now: Date = Date()) throws {
        try self.init(origin: origin, lease: lease, now: now, timeout: 10, clock: Date.init) { request, config, lifecycle in
            OpenVoiceSystemSocketTask(request: request, configuration: config, lifecycle: lifecycle)
        }
    }
    init(origin: URL, lease: OpenVoiceMediaLease, now: Date, timeout: TimeInterval, clock: (() -> Date)? = nil,
         heartbeatInterval: TimeInterval = 5, pongDeadline: TimeInterval = 10,
         makeTask: (URLRequest, URLSessionConfiguration, OpenVoiceSocketLifecycle) -> OpenVoiceSocketTask) throws {
        _ = try OpenVoiceURLSessionPolicy.origin(origin)
        try OpenVoiceWire.check(origin == lease.origin && lease.expiresAt > now && timeout > 0 && timeout <= 60)
        try OpenVoiceWire.check(heartbeatInterval > 0 && pongDeadline > 0 && heartbeatInterval <= 60 && pongDeadline <= 60)
        var c = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        c.scheme = "wss"; c.path = "/floating-voice/v1/realtime"; c.query = "model=local-chain-m1"
        let request = try OpenVoiceClient.mediaRequest(origin: origin, endpoint: c.url!, recipientMediaLease: lease.bearer)
        self.timeout = timeout; attachmentExpiresAt = lease.expiresAt; attachmentClock = clock ?? { now }
        self.heartbeatInterval = heartbeatInterval; self.pongDeadline = pongDeadline
        leaseOwner = lease.owner; mediaEpoch = lease.epoch; attachmentOrigin = origin; lifecycle = OpenVoiceSocketLifecycle()
        let config = OpenVoiceURLSessionPolicy.configuration(timeout: timeout)
        // Do not turn a control-HTTP resource deadline into a socket receive-idle
        // policy. URLSession's default resource lifetime is retained after upgrade;
        // our explicit open/send and ping deadlines bound transport work instead.
        config.timeoutIntervalForResource = URLSessionConfiguration.ephemeral.timeoutIntervalForResource
        task = makeTask(request, config, lifecycle)
        lifecycle.opened = { [weak self] in self?.didOpen() }
        lifecycle.ended = { [weak self] in self?.close() }
    }
    func matches(_ lease: OpenVoiceMediaLease) -> Bool { leaseOwner == lease.owner && mediaEpoch == lease.epoch && attachmentOrigin == lease.origin }
    private func watchdog() -> DispatchWorkItem {
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item); return item
    }
    public func open() async throws {
        try OpenVoiceWire.check(!closed && !opening && !isOpen && attachmentExpiresAt > attachmentClock(), "local_failure"); opening = true
        defer { if Task.isCancelled { close() } }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { openWaiter = $0; openTimer = watchdog(); task.resume() }
            try Task.checkCancellation()
        }, onCancel: { [weak self] in DispatchQueue.main.async { self?.close() } })
    }
    private func didOpen() {
        guard !closed && opening else { return }
        opening = false; isOpen = true; openTimer?.cancel(); openTimer = nil
        startHeartbeat()
        let waiter = openWaiter; openWaiter = nil; waiter?.resume()
    }
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.checkTransport() } }
        heartbeat = timer; timer.resume()
    }
    private func checkTransport() {
        guard isOpen && !closed && pingID == nil else { return }
        let id = UUID(); pingID = id
        let deadline = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
            guard let self, self.pingID == id && !self.closed else { return }; self.close()
        } }
        pongTimer = deadline; DispatchQueue.main.asyncAfter(deadline: .now() + pongDeadline, execute: deadline)
        task.ping { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pingID == id && !self.closed else { return }
                if error != nil { self.close(); return }
                self.pingID = nil; self.pongTimer?.cancel(); self.pongTimer = nil
                // Transport liveness ONLY: no event, readiness, credit, ASR or progress effect.
            }
        }
    }
    public func send(text: String) async throws {
        defer { if Task.isCancelled { close() } }
        try OpenVoiceWire.check(isOpen && !closed && sendWaiter == nil, "local_failure")
        try OpenVoiceWire.check(text.utf8.count <= OpenVoiceWire.maxMessageBytes, "message_too_large")
        let id = UUID(); sendID = id; writableBytes = text.utf8.count
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sendWaiter = continuation; sendTimer = watchdog()
                task.send(text) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self, self.sendID == id && !self.closed else { return }
                        if error != nil { self.close(); return }
                        self.sendID = nil; self.writableBytes = 0; self.sendTimer?.cancel(); self.sendTimer = nil
                        let waiter = self.sendWaiter; self.sendWaiter = nil; waiter?.resume()
                    }
                }
            }
            try Task.checkCancellation()
        }, onCancel: { [weak self] in DispatchQueue.main.async { self?.close() } })
    }
    public func receive() async throws -> Data {
        defer { if Task.isCancelled { close() } }
        try OpenVoiceWire.check(isOpen && !closed && receiveWaiter == nil, "local_failure")
        let id = UUID(); receiveID = id
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                receiveWaiter = continuation // Healthy application-message silence is not a failure.
                task.receive { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, self.receiveID == id && !self.closed else { return }
                        guard case .success(let data) = result, data.count <= OpenVoiceWire.maxMessageBytes else { self.close(); return }
                        self.receiveID = nil
                        let waiter = self.receiveWaiter; self.receiveWaiter = nil; waiter?.resume(returning: data)
                    }
                }
            }
            try Task.checkCancellation(); return data
        }, onCancel: { [weak self] in DispatchQueue.main.async { self?.close() } })
    }
    public func close() {
        guard !closed else { return }; closed = true; isOpen = false; opening = false
        openTimer?.cancel(); sendTimer?.cancel(); heartbeat?.cancel(); pongTimer?.cancel()
        openTimer = nil; sendTimer = nil; heartbeat = nil; pongTimer = nil; pingID = nil
        sendID = nil; receiveID = nil; writableBytes = 0
        task.cancel()
        let o = openWaiter, s = sendWaiter, r = receiveWaiter
        openWaiter = nil; sendWaiter = nil; receiveWaiter = nil
        let failure = OpenVoiceFailure("local_failure")
        o?.resume(throwing: failure); s?.resume(throwing: failure); r?.resume(throwing: failure)
    }
}
