import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct DiscardTests {
    @Test(arguments: ["device", "echo"])
    func manualHeldSpeechRemainsDiscardableAfterAudioRestart(restart: String) async throws {
        let r = Rig(appFile: tempDir() + "/settings.json")
        await r.start()
        r.controller.setSendMode(.manual)
        r.controller.composer.utterance("Keep private through restart.")
        r.controller.setMicMuted(true)
        r.controller.setOutputMuted(true)
        try await r.controller.apply(restart == "device" ? .outputDevice("fake-output") : .echoCancellation("on"))
        #expect(r.controller.status.pendingSpeech && r.controller.status.discardHotkeyEligible)
        r.controller.discardPending()
        #expect(r.controller.status.holding == nil && r.controller.composer.held.isEmpty)
        #expect(!r.controller.status.pendingSpeech && r.controller.status.micMuted && r.controller.status.outputMuted)
        r.controller.send()
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.prompts.isEmpty)
        r.controller.stop()
    }

    @Test(arguments: [false, true])
    func directKeepHeldRestartOrDiscardWhileOff(restart: Bool) async {
        let r = Rig()
        await r.start()
        r.controller.setSendMode(.manual)
        r.controller.composer.utterance("Retained unsent words.")
        r.controller.stop(keepHeld: true)
        #expect(r.controller.status.pendingSpeech && !r.controller.status.discardHotkeyEligible)
        if restart {
            await r.controller.start()
            #expect(r.controller.status.holding == "Retained unsent words.")
            #expect(r.controller.status.discardHotkeyEligible)
        }
        r.controller.discardPending()
        #expect(r.controller.composer.held.isEmpty && !r.controller.status.pendingSpeech)
        #expect(r.controller.status.running == restart)
        #expect(r.backend.prompts.isEmpty)
        r.controller.stop()
    }

    @Test(arguments: [false, true])
    func shortcutRegistrationAndConflictPolicy(conflict: Bool) {
        var registrations = 0, unregistrations = 0, errors: [String] = []
        let binding = DiscardShortcutBinding(register: {
            registrations += 1; return conflict ? "Discard shortcut unavailable; button still works" : nil
        }, unregister: { unregistrations += 1 }, reportError: { errors.append($0) })
        var status = ConversationController.Status()
        binding.update(status)
        status.running = true; binding.update(status)
        #expect(registrations == 0)
        status.pendingSpeech = true; binding.update(status); binding.update(status)
        status.micMuted = true; binding.update(status)
        #expect(registrations == 1 && errors.count == (conflict ? 1 : 0))
        status.pendingSpeech = false; binding.update(status)
        #expect(unregistrations == 1)
        status.pendingSpeech = true; binding.update(status)
        status.running = false; binding.update(status)
        #expect(registrations == 2 && unregistrations == 2)
    }

    @Test func prerollAndPartialPCMFrameAreDropped() {
        var written: [Data] = []
        final class Recording: RecognitionSession {
            let writePCM: (Data) -> Void
            init(_ writePCM: @escaping (Data) -> Void) { self.writePCM = writePCM }
            func start() {}; func write(_ pcm: Data) { writePCM(pcm) }
            func end() {}; func cancel() {}
        }
        let t = TurnTaker(config: VoiceConfig(), callbacks: TurnCallbacks(), makeRecognition: { _ in
            Recording { written.append($0) }
        })
        t.push(Data(repeating: 99, count: 7 * 640 + 320))
        t.discard()
        for _ in 0..<8 { t.push(FakeInput.tone) }
        #expect(written.count == 8 && written.allSatisfy { $0 == FakeInput.tone })
        t.stop()
    }

    @Test func activeBeforeFirstPartialAndLateCallbacksCannotResurrect() async {
        let r = Rig()
        await r.start()
        r.input.frames(8, voiced: true)
        #expect(r.controller.status.discardHotkeyEligible)
        let old = r.recognitions[0]
        let stops = r.output.stops
        r.controller.discardPending()
        #expect(old.cancelled && !r.controller.utteranceInProgress)
        #expect(!r.controller.status.pendingSpeech && r.controller.status.running)
        old.callbacks.live("private words")
        old.callbacks.partial("private words")
        old.callbacks.done("private words.")
        old.callbacks.error(ClientError("stale error"))
        #expect(r.backend.prompts.isEmpty && r.backend.interrupts.isEmpty)
        #expect(r.output.stops == stops && r.controller.status.lastError == nil)
        #expect(r.lines.contains { $0.contains("discard stage=unsent droppedCapture=true") })
        #expect(!r.lines.contains { $0.contains("private words") })
        r.transcript = "Fresh thought."
        r.speak()
        #expect(await waitUntil { r.backend.prompts.count == 1 })
        #expect(r.backend.prompts.first?.text == "[voice] Fresh thought.")
        old.callbacks.done("late old final")
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(r.backend.prompts.count == 1)
        r.controller.stop()
    }

    @Test(arguments: ["manual", "countdown", "busy"])
    func heldAndTimersAreCancelled(mode: String) async {
        let r = Rig(holdMs: 80, quietMs: 80, configure: { $0.pauseMs = 500 })
        await r.start()
        if mode == "manual" { r.controller.setSendMode(.manual) }
        if mode == "busy" { r.backend.send("session.execution.started", "ses_A"); #expect(await waitUntil { r.controller.status.busy }) }
        r.transcript = "a private unfinished thought with"
        r.speak()
        #expect(await waitUntil { r.controller.status.holding != nil })
        r.controller.discardPending()
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(r.controller.status.holding == nil && !r.controller.status.pendingSpeech)
        #expect(r.backend.prompts.isEmpty && r.backend.admits.isEmpty)
        r.controller.send()
        r.controller.stop()
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.prompts.isEmpty)
    }

    @Test(arguments: ["final", "mute", "send"])
    func awaitingFinalAndSendAfterFinalAreInvalidated(trigger: String) async {
        let r = Rig()
        await r.start()
        r.silentEnd = true
        r.input.frames(12, voiced: true)
        let old = r.recognitions[0]
        if trigger == "mute" { r.controller.setMicMuted(true) }
        else if trigger == "send" { r.controller.send() }
        else { r.controller.turnTaker?.endNow() }
        #expect(old.ended && r.controller.status.pendingSpeech)
        r.controller.discardPending()
        old.callbacks.done("private final.")
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(r.backend.prompts.isEmpty && r.controller.status.holding == nil)
        #expect(r.controller.status.micMuted == (trigger == "mute"))
        r.input.frames(7, voiced: true)
        #expect(r.recognitions.count == 1, "onset/pre-roll was cleared; mute stays muted")
        r.controller.stop()
    }

    @Test func discardWinsBeforeDeferredSubmission() async {
        let r = Rig()
        await r.start()
        r.controller.setSendMode(.manual)
        r.controller.composer.utterance("Unsent.")
        r.controller.send() // synchronous composition, backend task has not run
        #expect(r.controller.status.pendingSpeech)
        r.controller.discardPending()
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.prompts.isEmpty)
        r.controller.stop()
    }

    @Test func issuedPostIsCommittedAndPlaybackIsUntouched() async {
        let r = Rig(duration: 1)
        await r.start()
        r.backend.promptDelay = 0.2
        r.controller.setSendMode(.manual)
        var submitted = false
        r.controller.onCaption = { if case .posted = $0 { submitted = true } }
        r.controller.composer.utterance("Already issued.")
        r.controller.send()
        #expect(await waitUntil { submitted })
        r.reply(id: "playing", "Still speaking.")
        #expect(await waitUntil { !r.output.playing.isEmpty })
        let stops = r.output.stops
        r.controller.composer.utterance("Discard just this.")
        r.controller.discardPending()
        #expect(r.controller.status.busy && r.output.stops == stops && !r.output.playing.isEmpty)
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.prompts.map(\.text) == ["[voice] Already issued."])
        #expect(r.backend.interrupts.isEmpty)
        r.controller.stop()
    }

    @Test func coldBufferedPCMCannotOpenSocketAfterDiscard() async {
        var resume: CheckedContinuation<SpeechModelState, Error>?
        var opened = 0
        let warmup = SpeechWarmup()
        let input = FakeInput(), backend = FakeBackend()
        var app = AppSettings(); app.target = "ses_fake"
        let c = ConversationController(settings: LoadedSettings(app: app, voice: VoiceConfig(), voiceFile: nil,
                    appFile: "/nonexistent", chiefFile: "/nonexistent"), backend: backend, synth: FakeSynth(),
                    output: FakeOutput(), input: input, makeRecognition: { callbacks in
            HealthCheckedRecognition(endpoint: "ws://unused", key: nil, callbacks: callbacks, warmup: warmup,
                probe: { _, _ in try await withCheckedThrowingContinuation { resume = $0 } },
                make: { opened += 1; return FakeRecognition($0, transcript: "Old buffered audio.") })
        })
        await c.start()
        input.frames(20, voiced: true)
        #expect(await waitUntil { resume != nil })
        #expect(c.status.pendingSpeech)
        c.discardPending()
        resume?.resume(returning: .unloaded)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(opened == 0 && backend.prompts.isEmpty)
        c.stop()
    }

    @Test func confirmationIsPrivateAndExpiresWithoutErasingNewWords() {
        let r = PillRig()
        var announcements = 0
        r.pill.onDiscardAnnouncement = { announcements += 1 }
        r.pill.handle(.youLive("private old words"))
        r.pill.handle(.discarded("private old words"))
        #expect(r.pill.you.final == "Discarded" && r.pill.you.tail.isEmpty)
        #expect(announcements == 1)
        r.advance(1499)
        #expect(r.pill.you.discarded)
        r.advance(1)
        #expect(r.pill.you.isEmpty && !r.pill.you.discarded)
        r.pill.handle(.discarded(""))
        r.advance(500)
        r.pill.handle(.youStarted)
        r.pill.handle(.youLive("new words"))
        r.advance(2000)
        #expect(r.pill.you.tail == "new words" && !r.pill.you.discarded)
    }

    @Test func eligibilityAndOffMuteState() async {
        let r = Rig()
        #expect(!r.controller.status.discardHotkeyEligible)
        r.controller.discardPending()
        #expect(!r.controller.status.running && r.input.starts == 0)
        await r.start()
        #expect(!r.controller.status.discardHotkeyEligible)
        r.controller.setSendMode(.manual)
        r.controller.composer.utterance("held")
        r.controller.setMicMuted(true)
        #expect(r.controller.status.discardHotkeyEligible)
        r.controller.discardPending()
        #expect(r.controller.status.micMuted && !r.controller.status.discardHotkeyEligible)
        #expect(Hotkey.parse(Hotkey.discardSpec)?.keyCode == 51)
        #expect(Hotkey.parse(Hotkey.discardSpec) != Hotkey.parse(Hotkey.defaultSpec))
        let fence = CaptureEpoch(); let queued = fence.current; fence.advance()
        #expect(queued != fence.current)
        r.controller.stop()
        #expect(!r.controller.status.discardHotkeyEligible)
    }
}
