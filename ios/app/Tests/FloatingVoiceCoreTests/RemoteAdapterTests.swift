import Foundation
import Testing
import AVFoundation
@testable import FloatingVoiceCore

private final class MemoryCredential: DeviceCredentialStore {
    var value: String? = String(repeating: "d", count: 43)
    var clears = 0
    var failSave = false
    func load() throws -> String? { value }
    func save(_ credential: String) throws { if failSave { throw CredentialFailure(operation: "write", status: -25291, malformed: false) }; value = credential }
    func clear() throws { value = nil; clears += 1 }
}
private final class BridgeFixture: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, bytes) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class IdleEventFixture: URLProtocol, @unchecked Sendable {
    static var stopped: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        // Deliberately NO body, event, heartbeat or completion.
    }
    override func stopLoading() { Self.stopped?() }
}

@Suite(.serialized) @MainActor struct RemoteAdapterTests {
    @Test func sessionPagesCarryCursorAndOldBridgeStillWorks() async throws {
        let backend = RemoteSessionBackend(transport: try transport())
        var urls: [String] = []
        BridgeFixture.handler = { request in
            urls.append(request.url!.absoluteString)
            let more = request.url!.query != nil
            return (200, self.json(["data":[["id":more ? "ses_300":"ses_1", "title":"Fixture", "time":["updated":450]]],
                "cursor":["next":more ? NSNull() as Any : "opaque_next" as Any]]))
        }
        let first = try await backend.listSessionsPage(cursor: nil)
        #expect(first.nextCursor == "opaque_next")
        let second = try await backend.listSessionsPage(cursor: first.nextCursor)
        #expect(second.sessions.first?.id == "ses_300" && second.nextCursor == nil)
        #expect(urls.last?.hasSuffix("/v1/sessions?cursor=opaque_next") == true)
        BridgeFixture.handler = { _ in (200, self.json(["data":[["id":"ses_old"]]])) }
        let old = try await backend.listSessionsPage(cursor: nil)
        #expect(old.sessions.first?.id == "ses_old" && old.nextCursor == nil)
    }
    @Test func malformedSessionCursorNeverBecomesARequest() async throws {
        let backend = RemoteSessionBackend(transport: try transport())
        BridgeFixture.handler = { _ in Issue.record("invalid cursor must not reach transport"); return (500, Data()) }
        for cursor in ["", "next&directory=private", String(repeating:"x", count:1025)] {
            do { _ = try await backend.listSessionsPage(cursor:cursor); Issue.record("invalid cursor accepted") }
            catch { }
        }
    }
    @Test func malformedUpstreamSessionCursorFailsInsteadOfTruncatingPicker() async throws {
        let backend = RemoteSessionBackend(transport: try transport())
        for cursor: Any in ["bad-shape", ["next":"bad.cursor"], ["next":123]] {
            BridgeFixture.handler = { _ in (200, self.json(["data":[], "cursor":cursor])) }
            do { _ = try await backend.listSessionsPage(cursor:nil); Issue.record("invalid response cursor accepted") }
            catch { }
        }
    }
    @Test(arguments: [false, true]) func voiceEndedUsesSilentAdmissionReceiptOnceAndNeverBecomesYou(_ fail: Bool) async throws {
        let backend = RemoteSessionBackend(transport: try transport())
        var bodies: [[String: Any]] = [], note: [String: Any]?
        BridgeFixture.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("selection") { return (200, self.json(["generation":"voice-ended"])) }
            if path.hasSuffix("events") { return (503, Data()) }
            if path.hasSuffix("state") { return (200, self.json(["active":false])) }
            if path.hasSuffix("prompt") {
                bodies.append(try self.requestBody(request))
                if fail { return (503, self.json(["error":"Synthetic refusal"])) }
                note = ["id":"msg_ended", "type":"user", "text":"[voice] ended", "sender":["kind":"system", "label":"Voicestack"], "displayText":"Voice ended"]
                return (200, self.json(["data":["id":"msg_ended"]]))
            }
            return (200, self.json(["data":note.map { [$0] } ?? []]))
        }
        try await backend.select("ses_A"); defer { backend.disconnect() }
        let lease = try #require(backend.lease), session = VoiceEndedSession(kind: .app, target: lease)
        for _ in 0..<2 {
            await session.end(currentLease: { backend.lease }, admit: { target, text in try await backend.admit(target: target, text: text) })
        }
        #expect(bodies.count == 1 && bodies[0]["text"] as? String == "[voice] ended" && bodies[0]["resume"] as? Bool == false)
        #expect(bodies[0]["delivery"] == nil && Set(bodies[0].keys) == ["text", "resume"])
        if !fail {
            try await backend.reconcile(lease)
            let row = try #require(backend.displayRecords.compactMap(MessageRow.init).first)
            #expect(row.isSystemNote && row.role == "System" && !row.isPrincipal && row.text == "Voice ended")
        }
    }
    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    }
    @Test(arguments: ["prompt-http", "admit-http", "prompt-lost", "admit-lost", "queue-lost", "steer-lost"])
    func voiceFailureRetainsRawReviewDraftThroughRealRemote(_ mode: String) async throws {
        let backend = RemoteSessionBackend(transport: try transport())
        let raw = "Literal [voice] words."
        var wire: [[String: Any]] = []
        BridgeFixture.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("selection") { return (200, self.json(["generation":"g"])) }
            if path.hasSuffix("events") { return (503, Data()) }
            if path.hasSuffix("prompt") {
                wire.append(try self.requestBody(request))
                if mode.hasSuffix("lost") { throw URLError(.networkConnectionLost) }
                return (503, self.json(["error":"synthetic refusal"]))
            }
            if path.hasSuffix("state") { return (200, self.json(["active":false])) }
            return (200, self.json(["data":[]]))
        }
        try await backend.select("ses_A")
        let target = try #require(backend.lease)
        var app = AppSettings(); app.target = "ses_A"
        let settings = LoadedSettings(app: app, voice: VoiceConfig(), voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent")
        let controller = ConversationController(settings: settings, backend: backend, synth: FakeSynth(), output: FakeOutput(), input: FakeInput(), makeRecognition: { FakeRecognition($0, transcript: "") })
        defer { controller.stop(); backend.disconnect() }
        let kind: PostKind = mode.hasPrefix("admit") ? .admitOnly : mode.hasPrefix("queue") ? .delivery(.queue) : mode.hasPrefix("steer") ? .delivery(.steer) : .normal
        await controller.post(raw, kind: kind, reason: "synthetic failed voice", to: target)
        #expect(wire.count == 1 && wire[0]["text"] as? String == "[voice] Literal [voice] words.")
        #expect((wire[0]["resume"] as? Bool == false) == mode.hasPrefix("admit"))
        #expect(backend.review == [BoundDraft(target: target, text: raw)])
        // Pending review renders BoundDraft.text verbatim: retain only the raw
        // transcript, not a blanket strip that would corrupt literal content.
        #expect(backend.review.first?.text == "Literal [voice] words.")
    }
    @Test(arguments: [false, true]) func failedTypedMarkerRemainsLiteralWithRealRemote(_ admit: Bool) async throws {
        let backend = RemoteSessionBackend(transport: try transport())
        let typed = "[voice] Keep my literal typed prefix."
        var wire: [String] = []
        BridgeFixture.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("selection") { return (200, self.json(["generation":"g"])) }
            if path.hasSuffix("events") { return (503, Data()) }
            if path.hasSuffix("prompt") {
                wire.append(try self.requestBody(request)["text"] as! String)
                throw URLError(.networkConnectionLost)
            }
            return (200, self.json(["data":[]]))
        }
        try await backend.select("ses_A"); defer { backend.disconnect() }
        let target = try #require(backend.lease)
        await #expect(throws: (any Error).self) {
            if admit { try await backend.admit(target: target, text: typed) }
            else { try await backend.prompt(target: target, text: typed, delivery: nil) }
        }
        #expect(wire == [typed] && backend.review == [BoundDraft(target: target, text: typed)])
    }
    @Test func speechUnavailableVoicesPreservesClosedWordingAndCredential() async throws {
        let credentials = MemoryCredential(), transport = try transport(credentials)
        BridgeFixture.handler = { _ in
            (503, self.json(["error": "speech_unavailable", "service": "tts", "endpoint": "127.0.0.1:8444"]))
        }
        do { _ = try await transport.json("/tts/v1/voices"); Issue.record("Expected unavailable") }
        catch { #expect(error.localizedDescription == "Speech service at 127.0.0.1:8444 isn't running") }
        #expect(credentials.clears == 0 && credentials.value != nil)
        do { _ = try await transport.json("/v1/health"); Issue.record("Expected bridge failure") }
        catch { #expect(!error.localizedDescription.contains("Speech service at")) }
    }
    @Test func eventsCancellationRecordsOriginBeforeGenericConsumerTeardown() async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [IdleEventFixture.self]
        let stream = HTTPChunkStream(URLRequest(url: URL(string: "https://example.test/events")!), idleTimeout: 75, configuration: cfg)
        _ = try await stream.headers()
        stream.cancel(cause: .pathChange)
        do { for try await _ in stream.chunks {} } catch {}
        #expect(await waitUntil {
            let entries = (try? JSONDecoder().decode([DiagnosticEntry].self, from: Data(StageDiagnostics.shared.export().utf8))) ?? []
            return entries.contains { $0.stage == .events && $0.status == -999 && $0.cancellationCause == .pathChange }
        })
    }
    @Test func existingInboxDeliveredHintRefreshesHistoryWithoutInventingStateOrNarration() async throws {
        let backend = RemoteSessionBackend(transport: try transport())
        var updated = false, historyReads = 0, narrations = 0
        BridgeFixture.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("selection") { return (200, self.json(["generation": "one"])) }
            if path.hasSuffix("events") { return (503, Data()) }
            if path.hasSuffix("state") { return (200, self.json(["active": false])) }
            historyReads += 1
            return (200, self.json(["data": updated ? [["id": "repaired", "type": "user", "text": "Owned repaired history"]] : []]))
        }
        backend.onNarration = { _ in narrations += 1 }
        try await backend.select("ses_A")
        defer { backend.disconnect() }
        let lease = try #require(backend.lease)
        try await backend.reconcile(lease)
        #expect(historyReads == 1 && backend.store?.active == false)
        updated = true
        backend.receiveRemote(ServerEvent(type: "session.inbox.delivered", data: ["sessionID": "ses_A"]), identity: "bridge-refresh", target: lease)
        #expect(await waitUntil { backend.store?.records.contains { String(decoding: $0, as: UTF8.self).contains("repaired") } == true })
        #expect(historyReads >= 2 && narrations == 0 && backend.store?.active == false)
        let before = historyReads
        backend.receiveRemote(ServerEvent(type: "session.inbox.delivered", data: ["sessionID": "ses_other"]), identity: "foreign", target: lease)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(historyReads == before)
    }
    private func transport(_ credentials: MemoryCredential = MemoryCredential()) throws -> BridgeTransport {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [BridgeFixture.self]
        return try BridgeTransport(base: URL(string: "https://example.test/floating-voice")!, credentials: credentials, configuration: cfg)
    }
    func json(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj, options: .sortedKeys) }
    @Test func reconnectCompletionDuringOutageProjectsAndNarratesOnlyMissingSuffix() async throws {
        let backend = RemoteSessionBackend(transport: try transport())
        var completed = false, updates: [NarrationUpdate] = []
        BridgeFixture.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("selection") { return (200, self.json(["generation": "one"])) }
            if path.hasSuffix("events") { return (503, Data()) }
            if path.hasSuffix("state") { return (200, self.json(["active": !completed])) }
            if !completed { return (200, self.json(["data": []])) }
            return (200, self.json(["data": [["id": "m", "type": "assistant", "time": ["created": 1, "completed": 2], "content": [["type": "text", "text": "First words. Finished during disconnect."]]]]]))
        }
        var spoken: [String] = []
        let segments = SpeechSegments { spoken.append($0) }
        backend.onNarration = { updates.append($0); segments.consume($0) }
        try await backend.select("ses_A")
        defer { backend.disconnect() }
        let lease = try #require(backend.lease)
        try await backend.reconcile(lease)
        backend.receiveRemote(ServerEvent(type: "session.text.delta", data: ["sessionID": "ses_A", "assistantMessageID": "m", "ordinal": 0, "delta": "First words. "]), identity: "before", target: lease)
        segments.flush(final: true) // model the prefix already spoken before disconnect
        #expect(spoken == ["First words."])
        let store = try #require(backend.store)
        let stale = store.beginHistorySnapshot()
        store.beginReconnect(); completed = true
        try await backend.reconcile(lease)
        #expect(store.liveBlocks["m:0"] == "First words. Finished during disconnect.")
        let record = try #require(try JSONSerialization.jsonObject(with: store.records[0]) as? [String: Any])
        #expect((record["time"] as? [String: Int])?["completed"] == 2)
        #expect(updates.map(\.suffix) == ["First words. ", "Finished during disconnect."])
        #expect(updates.last?.final == true)
        #expect(spoken == ["First words.", "Finished during disconnect."])
        try await backend.reconcile(lease)
        backend.receiveRemote(ServerEvent(type: "session.text.ended", data: ["sessionID": "ses_A", "assistantMessageID": "m", "ordinal": 0, "text": "First words. Finished during disconnect."]), identity: "buffered-end", target: lease)
        #expect(updates.count == 2)
        #expect(throws: ClientError.self) { try store.reconcile(history: Data("{\"data\":[]}".utf8), active: true, for: lease, snapshot: stale) }
    }
    @Test(arguments: [false, true]) func longGapPaginatesToBoundaryOrVisiblyMarksIncomplete(_ exceedsBound: Bool) async throws {
        let backend = RemoteSessionBackend(transport: try transport())
        var gap = false, cursors: [String] = [], errors: [String] = []
        backend.onError = { errors.append($0) }
        BridgeFixture.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("selection") { return (200, self.json(["generation": "one"])) }
            if path.hasSuffix("events") { return (503, Data()) }
            if path.hasSuffix("state") { return (200, self.json(["active": false])) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let cursor = query.first { $0.name == "cursor" }?.value
            let page = cursor.flatMap(Int.init) ?? 0
            if let cursor { cursors.append(cursor) }
            let ids = !gap ? ["boundary"] : ((page == 2 && !exceedsBound) ? ["boundary"] : (0..<40).map { "new\(page * 40 + $0)" })
            return (200, self.json(["data": ids.map { ["id": $0, "type": "user", "time": ["created": 1], "content": []] as [String: Any] }, "cursor": ["next": "\(page + 1)"]]))
        }
        try await backend.select("ses_A")
        let target = try #require(backend.lease)
        try await backend.reconcile(target); gap = true
        try await backend.reconcile(target)
        #expect(cursors.count == (exceedsBound ? 9 : 2))
        #expect(backend.catchUpIncomplete == exceedsBound)
        #expect(errors.contains { $0.contains("catch-up incomplete") } == exceedsBound)
        #expect((backend.store?.records.count ?? 0) > 40)
        backend.disconnect()
    }
    @Test func idleSSEHeadersDoNotWaitForTextAndCancelCloses() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IdleEventFixture.self]
        let stopped = AsyncStream<Void>.makeStream()
        IdleEventFixture.stopped = { stopped.continuation.yield(()); stopped.continuation.finish() }
        defer { IdleEventFixture.stopped = nil }
        let stream = HTTPChunkStream(URLRequest(url: URL(string: "https://example.test/events")!), idleTimeout: 1, configuration: config)
        let start = Date()
        #expect(try await stream.headers().statusCode == 200)
        #expect(Date().timeIntervalSince(start) < 1)
        stream.cancel()
        for await _ in stopped.stream { break }
    }
    @Test func pairingResponseLossSaveFailureAndRelaunch() async throws {
        let primary = MemoryCredential(), pending = MemoryCredential()
        primary.value = nil; pending.value = nil
        let remote = try transport(primary), proof = String(repeating: "p", count: 43)
        var calls = 0, ack = 0, loseResponse = true
        BridgeFixture.handler = { request in
            if request.url!.path.hasSuffix("ack") { ack += 1; return (200, self.json(["acknowledged": true])) }
            calls += 1
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
            }
            let body = try JSONSerialization.jsonObject(with: bytes) as! [String: String]
            #expect(body["credential"] == proof)
            #expect(pending.value == proof)
            if loseResponse { throw URLError(.networkConnectionLost) }
            return (200, self.json(["credential": proof]))
        }
        await #expect(throws: (any Error).self) { try await remote.pair(bootstrap: "one-use", pending: pending, makeProof: { proof }) }
        #expect(primary.value == nil && pending.value == proof)
        loseResponse = false; primary.failSave = true
        await #expect(throws: (any Error).self) { try await remote.pair(bootstrap: "one-use", pending: pending, makeProof: { fatalError("must reuse proof") }) }
        primary.failSave = false
        try await transport(primary).pair(bootstrap: "one-use", pending: pending, makeProof: { fatalError("relaunch must reuse proof") })
        #expect(primary.value == proof && pending.value == nil && ack == 1 && calls == 3)
        #expect(primary.clears == 0)
    }
    @Test func credentialSeamSecureRequestsAndFailedPairPreserves() async throws {
        let keys = MemoryCredential(), remote = try transport(keys)
        let lease = TargetLease(sessionID: "ses_A", generation: "g1")
        let request = try remote.request("/v1/sessions/ses_A/prompt", method: "POST", body: ["text": "hello"], lease: lease)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "d", count: 43))
        #expect(request.value(forHTTPHeaderField: "X-FV-Generation") == "g1")
        #expect(request.url?.query == nil)
        BridgeFixture.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (401, Data())
        }
        await #expect(throws: (any Error).self) { try await remote.pair(bootstrap: "one-use") }
        #expect(keys.value == String(repeating: "d", count: 43))
        #expect(keys.clears == 0)
        #expect(throws: (any Error).self) { try BridgeTransport(base: URL(string: "http://example.test/floating-voice")!, credentials: keys) }
        #expect(throws: (any Error).self) { try BridgeTransport(base: URL(string: "https://secret@example.test/floating-voice")!, credentials: keys) }
    }
    @Test func unknownPromptDeliveryIsNotRetriedAndLeaseCannotRedirect() async throws {
        let backend = RemoteSessionBackend(transport: try transport())
        var prompts = 0
        BridgeFixture.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("selection") { return (200, self.json(["sessionID": "ses_A", "generation": "one"])) }
            if path.hasSuffix("prompt") { prompts += 1; throw URLError(.networkConnectionLost) }
            if path.hasSuffix("events") { return (503, Data()) }
            return (200, self.json(["data": []]))
        }
        try await backend.select("ses_A")
        let original = try #require(backend.lease)
        await #expect(throws: (any Error).self) { try await backend.prompt(target: original, text: "do not retry", delivery: .queue) }
        #expect(prompts == 1)
        #expect(backend.review == [BoundDraft(target: original, text: "do not retry")])
        let stale = TargetLease(sessionID: "ses_B", generation: "old")
        await #expect(throws: (any Error).self) { try await backend.prompt(target: stale, text: "wrong target", delivery: nil) }
        #expect(prompts == 1)
        backend.disconnect()
    }
    @Test(arguments: [true, false], [true, false]) func bufferedSnapshotOverlapAndNewBlocks(_ included: Bool, _ endBuffered: Bool) async throws {
        let backend = RemoteSessionBackend(transport: try transport())
        let prefix = "Historical prefix. "
        let suffix = "This resumed sentence must be spoken exactly once."
        var pages = 0, spoken: [String] = [], segmenters: [String: SpeechSegments] = [:]
        let done = AsyncStream<Void>.makeStream()
        backend.onNarration = { update in
            let segments = segmenters[update.blockKey] ?? SpeechSegments { spoken.append($0) }
            segmenters[update.blockKey] = segments; segments.consume(update)
            if update.blockKey == "new:0" && update.final { done.continuation.yield(()); done.continuation.finish() }
        }
        func event(_ id: String, _ type: String, message: String, text: String) -> String {
            let bytes = json(["id": id, "type": "session.text."+type, "data": ["sessionID": "ses_A", "assistantMessageID": message, "ordinal": 0, type == "delta" ? "delta" : "text": text]])
            return "data: " + String(data: bytes, encoding: .utf8)! + "\n\n"
        }
        let ending = event("e", "ended", message: "old", text: prefix+suffix)
        let sse = event("d", "delta", message: "old", text: suffix) + (endBuffered ? ending + ending : "") + event("n", "delta", message: "new", text: "Entirely new speech.") + event("ne", "ended", message: "new", text: "Entirely new speech.")
        BridgeFixture.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
            if request.url!.path.hasSuffix("selection") { return (200, self.json(["generation": "g1"])) }
            #expect(request.value(forHTTPHeaderField: "X-FV-Generation") == "g1")
            if request.url!.path.hasSuffix("events") { return (200, Data(sse.utf8)) }
            if request.url!.path.hasSuffix("state") { return (200, self.json(["active": true])) }
            if request.url!.path.hasSuffix("messages") {
                pages += 1
                if request.url!.query!.contains("cursor=next") {
                    return (200, self.json(["data": [["id": "u", "type": "user", "text": "Original **Markdown**", "time": ["created": 0], "future": ["retained": true]]]]))
                }
                return (200, self.json(["data": [["id": "old", "type": "assistant", "time": ["created": 1], "content": [["type": "text", "text": prefix + (included ? suffix : "")]], "unknown": ["attachment": "retained"]]], "cursor": ["next": "next"]]))
            }
            return (404, Data())
        }
        try await backend.select("ses_A")
        for await _ in done.stream { break }
        let lease = try #require(backend.lease)
        #expect(pages == 1)
        try await backend.loadOlder()
        if !endBuffered {
            #expect(backend.store?.liveBlocks["old:0"] == prefix + (included ? suffix : ""))
            let ended = ServerEvent(type: "session.text.ended", data: ["sessionID": "ses_A", "assistantMessageID": "old", "ordinal": 0, "text": prefix+suffix])
            backend.receiveRemote(ended, identity: "late-end", target: lease)
            backend.receiveRemote(ended, identity: "late-end", target: lease)
        }
        #expect(pages == 2)
        #expect(backend.store?.liveBlocks["old:0"] == prefix+suffix)
        #expect(spoken == (included ? ["Entirely new speech."] : (endBuffered ? [suffix, "Entirely new speech."] : ["Entirely new speech.", suffix])))
        let records = try #require(backend.store?.records)
        #expect(records.count == 3)
        #expect(records.contains { String(data: $0, encoding: .utf8)?.contains("retained") == true })
        let stale = TargetLease(sessionID: "ses_A", generation: "stale")
        backend.receiveRemote(ServerEvent(type: "session.text.delta", data: ["sessionID": "ses_A", "assistantMessageID": "old", "ordinal": 0, "delta": "WRONG"]), identity: "stale", target: stale)
        #expect(backend.store?.liveBlocks["old:0"] == prefix+suffix)
        backend.disconnect()
    }
    @Test func syntheticHardwareDownmixAndFrameCarry() throws {
        let channels = [Array(repeating: Float(0.5), count: 4800), Array(repeating: Float(-0.25), count: 4800)]
        let pcm = PCMFrames.monoS16(channels)
        #expect(pcm.count == 9600)
        let converted = resampleS16(pcm, from: 48000, to: 16000)
        var framer = PCMFrames(), frames: [Data] = []
        for offset in stride(from: 0, to: converted.count, by: 113) { frames += framer.push(converted.subdata(in: offset..<min(offset+113, converted.count))) }
        #expect(frames.count == 5)
        #expect(frames.allSatisfy { $0.count == 640 })
        #expect(abs(TurnTaker.rms(frames[0]) - 0.125) < 0.001)
        #expect(PCMFrames.monoS16([[.nan, .infinity, -2, 2]]).count == 8)
    }
    @Test(arguments: [44100.0, 48000.0]) func realConverterSyntheticStereo(_ rate: Double) throws {
        let source = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
        let converter = try #require(AVAudioConverter(from: source, to: target))
        let conversion = CaptureConversion(converter: converter, target: target)
        var frames: [Data] = []
        for _ in 0..<50 {
            let count = AVAudioFrameCount(rate/50)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: count))
            buffer.frameLength = count
            for i in 0..<Int(count) { buffer.floatChannelData![0][i] = 0.25; buffer.floatChannelData![1][i] = 0.25 }
            frames += try conversion.convert(buffer)
        }
        #expect((48...50).contains(frames.count)) // converter's bounded filter latency, no device involved
        #expect(frames.allSatisfy { $0.count == 640 })
        #expect(abs(TurnTaker.rms(try #require(frames.last)) - 0.25) < 0.01)
    }
}
