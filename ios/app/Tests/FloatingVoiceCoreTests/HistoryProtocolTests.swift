import Foundation
import Testing
@testable import FloatingVoiceCore

private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("bridge/fixtures/\(name).json"))
}

@Suite @MainActor struct HistoryProtocolTests {
    let lease = TargetLease(sessionID: "ses_testA", generation: "one")
    func page(_ text: String, completed: Bool = false, extra: [String: Any] = [:]) throws -> Data {
        var record: [String: Any] = ["id": "m", "type": "assistant", "time": completed ? ["created": 1, "completed": 2] : ["created": 1],
                                    "content": [["type": "text", "text": text], ["type": "tool", "future": ["attachment": "raw"]]]]
        record.merge(extra) { _, b in b }
        return try JSONSerialization.data(withJSONObject: ["data": [record]])
    }
    func event(_ type: String, _ text: String) -> ServerEvent {
        ServerEvent(type: "session.text.\(type)", data: ["sessionID": lease.sessionID, "assistantMessageID": "m", "ordinal": 0,
                                                       type == "delta" ? "delta" : "text": text])
    }
    @Test(arguments: [
        "Run this:\n```sh\nnot spoken\n```\nThen done.",
        "See [the docs](http://x.y/z) and ![img](a.png) now",
        "Open https://example.com/a?b=1 please",
        "# Title\n- item *one*\n> quoted `code` ~x~",
        "This sentence is long enough to speak before the final flush. A short tail."
    ])
    func contextSeamPreservesAcceptedCleaningAndSegmenting(_ text: String) throws {
        let store = ConversationStore(target: lease)
        try store.reconcile(history: Data("{\"data\":[]}".utf8), active: true, for: lease)
        var contextOutput: [String] = [], originalOutput: [String] = []
        let context = SpeechSegments { contextOutput.append($0) }
        let original = SpeechSegments { originalOutput.append($0) }
        context.consume(try #require(store.receive(event("delta", text), eventID: "d", for: lease)))
        original.push(text)
        context.consume(try #require(store.receive(event("ended", text), eventID: "e", for: lease)))
        original.flush(final: true)
        #expect(contextOutput == originalOutput)
    }
    @Test func prefixRepairEndStillFlushesPendingShortSuffixExactlyOnce() throws {
        let store = ConversationStore(target: lease)
        try store.reconcile(history: page("Old mistaken prefix. "), active: true, for: lease)
        var spoken: [String] = []
        let segments = SpeechSegments { spoken.append($0) }
        segments.consume(try #require(store.receive(event("delta", "New words"), eventID: "d", for: lease)))
        #expect(spoken.isEmpty)
        let end = event("ended", "Correct historical prefix. New words")
        let update = try #require(store.receive(end, eventID: "e", for: lease))
        #expect(update.final && update.suffix.isEmpty)
        segments.consume(update)
        #expect(spoken == ["New words"])
        #expect(store.receive(end, eventID: "e2", for: lease) == nil)
        #expect(store.liveBlocks["m:0"] == "Correct historical prefix. New words")
    }
    @Test(arguments: [
        ("History. ```swift\n", "let secret = 123\n", "```\nReal prose.", "Real prose."),
        ("History. [Historical", " new label](https://example.invalid)", " and prose.", "new label and prose."),
        ("History. `old", "New`", " prose.", "New prose."),
        ("History. [Old label](https://exam", "ple.invalid)", " Fresh prose.", "Fresh prose.")
    ])
    func reconnectKeepsFullMarkdownContext(_ parts: (String, String, String, String)) throws {
        let (history, delta, tail, expected) = parts
        let store = ConversationStore(target: lease)
        try store.reconcile(history: page(history), active: true, for: lease)
        store.beginReconnect()
        try store.reconcile(history: page(history), active: true, for: lease)
        var spoken: [String] = []
        let segments = SpeechSegments { spoken.append($0) }
        segments.consume(try #require(store.receive(event("delta", delta), eventID: "d", for: lease)))
        #expect(spoken.isEmpty)
        let end = event("ended", history + delta + tail)
        segments.consume(try #require(store.receive(end, eventID: "e", for: lease)))
        #expect(spoken == [expected])
        #expect(store.receive(end, eventID: "e-again", for: lease) == nil)
    }
    @Test func changedStalePagesCannotRevertLiveCorrectionOrLoseRawMetadata() throws {
        let store = ConversationStore(target: lease)
        let oldRequest = store.beginHistorySnapshot()
        let newRequest = store.beginHistorySnapshot()
        try store.reconcile(history: page("Original uncompleted snapshot."), active: true, for: lease, snapshot: oldRequest)
        try store.reconcile(history: page("New snapshot. ", extra: ["metadata": ["new": true]]), active: true, for: lease, snapshot: newRequest)
        try store.reconcile(history: page("Stale nonprefix.", extra: ["metadata": ["oldUnknown": "kept"]]), active: true, for: lease, snapshot: oldRequest)
        #expect(store.liveBlocks["m:0"] == "New snapshot. ")
        _ = store.receive(event("delta", "Live."), eventID: "d", for: lease)
        _ = store.receive(event("ended", "Authoritatively corrected live."), eventID: "e", for: lease)
        let late = store.beginHistorySnapshot()
        try store.reconcile(history: page("Different stale ended text.", completed: true, extra: ["future": "also retained"]), active: false, for: lease, snapshot: late)
        #expect(store.liveBlocks["m:0"] == "Authoritatively corrected live.")
        let raw = try #require(try JSONSerialization.jsonObject(with: store.records[0]) as? [String: Any])
        let blocks = try #require(raw["content"] as? [[String: Any]])
        #expect(blocks[0]["text"] as? String == store.liveBlocks["m:0"])
        #expect((blocks[1]["future"] as? [String: String])?["attachment"] == "raw")
        #expect((raw["metadata"] as? [String: Any])?["oldUnknown"] as? String == "kept")
        #expect(raw["future"] as? String == "also retained")
        store.beginReconnect()
        #expect(throws: ClientError.self) { try store.reconcile(history: page("Obsolete epoch"), active: false, for: lease, snapshot: late) }
        try store.reconcile(history: page("Reconnect stale correction"), active: false, for: lease)
        #expect(store.liveBlocks["m:0"] == "Authoritatively corrected live.")
    }
    @Test func completedSnapshotCannotBeRevertedByChangedOverlap() throws {
        let store = ConversationStore(target: lease)
        try store.reconcile(history: page("Known ended.", completed: true), active: false, for: lease)
        try store.reconcile(history: page("Older different text."), active: false, for: lease, snapshot: store.beginHistorySnapshot())
        #expect(store.liveBlocks["m:0"] == "Known ended.")
    }
    @Test func reconnectRepairPreservesSilentHistoryAndRejectsStaleSameEpochPages() throws {
        let store = ConversationStore(target: lease)
        try store.reconcile(history: page("Silent history. "), active: true, for: lease)
        var spoken: [String] = []
        let segments = SpeechSegments { spoken.append($0) }
        segments.consume(try #require(store.receive(event("delta", "First words. "), eventID: "first", for: lease)))
        segments.flush(final: true)
        store.beginReconnect()
        let stale = store.beginHistorySnapshot(), fresh = store.beginHistorySnapshot()
        let updates = try store.reconcile(history: page("Silent history. First words. Finished during disconnect.", completed: true), active: false, for: lease, snapshot: fresh)
        updates.forEach { segments.consume($0) }
        #expect(updates.map(\.suffix) == ["Finished during disconnect."])
        #expect(spoken == ["First words.", "Finished during disconnect."])
        let ignored = try store.reconcile(history: page("Silent history. First words. "), active: true, for: lease, snapshot: stale)
        #expect(ignored.isEmpty)
        #expect(store.liveBlocks["m:0"] == "Silent history. First words. Finished during disconnect.")
    }
    @Test func reconnectShorterSnapshotCannotMoveSpokenBoundaryBackwards() throws {
        let store = ConversationStore(target: lease)
        try store.reconcile(history: Data("{\"data\":[]}".utf8), active: true, for: lease)
        _ = store.receive(event("delta", "First words. "), eventID: "first", for: lease)
        store.beginReconnect()
        let updates = try store.reconcile(history: page("First"), active: true, for: lease, snapshot: store.beginHistorySnapshot())
        #expect(updates.isEmpty && store.liveBlocks["m:0"] == "First")
        let end = try #require(store.receive(event("ended", "First words. Finished during disconnect."), eventID: "end", for: lease))
        #expect(end.suffix == "Finished during disconnect.")
        #expect(end.context == "First words. Finished during disconnect.")
    }
    @Test func staleHistoryCannotOverrideLiveExecutionOrBlockLongCodeContext() throws {
        let store = ConversationStore(target: lease)
        try store.reconcile(history: page("History. ```swift\n"), active: true, for: lease)
        let request = store.beginHistorySnapshot()
        let finished = ServerEvent(type: "session.execution.succeeded", data: ["sessionID": lease.sessionID])
        _ = store.receive(finished, eventID: "execution", for: lease)
        try store.reconcile(history: page("Changed stale text."), active: true, for: lease, snapshot: request)
        #expect(!store.active)
        // Use a separate block/store to prove code beyond the long-chunk threshold is silent.
        let codeStore = ConversationStore(target: lease)
        try codeStore.reconcile(history: page("History. ```swift\n"), active: true, for: lease)
        let code = String(repeating: "let hidden = 123; ", count: 30)
        var spoken: [String] = []
        let segments = SpeechSegments { spoken.append($0) }
        segments.consume(try #require(codeStore.receive(event("delta", code), eventID: "d", for: lease)))
        #expect(spoken.isEmpty)
        segments.consume(try #require(codeStore.receive(event("ended", "History. ```swift\n" + code + "\n```\nReal prose."), eventID: "e", for: lease)))
        #expect(spoken == ["Real prose."])
    }
    @Test func midReplyReconnectNarratesOnlyNewSuffixIncludingAuthoritativeEnd() throws {
        let store = ConversationStore(target: lease)
        try store.reconcile(history: fixture("history-asc-page1"), active: true, for: lease)
        store.beginReconnect()
        try store.reconcile(history: fixture("history-asc-page1"), active: true, for: lease)
        func event(_ type: String, _ fields: [String: Any]) -> ServerEvent {
            ServerEvent(type: type, data: fields.merging(["sessionID": lease.sessionID, "assistantMessageID": "msg_fixture2", "ordinal": 0]) { _, b in b })
        }
        var spoken: [String] = []
        let segments = SpeechSegments { spoken.append($0) }
        let delta = event("session.text.delta", ["delta": "New "])
        let first = try #require(store.receive(delta, eventID: "evt_new1", for: lease))
        #expect(first.suffix == "New ")
        segments.consume(first)
        #expect(store.receive(delta, eventID: "evt_new1", for: lease) == nil)
        // A delayed overlapping page cannot move the narration boundary backwards.
        try store.reconcile(history: fixture("history-asc-page1"), active: true, for: lease)
        let end = event("session.text.ended", ["text": "Already visible. New suffix."])
        let last = try #require(store.receive(end, eventID: "evt_new2", for: lease))
        #expect(last.suffix == "suffix." && last.final)
        segments.consume(last)
        #expect(spoken == ["New suffix."])
        #expect(store.receive(end, eventID: "evt_duplicate_end", for: lease) == nil)
        #expect(store.liveBlocks["msg_fixture2:0"] == "Already visible. New suffix.")
    }
    @Test func multipageOverlapsRetainOriginalAttachmentAndUnknownFieldsInChronologicalOrder() throws {
        let store = ConversationStore(target: lease)
        try store.reconcile(history: fixture("history-asc-page2"), active: false, for: lease)
        try store.reconcile(history: fixture("history-asc-page1"), active: false, for: lease)
        try store.reconcile(history: fixture("history-asc-page2"), active: false, for: lease)
        let records = try store.records.map { try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        #expect(records.compactMap { $0["id"] as? String } == ["msg_fixture1", "msg_fixture2", "msg_fixture3"])
        #expect((records[0]["files"] as? [[String: Any]])?.first?["mime"] as? String == "image/png")
        #expect((records[1]["content"] as? [[String: Any]])?.count == 3)
        #expect((records[1]["metadata"] as? [String: Any])?["future"] != nil)
        #expect((records[2]["metadata"] as? [String: Any])?["unknown"] != nil)
    }
    @Test func actualDefaultTTSRequestMatchesSharedWAVFixtureAndPCMRemainsAvailable() throws {
        let expected = try #require(try JSONSerialization.jsonObject(with: fixture("tts-default-request")) as? [String: String])
        #expect(HTTPSpeechSynthesizer.requestBody("Synthetic", config: VoiceConfig()) == expected)
        var pcm = VoiceConfig(); pcm.ttsStream = true
        #expect(HTTPSpeechSynthesizer.requestBody("Synthetic", config: pcm)["response_format"] == "pcm")
    }
}
