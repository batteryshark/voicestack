import Foundation
import Testing
@testable import FloatingVoiceCore

/// Reviewed 748bb89 fixtures; Mac storage/target adapters replace phone call banks/leases.
@Suite(.serialized) @MainActor struct AutomaticCutInTests {
    @MainActor final class Outcomes {
        var rows: [UtteranceOutcomeDiagnostic] = []
        func bind(_ rig: Rig) {
            rig.controller.outcomeDiagnostics = UtteranceOutcomeLog(write: { [self] row, _ in rows.append(row) })
        }
    }
    private func playing(_ rig: Rig) async {
        rig.reply(id: "base", one + " " + two)
        #expect(await waitUntil { rig.output.playing == [one] })
    }
    @Test func acknowledgementVocabularyAndPunctuationAreShared() {
        for phrase in AutomaticCutInTuning.acknowledgementPhrases {
            #expect(AutomaticCutInTuning.acknowledgement(" \(phrase.uppercased())!? "))
        }
        for word in ["stop", "wait", "okay, actually…", "yeah but", "", "…"] {
            #expect(!AutomaticCutInTuning.acknowledgement(word))
        }
        #expect(AutomaticCutInTuning.duckGain == 0.25)
    }
    @Test func durationIsOnlyAFallbackAndCannotOverrideRecognizedAck() {
        var policy = AutomaticCutInDecision(beganDuringPlayback: true)
        #expect(policy.onset == .duck)
        #expect(policy.interim("yeah", playbackActive: true) == .none)
        #expect(policy.voiced(50_000, playbackActive: true) == .none)
        #expect(policy.interim("yeah, actually stop", playbackActive: true) == .commit)
        #expect(policy.final("yeah, actually stop") == .realSpeech)
        var unavailable = AutomaticCutInDecision(beganDuringPlayback: true)
        #expect(unavailable.voiced(AutomaticCutInTuning.sustainedFallbackMs - 1, playbackActive: true) == .none)
        #expect(unavailable.voiced(AutomaticCutInTuning.sustainedFallbackMs, playbackActive: true) == .commit)
        #expect(unavailable.interim("yeah", playbackActive: true) == .restoreDucked)
        #expect(unavailable.voiced(50_000, playbackActive: true) == .none)
    }
    @Test func ackDucksButNeverStopsOrPostsAndConcurrentRepliesSurvive() async {
        let rig = Rig(duration: 0.3), records = Outcomes(); records.bind(rig)
        rig.transcript = "Yeah!"; await rig.start(); defer { rig.controller.stop() }
        await playing(rig)
        rig.input.frames(8, voiced: true)
        #expect(rig.output.gain == 0.25)
        rig.recognitions[0].callbacks.live("Yeah!")
        rig.input.frames(100, voiced: true)
        #expect(rig.output.cutInPauses == 0 && rig.output.stops == 0)
        rig.reply(id: "concurrent", three)
        rig.input.frames(170, voiced: false)
        #expect(await waitUntil { !rig.controller.utteranceInProgress })
        #expect(rig.output.gain == 1 && rig.backend.prompts.isEmpty)
        #expect(records.rows.last?.outcome == .backchannel)
        #expect(await waitUntil(5) { rig.output.plays.count == 3 && rig.output.plays.allSatisfy { $0.outcome == "played" } })
        #expect(rig.output.plays.map(\.text) == [one, two, three])
    }
    @Test(arguments: ["stop", "wait"]) func oneRecognizedWordPausesImmediatelyUntilRealFinal(_ word: String) async {
        let rig = Rig(duration: 5), records = Outcomes(); records.bind(rig)
        rig.transcript = word; await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.live(word)
        #expect(rig.output.cutInPaused && rig.output.stops == 0)
        rig.input.frames(170, voiced: false)
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.text == "[voice] " + word)
        #expect(rig.output.stops == 1 && rig.backend.interrupts.isEmpty)
        #expect(records.rows.last?.cutInStoppedPlayback == true)
        #expect(records.rows.last?.outcome == .posted)
    }
    @Test func ackThenRealWordsPostsWholeFinal() async {
        let rig = Rig(duration: 5), records = Outcomes(); records.bind(rig)
        rig.transcript = "okay, actually change the plan."; await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.live("okay")
        #expect(!rig.output.cutInPaused)
        rig.recognitions[0].callbacks.live("okay, actually")
        #expect(rig.output.cutInPaused && rig.output.stops == 0)
        rig.input.frames(170, voiced: false)
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.text == "[voice] okay, actually change the plan.")
        #expect(records.rows.last?.finalWordCount == 5)
    }
    @Test(arguments: ["", " \n\t ", "…"]) func emptyCommittedFinalRestoresPositionQueueAndPrivateNotice(_ final: String) async {
        let rig = Rig(duration: 0.3), records = Outcomes(); records.bind(rig)
        var notices: [PrivateVoiceNotice] = []; rig.controller.onPrivateNotice = { notices.append($0) }
        rig.transcript = final; await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.partial("stop")
        let ticks = rig.output.playedTicks, tickets = rig.synth.prepared
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(rig.output.playedTicks == ticks && rig.output.cutInPaused)
        #expect(rig.synth.prepared == tickets)
        rig.reply(id: "during", three)
        rig.input.frames(170, voiced: false)
        #expect(await waitUntil { !rig.controller.utteranceInProgress })
        #expect(rig.output.cutInResumes == 1 && rig.output.gain == 1 && rig.output.stops == 0)
        #expect(rig.controller.status.notice == "Didn't catch that" && notices == [.didntCatchThat])
        #expect(rig.backend.prompts.isEmpty && rig.backend.interrupts.isEmpty)
        let value = records.rows.last
        #expect(value?.outcome == .emptyDiscarded && value?.finalEmpty == true && value?.finalWordCount == 0 && value?.cutInStoppedPlayback == true)
        #expect(await waitUntil(5) { rig.output.plays.count == 3 && rig.output.plays.allSatisfy { $0.outcome == "played" } })
    }
    @Test func emptyWithoutCommitHasNoNoticeAndIdleAckPosts() async {
        let rig = Rig(), records = Outcomes(); records.bind(rig)
        rig.transcript = ""; await rig.start(); defer { rig.controller.stop() }
        rig.speak(); #expect(await waitUntil { !rig.controller.utteranceInProgress })
        #expect(rig.controller.status.notice == nil && records.rows.last?.outcome == .emptyDiscarded)
        rig.transcript = "okay"; rig.speak()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.text == "[voice] okay")
    }
    @Test func unavailableInterimFallsBackAndLateAckRestoresWithoutNotice() async {
        let rig = Rig(duration: 5)
        rig.transcript = "yeah"; await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(45, voiced: true)
        #expect(rig.output.cutInPaused)
        rig.recognitions[0].callbacks.live("yeah")
        #expect(!rig.output.cutInPaused && rig.output.gain == 0.25)
        rig.input.frames(170, voiced: false)
        #expect(await waitUntil { !rig.controller.utteranceInProgress })
        #expect(rig.output.gain == 1 && rig.output.stops == 0 && rig.controller.status.notice == nil)
    }
    @Test func discardWinsOverOldFinalAndRestoresTentativePlayback() async {
        let rig = Rig(duration: 5), records = Outcomes(); records.bind(rig)
        await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); let old = rig.recognitions[0]
        old.callbacks.live("stop"); rig.controller.discardPending()
        #expect(!rig.output.cutInPaused && rig.output.stops == 0 && rig.output.gain == 1)
        old.callbacks.done("stop")
        #expect(rig.backend.prompts.isEmpty && records.rows.last?.outcome == .discardedByUser)
        rig.input.frames(8, voiced: true); old.callbacks.done("")
        #expect(rig.controller.utteranceInProgress && rig.output.gain == 0.25)
    }
    @Test(arguments: ["mute", "stop", "end", "target"]) func explicitAuthorityCannotBeUndoneByLateFinal(_ action: String) async {
        let rig = Rig(duration: 5); rig.transcript = ""
        await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); let old = rig.recognitions[0]; old.callbacks.live("stop")
        switch action {
        case "mute": rig.controller.setOutputMuted(true)
        case "stop": await rig.controller.stopReply()
        case "end": rig.controller.endVoice()
        default: rig.controller.setTargetSetting("ses_B")
        }
        let resumes = rig.output.cutInResumes
        old.callbacks.done(""); old.callbacks.done("stale words")
        #expect(rig.output.cutInResumes == resumes && rig.output.stops >= 1)
        #expect(rig.backend.prompts.isEmpty)
    }
    @Test func manualSendOverridesBackchannelButMuteDoesNotInventSendInManualMode() async {
        let rig = Rig(duration: 5), records = Outcomes(); records.bind(rig)
        rig.transcript = "okay"; rig.controller.setSendMode(.manual)
        await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.text == "[voice] okay" && records.rows.last?.outcome == .posted)
        rig.transcript = "keep this for later"; rig.input.frames(8, voiced: true); rig.controller.setMicMuted(true)
        #expect(await waitUntil { !rig.controller.utteranceInProgress })
        #expect(rig.backend.prompts.count == 1 && rig.controller.composer.held == "keep this for later")
        #expect(records.rows.last?.outcome == .heldForSend)
    }
    @Test func delayedEmptyFinalWaitsPausedAndTimeoutRecoversWithoutPosting() async {
        for timeout in [false, true] {
            let rig = Rig(duration: 5), records = Outcomes(); records.bind(rig)
            rig.silentEnd = true; await rig.start(); await playing(rig)
            rig.controller.turnTaker?.finalTimeout = timeout ? 0.03 : 5
            rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.live("wait")
            rig.input.frames(170, voiced: false)
            if timeout {
                #expect(await waitUntil { !rig.controller.utteranceInProgress })
                #expect(records.rows.contains { $0.outcome == .quarantined })
            } else {
                #expect(rig.output.cutInPaused && rig.backend.prompts.isEmpty)
                rig.recognitions[0].callbacks.done("")
                #expect(records.rows.last?.outcome == .emptyDiscarded)
            }
            #expect(!rig.output.cutInPaused && rig.output.stops == 0 && rig.backend.prompts.isEmpty)
            rig.controller.stop()
        }
    }
    @Test func abortIsDeferredUntilValidFinalAndFencedAgainstTargetChange() async {
        let rig = Rig(duration: 5, configure: { $0.bargeInAborts = true })
        rig.transcript = ""; await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.live("stop")
        #expect(rig.backend.interrupts.isEmpty)
        rig.input.frames(170, voiced: false); #expect(await waitUntil { !rig.controller.utteranceInProgress })
        #expect(rig.backend.interrupts.isEmpty)
        rig.transcript = "stop"; rig.input.frames(8, voiced: true); rig.input.frames(170, voiced: false)
        #expect(await waitUntil { rig.backend.interrupts.count == 1 })
    }
    @Test func closedRecordsContainCountsNotPrivateWordsAndBusyMergesRetainIdentity() async throws {
        let rig = Rig(quietMs: 80), records = Outcomes(); records.bind(rig)
        await rig.start(); defer { rig.controller.stop() }
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        rig.transcript = "private alpha"; rig.speak(); #expect(await waitUntil { !rig.controller.utteranceInProgress })
        rig.transcript = "private beta"; rig.speak(); #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(records.rows.contains { $0.ordinal == 1 && $0.outcome == .heldForBusy })
        #expect(records.rows.contains { $0.ordinal == 1 && $0.outcome == .mergedIntoNext && $0.mergedIntoOrdinal == 2 })
        #expect(records.rows.last?.outcome == .posted && records.rows.last?.delivery == .queue)
        let json = String(decoding: try JSONEncoder().encode(records.rows), as: UTF8.self)
        #expect(!json.contains("private") && !json.contains("ses_A"))
    }
    @Test func realFinalDeferredAbortAndPostLoseAuthorityAtTargetSwitch() async {
        let rig = Rig(duration: 5, configure: { $0.bargeInAborts = true })
        await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true)
        rig.recognitions[0].callbacks.done("stop now")
        rig.controller.setTargetSetting("ses_B") // Before either deferred task runs.
        #expect(await rig.controller.waitForPosts(timeout: 1))
        #expect(rig.backend.interrupts.isEmpty && rig.backend.prompts.isEmpty)
        #expect(rig.controller.draftsForReview.contains("stop now"))
    }
    @Test func busyRealFinalDefersAbortAndRecordsAdmitOnlyWithoutASecondTurn() async {
        let rig = Rig(duration: 5, configure: { $0.bargeInAborts = true }), records = Outcomes(); records.bind(rig)
        rig.transcript = "wait for me"; await rig.start(); defer { rig.controller.stop() }
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy }); await playing(rig)
        rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.live("wait")
        #expect(rig.backend.interrupts.isEmpty && rig.output.stops == 0)
        rig.input.frames(170, voiced: false)
        #expect(await waitUntil { rig.backend.admits.count == 1 })
        #expect(rig.backend.admits == ["[voice] wait for me"] && rig.backend.prompts.isEmpty)
        #expect(records.rows.last?.outcome == .posted && records.rows.last?.delivery == .admitOnly)
    }
}
