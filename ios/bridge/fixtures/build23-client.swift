// Test-only adapter + driver. All application core sources are extracted byte-for-byte
// from build 23 by build23-compat.test.mjs. No Keychain, device, TLS trust edits or live service.
import Foundation

final class Build23Loopback: URLProtocol, URLSessionDataDelegate {
    static var port = 0
    private var forwarded: URLSessionDataTask?
    private var session: URLSession?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "build23-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.scheme = "http"; url.host = "127.0.0.1"; url.port = Self.port; request.url = url.url
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
            request.httpBody = bytes
        }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        forwarded = session?.dataTask(with: request); forwarded?.resume()
    }
    override func stopLoading() { forwarded?.cancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { client?.urlProtocol(self, didLoad: data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { client?.urlProtocol(self, didFailWithError: error) } else { client?.urlProtocolDidFinishLoading(self) }
        session.finishTasksAndInvalidate()
    }
}
final class Build23Credential: DeviceCredentialStore {
    func load() throws -> String? { "synthetic-build23-phone" }
    func save(_ credential: String) throws {}
    func clear() throws {}
}
func require23(_ ok: Bool, _ message: String) throws {
    if !ok { throw ClientError(message) }
}
func clean23(_ value: Any) throws {
    let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let text = String(decoding: bytes, as: UTF8.self)
    for denied in ["SYNTHETIC_VIEWER_TOKEN", "SYNTHETIC_WRAPPED_TOKEN", "unlearned.fixture.ts.net", "opaque-viewer.fixture.invalid", "DO_NOT_PROJECT_SOURCE", "OTHER_SESSION_SECRET"] {
        try require23(!text.contains(denied), "Projection leaked synthetic sentinel: " + denied)
    }
}
@main struct Build23CompatibilityClient {
    @MainActor static func main() async throws {
        Build23Loopback.port = Int(CommandLine.arguments[1])!
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Build23Loopback.self]
        let transport = try BridgeTransport(base: URL(string: "https://build23-fixture.invalid/floating-voice")!, credentials: Build23Credential(), configuration: config)
        let backend = RemoteSessionBackend(transport: transport)
        _ = try await backend.connect()
        try require23(try await backend.chief() == "ses_compat23", "chief route")
        try require23(try await backend.listSessions().contains { $0.id == "ses_compat23" }, "session list")
        var observed: [ServerEvent] = []
        backend.onRemoteEvent = { observed.append($0) }
        try await backend.select("chief")
        let lease = try await backend.targetLease(sessionID: "ses_compat23")
        try await backend.waitForAuthoritativeCatchUp(lease)
        let history = try await transport.json("/v1/sessions/ses_compat23/messages?limit=100&order=desc", lease: lease)
        try clean23(history)
        try require23(String(decoding: JSONSerialization.data(withJSONObject: history), as: UTF8.self).contains("apple.com"), "ordinary HTTPS link lost")
        let records = history["data"] as! [[String: Any]]
        let projected = records.first { $0["id"] as? String == "msg_canvas_fixture" }!
        let tool = (projected["content"] as! [[String: Any]])[1]
        try require23((tool["state"] as? [String: Any])?["content"] == nil, "canvas_show content not dropped")
        let row = MessageRow(try JSONSerialization.data(withJSONObject: projected))!
        try require23(row.body.contains { $0.label?.contains("canvas_show") == true && $0.reference == nil }, "build23 must retain collapsed tool row, not decode a new panel")
        print("build23 history PASS: projected URLs/source absent, canvas_show collapsed row")

        // No prompt or mutation refresh can account for this read: the old backend
        // must repair its initial history after the new bridge's legacy skip hint.
        let deadline = Date().addingTimeInterval(6)
        while !(backend.store?.records.contains { String(decoding: $0, as: UTF8.self).contains("msg_after_skip") } ?? false), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require23(backend.store?.records.contains { String(decoding: $0, as: UTF8.self).contains("msg_after_skip") } == true, "skip hint did not repair old backend history")
        try require23(observed.contains { $0.type == "session.inbox.delivered" }, "old client did not consume skip hint")

        let policy = ReachOutPolicy(callsEnabled: true, quietHoursEnabled: false, timeZone: "UTC")
        let settings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String: Any]
        _ = try await transport.json("/v1/push/enrollment", method: "PUT", body: ["alertToken": String(repeating: "a", count: 64), "voipToken": String(repeating: "b", count: 64), "environment": "sandbox", "build": "23", "revision": 1])
        _ = try await transport.json("/v1/push/settings", method: "PUT", body: settings)
        let saved = try await transport.json("/v1/push/settings")
        let acknowledged = try JSONDecoder().decode(ReachOutPolicy.self, from: JSONSerialization.data(withJSONObject: saved["settings"] as Any))
        var sync = PushPolicySync(policy: policy)
        try require23(sync.acknowledge(acknowledged, at: Date()) && sync.synced, "old push settings ACK decoder")
        try await backend.prompt(target: lease, text: "Synthetic build23 compatibility prompt", delivery: .queue)
        try await backend.admit(target: lease, text: "Synthetic build23 admission")
        try await backend.prompt(target: lease, text: "Synthetic build23 default prompt", delivery: nil)
        try require23(try await backend.interrupt(target: lease), "interrupt result")
        let ready = try await transport.json("/v1/push/reachouts/compat-ready")
        let context = try ReachOutContext(record: ready, reachoutID: "compat-ready")
        try require23(context.session == lease.sessionID && context.reviewURL.flatMap { LinkPolicy().install($0) } != nil, "structured install context")
        let opened = PendingPushReceipt(reachoutID: "compat-ready", call: nil, receipt: CallReceipt(.notificationOpened))
        _ = try await transport.json("/v1/push/events", method: "POST", body: opened.body())
        let call = try await transport.json("/v1/push/reachouts/compat-call")
        let callID = UUID(uuidString: call["callUUID"] as! String)!
        for event in [CallReceipt.Event.reported, .ringing, .answered, .ended] {
            let receipt = event == .ended ? CallReceipt(event, reason: .requested, initiator: .app, reportedRinging: true) : CallReceipt(event)
            let entry = PendingPushReceipt(reachoutID: "compat-call", call: callID, receipt: receipt)
            _ = try await transport.json("/v1/push/events", method: "POST", body: entry.body())
            if event == .ended { _ = try await transport.json("/v1/push/events", method: "POST", body: entry.body()) }
        }
        let reconnectDeadline = Date().addingTimeInterval(6)
        while !(backend.store?.records.contains { String(decoding: $0, as: UTF8.self).contains("msg_after_rotation") } ?? false), Date() < reconnectDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require23(backend.store?.records.contains { String(decoding: $0, as: UTF8.self).contains("msg_after_rotation") } == true, "old backend did not automatically reconnect/resync after rotation")
        for event in observed { try clean23(event.data) }
        backend.disconnect()
        print("build23 routes PASS: selection, prompt, interrupt, push enrollment/settings/context, legacy receipts and replay")
        print("build23 backend PASS: skip hint repaired history, projected events accepted, rotation auto-reconnected/resynced without prompt replay")

        try await backend.select("ses_compat23")
        let streamLease = try await backend.targetLease(sessionID: "ses_compat23")
        backend.disconnect()
        for attempt in 1...2 {
            let request = try transport.request("/v1/sessions/ses_compat23/events", lease: streamLease)
            let stream = transport.stream(request)
            try require23(try await stream.headers().statusCode == 200, "event headers")
            var parser = SSEParser(), bytes = Data(), events: [ServerEvent] = []
            for try await chunk in stream.chunks {
                bytes.append(chunk)
                for json in parser.push(chunk) {
                    if let event = ServerEvent(json: json) {
                        events.append(event); try clean23(event.data)
                        if event.type == "fixture.projection" {
                            let record = event.data["record"] as! [String: Any]
                            let tool = (record["content"] as! [[String: Any]])[1]
                            try require23((tool["state"] as! [String: Any])["content"] == nil, "event canvas_show content not dropped")
                        }
                    }
                }
            }
            try require23(!parser.exceededLimit, "SSE parser overflow")
            try require23(String(decoding: bytes, as: UTF8.self).contains(": heartbeat"), "missing heartbeat")
            try require23(events.contains { $0.type == "fixture.projection" }, "missing projected event")
            try require23(events.contains { $0.type == "session.inbox.delivered" && $0.data.count == 1 }, "skip hint shape changed")
            print("build23 stream=\(attempt) PASS: heartbeats ignored as events, skip hint accepted, clean rotation EOF")
        }
        print("BUILD23_BUILD24_COMPATIBILITY_PASS")
    }
}
