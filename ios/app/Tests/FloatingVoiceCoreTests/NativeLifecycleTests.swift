import Foundation
import Testing
@testable import FloatingVoiceCore

/// No AVAudioSession/engine is constructed. These are the exact ownership and notification
/// handlers used by IOSAudio and PhoneModel, with resource/permission operations injected.
@MainActor private final class NativeInput: AudioInput {
    var onPCM: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    var duplexSafe = true
    let capture = CaptureLifecycle()
    var permissions: [CheckedContinuation<Void, Error>] = []
    var gated = true
    var active = false, engine = false, tap = false
    var failAt = 0
    var opens = 0, closes = 0
    var queued: [() -> Void] = []
    func start() async throws {
        try await capture.start(permission: {
            if self.gated { try await withCheckedThrowingContinuation { self.permissions.append($0) } }
        }, activate: {
            self.active = true
            if self.failAt == 1 { throw ClientError("routing failed after activation") }
        }, open: { owner in
            self.opens += 1
            if self.failAt == 2 { throw ClientError("format failed") }
            self.tap = true; self.engine = true
            self.queued.append { [weak self] in
                guard let self, self.capture.admits(owner) else { return }
                self.onPCM?(FakeInput.tone)
            }
            if self.failAt == 3 { throw ClientError("engine start failed") }
        }, close: { self.close() }, deactivate: { self.active = false })
    }
    func close() { closes += 1; tap = false; engine = false }
    func stop() { capture.stop(close: { self.close() }, deactivate: { self.active = false }) }
    func allow(_ index: Int = 0) { permissions[index].resume() }
}

@MainActor private final class NativeRig {
    let input = NativeInput()
    let backend = FakeBackend()
    let synth = FakeSynth()
    let lifecycle = NativeVoiceLifecycle()
    let controller: ConversationController
    init() {
        var app = AppSettings(); app.target = "ses_A"
        controller = ConversationController(settings: LoadedSettings(app: app, voice: VoiceConfig(), voiceFile: nil,
            appFile: "/nonexistent", chiefFile: "/nonexistent"), backend: backend, synth: synth,
            output: FakeOutput(), input: input, makeRecognition: { FakeRecognition($0, transcript: "words") })
        lifecycle.controller = controller
    }
    func start() -> Task<Void, Never> {
        let owner = lifecycle.requestStart()
        return Task { await self.lifecycle.start(owner) }
    }
    func stop() { lifecycle.invalidate(); controller.stop(keepHeld: true) }
}

@Suite("Native capture ownership and notification integration") @MainActor
struct NativeLifecycleTests {
    @Test(arguments: ["Stop", "background", "selection change"])
    func pendingPermissionInvalidated(_ action: String) async {
        let r = NativeRig(); let start = r.start()
        #expect(await waitUntil { r.input.permissions.count == 1 })
        // PhoneModel's Stop, scene background and select all invalidate then stop this controller.
        r.stop(); r.input.allow(); await start.value
        #expect(!r.controller.status.running)
        #expect(!r.input.capture.capturing && !r.input.active && !r.input.engine && !r.input.tap)
        #expect(r.input.opens == 0)
    }

    @Test(arguments: [true, false])
    func rapidStopStartOldPermissionCannotOverride(_ oldFirst: Bool) async {
        let r = NativeRig(); let old = r.start()
        #expect(await waitUntil { r.input.permissions.count == 1 })
        r.stop(); let new = r.start()
        #expect(await waitUntil { r.input.permissions.count == 2 })
        if oldFirst { r.input.allow(0); await old.value }
        r.input.allow(1); await new.value
        let generation = r.input.capture.generation
        if !oldFirst { r.input.allow(0); await old.value }
        #expect(r.input.capture.capturing && r.input.active && r.controller.status.running)
        #expect(r.input.opens == 1 && r.input.capture.generation == generation)
        r.stop()
        #expect(!r.input.active && !r.input.capture.capturing)
    }

    @Test(arguments: [1, 2, 3])
    func everyPartialResourceFailureUnwinds(_ stage: Int) async {
        let r = NativeRig(); r.input.gated = false; r.input.failAt = stage
        await r.start().value
        #expect(!r.controller.status.running && !r.input.active && !r.input.engine && !r.input.tap)
        #expect(r.input.closes == 1)
    }

    @Test func queuedPCMAndControllerCallbackCannotEnterLaterCapture() async {
        let r = NativeRig(); r.input.gated = false
        await r.start().value
        let oldPCM = r.input.queued[0], oldControllerPCM = r.input.onPCM
        r.stop(); await r.start().value
        var frames = 0
        r.controller.onCaption = { if case .micLevel = $0 { frames += 1 } }
        #expect(await waitUntil { r.controller.currentLease != nil })
        oldPCM(); oldControllerPCM?(FakeInput.tone)
        #expect(frames == 0)
        r.input.queued[1]()
        #expect(frames == 1)
        r.stop()
    }

    @Test func interruptionRetainsDesiredMutesBeforePermissionAndNarration() async {
        let r = NativeRig(); r.input.gated = false
        await r.start().value
        r.lifecycle.setMicMuted(true); r.lifecycle.setOutputMuted(true)
        r.lifecycle.handle(.interruptionBegan); r.lifecycle.handle(.interruptionBegan)
        #expect(!r.input.active && !r.controller.status.running)
        r.input.gated = true
        r.lifecycle.handle(.interruptionEnded(resume: true))
        r.lifecycle.handle(.interruptionEnded(resume: true))
        #expect(await waitUntil { r.input.permissions.count == 1 })
        #expect(r.controller.status.micMuted && r.controller.status.outputMuted)
        r.controller.consumeNarration(.init(blockKey: "new", suffix: "Must stay silent.", context: "Must stay silent.", silentUTF16: 0, final: true))
        r.lifecycle.handle(.routeChanged); r.lifecycle.handle(.mediaReset)
        r.input.allow();
        #expect(await waitUntil { r.input.capture.capturing && r.controller.status.phase == "ready" })
        #expect(r.controller.status.running && r.controller.status.micMuted && r.controller.status.outputMuted)
        #expect(r.synth.prepared.isEmpty && r.input.opens == 2)
        r.stop()
    }

    @Test(arguments: ["Stop", "background", "selection change"])
    func interruptionExplicitStopInvalidatesResume(_ action: String) async {
        let r = NativeRig(); r.input.gated = false; await r.start().value
        r.lifecycle.handle(.interruptionBegan); r.stop()
        r.lifecycle.handle(.interruptionEnded(resume: true)); r.lifecycle.handle(.routeChanged); r.lifecycle.handle(.mediaReset)
        await Task.yield()
        #expect(!r.controller.status.running && !r.input.active && r.input.opens == 1)
    }

    @Test func validUnmutedResumeAndRecoveryCoalescing() async {
        let r = NativeRig(); r.input.gated = false; await r.start().value
        r.lifecycle.handle(.interruptionBegan); r.lifecycle.handle(.interruptionEnded(resume: true))
        #expect(await waitUntil { r.input.opens == 2 && r.controller.status.phase == "ready" })
        #expect(!r.controller.status.micMuted && !r.controller.status.outputMuted)
        r.lifecycle.handle(.routeChanged); r.lifecycle.handle(.routeChanged); r.lifecycle.handle(.mediaReset)
        #expect(await waitUntil { r.input.opens == 3 && r.controller.status.phase == "ready" })
        #expect(r.controller.status.running)
        r.stop()
    }

    @Test func stopDuringResumedPermissionCannotReactivate() async {
        let r = NativeRig(); r.input.gated = false; await r.start().value
        r.lifecycle.setMicMuted(true); r.lifecycle.setOutputMuted(true)
        r.lifecycle.handle(.interruptionBegan)
        r.input.gated = true
        r.lifecycle.handle(.interruptionEnded(resume: true))
        #expect(await waitUntil { r.input.permissions.count == 1 })
        r.stop(); r.input.allow()
        await Task.yield(); await Task.yield()
        #expect(!r.controller.status.running && !r.input.active && r.input.opens == 1)
    }

    @Test func deniedAndCancelledPermissionAcquireNothing() async {
        let r = NativeRig(); let denied = r.start()
        #expect(await waitUntil { r.input.permissions.count == 1 })
        r.input.permissions[0].resume(throwing: ClientError("permission denied"))
        await denied.value
        #expect(!r.controller.status.running && !r.input.active && r.input.opens == 0)
        let cancelled = r.start()
        #expect(await waitUntil { r.input.permissions.count == 2 })
        cancelled.cancel(); r.input.allow(1); await cancelled.value
        #expect(!r.controller.status.running && !r.input.active && r.input.opens == 0)
    }

    @Test func interruptionWithoutResumeStaysOff() async {
        let r = NativeRig(); r.input.gated = false; await r.start().value
        r.lifecycle.handle(.interruptionBegan); r.lifecycle.handle(.interruptionEnded(resume: false))
        r.lifecycle.handle(.interruptionEnded(resume: true)); r.lifecycle.handle(.routeChanged)
        await Task.yield()
        #expect(!r.lifecycle.requested && !r.controller.status.running && !r.input.active)
    }
}
