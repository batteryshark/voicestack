import Foundation
import Testing
@testable import FloatingVoiceCore

private final class OC240Credential: DeviceCredentialStore {
    func load() throws -> String? { String(repeating: "s", count: 43) }
    func save(_ credential: String) throws {}
    func clear() throws {}
}
private final class OC240Protocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// Captured DTOs through the SAME Node projection + Swift parsers as installed31.
/// No live requests, real credentials, microphone, phone, or simulator are used.
@Suite(.serialized) @MainActor struct OpenChamber240CompatibilityTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func fixture() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shared/opencode240-fixture.json"))) as! [String: Any]
    }
    private func page(_ name: String, projected: Bool = true) throws -> Data {
        if !projected { return try json(fixture()[name]!) }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = root
        process.arguments = ["node", "--input-type=module", "-e", "import fs from 'node:fs'; import { phoneProjection } from './bridge/rich-content.mjs'; const f=JSON.parse(fs.readFileSync('shared/opencode240-fixture.json')); console.log(JSON.stringify(phoneProjection(f[process.argv[1]])));", name]
        process.standardOutput = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return bytes
    }
    private func toolEvent(sessionID: String) throws -> ServerEvent {
        let shape = try fixture()["toolInputEndedShape"] as! [String: Any]
        let object: [String: Any] = ["id": "evt_input", "created": 1, "type": shape["type"]!,
            "location": ["directory": "/synthetic"],
            "data": ["sessionID": sessionID, "assistantMessageID": "msg_tool", "id": "tool_one", "text": "Synthetic tool input must not be narrated."],
            "durable": ["aggregateID": sessionID, "seq": 1, "version": 1]]
        #expect(Set(object.keys) == Set(shape.keys))
        return try #require(ServerEvent(json: String(data: json(object), encoding: .utf8)!))
    }

    @Test(arguments: [false, true]) func capturedIdlePagesRemainRawButNeverRenderOrNarrate(_ projected: Bool) throws {
        let sid = try fixture()["sessionID"] as! String
        let lease = TargetLease(sessionID: sid, generation: "fixture")
        let store = ConversationStore(target: lease), snapshot = store.beginHistorySnapshot()
        #expect(try store.reconcile(history: page("latestPage", projected: projected), active: false, for: lease, snapshot: snapshot).isEmpty)
        #expect(try store.reconcile(history: page("olderPage", projected: projected), active: false, for: lease, snapshot: snapshot).isEmpty)
        #expect(store.records.count == 4)
        let rows = store.records.compactMap(MessageRow.init)
        #expect(rows.count == 2 && rows.map(\.role) == ["You", "Chief"])
        #expect(rows[1].text == "Acknowledged in this throwaway session.")
        if projected { #expect(rows[0].sender?.kind == .canvas) }
        let idleRecords = store.records.filter { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["type"] as? String == "idle" }
        #expect(idleRecords.count == 2 && idleRecords.allSatisfy { MessageRow($0) == nil })
        let newestIdle = "msg_SYNTHETIC0007"
        #expect(HistoryAnchor.resolve(newestIdle, records: store.records)?.rowID == rows[1].id)
        #expect(HistoryAnchor.resolve(newestIdle, records: store.records)?.kind == .neighbour)
        #expect(HistoryAnchor.resolve("msg_SYNTHETIC0005", records: store.records)?.rowID == rows[0].id)
        // Repeated pages remain idempotent, retaining model/tokens/finish fields.
        try store.reconcile(history: page("latestPage", projected: projected), active: false, for: lease, snapshot: snapshot)
        #expect(store.records.count == 4)
        #expect(rows[1].detail.contains("tokens") && rows[1].detail.contains("finish"))
    }

    @Test func rawIdleIDRemainsAValidCatchUpBoundaryAcrossRealCursorPages() throws {
        let latest = try JSONSerialization.jsonObject(with: page("latestPage")) as! [String: Any]
        let older = try JSONSerialization.jsonObject(with: page("olderPage")) as! [String: Any]
        let ids = { (page: [String: Any]) in (page["data"] as! [[String: Any]]).map { $0["id"] as! String } }
        let cursor = try #require((latest["cursor"] as? [String: Any])?["next"] as? String)
        #expect(cursor.range(of: "^[A-Za-z0-9_-]{1,1024}$", options: .regularExpression) != nil)
        var idleBoundary = HistoryCatchUp(boundary: ids(latest)[0])
        let idleContinues = idleBoundary.accept(ids: ids(latest), next: cursor)
        #expect(!idleContinues && idleBoundary.complete)
        var olderBoundary = HistoryCatchUp(boundary: ids(older)[0])
        let latestContinues = olderBoundary.accept(ids: ids(latest), next: cursor)
        #expect(latestContinues)
        let olderContinues = olderBoundary.accept(ids: ids(older), next: nil)
        #expect(!olderContinues && olderBoundary.complete)
    }

    @Test(arguments: ["succeeded", "failed", "interrupted"])
    func retainedExecutionContractStillDrivesBusyAndIgnoresToolInputText(_ outcome: String) async throws {
        let rig = Rig(); await rig.start(); defer { rig.controller.stop() }
        rig.controller.handle(ServerEvent(type: "session.execution.started", data: ["sessionID": "ses_A"]))
        #expect(rig.controller.status.busy)
        let event = try toolEvent(sessionID: "ses_A")
        #expect(event.identity == "evt_input" && event.type == "session.tool.input.ended")
        rig.controller.handle(event)
        #expect(rig.controller.status.busy && !rig.controller.status.narrationPaused)
        #expect(rig.output.plays.isEmpty && rig.backend.prompts.isEmpty)
        rig.controller.handle(ServerEvent(type: "session.execution.\(outcome)", data: ["sessionID": "ses_A"]))
        #expect(!rig.controller.status.busy)
    }

    @Test func newToolEventSchedulesAuthoritativeStateAndHistoryRefreshThroughRealRemote() async throws {
        let latest = try page("latestPage"), older = try page("olderPage")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OC240Protocol.self]
        let transport = try BridgeTransport(base: URL(string: "https://oc240.fixture/floating-voice")!, credentials: OC240Credential(), configuration: config)
        let backend = RemoteSessionBackend(transport: transport)
        var active = true, reads = 0, narrations = 0
        OC240Protocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("selection") { return (200, try self.json(["generation": "one"])) }
            if path.hasSuffix("events") { return (503, Data()) }
            if path.hasSuffix("state") { return (200, try self.json(["active": active])) }
            reads += 1
            return (200, request.url!.query?.contains("cursor=") == true ? older : latest)
        }
        let sid = try fixture()["sessionID"] as! String
        try await backend.select(sid); defer { backend.disconnect() }
        let lease = try #require(backend.lease)
        backend.onNarration = { _ in narrations += 1 }
        try await backend.reconcile(lease)
        #expect(backend.store?.active == true, "An idle history record is not a newer execution-state authority")
        let surface = VoiceSurface(); surface.replaceBinding(target: lease)
        surface.update(records: backend.store!.records, connection: "connected", active: true)
        #expect(surface.state == "Agent thinking")
        active = false; let before = reads
        backend.receiveRemote(try toolEvent(sessionID: sid), identity: "evt_input", target: lease)
        #expect(await waitUntil { reads > before && backend.store?.active == false })
        #expect(narrations == 0)
        surface.update(records: backend.store!.records, connection: "connected", active: backend.store!.active)
        #expect(surface.state != "Agent thinking")
    }
}
