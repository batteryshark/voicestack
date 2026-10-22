import Foundation
import Testing
@testable import FloatingVoiceCore

private final class RouteCredential: DeviceCredentialStore {
    func load() throws -> String? { String(repeating: "t", count: 43) }
    func save(_ value: String) throws {}
    func clear() throws {}
}
private final class RouteProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((RouteProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func headers() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
    }
    func json(_ value: [String: Any]) {
        headers(); client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value)); client?.urlProtocolDidFinishLoading(self)
    }
}
private final class RouteFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var event: RouteProtocol?, first: RouteProtocol?
    private var reads = 0
    var delayed = false
    var repeatPages = false
    var oldParts: [[String: Any]] = [["type":"text", "text":"Older reply."]]
    func handle(_ p: RouteProtocol) {
        let path = p.request.url!.path
        if path.hasSuffix("selection") { p.json(["generation": "route"]); return }
        if path.hasSuffix("events") {
            lock.lock(); event = p; let held = delayed; lock.unlock()
            if !held { p.headers() }; return
        }
        if path.hasSuffix("state") { p.json(["active": false]); return }
        let cursor = URLComponents(url: p.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
        lock.lock(); reads += 1
        if delayed && reads == 1 { first = p; lock.unlock(); return }
        lock.unlock()
        if delayed { p.json(["data": [["id":"first", "type":"user", "text":"In-flight explicit read."]]]); return }
        if cursor != nil && !repeatPages { p.json(["data": [["id":"old", "type":"assistant", "content":oldParts]]]); return }
        let number = Int(cursor ?? "0") ?? 0
        p.json(["data": (0..<40).map { ["id":"new-\(number)-\($0)", "type":"user", "text":"Latest page."] }, "cursor":["next":String(number+1)]])
    }
    var hasHeldRequests: Bool { lock.lock(); defer { lock.unlock() }; return event != nil && first != nil }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func releaseHeaders() { lock.lock(); let p = event; lock.unlock(); p?.headers() }
    func releaseFirstHistory() { lock.lock(); let p = first; lock.unlock(); p?.json(["data": [["id":"first", "type":"user", "text":"In-flight explicit read."]]]) }
}

@Suite(.serialized) @MainActor struct NotificationRoutingTests {
    private func backend(_ fixture: RouteFixture) throws -> RemoteSessionBackend {
        RouteProtocol.handler = { fixture.handle($0) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RouteProtocol.self]
        return RemoteSessionBackend(transport: try BridgeTransport(base: URL(string: "https://example.test/floating-voice")!, credentials: RouteCredential(), configuration: configuration))
    }
    @Test func delayedSSEHeadersCannotInvalidateAnAlreadyReadingHistorySnapshot() async throws {
        let fixture = RouteFixture(); fixture.delayed = true
        let remote = try backend(fixture)
        defer { remote.disconnect(); RouteProtocol.handler = nil }
        try await remote.select("ses_route")
        let target = try #require(remote.lease)
        let explicitRead = Task { try await remote.reconcile(target) }
        #expect(await waitUntil { fixture.hasHeldRequests })
        fixture.releaseHeaders()
        #expect(await waitUntil { remote.connection == "catching up" })
        fixture.releaseFirstHistory()
        // Before the fix this throws Stale history epoch, exactly like the phone tap.
        try await explicitRead.value
        try await remote.waitForAuthoritativeCatchUp(target)
        #expect(remote.connection == "connected" && fixture.readCount == 2)
    }
    @Test func olderMessageIsLocatedOnlyAfterAuthoritativeCatchUp() async throws {
        let fixture = RouteFixture(), remote = try backend(fixture)
        defer { remote.disconnect(); RouteProtocol.handler = nil }
        try await remote.select("ses_route")
        let target = try #require(remote.lease)
        try await remote.locateMessage("old", target: target)
        #expect(fixture.readCount == 2)
        #expect(remote.store?.records.compactMap(MessageRow.init).contains { $0.id == "old" } == true)
        #expect(remote.connection == "connected")
    }
    @Test func olderPagingIsBoundedAndStaleLeaseCannotPresent() async throws {
        let fixture = RouteFixture(); fixture.repeatPages = true
        let remote = try backend(fixture)
        defer { remote.disconnect(); RouteProtocol.handler = nil }
        try await remote.select("ses_route")
        let target = try #require(remote.lease)
        do { try await remote.locateMessage("missing", target: target, maxOlderPages: 2); Issue.record("Unbounded/missing target accepted") }
        catch { #expect(error as? NotificationRouteFailure == .olderPageLimit) }
        #expect(fixture.readCount == 3)
        remote.disconnect()
        do { try await remote.waitForAuthoritativeCatchUp(target); Issue.record("Stale target accepted") }
        catch { #expect(error as? NotificationRouteFailure == .targetChanged) }
    }
    @Test func olderToolAndHiddenRawTargetBothPageBeforeVisibleAnchorResolution() async throws {
        for parts in [[["type":"tool","state":["status":"completed","content":[]]]], [["type":"text","text":"  "]]] as [[[String:Any]]] {
            let fixture = RouteFixture(); fixture.oldParts = parts
            let remote = try backend(fixture)
            try await remote.select("ses_route")
            let target = try #require(remote.lease)
            try await remote.locateMessage("old",target:target)
            #expect(fixture.readCount == 2)
            let anchor = try #require(HistoryAnchor.resolve("old",records:remote.store?.records ?? []))
            #expect(anchor.sourceID == "old")
            if parts[0]["type"] as? String == "tool" { #expect(anchor.rowID == "old" && anchor.kind == .work) }
            else { #expect(anchor.rowID != "old" && anchor.kind == .neighbour) }
            remote.disconnect(); RouteProtocol.handler = nil
        }
    }
    @Test func closedRouteFailureDoesNotExportSensitiveErrorTextAndOldEntriesDecode() async throws {
        let diagnostics = StageDiagnostics()
        do {
            try await NotificationRouting.step(.message, diagnostics: diagnostics) { throw NotificationRouteFailure.messageUnavailable }
        } catch {}
        do {
            try await NotificationRouting.step(.lookup, diagnostics: diagnostics) { throw ClientError("SECRET_URL_TOKEN_MESSAGE") }
        } catch {}
        let output = diagnostics.export()
        #expect(output.contains("messageUnavailable") && output.contains("notificationRoute") && !output.contains("SECRET"))
        let old = Data("[{\"time\":0,\"stage\":\"history\",\"category\":\"complete\",\"elapsedMs\":1,\"protectedData\":true}]".utf8)
        #expect(try JSONDecoder().decode([DiagnosticEntry].self, from: old).first?.routeFailure == nil)
    }
    @Test func routeFailuresAreNotMisrepresentedAsNetworkLoss() {
        #expect(PrincipalError.message("Notification: Couldn't open that message", captureRunning: false) == "Couldn't open that message. Check History or try again.")
        #expect(PrincipalError.message("This reach-out is expired or unavailable. Reconnect and check History.", captureRunning: false) != "Connection lost")
        #expect(PrincipalError.message("Invalid connection state", captureRunning: false) != "Connection lost")
        #expect(PrincipalError.message("Network connection lost (-1005)", captureRunning: false) == "Connection lost")
    }
}
