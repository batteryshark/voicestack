import Foundation
import Testing
@testable import FloatingVoiceCore

// Reviewed 152a394 fixtures; only call-bank/TargetLease/suspension adapters differ on Mac.
final class SegmentRecognitionFixture: RecognitionSession {
    let callbacks: RecognitionCallbacks, text: String
    var pcm: [Data] = []
    var held = false, failEnd = false, ended = false, cancelled = false, finished = false
    var cold = false, prepared = false, peak = 0, outstanding = 0
    var holdDrain = false
    var resumeDrain: CheckedContinuation<Void, Never>?
    private var budget = PCMSendBudget()
    init(_ callbacks: RecognitionCallbacks, text: String) { self.callbacks = callbacks; self.text = text }
    func start() {}
    func setCold(_ cold: Bool) { self.cold = cold }
    func prepareContinuation() { prepared = true; cold = false }
    func write(_ bytes: Data) { pcm.append(bytes) }
    @MainActor func writeBuffered(_ bytes: Data) async throws {
        try Task.checkCancellation()
        if holdDrain { await withCheckedContinuation { resumeDrain = $0 } }
        try Task.checkCancellation()
        guard budget.reserve(bytes.count) else { throw ClientError("fixture send backlog") }
        outstanding += 1; peak = max(peak, outstanding); pcm.append(bytes)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.budget.release(bytes.count); self.outstanding -= 1; continuation.resume()
            }
        }
    }
    func end() {
        ended = true
        if !held { DispatchQueue.main.async { self.finish() } }
    }
    func finish() {
        guard !cancelled, !finished else { return }; finished = true
        if failEnd { callbacks.error(ClientError("fixture segment final failed")); callbacks.done("") }
        else { callbacks.done(text) }
    }
    func cancel() { cancelled = true; callbacks.done("") }
    func releaseDrain() { holdDrain = false; let held = resumeDrain; resumeDrain = nil; held?.resume() }
}

@MainActor final class LongThoughtRig {
    let backend = FakeBackend(), input = FakeInput(), output = FakeOutput(duration: 60)
    let controller: ConversationController
    var sessions: [SegmentRecognitionFixture] = [], transports: [RecognitionSession] = []
    var expectedPCM: [Data] = [], captions: [String] = []
    var finals: [String], held: Set<Int> = [], failures: Set<Int> = [], heldDrains: Set<Int> = []
    var rows: [UtteranceOutcomeDiagnostic] = [], rollovers: [Int] = []
    init(_ finals: [String], health: Bool = false, delivery: BusyDelivery = .queue, manual: Bool = false, pauseMs: Double = 3200) {
        self.finals = finals
        var app = AppSettings(); app.target = "ses_long"; app.busyDelivery = delivery; app.busyMergeQuietMs = 20
        if manual { app.sendMode = .manual }
        var voice = VoiceConfig(); voice.pauseMs = pauseMs; voice.onsetGraceMs = 0
        let settings = LoadedSettings(app: app, voice: voice, voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent")
        var make: (RecognitionCallbacks) -> RecognitionSession = { FakeRecognition($0, transcript: "") }
        controller = ConversationController(settings: settings, backend: backend, synth: FakeSynth(), output: output, input: input,
            makeRecognition: { make($0) }, now: { 100_000 }, chiefPollInterval: 3600)
        make = { [weak self] callbacks in
            guard let self else { return FakeRecognition(callbacks, transcript: "") }
            let index = sessions.count
            let raw: (RecognitionCallbacks) -> RecognitionSession = { callbacks in
                let fixture = SegmentRecognitionFixture(callbacks, text: index < self.finals.count ? self.finals[index] : "new thought")
                fixture.held = self.held.contains(index); fixture.failEnd = self.failures.contains(index)
                fixture.holdDrain = self.heldDrains.contains(index)
                self.sessions.append(fixture); return fixture
            }
            let transport: RecognitionSession
            if health {
                transport = HealthCheckedRecognition(endpoint: "ws://fixture", key: nil, callbacks: callbacks,
                    warmup: SpeechWarmup(), probe: { _, _ in .unloaded }, make: raw)
            } else { transport = raw(callbacks) }
            transports.append(transport); return transport
        }
        controller.outcomeDiagnostics = UtteranceOutcomeLog(write: { [weak self] row, _ in self?.rows.append(row) },
            segment: { [weak self] count, _ in self?.rollovers.append(count) })
        controller.onCaption = { [weak self] event in
            if case .youLive(let text) = event { self?.captions.append(text) }
        }
    }
    func start() async {
        await controller.start()
        #expect(await waitUntil { self.controller.status.phase == "ready" })
        controller.turnTaker?.finalTimeout = 30
    }
    func capture(_ count: Int, voiced: Bool = true) {
        for _ in 0..<count {
            var pcm = voiced ? FakeInput.tone : Data(count: 640)
            for byte in 0..<4 { pcm[byte*2] = UInt8(truncatingIfNeeded: expectedPCM.count >> (byte*8)); pcm[byte*2+1] = 0 }
            expectedPCM.append(pcm); input.onPCM?(pcm)
        }
    }
    func firstCap() { capture(TurnTaker.onsetVoiced + TurnTaker.segmentFrameLimit) }
    func outcomes() throws -> [UtteranceOutcomeDiagnostic] { rows }
    func stop() {
        controller.stop(); controller.onCaption = nil
        for session in sessions { session.pcm = [] }
    }
}

@Suite(.serialized) @MainActor struct LongThoughtTests {
    @Test func twoHundredSecondsRollsTwiceAndPostsOneOrderedThoughtWithoutLostOrDuplicatedFrames() async throws {
        let r = LongThoughtRig(["The first ninety seconds", "continue without a seam", "and end here."])
        await r.start(); defer { r.stop() }
        r.firstCap(); #expect(r.backend.prompts.isEmpty)
        try #require(await waitUntil(15) { r.sessions.count == 2 })
        r.capture(4500); #expect(r.backend.prompts.isEmpty)
        try #require(await waitUntil(15) { r.sessions.count == 3 })
        r.capture(1000 - TurnTaker.onsetVoiced); r.capture(160, voiced: false)
        #expect(await waitUntil(15) { r.backend.prompts.count == 1 })
        #expect(r.backend.prompts.first?.text == "[voice] The first ninety seconds continue without a seam and end here.")
        #expect(r.sessions.flatMap(\.pcm) == r.expectedPCM)
        #expect(r.sessions.dropFirst().allSatisfy { $0.peak == 1 && $0.prepared })
        #expect(r.captions.contains("The first ninety seconds continue without a seam"))
        let last = try #require(r.outcomes().last)
        #expect(last.segmentRollover == 2 && last.turnEndReason == .pause && last.outcome == .posted)
        #expect(r.rollovers == [1, 2] && !r.rows.contains { $0.turnEndReason == .durationLimit })
    }
    @Test(arguments: ["pause", "send", "mute", "logicalStop"])
    func logicalBoundaryWhileCappedFinalPendingKeepsAllCapturedPCMAndSendsOnce(_ boundary: String) async throws {
        let r = LongThoughtRig(["A held prefix", "and its tail."]); r.held = [0]
        await r.start(); defer { r.stop() }; r.firstCap(); r.capture(25)
        #expect(r.sessions.count == 1 && r.sessions[0].ended && r.backend.prompts.isEmpty)
        switch boundary {
        case "pause": r.capture(160, voiced: false)
        case "send": r.controller.send()
        case "mute": r.controller.setMicMuted(true)
        default: r.controller.turnTaker?.endNow(reason: .stop)
        }
        r.sessions[0].finish()
        #expect(await waitUntil(15) { r.backend.prompts.count == 1 })
        #expect(r.backend.prompts.first?.text == "[voice] A held prefix and its tail.")
        #expect(r.sessions.flatMap(\.pcm) == r.expectedPCM)
        #expect(try r.outcomes().last?.turnEndReason == (boundary == "pause" ? .pause : boundary == "send" ? .manualSend : boundary == "mute" ? .muteSend : .stop))
    }
    @Test(arguments: [BusyDelivery.queue, .steer]) func rolloverWhileBusyUsesOneExistingDelivery(_ delivery: BusyDelivery) async {
        let r = LongThoughtRig(["One long", "busy thought."], delivery: delivery)
        await r.start(); defer { r.stop() }
        r.backend.send("session.execution.started", "ses_long")
        #expect(await waitUntil { r.controller.status.busy })
        r.firstCap(); #expect(await waitUntil { r.sessions.count == 2 }); r.capture(10); r.controller.send()
        #expect(await waitUntil(15) { r.backend.prompts.count == 1 })
        #expect(r.backend.prompts.first?.text == "[voice] One long busy thought." && r.backend.prompts.first?.delivery == delivery)
    }
    @Test func continuationWithNoPartialsIsNeitherNoiseNorWordsStopped() async {
        let r = LongThoughtRig(["A real prefix", "and sixty more seconds."])
        await r.start(); defer { r.stop() }
        r.firstCap(); #expect(await waitUntil { r.sessions.count == 2 })
        r.controller.turnTaker?.expectLiveWords = true
        r.capture(3000)
        #expect(r.controller.utteranceInProgress && r.backend.prompts.isEmpty && !r.sessions[1].cancelled)
        r.controller.send(); #expect(await waitUntil(15) { r.backend.prompts.count == 1 })
        #expect(r.backend.prompts.first?.text == "[voice] A real prefix and sixty more seconds.")
    }
    @Test func aPartialDoesNotEnableWordsStoppedWhileContinuationPCMStillDrains() async {
        let r = LongThoughtRig(["Earlier words", "fully drained tail."]); r.heldDrains = [1]
        await r.start(); defer { r.sessions.forEach { $0.releaseDrain() }; r.stop() }; r.firstCap()
        #expect(await waitUntil { r.sessions.count == 2 }); r.capture(1)
        #expect(await waitUntil { r.sessions[1].resumeDrain != nil })
        #expect(r.controller.turnTaker?.hasBufferedRecognitionAudio == true)
        r.sessions[1].callbacks.live("a partial"); r.capture(300)
        #expect(r.controller.utteranceInProgress && !r.sessions[1].ended && r.backend.prompts.isEmpty)
        r.controller.send(); r.sessions[1].releaseDrain()
        #expect(await waitUntil(15) { r.backend.prompts.count == 1 })
        #expect(r.backend.prompts.first?.text == "[voice] Earlier words fully drained tail.")
        #expect(r.sessions.flatMap(\.pcm) == r.expectedPCM)
    }
    @Test(arguments: [200.0, 3200.0], [false, true])
    func wordsStoppedRearmsAfterDrainWithoutChargingBacklogTime(_ pauseMs: Double, _ health: Bool) async throws {
        let r = LongThoughtRig(["Earlier words", "the final tail."], health: health, pauseMs: pauseMs)
        r.heldDrains = [1]
        await r.start(); defer { r.sessions.forEach { $0.releaseDrain() }; r.stop() }; r.firstCap()
        try #require(await waitUntil(15) { r.sessions.count == 2 }); r.capture(1)
        try #require(await waitUntil { r.sessions[1].resumeDrain != nil })
        r.sessions[1].callbacks.live("own segment words")
        let pauseFrames = Int(pauseMs / 20)
        r.capture(pauseFrames + 80)
        #expect(r.controller.utteranceInProgress && !r.sessions[1].ended && r.backend.prompts.isEmpty)
        r.sessions[1].releaseDrain()
        try #require(await waitUntil(15) { r.controller.turnTaker?.hasBufferedRecognitionAudio == false })
        r.sessions[1].callbacks.live("own segment words")
        for frame in 1...pauseFrames {
            r.capture(1)
            try #require(await waitUntil { r.controller.turnTaker?.hasBufferedRecognitionAudio == false })
            if frame < pauseFrames { #expect(!r.sessions[1].ended && r.backend.prompts.isEmpty) }
        }
        try #require(await waitUntil(15) { r.backend.prompts.count == 1 })
        #expect(r.backend.prompts.first?.text == "[voice] Earlier words the final tail.")
        #expect(r.sessions.count == 2 && r.sessions.allSatisfy(\.finished))
        #expect(r.sessions.flatMap(\.pcm) == r.expectedPCM)
        #expect(r.rows.last?.turnEndReason == .wordsStopped)
        #expect(try r.outcomes().filter { $0.outcome == .posted }.count == 1)
    }
    @Test(arguments: ["", "okay"]) func emptyOrAcknowledgementTailKeepsWholePrefix(_ tail: String) async {
        let r = LongThoughtRig(["A genuine long thought", tail])
        await r.start(); defer { r.stop() }; r.controller.speaker.enqueue(one)
        #expect(await waitUntil { r.output.playing == [one] }); r.firstCap()
        #expect(await waitUntil { r.sessions.count == 2 }); r.capture(10); r.capture(160, voiced: false)
        #expect(await waitUntil(15) { r.backend.prompts.count == 1 })
        #expect(r.backend.prompts.first?.text == "[voice] A genuine long thought" + (tail.isEmpty ? "" : " okay"))
    }
    @Test func manualModeMuteHoldsTheJoinedThoughtUntilExplicitSend() async {
        let r = LongThoughtRig(["Manual prefix", "and tail."], manual: true); r.held = [0]
        await r.start(); defer { r.stop() }; r.firstCap(); r.capture(20)
        r.controller.setMicMuted(true); r.sessions[0].finish()
        #expect(await waitUntil(15) { !r.controller.utteranceInProgress })
        #expect(r.backend.prompts.isEmpty && r.controller.composer.held == "Manual prefix and tail.")
        r.controller.send(); #expect(await waitUntil { r.backend.prompts.count == 1 })
        #expect(r.backend.prompts.first?.text == "[voice] Manual prefix and tail.")
    }
    @Test func directStopRetainsJoinedKnownTextAndNeverSendsOrStartsStandby() async {
        let r = LongThoughtRig(["Earlier prefix", "not returned"]); r.held = [1]
        await r.start(); defer { r.stop() }; r.firstCap()
        #expect(await waitUntil { r.sessions.count == 2 })
        r.capture(4500); #expect(await waitUntil(15) { r.sessions[1].ended })
        r.sessions[1].callbacks.live("known continuation"); r.capture(20)
        r.controller.stop()
        #expect(r.backend.prompts.isEmpty && r.sessions.count == 2)
        #expect(r.controller.draftsForReview.contains("Earlier prefix known continuation"))
        r.sessions[1].callbacks.done("stale final"); #expect(r.backend.prompts.isEmpty)
    }
    @Test(arguments: [false, true]) func failedContinuationFinalRetainsPrefixAndKnownPartialForReview(_ timeout: Bool) async throws {
        let r = LongThoughtRig(["Reliable prefix", "not authoritative"])
        if timeout { r.held = [1] } else { r.failures = [1] }
        await r.start(); defer { r.stop() }; r.firstCap()
        #expect(await waitUntil { r.sessions.count == 2 })
        r.sessions[1].callbacks.live("known partial")
        if timeout { r.controller.turnTaker?.finalTimeout = 0.05 }
        r.capture(10); r.controller.send()
        #expect(await waitUntil(15) { !r.controller.utteranceInProgress })
        #expect(r.backend.prompts.isEmpty)
        #expect(r.controller.draftsForReview.contains("Reliable prefix known partial"))
        #expect(try r.outcomes().last?.turnEndReason == (timeout ? .finalTimeout : .discontinuity))
    }
    @Test func discardDuringSecondRolloverDropsPrefixAndBufferedTailAndFencesOldFinals() async throws {
        let r = LongThoughtRig(["First prefix", "second prefix", "new thought."]); r.held = [1]
        await r.start(); defer { r.stop() }; r.firstCap()
        #expect(await waitUntil { r.sessions.count == 2 }); r.capture(4500)
        #expect(await waitUntil(15) { r.sessions[1].ended }); r.capture(50)
        let stale = r.sessions[1]; r.controller.discardPending(); stale.callbacks.done("late words")
        #expect(!r.controller.utteranceInProgress && r.backend.prompts.isEmpty && r.controller.draftsForReview.isEmpty)
        #expect(try r.outcomes().last?.outcome == .discardedByUser && r.outcomes().last?.segmentRollover == 2)
        r.capture(8); r.controller.send(); #expect(await waitUntil { r.backend.prompts.count == 1 })
        #expect(r.backend.prompts.first?.text == "[voice] new thought.")
    }
    @Test(arguments: ["stopVoice", "quit", "target"]) func hardEndDuringRolloverRetainsKnownTextButNeverStartsNextSocket(_ end: String) async {
        let r = LongThoughtRig(["Reliable prefix", "final second segment"]); r.held = [1]
        await r.start(); defer { r.stop() }; r.firstCap()
        #expect(await waitUntil { r.sessions.count == 2 }); r.sessions[1].callbacks.live("known partial")
        r.capture(4500); #expect(await waitUntil(15) { r.sessions[1].ended }); r.capture(20)
        switch end {
        case "stopVoice": r.controller.endVoice()
        case "quit": _ = await r.controller.shutdown(deliberateQuit: true)
        default: r.controller.setTargetSetting("ses_new")
        }
        r.sessions[1].finish()
        #expect(r.controller.draftsForReview.contains("Reliable prefix known partial"))
        #expect(r.backend.prompts.isEmpty && r.sessions.count == 2)
        if end != "target" {
            #expect(await r.controller.waitForPosts(timeout: 1))
            #expect(r.backend.endAttempts == ["ses_long"])
        }
    }
    @Test func cutInAcrossRolloverKeepsSingleDecisionAndWholeFinal() async throws {
        let r = LongThoughtRig(["Actually change", "the plan."])
        await r.start(); defer { r.stop() }; r.controller.speaker.enqueue(one)
        #expect(await waitUntil { r.output.playing == [one] })
        r.capture(8); r.sessions[0].callbacks.live("actually")
        #expect(r.output.cutInPaused && r.output.stops == 0)
        for words in 1...45 {
            r.sessions[0].callbacks.live("actually " + String(repeating: "more ", count: words)); r.capture(100)
        }
        #expect(await waitUntil { r.sessions.count == 2 })
        #expect(r.output.cutInPaused && r.output.stops == 0 && r.backend.prompts.isEmpty)
        r.capture(10); r.controller.send(); #expect(await waitUntil { r.backend.prompts.count == 1 })
        #expect(r.backend.prompts.first?.text == "[voice] Actually change the plan.")
        #expect(try r.outcomes().last?.cutInStoppedPlayback == true && r.outcomes().last?.segmentRollover == 1)
        #expect(r.rows.filter { $0.outcome == .posted }.count == 1 && r.rows.last?.ordinal == 1)
    }
    @Test func sixtySecondsPendingColdFinalFitsBoundAndOnlyFirstSegmentGetsColdBudget() async throws {
        let r = LongThoughtRig(["Cold first segment", "warm continuation."], health: true); r.held = [0]
        await r.start(); defer { r.stop() }; r.firstCap()
        try #require(await waitUntil(15) { r.sessions.first?.ended == true })
        let firstBudget = await r.transports[0].finalBudget(ordinary: 8)
        #expect(r.sessions[0].cold && firstBudget == 60)
        r.capture(3000)
        #expect(r.sessions.count == 1 && r.controller.utteranceInProgress)
        r.controller.send(); r.sessions[0].finish()
        #expect(await waitUntil(15) { r.backend.prompts.count == 1 })
        let nextBudget = await r.transports[1].finalBudget(ordinary: 8)
        #expect(!r.sessions[1].cold && nextBudget == 8)
        #expect(r.sessions.flatMap(\.pcm) == r.expectedPCM)
    }
    @Test func excessiveRolloverBacklogFailsToReviewInsteadOfTruncatingOrGrowingUnbounded() async {
        let r = LongThoughtRig(["not yet final"]); r.held = [0]
        await r.start(); defer { r.stop() }; r.firstCap()
        r.sessions[0].callbacks.live("known words"); r.capture(4500)
        #expect(!r.controller.utteranceInProgress && r.backend.prompts.isEmpty && r.sessions.count == 1)
        #expect(r.controller.draftsForReview.contains("known words"))
    }
    @Test func healthQueueIsBoundedAndOverflowRejectsLateWrites() {
        var errors = 0, finals = 0, sockets = 0
        let callbacks = RecognitionCallbacks(partial: { _ in }, error: { _ in errors += 1 }, done: { _ in finals += 1 })
        let session = HealthCheckedRecognition(endpoint: "ws://fixture", key: nil, callbacks: callbacks,
            warmup: SpeechWarmup(), probe: { _, _ in .loaded }) {
                sockets += 1; return FakeRecognition($0, transcript: "never starts")
            }
        for _ in 0..<4550 { session.write(Data(count: 640)) }
        #expect(session.pendingBytes == 2_912_000 && session.hasBufferedAudio)
        session.write(Data(count: 640))
        #expect(session.pendingBytes == 0 && !session.hasBufferedAudio && errors == 1 && finals == 1 && sockets == 0)
        session.write(Data(count: 640)); session.end()
        #expect(session.pendingBytes == 0 && errors == 1 && finals == 1)
        session.cancel()
    }
    @Test func discardedBlockedDrainCannotLeakPCMIntoFreshThought() async throws {
        let r = LongThoughtRig(["Discarded prefix", "discarded tail", "fresh thought."])
        r.heldDrains = [1]
        await r.start(); defer { r.sessions.forEach { $0.releaseDrain() }; r.stop() }; r.firstCap()
        try #require(await waitUntil { r.sessions.count == 2 }); r.capture(1)
        try #require(await waitUntil { r.sessions[1].resumeDrain != nil })
        r.capture(20); r.controller.discardPending(); r.sessions[1].releaseDrain()
        r.sessions[1].callbacks.done("stale tail")
        r.capture(8); r.controller.send()
        #expect(await waitUntil { r.backend.prompts.count == 1 })
        #expect(r.backend.prompts.first?.text == "[voice] fresh thought.")
        #expect(r.sessions[1].pcm.isEmpty && r.controller.draftsForReview.isEmpty)
    }
    @Test func legacyOutcomeJSONDecodesWithoutNewFieldsAndNewRecordsExcludeText() throws {
        let old = Data(#"{"ordinal":1,"sequence":1,"finalWordCount":2,"finalEmpty":false,"finalReceived":true,"cutInStoppedPlayback":false,"outcome":"posted","delivery":"normal"}"#.utf8)
        let decoded = try JSONDecoder().decode(UtteranceOutcomeDiagnostic.self, from: old)
        #expect(decoded.segmentRollover == nil && decoded.turnEndReason == nil)
        #expect(TurnEndReason(rawValue: "durationLimit") == .durationLimit)
    }
    @Test func reviewedSendBudgetHasBothCountAndByteLimits() {
        var budget = PCMSendBudget()
        for _ in 0..<100 { let admitted = budget.reserve(640); #expect(admitted) }
        let full = budget.reserve(1); #expect(!full)
        budget.release(640)
        let tooLarge = budget.reserve(641); #expect(!tooLarge)
        let fits = budget.reserve(640); #expect(fits)
        let negative = budget.reserve(-1); #expect(!negative)
    }
}
