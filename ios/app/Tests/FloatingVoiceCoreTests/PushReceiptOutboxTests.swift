import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct PushReceiptOutboxTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func terminalSurvivesProcessLossAndOnlyAcknowledgementRemovesIt() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("receipts.json"), call = UUID()
        let value = PendingPushReceipt(reachoutID:"test-call",call:call,receipt:CallReceipt(.ended,reason:.providerReset,initiator:.providerReset,reportedRinging:true))
        var outbox: PushReceiptOutbox? = PushReceiptOutbox(file:file)
        try outbox?.enqueue(value)
        // Simulated suspension/process loss BEFORE any network acknowledgement.
        outbox = nil
        let relaunched = PushReceiptOutbox(file:file)
        #expect(relaunched.entries == [value])
        let body = try value.body()
        #expect(body["callUUID"] as? String == call.uuidString.lowercased())
        #expect(body["endReason"] as? String == "providerReset" && body["reportedRinging"] as? Bool == true)
        try relaunched.acknowledge(value.id)
        #expect(PushReceiptOutbox(file:file).entries.isEmpty)
    }
    @Test func terminalTakesPriorityButDeclineAndEndBothRemainIdempotent() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let queue = PushReceiptOutbox(file:directory.appendingPathComponent("receipts.json")), call = UUID()
        for event in [CallReceipt.Event.reported,.ringing] {
            try queue.enqueue(PendingPushReceipt(reachoutID:"test",call:call,receipt:CallReceipt(event)))
        }
        let declined = PendingPushReceipt(reachoutID:"test",call:call,receipt:CallReceipt(.declined,reason:.declined,initiator:.systemEndAction,reportedRinging:true))
        try queue.enqueue(declined); try queue.enqueue(declined)
        try queue.enqueue(PendingPushReceipt(reachoutID:"test",call:call,receipt:CallReceipt(.ended,reason:.declined,initiator:.systemEndAction,reportedRinging:true)))
        #expect(queue.entries.map(\.receipt.event) == [.declined,.ended])
    }
    @Test func failedPersistenceStillRetainsTerminalForImmediateDeliveryAndAckIsNotFaked() throws {
        let queue = PushReceiptOutbox(file:URL(fileURLWithPath:"/unused/receipts.json"),save:{ _ in throw ClientError("storage unavailable") })
        let entry = PendingPushReceipt(reachoutID:"test",call:UUID(),receipt:CallReceipt(.ended,reason:.ringExpired,initiator:.ringDeadline))
        #expect(throws:(any Error).self) { try queue.enqueue(entry) }
        #expect(queue.entries == [entry])
        #expect(throws:(any Error).self) { try queue.acknowledge(entry.id) }
        #expect(queue.entries == [entry])
    }
    @Test func nativeWiringPersistsBeforeDispatchAndAcquiresAssertionBeforeProviderRetirement() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let native = try String(contentsOf:root.appendingPathComponent("native/PushCoordinator.swift"),encoding:.utf8)
        #expect(native.contains("model.calls.detailedReceipt ="))
        #expect(native.contains("beginBackgroundTask(withName: \"Call terminal receipts\")"))
        #expect(native.contains("try receiptOutbox.enqueue") && native.contains("try receiptOutbox.acknowledge(entry.id)"))
        #expect(native.contains("receiptWorker?.cancel()") && native.contains("flushReceiptOutbox()"))
    }
}
