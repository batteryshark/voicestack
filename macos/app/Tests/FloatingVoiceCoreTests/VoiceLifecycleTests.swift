import Foundation
import Testing
@testable import FloatingVoiceCore
@testable import FloatingVoiceAudio

/// Exercises MacAudio.start/begin/close, replacing only device/permission operations.
@Suite(.serialized) @MainActor struct VoiceLifecycleTests {
    final class Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    @Test func permissionReturningAfterStopCannotAcquireCapture() async {
        let gate = Gate(), audio = MacAudio(config: { VoiceConfig() })
        var opens = 0
        audio.startupTestHooks = .init(permission: { await gate.wait() }, open: { _ in opens += 1 })
        let start = Task { try await audio.start() }
        #expect(await waitUntil { gate.entered })
        audio.stop()
        gate.release()
        _ = await start.result
        #expect(opens == 0)
        #expect(!audio.capturing)
        audio.stop()
    }

    @Test(arguments: [false, true]) func queuedStartupAfterStopCannotAcquire(capture: Bool) async {
        let gate = Gate(), audio = MacAudio(config: { VoiceConfig() })
        var opens = 0
        audio.startupTestHooks = .init(permission: {}, beforeEngine: { await gate.wait() }, open: { _ in opens += 1 })
        let start = Task {
            if capture { try await audio.start() }
            else { try await audio.play(.whole(Data(), sampleRate: 24000), label: "fake") {} }
        }
        #expect(await waitUntil { gate.entered })
        audio.stop()
        gate.release()
        _ = await start.result
        #expect(opens == 0)
        #expect(!audio.capturing)
        audio.stop()
    }

    @Test(arguments: [false, true]) func oldStartupFailureCannotCloseNewCapture(oldCapture: Bool) async throws {
        let gate = Gate(), audio = MacAudio(config: { VoiceConfig() })
        var opens = 0, closes = 0
        audio.startupTestHooks = .init(permission: {}, open: { _ in opens += 1 }, ready: {
            if opens == 1 { await gate.wait(); throw CancellationError() }
        }, closed: { closes += 1 })
        let old = Task {
            if oldCapture { try await audio.start() }
            else { try await audio.play(.whole(Data(), sampleRate: 24000), label: "fake") {} }
        }
        #expect(await waitUntil { gate.entered })
        audio.stop()
        try await audio.start()
        #expect(audio.capturing && opens == 2)
        let before = closes
        gate.release()
        _ = await old.result
        #expect(closes == before)
        #expect(audio.capturing)
        audio.stop()
    }

    @Test func cancelledPermissionCannotAcquireWithoutStop() async {
        let gate = Gate(), audio = MacAudio(config: { VoiceConfig() })
        var opens = 0
        audio.startupTestHooks = .init(permission: { await gate.wait() }, open: { _ in opens += 1 })
        let start = Task { try await audio.start() }
        #expect(await waitUntil { gate.entered })
        start.cancel()
        gate.release()
        _ = await start.result
        #expect(opens == 0)
        audio.stop()
    }

    @Test(arguments: [false, true]) func currentStartupFailureStillClosesOwnGraph(capture: Bool) async {
        let audio = MacAudio(config: { VoiceConfig() })
        var acquired = false
        audio.startupTestHooks = .init(permission: {}, open: { _ in acquired = true },
            ready: { throw ClientError("Synthetic startup failure") }, closed: { acquired = false })
        do {
            if capture { try await audio.start() }
            else { try await audio.play(.whole(Data(), sampleRate: 24000), label: "fake") {} }
            Issue.record("Expected startup failure")
        } catch { #expect(error.localizedDescription == "Synthetic startup failure") }
        #expect(!acquired && !audio.capturing)
        audio.stop()
    }
}
