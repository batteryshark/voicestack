import Foundation
import Testing
@testable import FloatingVoiceCore

/// New synthetic source only. No captured records, service, device or execution proof.
@Suite @MainActor struct OrdinalSparseStorageTests {
    private let lease = TargetLease(sessionID: "synthetic-session", generation: "synthetic-generation")
    private let message = "synthetic-message"

    private func reconcile(_ store: ConversationStore, content: [[String: Any]]? = nil,
                           completed: Bool = false, snapshot: HistorySnapshot? = nil) throws -> [NarrationUpdate] {
        var records: [[String: Any]] = []
        if let content {
            var time: [String: Any] = ["created": 1]
            if completed { time["completed"] = 2 }
            records = [["id": message, "type": "assistant", "time": time, "content": content]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["data": records])
        return try store.reconcile(history: data, active: !completed, for: lease,
                                   snapshot: snapshot ?? store.beginHistorySnapshot())
    }
    private func event(_ kind: String, _ ordinal: Int, text: String? = nil,
                       delta: String? = nil) -> ServerEvent {
        var data: [String: Any] = ["sessionID": lease.sessionID,
                                  "assistantMessageID": message, "ordinal": ordinal]
        if let text { data["text"] = text }
        if let delta { data["delta"] = delta }
        return ServerEvent(type: "session.text." + kind, data: data)
    }
    private func blocks(_ store: ConversationStore) throws -> [[String: Any]] {
        guard let raw = store.records.first else { return [] }
        let record = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        return record["content"] as? [[String: Any]] ?? []
    }
    private func texts(_ store: ConversationStore) throws -> [String] {
        try blocks(store).filter { $0["type"] as? String == "text" }.map { $0["text"] as? String ?? "" }
    }

    @Test func hugeOrdinalRetainsExactIdentityAndImmediateNarrationWithoutGapAllocation() throws {
        let store = ConversationStore(target: lease)
        _ = try reconcile(store)
        let update = store.receive(event("ended", Int.max, text: "Far actual text."), eventID: "far-final", for: lease)
        #expect(update?.blockKey == message + ":" + String(Int.max))
        #expect(update?.context == "Far actual text." && update?.final == true)
        #expect(store.liveBlocks[message + ":" + String(Int.max)] == "Far actual text.")
        #expect(try blocks(store).isEmpty)
        #expect(store.receive(event("delta", Int.max, delta: "late"), eventID: "late", for: lease) == nil)
        #expect(try reconcile(store, content: [["type": "text", "text": "Known prefix."]]).isEmpty)
        #expect(try texts(store) == ["Known prefix."])
        #expect(store.liveBlocks[message + ":" + String(Int.max)] == "Far actual text.")
    }

    @Test func sparseArrivalMaterializesOnlyActualContiguousTextAndDoesNotRenumber() throws {
        let store = ConversationStore(target: lease)
        _ = try reconcile(store)
        let tail = store.receive(event("delta", 2, delta: "Tail"), eventID: "tail-delta", for: lease)
        #expect(tail?.blockKey == message + ":2" && tail?.suffix == "Tail")
        let final = store.receive(event("ended", 2, text: "Tail final."), eventID: "tail-final", for: lease)
        #expect(final?.context == "Tail final." && final?.final == true)
        #expect(try texts(store).isEmpty)
        _ = store.receive(event("ended", 0, text: "First."), eventID: "first-final", for: lease)
        #expect(try texts(store) == ["First."])
        #expect(store.liveBlocks[message + ":2"] == "Tail final.")
        _ = store.receive(event("ended", 1, text: "Second."), eventID: "second-final", for: lease)
        #expect(try texts(store) == ["First.", "Second.", "Tail final."])
        #expect(store.receive(event("ended", 2, text: "Tail final."), eventID: "tail-final", for: lease) == nil)
    }

    @Test func historyEstablishesPerTextPositionAmongOtherKindsWithoutReplayingSpeech() throws {
        let store = ConversationStore(target: lease)
        _ = try reconcile(store)
        let update = store.receive(event("ended", 2, text: "Live tail."), eventID: "tail", for: lease)
        #expect(update?.context == "Live tail.") // Narration precedes display reconciliation, as before.
        let content: [[String: Any]] = [
            ["type": "reasoning", "text": "Reasoning metadata."],
            ["type": "text", "text": "Historical first."],
            ["type": "tool", "name": "synthetic-tool", "state": ["status": "completed"]],
            ["type": "text", "text": "Historical second."],
            ["type": "text", "text": "Older tail snapshot."]
        ]
        #expect(try reconcile(store, content: content).isEmpty)
        #expect(try blocks(store).map { $0["type"] as? String ?? "" } == ["reasoning", "text", "tool", "text", "text"])
        #expect(try texts(store) == ["Historical first.", "Historical second.", "Live tail."])
        #expect(try reconcile(store, content: content).isEmpty)
    }

    @Test func reconnectUsesExistingSnapshotPreferenceAndCoveredSpeechFrontier() throws {
        let store = ConversationStore(target: lease)
        _ = try reconcile(store)
        let first = store.receive(event("delta", 2, delta: "Tail"), eventID: "delta", for: lease)
        #expect(first?.context == "Tail" && first?.final == false)
        store.beginReconnect()
        #expect(store.receive(event("delta", 2, delta: "ignored while unreconciled"), eventID: "unreconciled", for: lease) == nil)
        let content: [[String: Any]] = [
            ["type": "text", "text": "Silent first."],
            ["type": "text", "text": "Silent second."],
            ["type": "text", "text": "Tail extended."]
        ]
        let updates = try reconcile(store, content: content)
        #expect(updates.count == 1 && updates.first?.blockKey == message + ":2")
        #expect(updates.first?.suffix == " extended." && updates.first?.context == "Tail extended.")
        #expect(try texts(store) == ["Silent first.", "Silent second.", "Tail extended."])
        #expect(try reconcile(store, content: content).isEmpty)
        let final = store.receive(event("ended", 2, text: "Tail extended."), eventID: "final", for: lease)
        #expect(final?.suffix == "" && final?.final == true)
        #expect(store.receive(event("delta", 2, delta: "late"), eventID: "late", for: lease) == nil)
    }

    @Test func completedSparseTailSurvivesReconnectUntilHistorySuppliesItsPrefix() throws {
        let store = ConversationStore(target: lease)
        _ = try reconcile(store)
        _ = store.receive(event("ended", 1, text: "Completed live tail."), eventID: "tail-final", for: lease)
        store.beginReconnect()
        #expect(try reconcile(store, content: [["type": "text", "text": "Historical prefix."]]).isEmpty)
        #expect(try texts(store) == ["Historical prefix.", "Completed live tail."])
        #expect(store.liveBlocks[message + ":1"] == "Completed live tail.")
        #expect(try reconcile(store, content: [
            ["type": "text", "text": "Historical prefix."],
            ["type": "text", "text": "Older snapshot tail."]
        ]).isEmpty)
        #expect(try texts(store) == ["Historical prefix.", "Completed live tail."])
        #expect(store.receive(event("ended", 1, text: "Completed live tail."), eventID: "tail-final", for: lease) == nil)
        #expect(store.receive(event("ended", 1, text: "Late replacement."), eventID: "late-final", for: lease) == nil)
    }

    @Test func nonPrefixReconnectRepairDoesNotReplayUnknownBaselineDeltas() throws {
        let store = ConversationStore(target: lease)
        _ = try reconcile(store)
        _ = store.receive(event("delta", 1, delta: "Known tail."), eventID: "tail", for: lease)
        store.beginReconnect()
        let updates = try reconcile(store, content: [
            ["type": "text", "text": "Silent first."],
            ["type": "text", "text": "Earlier prefix and known tail."]
        ])
        #expect(updates.isEmpty) // Preserve the pre-existing non-prefix repair policy; no invented frontier.
        #expect(try texts(store) == ["Silent first.", "Earlier prefix and known tail."])
        let wrong = TargetLease(sessionID: lease.sessionID, generation: "other-generation")
        #expect(store.receive(event("ended", 1, text: "Wrong lease."), eventID: "wrong", for: wrong) == nil)
        #expect(try texts(store) == ["Silent first.", "Earlier prefix and known tail."])
    }

    @Test func absentTextFallbackRetainsRecordLiveAndSubsequentFullFinal() throws {
        let store = ConversationStore(target: lease)
        _ = try reconcile(store)
        let first = store.receive(event("delta", 1, delta: "Retained."), eventID: "retained", for: lease)
        #expect(first?.context == "Retained.")
        store.beginReconnect()
        #expect(try reconcile(store, content: [
            ["type": "text", "text": "Prefix."], ["type": "text", "marker": "preserved"]
        ]).isEmpty)
        #expect(try texts(store) == ["Prefix.", "Retained."])
        #expect(try blocks(store)[1]["marker"] as? String == "preserved")
        #expect(store.liveBlocks[message + ":1"] == "Retained.")
        let final = store.receive(event("ended", 1, text: "Retained. Finished."), eventID: "retained-final", for: lease)
        #expect(final?.suffix == " Finished." && final?.context == "Retained. Finished." && final?.final == true)
        #expect(try texts(store) == ["Prefix.", "Retained. Finished."])
        #expect(store.receive(event("ended", 1, text: "Retained. Finished."), eventID: "retained-final", for: lease) == nil)
    }

    @Test func presentTextFieldOverridesFallbackEvenWhenEmptyNullOrNonString() throws {
        for value: Any in ["Replacement.", "", NSNull(), 42] {
            let store = ConversationStore(target: lease)
            _ = try reconcile(store)
            _ = store.receive(event("delta", 1, delta: "Retained."), eventID: "retained", for: lease)
            store.beginReconnect()
            #expect(try reconcile(store, content: [
                ["type": "text", "text": "Prefix."], ["type": "text", "text": value, "marker": "preserved"]
            ]).isEmpty)
            let winning = try #require(blocks(store)[1]["text"])
            #expect(try JSONSerialization.data(withJSONObject: [winning]) == JSONSerialization.data(withJSONObject: [value]))
            #expect(try texts(store) == ["Prefix.", value as? String ?? ""])
            #expect(store.liveBlocks[message + ":1"] == (value as? String ?? ""))
            #expect(try blocks(store)[1]["marker"] as? String == "preserved")
        }
    }

    @Test func sameTokenPagesPendingBoundaryAndRequestOrderKeepActualParts() throws {
        let store = ConversationStore(target: lease)
        _ = try reconcile(store)
        _ = store.receive(event("ended", 2, text: "Tail."), eventID: "tail", for: lease)
        _ = store.receive(event("ended", 4, text: "Later."), eventID: "later", for: lease)
        let token = store.beginHistorySnapshot()
        #expect(try reconcile(store, content: [["type": "text", "text": "Prefix."]], snapshot: token).isEmpty)
        #expect(try texts(store) == ["Prefix."])
        #expect(try reconcile(store, content: [
            ["type": "text", "text": "Prefix."], ["type": "text", "text": "Middle."]
        ], snapshot: token).isEmpty)
        #expect(try texts(store) == ["Prefix.", "Middle.", "Tail."])
        #expect(store.liveBlocks[message + ":4"] == "Later.")
        #expect(try reconcile(store, content: [["type": "text", "text": "Shorter."]]).isEmpty)
        #expect(try texts(store) == ["Shorter.", "Middle.", "Tail."])
        #expect(try reconcile(store, content: [["type": "text", "text": "Older response."]], snapshot: token).isEmpty)
        #expect(try texts(store) == ["Shorter.", "Middle.", "Tail."])
        _ = store.receive(event("ended", 3, text: "Gap filled."), eventID: "gap", for: lease)
        #expect(try texts(store) == ["Shorter.", "Middle.", "Tail.", "Gap filled.", "Later."])
    }

    @Test func staleEpochRejectedAndEndedRecordMetadataPreservesSparseFallback() throws {
        let store = ConversationStore(target: lease)
        _ = try reconcile(store, content: [["type": "text", "text": "Stable prefix."]], completed: true)
        _ = store.receive(event("delta", 3, delta: "Retained tail."), eventID: "tail", for: lease)
        let stale = store.beginHistorySnapshot()
        store.beginReconnect()
        #expect(throws: (any Error).self) {
            try reconcile(store, content: [["type": "text", "text": "Stale." ]], snapshot: stale)
        }
        let updates = try reconcile(store, content: [
            ["type": "reasoning", "text": "Reasoning."], ["type": "text", "text": "Ignored replacement."],
            ["type": "tool", "name": "synthetic-tool"], ["type": "text", "text": "Second."],
            ["type": "text", "text": "Third."], ["type": "text"]
        ])
        #expect(try texts(store) == ["Stable prefix.", "Second.", "Third.", "Retained tail."])
        #expect(try blocks(store).map { $0["type"] as? String ?? "" } == ["reasoning", "text", "tool", "text", "text", "text"])
        let raw = try #require(store.records.first)
        let record = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect((record["time"] as? [String: Any])?["completed"] as? Int == 2)
        #expect(updates.count == 1 && updates.first?.suffix == "" && updates.first?.final == true)
        #expect(store.liveBlocks[message + ":3"] == "Retained tail.")
    }
}
