import Foundation
import Testing
@testable import FloatingVoiceCore

/// Mute mic does not throw away words in motion: the utterance in progress ends, its final text is merged with what is
/// held or counting down, and goes in at once (auto) or into Holding (manual). Then the mic stays muted.
@Suite(.serialized) @MainActor struct MuteSendTests {
    /// Speech still going: voiced frames and no pause yet.
    func talking(_ rig: Rig, _ text: String, frames: Int = 30) {
        rig.transcript = text
        rig.input.frames(frames, voiced: true)
    }

    func finished(_ rig: Rig, _ text: String) async {
        rig.transcript = text
        rig.speak()
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    @Test func idleAutoSendsTheUtteranceInProgressAtOnce() async {
        let rig = Rig()
        await rig.start()
        talking(rig, "Please do the thing.")
        #expect(rig.controller.turnTaker?.inUtterance == true)
        rig.controller.setMicMuted(true)
        #expect(await waitUntil(1) { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0] == .init(session: "ses_A", text: "[voice] Please do the thing.", delivery: nil))
        #expect(rig.controller.status.micMuted, "then stays muted")
        // No new audio is taken while muted.
        let recognitions = rig.recognitions.count
        rig.input.frames(40, voiced: true)
        rig.input.frames(60, voiced: false)
        #expect(rig.recognitions.count == recognitions)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.backend.prompts.count == 1)
        rig.controller.stop()
    }

    @Test func midSentenceWordsAreSentToo() async {
        let rig = Rig(holdMs: 5_000)
        await rig.start()
        talking(rig, "and then we could")
        rig.controller.setMicMuted(true)
        #expect(await waitUntil(1) { rig.backend.prompts.count == 1 }, "no mid-sentence hold: nothing more is coming while muted")
        #expect(rig.backend.prompts.first?.text == "[voice] and then we could")
        rig.controller.stop()
    }

    @Test func mergesWithWhatIsHeldAndCountingDown() async {
        let rig = Rig(holdMs: 5_000)
        await rig.start()
        await finished(rig, "So I was going to say that")   // mid-sentence: held, hold timer counting down
        #expect(rig.controller.status.holding == "So I was going to say that")
        var events: [CaptionEvent] = []
        rig.controller.onCaption = { events.append($0) }
        talking(rig, "we should ship it.")                    // the next part, still being said
        rig.controller.setMicMuted(true)
        #expect(await waitUntil(1) { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] So I was going to say that we should ship it.", "one message, in order")
        #expect(rig.controller.status.holding == nil)
        #expect(events.contains(.countdownCancelled), "the countdown is over")
        rig.controller.stop()
    }

    @Test func heldWordsWithNothingInProgressGoAtOnce() async {
        let rig = Rig(holdMs: 5_000)
        await rig.start()
        await finished(rig, "I was going to say that")
        #expect(rig.backend.prompts.isEmpty)
        rig.controller.setMicMuted(true)
        #expect(await waitUntil(1) { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] I was going to say that")
        rig.controller.stop()
    }

    @Test func muteWithNothingToSendDoesNothing() async {
        let rig = Rig()
        await rig.start()
        rig.controller.setMicMuted(true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.backend.prompts.isEmpty && rig.backend.admits.isEmpty && rig.controller.status.micMuted)
        rig.controller.stop()
    }

    // MARK: Busy chief

    @Test func busyChiefGetsTheQueueDeliveryWithoutTheQuietWait() async {
        let rig = Rig(quietMs: 10_000)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await finished(rig, "First part of it.")             // merging: would wait 10 s of quiet
        #expect(rig.backend.prompts.isEmpty)
        talking(rig, "And the second part.")
        rig.controller.setMicMuted(true)
        #expect(await waitUntil(1) { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0] == .init(session: "ses_A", text: "[voice] First part of it. And the second part.", delivery: .queue))
        rig.controller.stop()
    }

    @Test func busyChiefWithSteerSettingGetsASteer() async {
        let rig = Rig(busyDelivery: .steer, quietMs: 10_000)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        talking(rig, "Please also check the logs.")
        rig.controller.setMicMuted(true)
        #expect(await waitUntil(1) { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].delivery == .steer)
        rig.controller.stop()
    }

    @Test func busyChiefTurnEndingBeforeTheFinalMakesItANormalMessage() async {
        let rig = Rig(quietMs: 10_000)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        talking(rig, "Do this next.")
        rig.backend.send("session.execution.succeeded", "ses_A")
        #expect(await waitUntil { !rig.controller.status.busy })
        rig.controller.setMicMuted(true)
        #expect(await waitUntil(1) { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0] == .init(session: "ses_A", text: "[voice] Do this next.", delivery: nil))
        rig.controller.stop()
    }

    // MARK: Manual mode

    @Test func manualPutsTheFinalIntoHoldingAndNeverSendsWithoutSend() async {
        let rig = Rig()
        rig.controller.setSendMode(.manual)
        await rig.start()
        await finished(rig, "Something I said before.")
        talking(rig, "And something still being said.")
        rig.controller.setMicMuted(true)
        #expect(await waitUntil(1) { rig.controller.status.holding == "Something I said before. And something still being said." })
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.backend.prompts.isEmpty && rig.backend.admits.isEmpty, "manual never sends without Send")
        #expect(rig.controller.status.micMuted)
        rig.controller.send()                                  // Send works while muted
        #expect(await waitUntil(1) { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] Something I said before. And something still being said.")
        #expect(rig.controller.status.micMuted)
        rig.controller.stop()
    }

    // MARK: Final text that does not come

    @Test func aFinalThatNeverArrivesStillSendsWhatWasHeldAfterTheTimeout() async {
        let rig = Rig(holdMs: 5_000)
        rig.silentEnd = true
        await rig.start()
        rig.controller.turnTaker?.finalTimeout = 0.3
        // Held words from an earlier utterance (the fake server answers that one: silentEnd only after this point).
        rig.silentEnd = false
        await finished(rig, "Earlier words and")
        rig.silentEnd = true
        talking(rig, "Words that never get a final.")
        rig.controller.setMicMuted(true)
        #expect(rig.backend.prompts.isEmpty)
        #expect(await waitUntil(2) { rig.backend.prompts.count == 1 }, "dropped after the timeout; what was held goes in")
        #expect(rig.backend.prompts[0].text == "[voice] Earlier words and")
        #expect(rig.controller.status.lastError?.contains("No final transcript") == true)
        #expect(rig.controller.status.micMuted)
        rig.controller.stop()
    }

    // MARK: Unmute

    @Test func unmuteResumesNormalListening() async {
        let rig = Rig()
        await rig.start()
        talking(rig, "Before the mute.")
        rig.controller.setMicMuted(true)
        #expect(await waitUntil(1) { rig.backend.prompts.count == 1 })
        rig.backend.send("session.execution.succeeded", "ses_A")
        try? await Task.sleep(nanoseconds: 100_000_000)
        rig.controller.setMicMuted(false)
        #expect(!rig.controller.status.micMuted)
        await finished(rig, "After the unmute.")
        #expect(await waitUntil(1) { rig.backend.prompts.count == 2 })
        #expect(rig.backend.prompts[1].text == "[voice] After the unmute.")
        rig.controller.stop()
    }
}
