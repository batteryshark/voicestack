import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct RouteVoicePolicyTests {
    @Test func midThoughtPauseAndTapSend() async {
        let rig = Rig { $0.pauseMs = 3200 }
        rig.transcript = "Please keep this as one thought."
        await rig.start()
        rig.input.frames(30, voiced: true); rig.input.frames(125, voiced: false)
        #expect(rig.recognitions.count == 1 && !rig.recognitions[0].ended)
        #expect(rig.controller.status.sendCountdown?.seconds(at: rig.clock) == 3)
        rig.input.frames(30, voiced: true)
        #expect(rig.controller.status.sendCountdown == nil)
        rig.input.frames(25, voiced: false); rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.text == "[voice] " + rig.transcript && rig.recognitions.count == 1)
        #expect(rig.controller.status.sendCountdown == nil)
        rig.controller.stop()
    }

    @Test func speakerNeverOpensRecognitionAndResumesAfterQuietTail() async {
        let rig = Rig(duration: 5)
        rig.input.duplexSafe = false
        await rig.start()
        rig.controller.speaker.enqueue(one)
        #expect(await waitUntil { rig.controller.speaker.playing })
        #expect(rig.controller.status.halfDuplex && rig.controller.status.canBargeIn)
        rig.input.noise(300, rms: 0.4)
        #expect(rig.recognitions.isEmpty && rig.backend.prompts.isEmpty)
        rig.controller.speaker.stop()
        rig.clock += rig.controller.app.turnEndQuietMs - 1
        rig.input.frames(20, voiced: true)
        #expect(rig.recognitions.isEmpty && rig.controller.status.listeningSuppressed)
        rig.clock += 2
        rig.speak()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(!rig.controller.status.listeningSuppressed)
        rig.controller.stop()
    }

    @Test func liveRouteSwitchChangesDuplexImmediatelyDuringPlayback() async {
        let rig = Rig(duration: 5)
        rig.input.duplexSafe = false
        await rig.start()
        rig.controller.speaker.enqueue(one)
        #expect(await waitUntil { rig.controller.speaker.playing })
        rig.input.duplexSafe = true
        #expect(!rig.controller.halfDuplex && !rig.controller.status.listeningSuppressed)
        rig.input.frames(8, voiced: true)
        #expect(rig.recognitions.count == 1)
        rig.input.duplexSafe = false
        #expect(rig.controller.halfDuplex && rig.controller.status.listeningSuppressed)
        #expect(rig.recognitions.first?.cancelled == true)
        rig.input.frames(100, voiced: true)
        #expect(rig.recognitions.count == 1 && rig.backend.prompts.isEmpty)
        rig.controller.stop()
    }

    @Test func manualBargeInListensAfterShortGuardAndNeverInterruptsTheModel() async {
        let rig = Rig(duration: 5) { $0.bargeInAborts = true }
        rig.input.duplexSafe = false
        rig.transcript = "Yes."
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        rig.controller.speaker.enqueue(one)
        #expect(await waitUntil { rig.controller.speaker.playing })
        rig.controller.bargeIn()
        #expect(!rig.controller.speaker.playing && rig.controller.status.listeningSuppressed)
        #expect(rig.controller.status.busy && rig.backend.interrupts.isEmpty && rig.backend.admits.isEmpty)
        rig.reply(id: "later", two)
        #expect(await waitUntil { rig.lines.contains { $0.hasPrefix("text.ended") && $0.contains("later") } })
        #expect(!rig.controller.speaker.active && rig.controller.status.narrationPaused)
        rig.clock += ConversationController.manualBargeQuietMs + 1
        rig.speak()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.delivery == .queue)
        #expect(rig.backend.interrupts.isEmpty && rig.backend.admits.isEmpty)
        rig.controller.stop()
    }

    @Test func queuedSpeakerCaptureCannotLeakAcrossTheRouteSwitch() async {
        let rig = Rig(duration: 5)
        rig.input.duplexSafe = false
        await rig.start()
        rig.controller.speaker.enqueue(one)
        #expect(await waitUntil { rig.controller.speaker.playing })
        rig.input.duplexSafe = true
        rig.input.lastCaptureRendered = true
        rig.input.lastCaptureDuplexSafe = false // old speaker buffers queued before the actor hop
        rig.input.frames(40, voiced: true)
        #expect(rig.recognitions.isEmpty && !rig.controller.halfDuplex)
        rig.input.lastCaptureDuplexSafe = true // fresh receiver input is admitted immediately
        rig.input.frames(8, voiced: true)
        #expect(rig.recognitions.count == 1)
        rig.controller.stop()
    }

    @Test func duplexSettingIsTheOverrideEvenOnSafeRoutes() async {
        let rig = Rig(duration: 5) { $0.duplex = false }
        await rig.start()
        rig.controller.speaker.enqueue(one)
        #expect(await waitUntil { rig.controller.speaker.playing })
        #expect(rig.input.duplexSafe && rig.controller.halfDuplex)
        rig.input.frames(40, voiced: true)
        #expect(rig.recognitions.isEmpty)
        rig.controller.stop()
    }

    @Test(arguments: ["yes", "We'll do", "Yes, but I meant my home reply instead."])
    func finalOnlyDuplexInterjectionsUseTheSharedBackchannelDecision(_ text: String) async {
        let rig = Rig(duration: 5)
        rig.transcript = text
        await rig.start()
        rig.input.frames(60, voiced: false)
        rig.controller.speaker.enqueue("Yes. Will do. My whole reply follows.")
        #expect(await waitUntil { rig.controller.speaker.playing })
        // Only 160ms of genuine 0.06 RMS speech: below the sustained-barge
        // duration. No partial/live words; the final itself must admit barge-in.
        rig.input.noise(8, rms: 0.06)
        #expect(rig.controller.speaker.playing)
        rig.input.frames(60, voiced: false)
        #expect(await waitUntil { !rig.controller.utteranceInProgress })
        if text == "yes" {
            #expect(rig.controller.speaker.playing && rig.output.stops == 0 && rig.backend.prompts.isEmpty)
        } else {
            #expect(await waitUntil { !rig.controller.speaker.playing && rig.backend.prompts.count == 1 })
            #expect(rig.backend.prompts.first?.text == "[voice] " + text)
        }
        rig.controller.stop()
    }

    @Test func playbackCannotPoisonFloorAfterItEndsBeforeNoiseDiscard() {
        var playing = false
        var cb = TurnCallbacks(); cb.rendering = { playing }
        var cfg = VoiceConfig(); cfg.pauseMs = 60000
        let t = TurnTaker(config: cfg, callbacks: cb) { FakeRecognition($0, transcript: "") }
        t.expectLiveWords = true
        let input = FakeInput(); input.onPCM = { t.push($0) }
        input.noise(100, rms: 0.005)
        let baseline = t.noiseFloor
        playing = true
        input.noise(240, rms: 0.1)
        #expect(t.inUtterance && t.noiseFloor == baseline)
        playing = false
        input.noise(18, rms: 0.005) // 5s no-words discard happens AFTER playback
        #expect(!t.inUtterance && t.noiseFloor < 0.006)
        input.noise(250, rms: 0.008)
        #expect(t.noiseFloor > baseline) // ordinary ambient adaptation is unchanged
        t.stop()
    }

    @Test func savedBuiltInDefaultNeverOverridesBluetoothOrSystemRouteChoices() throws {
        let suite = "voice-route-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        SpeakerRoutePreference.save(false, defaults)
        var policy = BuiltInRoutePolicy(defaultSpeaker: SpeakerRoutePreference.load(defaults))
        policy.begin()
        #expect(policy.activationOverride(current: .bluetooth) == nil)
        #expect(policy.activationOverride(current: .headphones) == nil)
        #expect(policy.activationOverride(current: .speaker) == nil) // later system change is not overridden
        #expect(!SpeakerRoutePreference.load(UserDefaults(suiteName: suite)!))
        policy.begin()
        #expect(policy.activationOverride(current: .phone) == nil)
        #expect(!policy.categoryDefaultToSpeaker)
        policy.chooseSpeaker(true) // only deliberate in-app choices get saved
        SpeakerRoutePreference.save(policy.defaultSpeaker, defaults)
        #expect(policy.activationOverride(current: .bluetooth) == nil)
        #expect(policy.explicitOverride(current: .bluetooth, speaker: true) == nil)
        #expect(policy.explicitOverride(current: .phone, speaker: true) == true)
        #expect(policy.explicitOverride(current: .bluetooth, speaker: true) == false) // clear, never force speaker
        #expect(policy.clearOverrideForExternalRoute() == nil)
        #expect(SpeakerRoutePreference.load(UserDefaults(suiteName: suite)!))
        #expect(!PhoneAudioRoute.speaker.duplexSafe)
        #expect(PhoneAudioRoute.phone.duplexSafe)
        #expect(PhoneAudioRoute.headphones.duplexSafe(hasInput: true, inputIsBuiltIn: false))
        #expect(PhoneAudioRoute.bluetooth.duplexSafe(hasInput: true, inputIsBuiltIn: false))
        let path = tempDir() + "/settings.json"
        #expect(SettingsStore.load(env: ["FV_SETTINGS": path]).voice.pauseMs == 3200)
    }
}
