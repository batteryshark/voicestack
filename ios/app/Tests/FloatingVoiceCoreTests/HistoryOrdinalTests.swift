import Foundation
import Testing

@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct HistoryOrdinalTests {
    let lease = TargetLease(sessionID: "ses_offline", generation: "fixture")
    func fixture() throws -> (Data, String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("bridge/fixtures/history-ordinal.json")
        let bytes = try Data(contentsOf: url)
        let page = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let message = (page["data"] as! [[String: Any]]).first { $0["type"] as? String == "assistant" }!
        let answer = (message["content"] as! [[String: Any]])[1]["text"] as! String
        return (bytes, answer)
    }
    func row(_ store: ConversationStore) throws -> MessageRow {
        try #require(store.records.compactMap(MessageRow.init).first { $0.id == "msg_freshOrdinalAnswer01" })
    }
    func event(_ kind: String, _ ordinal: Int, _ text: String = "") -> ServerEvent {
        ServerEvent(
            type: "session.text." + kind,
            data: [
                "sessionID": lease.sessionID, "assistantMessageID": "msg_freshOrdinalAnswer01", "ordinal": ordinal,
                kind == "delta" ? "delta" : "text": text,
            ])
    }
    func inject(_ store: ConversationStore, answer: String, ordinal: Int = 0) {
        _ = store.receive(event("started", ordinal), eventID: "evt_start", for: lease)
        _ = store.receive(event("delta", ordinal, answer), eventID: "evt_delta", for: lease)
        _ = store.receive(event("ended", ordinal, answer), eventID: "evt_end", for: lease)
        // Even a duplicate event with the SAME id is ignored; the defect survives.
        _ = store.receive(event("ended", ordinal, answer), eventID: "evt_end", for: lease)
    }
    @Test func freshSnapshotHasOneVisibleAnswer() throws {
        let (snapshot, answer) = try fixture()
        let store = ConversationStore(target: lease)
        try store.reconcile(history: snapshot, active: false, for: lease)
        let projected = try row(store)
        #expect(projected.text == answer)
        #expect(projected.body.filter { $0.label == nil }.count == 1)
        #expect(projected.body.first?.label == "reasoning")
    }
    @Test func liveThenSnapshotMustMatchFreshOneAnswer() throws {
        let (snapshot, answer) = try fixture()
        let store = ConversationStore(target: lease)
        try store.reconcile(history: Data("{\"data\":[]}".utf8), active: false, for: lease)
        inject(store, answer: answer)  // Real v2.0.32 first text ordinal, NOT array index1.
        try store.reconcile(history: snapshot, active: false, for: lease)
        let projected = try row(store)
        let record =
            try JSONSerialization.jsonObject(with: store.records.first { MessageRow($0)?.id == "msg_freshOrdinalAnswer01" }!)
            as! [String: Any]
        let blocks = record["content"] as! [[String: Any]]
        #expect(blocks.filter { $0["type"] as? String == "text" }.count == 1)
        #expect(projected.text == answer)
        #expect(blocks.first?["type"] as? String == "reasoning")
    }
    @Test func snapshotThenBufferedTextEndMustNotOverwriteReasoning() throws {
        let (snapshot, answer) = try fixture()
        let store = ConversationStore(target: lease)
        try store.reconcile(history: snapshot, active: false, for: lease)
        inject(store, answer: answer)
        let projected = try row(store)
        #expect(projected.text == answer)
        #expect(projected.body.first?.label == "reasoning")
    }
    @Test func plainTextOnlyControlIsUnchanged() throws {
        let answer = "Plain text stays exactly once."
        let store = ConversationStore(target: lease)
        try store.reconcile(history: Data("{\"data\":[]}".utf8), active: false, for: lease)
        inject(store, answer: answer)
        try store.reconcile(history: page([text(answer)]), active: false, for: lease)
        #expect(try row(store).text == answer)
    }
    func text(_ value: String) -> [String: Any] { ["type": "text", "text": value] }
    func tool(_ id: String) -> [String: Any] {
        ["type": "tool", "id": id, "name": "synthetic", "state": ["status": "completed", "content": []]]
    }
    func page(_ content: [[String: Any]], completed: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "data": [
                [
                    "id": "msg_freshOrdinalAnswer01", "type": "assistant", "content": content,
                    "time": completed ? ["created": 1000, "completed": 2000] : ["created": 1000],
                ]
            ]
        ])
    }
    func content(_ store: ConversationStore) throws -> [[String: Any]] {
        let raw = try #require(store.records.first { MessageRow($0)?.id == "msg_freshOrdinalAnswer01" })
        return (try JSONSerialization.jsonObject(with: raw) as! [String: Any])["content"] as! [[String: Any]]
    }
    @Test(arguments: [false, true]) func interleavedToolsAndTwoTextsKeepCanonicalOrder(_ snapshotFirst: Bool) throws {
        let store = ConversationStore(target: lease)
        let blocks = [tool("first"), text("First answer."), tool("second"), text("Second answer.")]
        try store.reconcile(
            history: snapshotFirst ? page(blocks, completed: false) : Data("{\"data\":[]}".utf8), active: false,
            for: lease)
        // Authoritative ends, not append deltas, also exercise snapshot overlap.
        for (n, value) in ["First answer.", "Second answer."].enumerated() {
            _ = store.receive(event("ended", n, value), eventID: "end\(n)", for: lease)
        }
        try store.reconcile(history: page(blocks), active: false, for: lease, snapshot: store.beginHistorySnapshot())
        let result = try content(store)
        #expect(result.compactMap { $0["type"] as? String } == ["tool", "text", "tool", "text"])
        #expect(result.compactMap { $0["id"] as? String } == ["first", "second"])
        #expect(try row(store).text == "First answer.\n\nSecond answer.")
    }
    @Test func missingSecondTextSlotDoesNotOverwriteToolAndFillsInStableTextOrder() throws {
        let store = ConversationStore(target: lease)
        try store.reconcile(history: page([tool("kept")], completed: false), active: false, for: lease)
        _ = store.receive(event("ended", 1, "Second."), eventID: "second", for: lease)
        #expect(try content(store).first?["id"] as? String == "kept")
        _ = store.receive(event("ended", 0, "First."), eventID: "first", for: lease)
        try store.reconcile(
            history: page([text("First."), tool("kept"), text("Second.")]), active: false, for: lease,
            snapshot: store.beginHistorySnapshot())
        #expect(try content(store).compactMap { $0["type"] as? String } == ["text", "tool", "text"])
        #expect(try row(store).text == "First.\n\nSecond.")
    }
    @Test func identicalTextInDistinctSlotsIsNotHashDeduplicated() throws {
        let store = ConversationStore(target: lease)
        let answer = "Same words are legitimate in two distinct text parts."
        try store.reconcile(history: Data("{\"data\":[]}".utf8), active: false, for: lease)
        for n in 0...1 { _ = store.receive(event("ended", n, answer), eventID: "end\(n)", for: lease) }
        try store.reconcile(history: page([text(answer), tool("between"), text(answer)]), active: false, for: lease)
        #expect(try content(store).filter { $0["type"] as? String == "text" }.count == 2)
        #expect(try row(store).text == answer + "\n\n" + answer)
    }
    @Test func snapshotMetadataWinsWhileLiveTextKeepsAuthority() throws {
        let store = ConversationStore(target: lease)
        try store.reconcile(history: Data("{\"data\":[]}".utf8), active: true, for: lease)
        inject(store, answer: "Live final.")
        let canonical: [[String: Any]] = [
            ["type": "reasoning", "text": "Private reasoning fixture.", "future": ["retained": true]],
            ["type": "text", "text": "Stale final.", "state": ["future": "canonical"]],
        ]
        try store.reconcile(history: page(canonical), active: false, for: lease, snapshot: store.beginHistorySnapshot())
        let result = try content(store)
        #expect(result[0]["type"] as? String == "reasoning")
        #expect((result[0]["future"] as? [String: Bool])?["retained"] == true)
        #expect((result[1]["state"] as? [String: String])?["future"] == "canonical")
        #expect(try row(store).text == "Live final.")
    }
    @Test func reconnectCatchUpUsesTextOrdinalAndNarratesOnlyUncoveredSuffix() throws {
        let store = ConversationStore(target: lease)
        let reason: [String: Any] = ["type": "reasoning", "text": "Synthetic reasoning."]
        try store.reconcile(
            history: page([reason, text("Silent prefix. ")], completed: false), active: true, for: lease)
        var spoken: [String] = []
        let speech = SpeechSegments { spoken.append($0) }
        speech.consume(try #require(store.receive(event("delta", 0, "Live words. "), eventID: "live", for: lease)))
        speech.flush(final: true)
        store.beginReconnect()
        let final = "Silent prefix. Live words. Finished offline."
        let updates = try store.reconcile(
            history: page([reason, text(final)]), active: false, for: lease, snapshot: store.beginHistorySnapshot())
        #expect(updates.map(\.blockKey) == ["msg_freshOrdinalAnswer01:0"])
        #expect(updates.map(\.suffix) == ["Finished offline."])
        updates.forEach { speech.consume($0) }
        _ = store.receive(event("ended", 0, final), eventID: "replayed-new-id", for: lease)
        try store.reconcile(
            history: page([reason, text(final)]), active: false, for: lease, snapshot: store.beginHistorySnapshot())
        #expect(spoken == ["Live words.", "Finished offline."])
        #expect(try row(store).text == final)
    }
    @Test func liveAuthorityIsPerTextSlotNotTheWholeMessage() throws {
        let store = ConversationStore(target: lease)
        try store.reconcile(
            history: page([text("Old first."), tool("middle"), text("Second")], completed: false), active: true,
            for: lease)
        _ = store.receive(event("delta", 1, " live."), eventID: "live-second", for: lease)
        try store.reconcile(
            history: page([text("Correct first."), tool("middle"), text("Stale second.")]), active: false, for: lease,
            snapshot: store.beginHistorySnapshot())
        #expect(try row(store).text == "Correct first.\n\nSecond live.")
    }
    @Test func staleSnapshotCannotReorderCanonicalContentOrRevertCompletedText() throws {
        let store = ConversationStore(target: lease)
        let stale = store.beginHistorySnapshot()
        let fresh = store.beginHistorySnapshot()
        try store.reconcile(
            history: page([tool("kept"), text("Completed.")]), active: false, for: lease, snapshot: fresh)
        try store.reconcile(history: page([text("Stale."), tool("kept")]), active: false, for: lease, snapshot: stale)
        #expect(try content(store).compactMap { $0["type"] as? String } == ["tool", "text"])
        #expect(try row(store).text == "Completed.")
    }
    @Test func realRemoteReceiveAndLatestSnapshotAlsoMustRenderOneAnswer() async throws {
        let (snapshot, answer) = try fixture()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineWire.self]
        let transport = try BridgeTransport(
            base: URL(string: "https://offline.invalid/floating-voice")!, credentials: OfflineCredential(),
            configuration: config)
        let backend = RemoteSessionBackend(transport: transport)
        OfflineWire.page = Data("{\"data\":[]}".utf8)
        try await backend.select(lease.sessionID)
        defer { backend.disconnect() }
        let granted = try #require(backend.lease)
        try await backend.reconcile(granted)
        backend.receiveRemote(event("started", 0), identity: "evt_start", target: granted)
        backend.receiveRemote(event("delta", 0, answer), identity: "evt_delta", target: granted)
        backend.receiveRemote(event("ended", 0, answer), identity: "evt_end", target: granted)
        OfflineWire.page = snapshot
        try await backend.reconcile(granted)
        let projected = try #require(
            backend.displayRecords.compactMap(MessageRow.init).first { $0.id == "msg_freshOrdinalAnswer01" })
        #expect(projected.text == answer)
    }
    @Test func realRemoteNarrationFeedsControllerTTSAndMainLogExactlyOnceAcrossReplayAndReconnect() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineWire.self]
        let backend = RemoteSessionBackend(
            transport: try BridgeTransport(
                base: URL(string: "https://offline.invalid/floating-voice")!, credentials: OfflineCredential(),
                configuration: config))
        let synth = FakeSynth()
        let output = FakeOutput(duration: 0)
        let input = FakeInput()
        var app = AppSettings()
        app.target = lease.sessionID
        let controller = ConversationController(
            settings: LoadedSettings(
                app: app, voice: VoiceConfig(), voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent"),
            backend: FakeBackend(), synth: synth, output: output, input: input,
            makeRecognition: { FakeRecognition($0, transcript: "") })
        var voiceLog = ConversationVoiceLog()
        var updates: [NarrationUpdate] = []
        voiceLog.setVoice(running: true, muted: false)
        controller.onCaption = { voiceLog.handle($0, userText: "") }
        backend.onChange = { voiceLog.update(records: backend.displayRecords) }
        backend.onNarration = {
            updates.append($0)
            controller.consumeNarration($0)
        }
        OfflineWire.page = Data("{\"data\":[]}".utf8)
        try await backend.select(lease.sessionID)
        defer {
            controller.stop()
            backend.disconnect()
        }
        await controller.start()
        #expect(await waitUntil { controller.status.phase == "ready" })
        let granted = try #require(backend.lease)
        try await backend.reconcile(granted)
        let sentence = "This single synthetic answer must be spoken exactly once."
        backend.receiveRemote(event("delta", 0, sentence), identity: "live", target: granted)
        backend.receiveRemote(event("ended", 0, sentence), identity: "end", target: granted)
        OfflineWire.page = try page([["type": "reasoning", "text": "Synthetic reasoning."], text(sentence)])
        try await backend.reconcile(granted)
        backend.receiveRemote(event("ended", 0, sentence), identity: "end", target: granted)
        backend.receiveRemote(event("delta", 0, sentence), identity: "replayed-new-id", target: granted)
        backend.store?.beginReconnect()
        try await backend.reconcile(granted)
        backend.receiveRemote(event("ended", 0, sentence), identity: "reconnected-end", target: granted)
        #expect(await waitUntil { output.plays.count == 1 && output.plays[0].outcome == "played" })
        #expect(updates.filter { !$0.suffix.isEmpty }.map(\.suffix) == [sentence])
        #expect(synth.prepared == [sentence] && output.plays.map(\.text) == [sentence])
        #expect(voiceLog.turns.filter { $0.role == .chief }.map(\.spoken) == [sentence])
        // The idle main screen uses the same store records, not the speech path.
        var idleLog = ConversationVoiceLog()
        idleLog.update(records: backend.displayRecords)
        #expect(idleLog.turns.map(\.spoken) == [sentence])
        #expect(backend.displayRecords.compactMap(MessageRow.init).first?.text == sentence)
    }
}

private final class OfflineCredential: DeviceCredentialStore {
    func load() throws -> String? { "synthetic-fixture-only" }
    func save(_ credential: String) throws {}
    func clear() throws {}
}
private final class OfflineWire: URLProtocol, @unchecked Sendable {
    static var page = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var status = 200
        let bytes: Data
        if path.hasSuffix("selection") {
            bytes = Data("{\"sessionID\":\"ses_offline\",\"generation\":\"fixture\"}".utf8)
        } else if path.hasSuffix("state") {
            bytes = Data("{\"active\":false}".utf8)
        } else if path.hasSuffix("messages") {
            bytes = Self.page
        } else {
            status = 503
            bytes = Data()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
