import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct CallTests {
    let target = TargetLease(sessionID: "ses_A", generation: "one")

    @Test func immutableTargetSingleCallAndEpochFences() {
        let call = CallLifecycle()
        let epoch = call.begin(target: target)!
        let id = call.id
        #expect(call.begin(target: .init(sessionID: "ses_B", generation: "two")) == nil)
        #expect(call.target == target && call.id == id)
        #expect(call.end(epoch))
        #expect(!call.end(epoch))
        #expect(!call.activate(epoch) && !call.ready(epoch))
        let next = call.begin(target: target)!
        #expect(next != epoch && call.id != id)
        #expect(!call.end(epoch) && call.admits(next))
    }

    @Test func providerOrderingNeverWaitsForActivationToAdmitStart() {
        for earlyActivation in [false, true] {
            let call = CallLifecycle()
            let epoch = call.begin(target: target)!
            if earlyActivation { #expect(!call.activate(epoch)) }
            #expect(!call.mayRunMedia)
            #expect(call.connecting(epoch)) // configure + fulfill Start, no media wait
            #expect(!call.connecting(epoch))
            if !earlyActivation {
                #expect(!call.ready(epoch))
                #expect(call.activate(epoch))
            }
            #expect(call.mayRunMedia)
            #expect(call.ready(epoch))
            call.deactivate()
            #expect(!call.mayRunMedia && !call.ready(epoch))
            #expect(call.activate(epoch))
            #expect(call.ready(epoch))
        }
    }

    @Test func holdCannotResumeFromInterruptionHintOrStaleGrant() {
        let call = CallLifecycle()
        let epoch = call.begin(target: target)!
        call.connecting(epoch); call.activate(epoch); call.ready(epoch)
        #expect(call.hold(true, owner: epoch))
        #expect(!call.hold(true, owner: epoch) && !call.mayRunMedia)
        call.deactivate()
        call.hold(false, owner: epoch)
        #expect(!call.mayRunMedia) // .shouldResume is not activation
        call.activate(epoch)
        #expect(call.mayRunMedia)
        call.end(epoch)
        #expect(!call.activate(epoch) && !call.hold(false, owner: epoch))
    }

    @Test func timeoutAndProviderResetConvergeOnce() {
        let call = CallLifecycle()
        let epoch = call.begin(target: target)!
        call.connecting(epoch)
        var cleanups = 0
        // Fake clock deadline, followed by reset and a late activation/readiness callback.
        for _ in 0..<3 { if call.end(epoch) { cleanups += 1 } }
        #expect(cleanups == 1 && !call.activate(epoch) && !call.ready(epoch))
        let replacement = call.begin(target: target)!
        #expect(!call.end(epoch) && call.admits(replacement))
    }

    @Test func muteActionsMapExactlyOnceAndManualStillWaitsForSend() async {
        for manual in [false, true] {
            let rig = Rig()
            rig.controller.app.sendMode = manual ? .manual : .auto
            await rig.start()
            let lifecycle = NativeVoiceLifecycle(); lifecycle.controller = rig.controller
            let call = CallLifecycle(); let epoch = call.begin(target: target)!
            rig.input.frames(30, voiced: true)
            var changes = 0
            for _ in 0..<3 {
                if call.mute(true, owner: epoch) { changes += 1; lifecycle.setMicMuted(true) }
            }
            #expect(changes == 1)
            if manual {
                #expect(await waitUntil { !rig.controller.composer.held.isEmpty })
                #expect(rig.backend.prompts.isEmpty)
                rig.controller.send()
            }
            #expect(await waitUntil { rig.backend.prompts.count == 1 })
            lifecycle.setMicMuted(true)
            #expect(rig.backend.prompts.count == 1)
            rig.controller.stop(discardUnfinished: true)
        }
    }

    @Test func holdQuarantinesAutoCountdownAndInFlightWordsWithoutSending() async {
        let rig = Rig(holdMs: 50)
        rig.transcript = "unfinished words and"
        await rig.start()
        rig.speak()
        #expect(await waitUntil { !rig.controller.composer.held.isEmpty })
        rig.controller.pauseForCall()
        rig.controller.pauseForCall()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.backend.prompts.isEmpty && rig.backend.interrupts.isEmpty)
        #expect(rig.controller.draftsForReview.contains { $0.text == "unfinished words and" })
        #expect(!rig.input.started)
        await rig.start()
        #expect(rig.backend.prompts.isEmpty)
        rig.input.frames(30, voiced: true)
        rig.controller.pauseForCall()
        #expect(await waitUntil { rig.controller.draftsForReview.count >= 2 })
        #expect(rig.backend.prompts.isEmpty)
        rig.controller.stop(discardUnfinished: true)
    }

    @Test func holdFencesAnAlreadyScheduledButNotAdmittedPost() async {
        let rig = Rig()
        await rig.start()
        rig.controller.composer.utterance("Complete sentence.")
        rig.controller.pauseForCall() // before the queued post Task gets an executor turn
        await Task.yield()
        #expect(rig.backend.prompts.isEmpty)
        #expect(rig.controller.draftsForReview.contains { $0.text == "Complete sentence." })
        rig.controller.stop(discardUnfinished: true)
    }
}

@MainActor private final class RepairOutput: AudioOutput, PlaybackRepairReporting {
    var onPlaybackRepair: (() -> Void)?
    var attempts = 0, interruptions = 1, ready = false, stops = 0
    func play(_ audio: SpeechAudio, label: String, onStart: @escaping () -> Void) async throws {
        attempts += 1; onStart()
        if interruptions > 0 { interruptions -= 1; throw PlaybackInterruption.recoverable }
    }
    func stopPlayback() { stops += 1 }
    func waitUntilReady() async throws {
        while !ready { try await Task.sleep(nanoseconds: 1_000_000) }
    }
}

private final class WaitingTicket: SpeechTicket {
    let text = "One."
    var waiter: CheckedContinuation<SpeechAudio, Error>?
    var cancelled = false
    func audio() async throws -> SpeechAudio {
        try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func cancel() { cancelled = true; waiter?.resume(throwing: CancellationError()); waiter = nil }
}
private final class WaitingSynth: SpeechSynthesizer {
    let ticket = WaitingTicket()
    var attempts = 0
    func prepare(_ text: String) -> SpeechTicket {
        attempts += 1
        return attempts == 1 ? ticket : FakeTicket(text)
    }
}

@Suite(.serialized) @MainActor struct SentenceRepairTests {
    @Test func repairCancelsInFlightTTSTicketAndResynthesizes() async {
        let synth = WaitingSynth(), output = RepairOutput()
        output.interruptions = 0; output.ready = true
        var outcomes: [String] = []
        let speaker = Speaker(synth: synth, output: output) { _ in }
        speaker.onSentenceEnd = { _, _, outcome in outcomes.append(outcome) }
        speaker.enqueue("One.")
        #expect(await waitUntil { synth.ticket.waiter != nil })
        output.onPlaybackRepair?()
        #expect(await waitUntil { outcomes == ["played"] })
        #expect(synth.ticket.cancelled && synth.attempts == 2 && output.attempts == 1)
    }
    @Test func interruptedSentenceIsResynthesizedAndPlayedOnceAfterReadiness() async {
        let synth = FakeSynth(), output = RepairOutput()
        var outcomes: [String] = [], errors = 0
        let speaker = Speaker(synth: synth, output: output) { _ in errors += 1 }
        speaker.onSentenceEnd = { _, _, outcome in outcomes.append(outcome) }
        speaker.enqueue("One.", label: "reply")
        speaker.enqueue("Two.", label: "reply")
        #expect(await waitUntil { outcomes == ["interrupted"] })
        #expect(output.attempts == 1)
        output.ready = true
        #expect(await waitUntil { outcomes == ["interrupted", "played", "played"] })
        #expect(synth.prepared.filter { $0 == "One." }.count == 2 && errors == 0)
    }

    @Test func secondInterruptionFailsVisiblyWithoutLooping() async {
        let synth = FakeSynth(), output = RepairOutput()
        output.interruptions = 5; output.ready = true
        var errors = 0
        let speaker = Speaker(synth: synth, output: output) { _ in errors += 1 }
        speaker.enqueue("One.")
        #expect(await waitUntil { errors == 1 })
        #expect(output.attempts == 2 && synth.prepared.count == 2)
    }

    @Test func endDuringRepairCannotReplayIntoNextCall() async {
        let synth = FakeSynth(), output = RepairOutput()
        let speaker = Speaker(synth: synth, output: output) { _ in }
        speaker.enqueue("One.")
        #expect(await waitUntil { output.attempts == 1 })
        speaker.stop(); output.ready = true
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(output.attempts == 1 && !speaker.active)
    }

    @Test func heldSentenceAndQueueWaitUntilResume() async {
        let synth = FakeSynth(), output = RepairOutput()
        var outcomes: [String] = []
        let speaker = Speaker(synth: synth, output: output) { _ in }
        speaker.onSentenceEnd = { _, _, outcome in outcomes.append(outcome) }
        speaker.enqueue("One."); speaker.enqueue("Two.")
        #expect(await waitUntil { output.attempts == 1 })
        speaker.pause()
        output.ready = true
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(output.attempts == 1)
        speaker.resume()
        #expect(await waitUntil { outcomes == ["interrupted", "played", "played"] })
        #expect(synth.prepared.filter { $0 == "One." }.count == 2)
    }
}
