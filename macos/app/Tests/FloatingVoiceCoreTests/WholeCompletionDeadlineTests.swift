import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct WholeCompletionDeadlineTests {
    final class Recognition: RecognitionSession {
        let cb: RecognitionCallbacks
        var cancelled = false
        init(_ cb: RecognitionCallbacks) { self.cb = cb }
        func start() {}
        func write(_ pcm: Data) {}
        func end() {}
        func cancel() { cancelled = true }
    }

    /// Same ordering as the independent review repro: never yield between elapsed deadline and completion.
    /// This occupies this test's actor for 40 ms, not the host, model executor, or audio device.
    func occupyActorPastShortDeadline() {
        let until = ContinuousClock.now + .milliseconds(40)
        while ContinuousClock.now < until {}
    }

    @Test func overduePreEndNormalCompletionRetiresBeforeOverdueTimerCanRun() {
        var r: Recognition?, posts: [String] = [], errors = 0, review = ""
        var cb = TurnCallbacks(); cb.transcript = { posts.append($0) }; cb.error = { _ in errors += 1 }; cb.review = { review = $0 }
        let t = TurnTaker(config: VoiceConfig(), callbacks: cb) { r = Recognition($0); return r! }
        defer { t.stop() }
        t.warmWholeTimeout = 0.02
        t.push(Data(count: 640 * 50)); for _ in 0..<12 { t.push(FakeInput.tone) }
        #expect(t.inUtterance && !t.awaitingFinal)
        r?.cb.live("known partial")
        occupyActorPastShortDeadline()
        r?.cb.done("Early normal final.") // no logical end; timer has had no opportunity to run
        #expect(posts.isEmpty && errors == 1 && !t.inUtterance && r?.cancelled == true)
        #expect(review == "known partial")
        r?.cb.done("late final"); r?.cb.error(ClientError("late error"))
        #expect(posts.isEmpty && errors == 1)
    }

    @Test func withinBudgetPreEndNormalCompletionStillSucceedsExactlyOnce() {
        var r: Recognition?, posts: [String] = [], errors = 0
        var cb = TurnCallbacks(); cb.transcript = { posts.append($0) }; cb.error = { _ in errors += 1 }
        let t = TurnTaker(config: VoiceConfig(), callbacks: cb) { r = Recognition($0); return r! }
        defer { t.stop() }
        t.warmWholeTimeout = 2
        t.push(Data(count: 640 * 50)); for _ in 0..<12 { t.push(FakeInput.tone) }
        r?.cb.done("Early normal final."); r?.cb.done("late duplicate")
        #expect(posts == ["Early normal final."] && errors == 0 && !t.inUtterance)
    }

    @Test func ownedHealthKeepsPositiveColdStickyAfterWordsButNotUnknownOrUnresolved() async throws {
        for state in [SpeechModelState.loaded, .unknown, .loading, .unloaded] {
            var r: Recognition?, posts: [String] = [], errors = 0
            var cb = TurnCallbacks(); cb.transcript = { posts.append($0) }; cb.error = { _ in errors += 1 }
            let t = TurnTaker(config: VoiceConfig(), callbacks: cb) { callbacks in
                HealthCheckedRecognition(endpoint: "ws://fixture", key: nil, callbacks: callbacks, warmup: SpeechWarmup(), probe: { _, _ in state }) {
                    r = Recognition($0); return r!
                }
            }
            t.warmWholeTimeout = 0.02; t.coldWholeTimeout = 2
            t.push(Data(count: 640 * 50)); for _ in 0..<12 { t.push(FakeInput.tone) }
            try #require(await waitUntil { r != nil })
            r?.cb.live("words end warming UI, not cold eligibility")
            occupyActorPastShortDeadline()
            r?.cb.done("Early normal final.")
            #expect(posts == (state.isCold ? ["Early normal final."] : []))
            #expect(errors == (state.isCold ? 0 : 1))
            r?.cb.done("late duplicate")
            #expect(!t.inUtterance)
            t.stop()
        }
        // Unresolved health has no positive cold evidence and must not grant an early completion 180 s.
        var release: CheckedContinuation<SpeechModelState, Never>?, errors = 0, posts = 0
        var cbs = TurnCallbacks(); cbs.error = { _ in errors += 1 }; cbs.transcript = { _ in posts += 1 }
        var recognitionCallbacks: RecognitionCallbacks?
        let unresolved = TurnTaker(config: VoiceConfig(), callbacks: cbs) { callbacks in
            recognitionCallbacks = callbacks
            return HealthCheckedRecognition(endpoint: "ws://fixture", key: nil, callbacks: callbacks, warmup: SpeechWarmup(), probe: { _, _ in
                await withCheckedContinuation { release = $0 }
            }) { Recognition($0) }
        }
        unresolved.warmWholeTimeout = 0.02; unresolved.coldWholeTimeout = 2
        unresolved.push(Data(count: 640 * 50)); for _ in 0..<12 { unresolved.push(FakeInput.tone) }
        try #require(await waitUntil { release != nil })
        occupyActorPastShortDeadline(); recognitionCallbacks?.done("unresolved early final")
        release?.resume(returning: .unloaded)
        #expect(posts == 0 && errors == 1 && !unresolved.inUtterance)
        unresolved.stop()
    }

    @Test func coldFirstHasItsOwnWholeLimitAndContinuationRemainsOrdinary() async throws {
        // Positive cold is not unlimited: enforce its deadline even before logical end.
        var cold: Recognition?, posts = 0, errors = 0
        var cb = TurnCallbacks(); cb.transcript = { _ in posts += 1 }; cb.error = { _ in errors += 1 }
        let t = TurnTaker(config: VoiceConfig(), callbacks: cb) { callbacks in
            HealthCheckedRecognition(endpoint: "ws://fixture", key: nil, callbacks: callbacks, warmup: SpeechWarmup(), probe: { _, _ in .unloaded }) {
                cold = Recognition($0); return cold!
            }
        }
        t.warmWholeTimeout = 2; t.coldWholeTimeout = 0.02
        t.push(Data(count: 640 * 50)); for _ in 0..<12 { t.push(FakeInput.tone) }
        try #require(await waitUntil { cold != nil })
        occupyActorPastShortDeadline(); cold?.cb.done("overdue cold final")
        #expect(posts == 0 && errors == 1 && cold?.cancelled == true)
        t.stop()

        var segments: [Recognition] = [], finals: [String] = [], failures = 0
        var callbacks = TurnCallbacks(); callbacks.transcript = { finals.append($0) }; callbacks.error = { _ in failures += 1 }
        let long = TurnTaker(config: VoiceConfig(), callbacks: callbacks) { cbs in
            HealthCheckedRecognition(endpoint: "ws://fixture", key: nil, callbacks: cbs, warmup: SpeechWarmup(), probe: { _, _ in .unloaded }) {
                let r = Recognition($0); segments.append(r); return r
            }
        }
        long.warmWholeTimeout = 2; long.coldWholeTimeout = 3
        for _ in 0..<12 { long.push(FakeInput.tone) }
        try #require(await waitUntil { segments.count == 1 })
        for _ in 0..<4500 { long.push(FakeInput.tone) }
        segments[0].cb.done("Finalized prefix")
        try #require(await waitUntil { segments.count == 2 })
        #expect(!long.awaitingFinal)
        // Shorten only the test's ordinary limit now; cold allowance would still be three seconds.
        long.warmWholeTimeout = 0.02
        occupyActorPastShortDeadline(); segments[1].cb.done("overdue continuation")
        #expect(finals.isEmpty && failures == 1 && segments[1].cancelled && !long.inUtterance)
        segments[1].cb.done("late continuation"); #expect(finals.isEmpty && failures == 1)
        long.stop()
    }
}
