import Foundation
import Testing
@testable import FloatingVoiceCore

/// All timing is local/scaled; no model, microphone, or shared speech port.
@Suite(.serialized) @MainActor struct RecognitionDeadlineTests {
    final class Transport: RecognitionSession {
        let cb: RecognitionCallbacks
        var cancelled = false, ended = false, wireEnded = false
        var upload: TimeInterval = 0, response: TimeInterval = 0.12
        var endError = false, cold = false
        var automaticFinal = true
        var firstWriteDelay: TimeInterval = 0, admittedBytes = 0
        private let transmission = RecognitionEndTransmission()
        init(_ cb: RecognitionCallbacks) { self.cb = cb }
        func start() {}
        func write(_ pcm: Data) { admittedBytes += pcm.count }
        @MainActor func writeBuffered(_ pcm: Data) async throws {
            if admittedBytes == 0 { try await Task.sleep(for: .seconds(firstWriteDelay)) }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            write(pcm)
        }
        func end() {
            ended = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(upload))
                guard !cancelled else { return }
                if endError { transmission.resolve(.failure(ClientError("fixture end write failed"))); return }
                wireEnded = true; transmission.resolve(.success(.now))
                guard automaticFinal else { return }
                try? await Task.sleep(for: .seconds(response))
                cb.done("Whole thought.") // deliberately late even after cancel
            }
        }
        func finalBudget(ordinary: TimeInterval) async -> TimeInterval { cold ? 0.6 : ordinary }
        @MainActor func waitForEndTransmission() async throws -> ContinuousClock.Instant {
            try await transmission.value()
        }
        func cancel() { cancelled = true; transmission.resolve(.failure(CancellationError())) }
    }

    @Test func ordinaryFinalBetweenSoftAndHardIsNotQuarantined() async throws {
        var result = "", errors = 0, feedback: [Bool] = [], r: Transport?
        var cb = TurnCallbacks(); cb.transcript = { result = $0 }; cb.error = { _ in errors += 1 }
        // Barrier, not a 20 ms scheduler race: deliver the final only when soft feedback is observed.
        cb.transcribing = { active in
            feedback.append(active)
            if active {
                #expect(result.isEmpty && errors == 0)
                r?.cb.done("Whole thought.")
            }
        }
        let t = TurnTaker(config: VoiceConfig(), callbacks: cb) {
            let transport = Transport($0); transport.automaticFinal = false; r = transport; return transport
        }
        t.finalTimeout = 0.08
        t.push(Data(repeating: 0, count: 640 * 50))
        for _ in 0..<12 { t.push(FakeInput.tone) }
        t.endNow()
        #expect(await waitUntil { result == "Whole thought." })
        #expect(r?.wireEnded == true)
        #expect(errors == 0)
        #expect(feedback == [true, false])
        t.stop()
    }

    @Test func responseBudgetDoesNotIncludePendingUpload() async throws {
        var result = "", errors = 0, transport: Transport?
        var cb = TurnCallbacks(); cb.transcript = { result = $0 }; cb.error = { _ in errors += 1 }
        let t = TurnTaker(config: VoiceConfig(), callbacks: cb) {
            let r = Transport($0); r.upload = 0.20; r.response = 0.02; transport = r; return r
        }
        t.finalTimeout = 0.08 // upload exceeds even the scaled hard response budget
        t.push(Data(repeating: 0, count: 640 * 50))
        for _ in 0..<12 { t.push(FakeInput.tone) }
        t.endNow()
        try await Task.sleep(for: .milliseconds(180))
        #expect(t.awaitingFinal && errors == 0 && transport?.wireEnded == false)
        #expect(await waitUntil { result == "Whole thought." })
        #expect(errors == 0)
        t.stop()
    }

    @Test func fixedHardLimitQuarantinesDespitePartialProgressAndLateFinal() async throws {
        var finals = 0, errors = 0, review = "", feedback: [Bool] = [], r: Transport?
        var cb = TurnCallbacks(); cb.transcript = { _ in finals += 1 }; cb.error = { _ in errors += 1 }
        cb.review = { review = $0 }; cb.transcribing = { active in
            feedback.append(active)
            if active { r?.cb.live("known partial") }
        }
        let t = TurnTaker(config: VoiceConfig(), callbacks: cb) {
            let transport = Transport($0); transport.automaticFinal = false; r = transport; return transport
        }
        t.finalTimeout = 0.06
        t.push(Data(count: 640 * 50)); for _ in 0..<12 { t.push(FakeInput.tone) }; t.endNow()
        #expect(await waitUntil { errors == 1 })
        #expect(errors == 1 && finals == 0 && review == "known partial" && r?.cancelled == true)
        #expect(feedback == [true, false])
        r?.cb.done("late complete final")
        #expect(finals == 0)
        t.stop()
    }

    @Test func boundedSendStallRetiresBeforeLateTransmission() async throws {
        var finals = 0, errors = 0, review = "", r: Transport?
        var cb = TurnCallbacks(); cb.transcript = { _ in finals += 1 }; cb.error = { _ in errors += 1 }; cb.review = { review = $0 }
        let t = TurnTaker(config: VoiceConfig(), callbacks: cb) {
            let transport = Transport($0); transport.upload = 0.2; r = transport; return transport
        }
        t.finalSendTimeout = 0.05; t.finalTimeout = 0.02
        t.push(Data(count: 640 * 50)); for _ in 0..<12 { t.push(FakeInput.tone) }
        r?.cb.live("retained words"); t.endNow()
        #expect(await waitUntil { errors == 1 })
        try await Task.sleep(for: .milliseconds(230))
        #expect(finals == 0 && review == "retained words" && r?.wireEnded == false && r?.cancelled == true)
        t.stop()
    }

    @Test func endWriteErrorAndWholeOperationClamp() async throws {
        for writeError in [true, false] {
            var errors = 0, finals = 0, r: Transport?
            var cb = TurnCallbacks(); cb.error = { _ in errors += 1 }; cb.transcript = { _ in finals += 1 }
            let t = TurnTaker(config: VoiceConfig(), callbacks: cb) {
                let transport = Transport($0); transport.endError = writeError; transport.cold = !writeError
                transport.response = 0.3; r = transport; return transport
            }
            t.finalTimeout = 0.02; t.warmWholeTimeout = 0.15; t.coldWholeTimeout = 0.15
            t.push(Data(count: 640 * 50)); for _ in 0..<12 { t.push(FakeInput.tone) }; t.endNow()
            #expect(await waitUntil(0.25) { errors == 1 })
            #expect(finals == 0 && r?.cancelled == true)
            t.stop()
        }
    }

    @Test func discardAndStopDuringUploadOrSoftFeedbackFenceEveryLateEvent() async throws {
        for upload in [0.0, 0.15] {
            for stop in [false, true] {
                var finals = 0, errors = 0, feedback: [Bool] = [], r: Transport?
                var cb = TurnCallbacks(); cb.error = { _ in errors += 1 }; cb.transcript = { _ in finals += 1 }
                cb.transcribing = { feedback.append($0) }
                let t = TurnTaker(config: VoiceConfig(), callbacks: cb) {
                    let transport = Transport($0); transport.upload = upload; transport.response = 0.2; r = transport; return transport
                }
                t.finalTimeout = 0.05
                t.push(Data(count: 640 * 50)); for _ in 0..<12 { t.push(FakeInput.tone) }; t.endNow()
                try await Task.sleep(for: .milliseconds(70))
                if stop { t.stop() } else { t.discard() }
                let retiredFeedback = feedback
                try await Task.sleep(for: .milliseconds(200)); r?.cb.done("late final")
                #expect(finals == 0 && errors == 0 && feedback == retiredFeedback && feedback.last != true)
                #expect(r?.cancelled == true)
            }
        }
    }

    @Test func hungHealthComputationCannotOwnDeadlineOrOpenLateSocket() async throws {
        var release: CheckedContinuation<SpeechModelState, Never>?, sockets = 0, errors = 0
        var cb = TurnCallbacks(); cb.error = { _ in errors += 1 }
        let t = TurnTaker(config: VoiceConfig(), callbacks: cb) { callbacks in
            HealthCheckedRecognition(endpoint: "ws://fixture", key: nil, callbacks: callbacks, warmup: SpeechWarmup(), probe: { _, _ in
                await withCheckedContinuation { release = $0 }
            }) { sockets += 1; return FakeRecognition($0, transcript: "never") }
        }
        t.finalSendTimeout = 0.05
        t.push(Data(count: 640 * 50)); for _ in 0..<12 { t.push(FakeInput.tone) }; t.endNow()
        #expect(await waitUntil { errors == 1 })
        release?.resume(returning: .unloaded)
        try await Task.sleep(for: .milliseconds(20))
        #expect(sockets == 0 && !t.inUtterance)
        t.stop()
    }

    @Test func nestedHealthWrappersAwaitRealTransportEnd() async throws {
        var inner: Transport?, observedEnd = false
        let cb = RecognitionCallbacks(partial: { _ in }, error: { _ in }, done: { _ in })
        let outer = HealthCheckedRecognition(endpoint: "ws://fixture", key: nil, callbacks: cb, warmup: SpeechWarmup(), probe: { _, _ in .loaded }) { cb in
            HealthCheckedRecognition(endpoint: "ws://fixture", key: nil, callbacks: cb, warmup: SpeechWarmup(), probe: { _, _ in .loaded }) { cb in
                let r = Transport(cb); r.upload = 0.08; inner = r; return r
            }
        }
        outer.start(); outer.write(Data(count: 640)); outer.end()
        let wait = Task { _ = try await outer.waitForEndTransmission(); observedEnd = true }
        try await Task.sleep(for: .milliseconds(40))
        #expect(!observedEnd && inner?.wireEnded == false)
        try await wait.value
        #expect(observedEnd && inner?.wireEnded == true)
        outer.cancel()
    }

    @Test func rolloverSoftLimitDoesNotAnnounceWhileCaptureContinues() async throws {
        var r: Transport?, feedback: [Bool] = []
        var cb = TurnCallbacks(); cb.transcribing = { feedback.append($0) }
        let t = TurnTaker(config: VoiceConfig(), callbacks: cb) {
            let transport = Transport($0); transport.response = 0.15; r = transport; return transport
        }
        t.finalTimeout = 0.1
        for _ in 0..<4508 { t.push(FakeInput.tone) }
        try await Task.sleep(for: .milliseconds(120))
        #expect(t.awaitingFinal && r?.ended == true && feedback.isEmpty)
        t.discard()
        try await Task.sleep(for: .milliseconds(60))
        #expect(feedback.isEmpty && !t.inUtterance)
        t.stop()
    }

    @Test func pendingPCMDrainAndEndWriteBothPrecedeResponseClock() async throws {
        var inner: Transport?, finals: [String] = [], errors = 0
        var cb = TurnCallbacks(); cb.transcript = { finals.append($0) }; cb.error = { _ in errors += 1 }
        let t = TurnTaker(config: VoiceConfig(), callbacks: cb) { callbacks in
            HealthCheckedRecognition(endpoint: "ws://fixture", key: nil, callbacks: callbacks, warmup: SpeechWarmup(), probe: { _, _ in .loaded }) {
                let r = Transport($0); r.firstWriteDelay = 0.18; r.upload = 0.05; r.response = 0.05; inner = r; return r
            }
        }
        t.finalTimeout = 0.04; t.finalSendTimeout = 0.5
        t.push(Data(count: 640 * 50)); for _ in 0..<12 { t.push(FakeInput.tone) }; t.endNow()
        try await Task.sleep(for: .milliseconds(120))
        #expect(t.awaitingFinal && inner?.ended == false && errors == 0)
        #expect(await waitUntil { finals.count == 1 || errors > 0 })
        #expect(finals == ["Whole thought."] && errors == 0 && inner?.admittedBytes == 640 * 54)
        t.stop()
    }

    @Test func positiveColdBudgetHasNoOrdinaryGraceOrFeedback() async throws {
        var finals = 0, errors = 0, feedback: [Bool] = []
        var cb = TurnCallbacks(); cb.transcript = { _ in finals += 1 }; cb.error = { _ in errors += 1 }; cb.transcribing = { feedback.append($0) }
        let t = TurnTaker(config: VoiceConfig(), callbacks: cb) {
            let r = Transport($0); r.cold = true; r.upload = 0.15; r.response = 0.25; return r
        }
        t.finalTimeout = 0.1; t.finalSendTimeout = 0.05
        t.push(Data(count: 640 * 50)); for _ in 0..<12 { t.push(FakeInput.tone) }; t.endNow()
        #expect(await waitUntil { finals == 1 || errors > 0 })
        #expect(finals == 1 && errors == 0 && feedback.isEmpty)
        t.stop()
    }

    @Test func controllerNoticeIsOwnedAndCannotStompPrivateCueOrTargetRetirement() async throws {
        for retirement in ["final", "discard", "stop", "target", "newerNotice"] {
            let rig = Rig(); rig.silentEnd = true
            await rig.start(); defer { rig.controller.stop() }
            rig.controller.turnTaker?.finalTimeout = 0.1
            rig.input.frames(20, voiced: true); rig.controller.send()
            try #require(await waitUntil { rig.controller.status.notice == "Still transcribing…" })
            let r = try #require(rig.recognitions.first)
            switch retirement {
            case "final": r.callbacks.done("Whole final.")
            case "discard": rig.controller.discardPending()
            case "stop": rig.controller.stop()
            case "target": rig.controller.setTargetSetting("ses_B")
            default:
                // A newer private notice owns this surface; feedback teardown cannot clear it.
                rig.controller.stop(notice: "Newer private notice")
            }
            if retirement != "newerNotice" { #expect(rig.controller.status.notice != "Still transcribing…") }
            if retirement != "final" { r.callbacks.done("late final") }
            try await Task.sleep(for: .milliseconds(30))
            if retirement != "final" { #expect(rig.backend.prompts.isEmpty) }
            if retirement == "newerNotice" { #expect(rig.controller.status.notice == "Newer private notice") }
        }
    }

    @Test func completionWaiterCancellationDoesNotInventWireSuccess() async throws {
        let seam = RecognitionEndTransmission()
        let waiter = Task { try await seam.value() }
        await Task.yield(); waiter.cancel()
        do { _ = try await waiter.value; Issue.record("cancelled wire wait succeeded") } catch { #expect(error is CancellationError) }
        seam.resolve(.success(.now))
        _ = try await seam.value() // another owner's actual completion is still observable
    }
}
