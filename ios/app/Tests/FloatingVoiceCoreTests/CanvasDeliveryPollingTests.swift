import Foundation
import Testing
@testable import FloatingVoiceCore

@MainActor struct CanvasDeliveryPollingTests {
    @Test func initialDeliveredNeedsNoPoll() async throws {
        var updates: [CanvasDeliveryStatus] = []
        let result = try await CanvasDeliveryPolling.run(initial: "delivered", check: {},
            wait: { Issue.record("Unnecessary wait") }, fetchStatus: { Issue.record("Unnecessary poll"); return nil }, observe: { updates.append($0) })
        #expect(result == .delivered && result.message == "Input sent" && updates == [.delivered])
    }
    @Test func queuedAndSendingBecomeDelivered() async throws {
        var reads = 0, waits = 0, updates: [CanvasDeliveryStatus] = []
        let result = try await CanvasDeliveryPolling.run(initial: "queued", check: {}, wait: { waits += 1 },
            fetchStatus: { reads += 1; return reads == 1 ? "sending" : "delivered" }, observe: { updates.append($0) })
        #expect(result == .delivered && reads == 2 && waits == 2)
        #expect(updates == [.queued, .sending, .delivered])
    }
    @Test func absentReceiptPendingRepliesKeepPollingUntilLaterProofArrives() async throws {
        let replies = ["queued", "sending", "sending", "delivered"]
        var reads = 0, waits = 0, updates: [CanvasDeliveryStatus] = []
        let result = try await CanvasDeliveryPolling.run(initial: "queued", check: {}, wait: { waits += 1 },
            fetchStatus: { defer { reads += 1 }; return replies[reads] }, observe: { updates.append($0) })
        #expect(result == .delivered && reads == 4 && waits == 4)
        #expect(updates == [.queued, .queued, .sending, .sending, .delivered])
        #expect(!updates.contains(.uncertain))
    }
    @Test func genuineHostUncertaintyRemainsTerminalWithoutAnyAutomaticRetry() async throws {
        var reads = 0, waits = 0
        let result = try await CanvasDeliveryPolling.run(initial: "uncertain", check: {}, wait: { waits += 1 },
            fetchStatus: { reads += 1; return "delivered" }, observe: { _ in })
        #expect(result == .uncertain && reads == 0 && waits == 0)
        #expect(result.message == "Delivery unknown · check History; not retried")
    }
    @Test func allTwentyPendingPollsEndUnknownNotSendingOrRetryable() async throws {
        var reads = 0, updates: [CanvasDeliveryStatus] = []
        let result = try await CanvasDeliveryPolling.run(initial: "queued", check: {}, wait: {},
            fetchStatus: { reads += 1; return "sending" }, observe: { updates.append($0) })
        #expect(reads == 20 && result == .uncertain && updates.last == .uncertain)
        #expect(!result.pending && result != .unsent)
        #expect(result.message == "Delivery unknown · check History; not retried")
    }
    @Test func twentiethResponseIsProcessedBeforeBudgetExpires() async throws {
        var reads = 0, updates: [CanvasDeliveryStatus] = []
        let result = try await CanvasDeliveryPolling.run(initial: "queued", check: {}, wait: {},
            fetchStatus: { reads += 1; return reads == 20 ? "delivered" : "queued" }, observe: { updates.append($0) })
        #expect(reads == 20 && result == .delivered && updates.last == .delivered)
        #expect(!updates.contains(.uncertain))
    }
    @Test func unsupportedOrMissingStatusIsUnknownNotAnAssumedSuccess() async throws {
        for value: String? in [nil, "sent", "accepted", "done", ""] {
            let result = try await CanvasDeliveryPolling.run(initial: value, check: {}, wait: {},
                fetchStatus: { Issue.record("Unknown state must not poll or retry"); return "delivered" }, observe: { _ in })
            #expect(result == .uncertain)
        }
    }
    @Test func onlyExplicitHostUnsentIsRetryable() async throws {
        let result = try await CanvasDeliveryPolling.run(initial: "unsent", check: {}, wait: {},
            fetchStatus: { Issue.record("Unsent must not auto-retry"); return "queued" }, observe: { _ in })
        #expect(result == .unsent && !result.pending)
    }
    @Test func leaseChangeAfterFetchCannotPublishDelivered() async throws {
        var valid = true, updates: [CanvasDeliveryStatus] = []
        do {
            try await CanvasDeliveryPolling.run(initial: "sending", check: { if !valid { throw CancellationError() } }, wait: {},
                fetchStatus: { valid = false; return "delivered" }, observe: { updates.append($0) })
            Issue.record("Changed lease accepted")
        } catch { #expect(error is CancellationError) }
        #expect(updates == [.sending])
        #expect(CanvasSubmissionPolicy.failure(status: nil, admitted: true) == .unknown)
    }
    @Test func exhaustedZeroBudgetIsUnknownWithoutNetworkRead() async throws {
        let result = try await CanvasDeliveryPolling.run(initial: "queued", budget: 0, check: {}, wait: {},
            fetchStatus: { Issue.record("Budget exceeded"); return nil }, observe: { _ in })
        #expect(result == .uncertain)
    }
    @Test func nativeUsesTestedPollerAndUnknownCannotKeepAnUnsentRetryButton() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let native = try String(contentsOf: root.appendingPathComponent("native/CanvasShowPanel.swift"))
        #expect(native.contains("CanvasDeliveryPolling.run"))
        #expect(native.contains("delivery = state.rawValue; status = state.message"))
        let unknown = try #require(native.components(separatedBy: "case .unknown:").last)
        #expect(unknown.contains("delivery = CanvasDeliveryStatus.uncertain.rawValue"))
        #expect(!unknown.contains("submitted = nil") && !unknown.contains("submissionID ="))
    }
}
