import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite @MainActor struct MobileFoundationTests {
    let a = TargetLease(sessionID: "ses_testA", generation: "generation-one")
    @Test func bridgeHealthRetainsASRPrefixAndRejectsUnknownPath() {
        #expect(ServiceChecks.healthURL("wss://host:9443/floating-voice/asr/v1/transcribe?partials=1")?.absoluteString == "https://host:9443/floating-voice/asr/health")
        #expect(ServiceChecks.healthURL("wss://host/arbitrary") == nil)
        var parser = SSEParser()
        #expect(parser.push(Data(repeating: 65, count: 262145)).isEmpty)
        #expect(parser.exceededLimit)
        #expect(parser.push(Data("data: {}\n\n".utf8)).isEmpty)
    }
    @Test func draftCannotFollowPickerOrChiefReplacement() throws {
        let draft = BoundDraft(target: a, text: "Words already in motion")
        try draft.validate(current: a)
        #expect(throws: ClientError.self) { try draft.validate(current: TargetLease(sessionID: "ses_testB", generation: "generation-one")) }
        #expect(throws: ClientError.self) { try draft.validate(current: TargetLease(sessionID: "ses_testA", generation: "generation-two")) }
    }
    @Test func reconnectIsIdempotentAndRetainsFullRecordsWithoutNarration() throws {
        let store = ConversationStore(target: a)
        let history = Data(#"{"data":[{"id":"user1","type":"user","content":[{"type":"text","text":"Question"}]},{"id":"reply1","type":"assistant","content":[{"type":"text","text":"| A | B |\n|---|---|\n|1|2|"},{"type":"image","url":"synthetic"},{"type":"future-canvas","payload":{"unknown":[1,true]}}],"futureMetadata":{"preserve":true}}],"cursor":{}}"#.utf8)
        try store.reconcile(history: history, active: true, for: a)
        let first = store.records
        store.beginReconnect()
        try store.reconcile(history: history, active: false, for: a)
        #expect(store.records == first && store.records.count == 2 && !store.active)
        let decoded = try store.records.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let source = try #require(decoded.compactMap { $0 }.first { $0["id"] as? String == "reply1" })
        #expect((source["content"] as? [[String: Any]])?.count == 3)
        #expect((source["futureMetadata"] as? [String: Bool])?["preserve"] == true)
        let old = ServerEvent(type: "session.text.ended", data: ["sessionID": a.sessionID, "assistantMessageID": "reply1", "ordinal": 0, "text": "old reply"])
        let completion = try #require(store.receive(old, eventID: "replayed", for: a))
        var spoken: [String] = []
        let segments = SpeechSegments { spoken.append($0) }
        segments.consume(completion)
        #expect(completion.final && completion.suffix.isEmpty && spoken.isEmpty)
        let live = ServerEvent(type: "session.text.delta", data: ["sessionID": a.sessionID, "assistantMessageID": "reply2", "ordinal": 0, "delta": "new reply"])
        #expect(store.receive(live, eventID: "new", for: a)?.suffix == "new reply")
        #expect(store.receive(live, eventID: "new", for: a) == nil)
        #expect(store.liveBlocks["reply2:0"] == "new reply")
        store.beginReconnect()
        #expect(store.receive(live, eventID: "during-reconcile", for: a) == nil)
    }
    @Test func mismatchedHistoryAndEventsNeverEnterStore() throws {
        let store = ConversationStore(target: a)
        let other = TargetLease(sessionID: "ses_testB", generation: a.generation)
        #expect(throws: ClientError.self) { try store.reconcile(history: Data(#"{"data":[]}"#.utf8), active: true, for: other) }
        #expect(store.records.isEmpty && !store.active)
    }
    @Test func ambiguousAdmitDoesNotRetryAsPrompt() async {
        let rig = Rig()
        await rig.start()
        rig.backend.admitError = URLError(.networkConnectionLost)
        await rig.controller.post("Synthetic only", kind: .admitOnly, reason: "test", to: TargetLease(sessionID: "ses_A", generation: "initial"))
        #expect(rig.backend.admits == ["[voice] Synthetic only"])
        #expect(rig.backend.prompts.isEmpty)
        #expect(rig.controller.status.lastError?.contains("delivery unknown") == true)
        rig.controller.stop()
    }
    @Test func chiefReplacementDuringRecognitionKeepsOriginalTarget() async {
        let rig = Rig(configure: { $0.pauseMs = 3200 })
        rig.controller.setSendMode(.manual)
        await rig.start()
        rig.transcript = "Held original thought."
        rig.input.frames(20, voiced: true)
        rig.clock += 400
        writeChief(rig.chief, "ses_B")
        #expect(await waitUntil { rig.controller.status.target == "ses_B" })
        rig.controller.setMicMuted(true)
        #expect(await waitUntil { rig.controller.draftsForReview.first?.text == "Held original thought." })
        rig.controller.send()
        #expect(rig.backend.prompts.isEmpty)
        #expect(rig.controller.draftsForReview.first?.target.sessionID == "ses_A")
        rig.controller.stop()
    }
}
