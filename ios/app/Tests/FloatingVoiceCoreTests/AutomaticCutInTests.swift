import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct AutomaticCutInTests {
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
    private func logging(_ rig: Rig) -> StageDiagnostics {
        let stages = StageDiagnostics(); stages.beginCall()
        rig.controller.outcomeDiagnostics = UtteranceOutcomeLog(stages: stages)
        return stages
    }
    private func outcomes(_ stages: StageDiagnostics, general: Bool = false) -> [UtteranceOutcomeDiagnostic] {
        let data = Data((general ? stages.exportGeneral() : stages.export()).utf8)
        return (try! JSONDecoder().decode([DiagnosticEntry].self, from: data)).compactMap(\.utteranceOutcome)
    }
    private func playing(_ rig: Rig) async {
        rig.reply(id: "base", one + " " + two)
        #expect(await waitUntil { rig.output.playing == [one] })
    }
    @Test func ackDucksButNeverStopsOrPostsAndConcurrentRepliesSurvive() async {
        let rig = Rig(duration: 0.3); let stages = logging(rig)
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
        #expect(outcomes(stages).last?.outcome == .backchannel)
        #expect(await waitUntil(5) { rig.output.plays.count == 3 && rig.output.plays.allSatisfy { $0.outcome == "played" } })
        #expect(rig.output.plays.map(\.text) == [one, two, three])
    }
    @Test(arguments: ["stop", "wait"]) func oneRecognizedWordPausesImmediatelyUntilRealFinal(_ word: String) async {
        let rig = Rig(duration: 5); let stages = logging(rig)
        rig.transcript = word; await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.live(word)
        #expect(rig.output.cutInPaused && rig.output.stops == 0)
        rig.input.frames(170, voiced: false)
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] " + word)
        #expect(rig.output.stops == 1 && rig.backend.interrupts.isEmpty)
        #expect(outcomes(stages).last?.cutInStoppedPlayback == true)
        #expect(outcomes(stages).last?.outcome == .posted)
    }
    @Test func ackThenRealWordsPostsWholeFinal() async {
        let rig = Rig(duration: 5); let stages = logging(rig)
        rig.transcript = "okay, actually change the plan."; await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.live("okay")
        #expect(!rig.output.cutInPaused)
        rig.recognitions[0].callbacks.live("okay, actually")
        #expect(rig.output.cutInPaused && rig.output.stops == 0)
        rig.input.frames(170, voiced: false)
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] okay, actually change the plan.")
        #expect(outcomes(stages).last?.finalWordCount == 5)
    }
    @Test(arguments: ["", " \n\t ", "…"]) func emptyCommittedFinalRestoresPositionQueueAndPrivateNotice(_ final: String) async {
        let rig = Rig(duration: 0.3); let stages = logging(rig)
        var notices: [PrivateVoiceNotice] = []; rig.controller.onPrivateNotice = { notices.append($0) }
        rig.transcript = final; await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.partial("stop")
        let ticks = rig.output.playedTicks
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(rig.output.playedTicks == ticks && rig.output.cutInPaused)
        rig.reply(id: "during", three)
        rig.input.frames(170, voiced: false)
        #expect(await waitUntil { !rig.controller.utteranceInProgress })
        #expect(rig.output.cutInResumes == 1 && rig.output.gain == 1 && rig.output.stops == 0)
        #expect(rig.controller.status.notice == "Didn't catch that" && notices == [.didntCatchThat])
        #expect(rig.backend.prompts.isEmpty && rig.backend.interrupts.isEmpty)
        let value = outcomes(stages).last!
        #expect(value.outcome == .emptyDiscarded && value.finalEmpty && value.finalWordCount == 0 && value.cutInStoppedPlayback)
        #expect(outcomes(stages, general: true).count == outcomes(stages).count)
        #expect(await waitUntil(5) { rig.output.plays.count == 3 && rig.output.plays.allSatisfy { $0.outcome == "played" } })
    }
    @Test func emptyWithoutCommitHasNoNoticeAndIdleAckPosts() async {
        let rig = Rig(); let stages = logging(rig)
        rig.transcript = ""; await rig.start(); defer { rig.controller.stop() }
        rig.speak(); #expect(await waitUntil { !rig.controller.utteranceInProgress })
        #expect(rig.controller.status.notice == nil && outcomes(stages).last?.outcome == .emptyDiscarded)
        rig.transcript = "okay"; rig.speak()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] okay")
    }
    @Test func unavailableInterimFallsBackAndLateAckRestoresWithoutNotice() async {
        let rig = Rig(duration: 5); _ = logging(rig)
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
        let rig = Rig(duration: 5); let stages = logging(rig)
        await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); let old = rig.recognitions[0]
        old.callbacks.live("stop"); rig.controller.discardPending()
        #expect(!rig.output.cutInPaused && rig.output.stops == 0 && rig.output.gain == 1)
        old.callbacks.done("stop")
        #expect(rig.backend.prompts.isEmpty && outcomes(stages).last?.outcome == .discardedByUser)
        rig.input.frames(8, voiced: true)
        old.callbacks.done("")
        #expect(rig.controller.utteranceInProgress && rig.output.gain == 0.25)
    }
    @Test func outputMuteAndStopCannotBeUndoneByEmptyFinal() async {
        for stop in [false, true] {
            let rig = Rig(duration: 5); _ = logging(rig); rig.transcript = ""
            await rig.start(); await playing(rig)
            rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.live("stop")
            if stop { await rig.controller.stopReply() } else { rig.controller.setOutputMuted(true) }
            let resumes = rig.output.cutInResumes
            rig.input.frames(170, voiced: false)
            #expect(await waitUntil { !rig.controller.utteranceInProgress })
            #expect(rig.output.cutInResumes == resumes && rig.output.stops >= 1)
            rig.controller.stop()
        }
    }
    @Test func manualSendOverridesBackchannelButMuteDoesNotInventSendInManualMode() async {
        let rig = Rig(duration: 5); let stages = logging(rig)
        rig.transcript = "okay"; rig.controller.setSendMode(.manual)
        await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] okay" && outcomes(stages).last?.outcome == .posted)
        rig.transcript = "keep this for later"; rig.input.frames(8, voiced: true); rig.controller.setMicMuted(true)
        #expect(await waitUntil { !rig.controller.utteranceInProgress })
        #expect(rig.backend.prompts.count == 1 && rig.controller.composer.held == "keep this for later")
        #expect(outcomes(stages).last?.outcome == .heldForSend)
    }
    @Test func busyMergingRecordsEachUtteranceWithoutTranscript() async {
        let rig = Rig(quietMs: 80); let stages = logging(rig)
        await rig.start(); defer { rig.controller.stop() }
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        rig.transcript = "private alpha"; rig.speak(); #expect(await waitUntil { !rig.controller.utteranceInProgress })
        rig.transcript = "private beta"; rig.speak(); #expect(await waitUntil { rig.backend.prompts.count == 1 })
        let rows = outcomes(stages)
        #expect(rows.contains { $0.ordinal == 1 && $0.outcome == .heldForBusy })
        #expect(rows.contains { $0.ordinal == 1 && $0.outcome == .mergedIntoNext && $0.mergedIntoOrdinal == 2 })
        #expect(rows.last?.outcome == .posted && rows.last?.delivery == .queue)
        #expect(!stages.export().contains("private alpha") && !stages.exportGeneral().contains("private beta"))
    }
    @Test func abortIsDeferredUntilValidFinalAndFencedAgainstTargetChange() async {
        let rig = Rig(duration: 5, configure: { $0.bargeInAborts = true }); _ = logging(rig)
        rig.transcript = ""; await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.live("stop")
        #expect(rig.backend.interrupts.isEmpty)
        rig.input.frames(170, voiced: false); #expect(await waitUntil { !rig.controller.utteranceInProgress })
        #expect(rig.backend.interrupts.isEmpty)
        rig.transcript = "stop"; rig.input.frames(8, voiced: true); rig.input.frames(170, voiced: false)
        #expect(await waitUntil { rig.backend.interrupts.count == 1 })
    }
    @Test func outcomeBanksSurviveNoiseAndNeverResurrectExpiredCall() async {
        let stages = StageDiagnostics(); stages.beginCall()
        let log = UtteranceOutcomeLog(stages: stages)
        let record = UtteranceOutcomeRecord(ordinal: 1, call: stages.playbackCallToken, diagnostics: log, beganDuringPlayback: false)
        record.finalMetadata("secret words"); record.record(.backchannel)
        #expect(outcomes(stages).count == 1 && outcomes(stages, general: true).count == 1)
        for _ in 0..<400 { stages.record(.state, .complete) }
        #expect(outcomes(stages).count == 1)
        stages.beginCall(); stages.beginCall(); record.record(.staleLease)
        #expect(outcomes(stages).isEmpty && outcomes(stages, general: true).isEmpty)
    }
    @Test func delayedEmptyFinalWaitsPausedAndTimeoutRecoversWithoutPosting() async {
        for timeout in [false, true] {
            let rig = Rig(duration: 5); let stages = logging(rig)
            rig.silentEnd = true; await rig.start(); await playing(rig)
            rig.controller.turnTaker?.finalTimeout = timeout ? 0.03 : 5
            rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.live("wait")
            rig.input.frames(170, voiced: false)
            if timeout {
                #expect(await waitUntil { !rig.controller.utteranceInProgress })
                #expect(outcomes(stages).contains { $0.outcome == .quarantined })
            } else {
                #expect(rig.output.cutInPaused && rig.backend.prompts.isEmpty)
                rig.recognitions[0].callbacks.done("")
                #expect(outcomes(stages).last?.outcome == .emptyDiscarded)
            }
            #expect(!rig.output.cutInPaused && rig.output.stops == 0 && rig.backend.prompts.isEmpty)
            rig.controller.stop()
        }
    }
    @Test func recognitionNoiseAndRetiredTargetHaveClosedOutcomes() async {
        let rig = Rig(); let stages = logging(rig)
        await rig.start(); defer { rig.controller.stop() }
        rig.controller.turnTaker?.expectLiveWords = true
        rig.input.frames(270, voiced: true)
        #expect(outcomes(stages).last?.outcome == .noiseDiscarded)
        rig.controller.turnTaker?.expectLiveWords = false
        rig.input.frames(8, voiced: true)
        rig.controller.setTargetSetting("ses_B")
        #expect(await waitUntil { rig.controller.currentLease?.sessionID == "ses_B" })
        rig.controller.setMicMuted(true)
        #expect(await waitUntil { !rig.controller.utteranceInProgress })
        #expect(rig.backend.prompts.isEmpty)
        #expect(outcomes(stages).contains { $0.outcome == .staleLease })
        #expect(outcomes(stages).last?.outcome == .quarantined)
    }
    @Test func deferredPostDiscardDoesNotBecomePostedAndSteerModeIsRecorded() async {
        let rig = Rig(busyDelivery: .steer); let stages = logging(rig)
        await rig.start(); defer { rig.controller.stop() }
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        rig.input.frames(8, voiced: true)
        rig.recognitions[0].callbacks.done("locally deferred")
        rig.controller.discardPending() // Before the deferred Task is admitted.
        _ = await rig.controller.waitForPosts(timeout: 1)
        #expect(rig.backend.prompts.isEmpty && outcomes(stages).last?.outcome == .discardedByUser)
        rig.speak(); #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(outcomes(stages).last?.delivery == .steer)
    }
    @Test func generationRetirementCannotLeaveOrRestoreAnOrphanedPause() async {
        let rig = Rig(duration: 5); let stages = logging(rig)
        await rig.start(); defer { rig.controller.stop() }; await playing(rig)
        rig.input.frames(8, voiced: true); let old = rig.recognitions[0]
        old.callbacks.live("stop")
        rig.backend.generations["ses_A"] = "replacement"
        rig.controller.setTargetSetting("ses_A")
        #expect(await waitUntil { rig.controller.currentLease?.generation == "replacement" })
        #expect(!rig.output.cutInPaused && rig.output.stops == 1)
        old.callbacks.done("")
        #expect(rig.output.cutInResumes == 0 && rig.backend.prompts.isEmpty)
        #expect(outcomes(stages).last?.outcome == .staleLease)
    }
    @Test func busyRealFinalDefersAbortAndRecordsAdmitOnlyWithoutASecondTurn() async {
        let rig = Rig(duration: 5, configure: { $0.bargeInAborts = true }); let stages = logging(rig)
        rig.transcript = "wait for me"; await rig.start(); defer { rig.controller.stop() }
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy }); await playing(rig)
        rig.input.frames(8, voiced: true); rig.recognitions[0].callbacks.live("wait")
        #expect(rig.backend.interrupts.isEmpty && rig.output.stops == 0)
        rig.input.frames(170, voiced: false)
        #expect(await waitUntil { rig.backend.admits.count == 1 })
        #expect(rig.backend.admits == ["[voice] wait for me"] && rig.backend.prompts.isEmpty)
        #expect(outcomes(stages).last?.outcome == .posted && outcomes(stages).last?.delivery == .admitOnly)
    }
    @Test func closedOutcomePersistsAndReloadsIntoBothStores() {
        let file = URL(fileURLWithPath: tempDir()).appendingPathComponent("stages.json")
        let stages = StageDiagnostics(); stages.configure(file: file, build: 32); stages.beginCall()
        let record = UtteranceOutcomeRecord(ordinal: 9, call: stages.playbackCallToken,
            diagnostics: UtteranceOutcomeLog(stages: stages), beganDuringPlayback: true)
        record.finalMetadata("very private transcript"); record.record(.backchannel)
        let restored = StageDiagnostics(); restored.configure(file: file, build: 32)
        #expect(outcomes(restored).count == 1 && outcomes(restored, general: true).count == 1)
        #expect(outcomes(restored).last?.finalWordCount == 3)
        #expect(!restored.export().contains("private transcript"))
    }
}
