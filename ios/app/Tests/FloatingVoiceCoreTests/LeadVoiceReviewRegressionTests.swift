import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct LeadVoiceReviewRegressionTests {
    @Test func manualCutInRejectsPostStopAcousticTailBeforeListening() async {
        let rig = Rig(duration: 5)
        rig.input.duplexSafe = false
        rig.transcript = "Will do."
        await rig.start()
        rig.controller.speaker.enqueue(one)
        #expect(await waitUntil { rig.controller.speaker.playing })
        rig.controller.bargeIn()
        // The player/render latch has stopped. Real room echo has not.
        let stoppedAt = rig.clock
        for _ in 0..<12 { // 240ms of audible decay, advancing the real guard clock
            rig.input.frames(1, voiced: true); rig.clock += 20
        }
        #expect(rig.recognitions.isEmpty, "chief's post-stop acoustic decay must not reach ASR")
        for _ in 0..<60 { rig.input.frames(1, voiced: false); rig.clock += 20 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.backend.prompts.isEmpty)
        rig.clock = max(rig.clock, stoppedAt + 301)
        rig.transcript = "Yes."
        rig.speak()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.text == "[voice] Yes.")
        #expect(rig.backend.interrupts.isEmpty)
        rig.controller.stop()
    }

    @Test(arguments: [false, true])
    func routeDownAtOrJustAfterPlaybackEndStillArmsTail(sameTurn: Bool) async {
        let rig = Rig(duration: 5)
        await rig.start()
        rig.controller.speaker.enqueue(one)
        #expect(await waitUntil { rig.controller.speaker.playing })
        rig.controller.speaker.stop() // was duplex at the playback-end callback
        if !sameTurn { rig.clock += 100 }
        rig.input.duplexSafe = false // Bluetooth falls back to the speaker
        rig.input.frames(20, voiced: true)
        #expect(rig.recognitions.isEmpty && rig.controller.status.listeningSuppressed)
        rig.clock += rig.controller.app.turnEndQuietMs + 1
        rig.speak()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        rig.controller.stop()
    }

    @Test func externalOutputAloneIsNotProofOfADuplexMicrophone() {
        #expect(!PhoneAudioRoute.bluetooth.duplexSafe, "A2DP + built-in mic is not HFP")
        #expect(!PhoneAudioRoute.headphones.duplexSafe, "line-out/USB output can still use the built-in mic")
    }

    @Test func repairWindowRetiresEarlyWordsAndWaitsForFreshGraphFrames() async {
        let rig = Rig(duration: 5)
        await rig.start()
        rig.controller.speaker.enqueue(one)
        #expect(await waitUntil { rig.controller.speaker.playing })
        rig.input.frames(8, voiced: true)
        let early = rig.recognitions.first
        rig.input.captureGraphReady = false
        #expect(early?.cancelled == true, "the route repair must retire an onset opened before its graph stop")
        let count = rig.recognitions.count
        rig.input.frames(20, voiced: true)
        #expect(rig.recognitions.count == count, "no new onsets in the 150ms repair window")
        early?.callbacks.done("yes")
        #expect(rig.backend.prompts.isEmpty && rig.backend.interrupts.isEmpty)
        rig.input.captureGraphReady = true
        rig.input.frames(8, voiced: true)
        #expect(rig.recognitions.count == count + 1)
        rig.controller.stop()
    }

    @Test func finalOnlyAdapterDoesNotIntroduceAnAbortSendRace() async {
        let rig = Rig(duration: 5) { $0.bargeInAborts = true }
        rig.transcript = "Yes."
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        rig.controller.speaker.enqueue(one)
        #expect(await waitUntil { rig.controller.speaker.playing })
        rig.input.frames(8, voiced: true) // below sustained onset, no partial/live callback
        rig.input.frames(60, voiced: false)
        #expect(await waitUntil { !rig.controller.utteranceInProgress })
        #expect(rig.backend.prompts.isEmpty && rig.backend.interrupts.isEmpty && rig.controller.speaker.playing,
                "final-only acknowledgement restores playback without posting or model abort")
        rig.controller.stop()
    }

    @Test func activationUsesOneClearableSpeakerOverrideOnlyFromReceiver() {
        var policy = BuiltInRoutePolicy(defaultSpeaker: true)
        policy.begin()
        let initial = policy.activationOverride(current: .phone)
        let repeated = policy.activationOverride(current: .phone)
        #expect(initial == true && repeated == nil && !policy.categoryDefaultToSpeaker)
        policy.begin()
        #expect(policy.activationOverride(current: .speaker) == nil)
        policy.begin()
        #expect(policy.activationOverride(current: .bluetooth) == nil)
    }

    @Test func externalMicEvidenceIsRequiredForEveryExternalProfile() {
        for route in [PhoneAudioRoute.bluetooth, .headphones, .external] {
            #expect(!route.duplexSafe(hasInput: true, inputIsBuiltIn: true))
            #expect(!route.duplexSafe(hasInput: false, inputIsBuiltIn: false))
            #expect(route.duplexSafe(hasInput: true, inputIsBuiltIn: false))
        }
        #expect(PhoneAudioRoute.phone.duplexSafe(hasInput: true, inputIsBuiltIn: true))
        #expect(!PhoneAudioRoute.speaker.duplexSafe(hasInput: true, inputIsBuiltIn: false))
    }

    @Test func onlyTheInstalledReplacementGraphCanReopenAdmission() {
        var gate = CaptureGraphAdmission()
        gate.installed(1); gate.delivered(1)
        #expect(gate.ready)
        gate.beginRepair()
        gate.delivered(1) // old ingress is still delivering during debounce
        #expect(!gate.ready)
        gate.installed(2)
        gate.delivered(1)
        #expect(!gate.ready)
        gate.delivered(2)
        #expect(gate.ready)
    }
}
