#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Rewrites ONLY the synthetic HTTPS host to our fixed loopback fake broker. Not compiled for phone builds.
final class CanvasFixtureProtocol: URLProtocol, URLSessionDataDelegate {
    private var forwardedTask: URLSessionDataTask?
    private var forwardedSession: URLSession?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "canvas-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var forwarded = request
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.scheme = "http"; url.host = "127.0.0.1"; url.port = 18424
        forwarded.url = url.url
        if forwarded.httpBody == nil, let stream = forwarded.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
            forwarded.httpBody = bytes
        }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        forwardedSession = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        forwardedTask = forwardedSession?.dataTask(with: forwarded)
        forwardedTask?.resume()
    }
    override func stopLoading() { forwardedTask?.cancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { client?.urlProtocol(self, didLoad: data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { client?.urlProtocol(self, didFailWithError: error) } else { client?.urlProtocolDidFinishLoading(self) }
        session.finishTasksAndInvalidate()
    }
}
private final class CanvasFixtureCredential: DeviceCredentialStore {
    func load() throws -> String? { "synthetic-phone" }
    func save(_ credential: String) throws {}
    func clear() throws {}
}
enum CanvasShowFixture {
    @MainActor static func seed(_ model: PhoneModel, mode: String) async throws {
        let format = mode.hasSuffix("html") ? "html" : "openui"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CanvasFixtureProtocol.self]
        let transport = try BridgeTransport(base: URL(string: "https://canvas-fixture.invalid/floating-voice")!, credentials: CanvasFixtureCredential(), configuration: config)
        let backend = RemoteSessionBackend(transport: transport)
        try await backend.select("ses_" + format)
        model.installFixtureBackend(backend); model.paired = true; model.selection = "ses_" + format
        let result = try await transport.json("/v1/sessions/ses_\(format)/messages", lease: backend.lease)
        let records = try (result["data"] as? [[String: Any]] ?? []).map { try JSONSerialization.data(withJSONObject: $0) }
        model.messages = records.compactMap(MessageRow.init)
        model.canvasMessages = model.messages
        model.historyVisible = true
        _ = model.surface.replaceBinding(target: backend.lease!)
        model.surface.update(records: records, connection: "connected", active: false)
    }
}
#endif
