import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct TargetReviewSnapshotTests {
    @Test func successfulLiveFinalThenRepeatedTargetSwitchesNeverReviewAlreadySentWords() async throws {
        let r = LongThoughtRig(["Already sent words."])
        await r.start(); defer { r.stop() }
        r.capture(8); r.sessions[0].callbacks.live("Already sent words")
        r.controller.send()
        try #require(await waitUntil { r.backend.prompts.count == 1 && !r.controller.utteranceInProgress })
        // Reproduce the exact stale getter from independent review; eligibility,
        // not shared final cleanup, must keep it out of target review memory.
        #expect(r.controller.turnTaker?.knownRecognitionText == "Already sent words")
        for target in ["ses_B", "ses_C", "ses_long", "ses_B"] {
            r.controller.setTargetSetting(target)
            #expect(r.controller.draftsForReview.isEmpty)
        }
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.prompts.count == 1 && r.backend.prompts[0].session == "ses_long")
        #expect(r.backend.prompts[0].text == "[voice] Already sent words." && r.sessions.count == 1)
    }

    @Test(arguments: ["rolloverFinal", "actualEndFinal"])
    func pendingFinalSnapshotIsRetainedOnceAndNeverRedirected(_ pending: String) async throws {
        let r = LongThoughtRig(["Old-target final", "never open standby"]); r.held = [0]
        await r.start(); defer { r.stop() }
        if pending == "rolloverFinal" { r.firstCap(); r.capture(20) }
        else { r.capture(8) }
        let old = r.sessions[0]
        old.callbacks.live("Old-target known words")
        if pending == "actualEndFinal" { r.controller.send() }
        try #require(old.ended && r.controller.utteranceInProgress)
        r.controller.setTargetSetting("ses_B")
        #expect(r.controller.draftsForReview == ["Old-target known words"])
        old.callbacks.done("Late old-target final")
        r.controller.setTargetSetting("ses_C"); r.controller.setTargetSetting("ses_long")
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.controller.draftsForReview == ["Old-target known words"])
        #expect(r.backend.prompts.isEmpty && r.sessions.count == 1 && old.cancelled)
    }

    @Test(arguments: ["failure", "stop", "discard"])
    func retiredThoughtIsNotSnapshottedAgainAtLaterTargetChanges(_ retirement: String) async throws {
        let r = LongThoughtRig(["Known prefix", "unused final"])
        await r.start(); defer { r.stop() }; r.firstCap()
        try #require(await waitUntil { r.sessions.count == 2 })
        let old = r.sessions[1]
        old.callbacks.live("known tail")
        switch retirement {
        case "failure": old.callbacks.error(ClientError("fixture failure"))
        case "stop": r.controller.stop(); await r.controller.start()
        default: r.controller.discardPending()
        }
        #expect(!r.controller.utteranceInProgress)
        let expected = retirement == "discard" ? [] : ["Known prefix known tail"]
        #expect(r.controller.draftsForReview == expected)
        for target in ["ses_B", "ses_C", "ses_long"] { r.controller.setTargetSetting(target) }
        old.callbacks.done("stale final"); old.callbacks.live("stale live")
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.controller.draftsForReview == expected)
        #expect(r.backend.prompts.isEmpty && r.sessions.count == 2)
    }
}
