import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct LeaseIsolationTests {
    @Test func delayedInterruptCannotOwnANewDraftAfterNoWordRecognition() async {
        let rig = Rig(quietMs: 60_000)
        rig.backend.active = ["ses_A"]
        await rig.start()
        rig.transcript = ""
        rig.input.frames(30, voiced: true)
        #expect(rig.controller.utteranceInProgress)
        var release: CheckedContinuation<Bool, Never>?
        rig.backend.interruptGate = { await withCheckedContinuation { release = $0 } }
        let stop = Task { await rig.controller.stopReply() }
        #expect(await waitUntil { release != nil })
        rig.input.frames(60, voiced: false)
        #expect(await waitUntil { !rig.controller.utteranceInProgress })
        await say(rig, "A genuinely new draft.")
        release?.resume(returning: true)
        await stop.value
        #expect(rig.backend.admits.isEmpty)
        #expect(rig.controller.status.holding == "A genuinely new draft.")
        #expect(rig.controller.status.busy)
        rig.controller.stop()
    }
    @Test(arguments: ["B", "ABA", "generation", "newDraft", "sameOwner"])
    func delayedInterruptOwnsOnlyItsOriginalSelectionAndDraft(_ change: String) async {
        let rig = Rig(quietMs: 60_000)
        rig.backend.active = ["ses_A", "ses_B"]
        await rig.start()
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "Original A words.")
        var release: CheckedContinuation<Bool, Never>?
        rig.backend.interruptGate = { await withCheckedContinuation { release = $0 } }
        let stop = Task { await rig.controller.stopReply() }
        #expect(await waitUntil { release != nil })
        if change == "B" || change == "ABA" {
            rig.controller.setTargetSetting("ses_B")
            #expect(await waitUntil { rig.controller.currentLease?.sessionID == "ses_B" })
            if change == "ABA" {
                rig.controller.setTargetSetting("ses_A")
                #expect(await waitUntil { rig.controller.currentLease?.sessionID == "ses_A" })
            }
        } else if change == "generation" {
            rig.backend.generations["ses_A"] = "replacement"
            rig.controller.setTargetSetting("ses_A")
            #expect(await waitUntil { rig.controller.currentLease?.generation == "replacement" })
        } else if change == "newDraft" {
            rig.controller.send()
            #expect(await waitUntil { rig.backend.prompts.count == 1 })
        }
        if change != "sameOwner" { await say(rig, "Current owner words.") }
        let held = rig.controller.status.holding
        let review = rig.controller.draftsForReview
        release?.resume(returning: true)
        await stop.value
        if change == "sameOwner" {
            #expect(await waitUntil { rig.backend.admits == ["[voice] Original A words."] })
        } else {
            #expect(rig.backend.admits.isEmpty)
            #expect(rig.controller.status.holding == held)
            #expect(rig.controller.draftsForReview == review)
            #expect(rig.controller.status.busy)
            rig.controller.send()
            #expect(await waitUntil { rig.backend.prompts.last?.text == "[voice] Current owner words." })
            #expect(rig.backend.prompts.last?.delivery == .queue)
            #expect(rig.backend.sentLeases.last == rig.controller.currentLease)
        }
        rig.controller.stop()
    }
    func say(_ rig: Rig, _ words: String) async {
        rig.transcript = words
        rig.speak()
        #expect(await waitUntil { rig.controller.status.holding == words })
    }
    func manualRig() async -> Rig {
        let rig = Rig()
        rig.controller.setSendMode(.manual)
        await rig.start()
        return rig
    }
    @Test func newBWordsDoNotMixWithHeldAAndUseBBusyState() async {
        let rig = await manualRig()
        rig.backend.active = ["ses_A"]
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "Original A.")
        rig.controller.setTargetSetting("ses_B")
        #expect(await waitUntil { rig.controller.currentLease?.sessionID == "ses_B" })
        #expect(!rig.controller.status.busy)
        await say(rig, "Only B.")
        rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0] == .init(session: "ses_B", text: "[voice] Only B.", delivery: nil))
        #expect(rig.backend.sentLeases[0] == TargetLease(sessionID: "ses_B", generation: "initial"))
        #expect(rig.controller.draftsForReview == [BoundDraft(target: TargetLease(sessionID: "ses_A", generation: "initial"), text: "Original A.")])
        rig.controller.stop()
    }
    @Test func idleAToBusyBQueuesOnlyB() async {
        let rig = await manualRig()
        await say(rig, "Original idle A.")
        rig.backend.active = ["ses_B"]
        rig.controller.setTargetSetting("ses_B")
        #expect(await waitUntil { rig.controller.currentLease?.sessionID == "ses_B" && rig.controller.status.busy })
        await say(rig, "Queue only B.")
        rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0] == .init(session: "ses_B", text: "[voice] Queue only B.", delivery: .queue))
        rig.controller.stop()
    }
    @Test func AtoBtoAAndSameIDGenerationReplacementNeverResurrectOldDraft() async {
        let rig = await manualRig()
        await say(rig, "First A.")
        rig.controller.setTargetSetting("ses_B")
        #expect(await waitUntil { rig.controller.currentLease?.sessionID == "ses_B" })
        rig.backend.generations["ses_A"] = "second"
        rig.controller.setTargetSetting("ses_A")
        #expect(await waitUntil { rig.controller.currentLease?.generation == "second" })
        await say(rig, "Second A.")
        rig.backend.generations["ses_A"] = "third"
        rig.controller.setTargetSetting("ses_A")
        #expect(await waitUntil { rig.controller.currentLease?.generation == "third" })
        #expect(rig.controller.status.holding == nil)
        await say(rig, "Third A only.")
        rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] Third A only.")
        #expect(rig.backend.sentLeases == [TargetLease(sessionID: "ses_A", generation: "third")])
        #expect(rig.controller.draftsForReview.map(\.text) == ["First A.", "Second A."])
        rig.controller.stop()
    }
}
