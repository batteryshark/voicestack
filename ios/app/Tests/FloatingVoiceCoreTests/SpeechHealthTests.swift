import Foundation
import Testing
@testable import FloatingVoiceCore

private final class DelayedSpeechTicket: SpeechTicket {
    let text = "cold"
    var cancelled = false
    func audio() async throws -> SpeechAudio {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return .whole(Data([1, 2]), sampleRate: 24000)
    }
    func cancel() { cancelled = true }
}

/// Same 100-send/64KB policy and deferred main-queue releases as the socket.
/// The synchronous write path reproduces the old preroll-flush failure.
private final class BudgetEnforcedRecognition: RecognitionSession {
    let callbacks: RecognitionCallbacks
    let onDrained: () -> Void
    let releaseDelay: TimeInterval
    private var budget = PCMSendBudget()
    var accepted: [Data] = []
    var outstanding = 0, peakOutstanding = 0
    var backlogFailure = false, ended = false, cancelled = false
    init(_ callbacks: RecognitionCallbacks, releaseDelay: TimeInterval = 0.002, onDrained: @escaping () -> Void = {}) {
        self.callbacks = callbacks; self.releaseDelay = releaseDelay; self.onDrained = onDrained
    }
    func start() {}
    private func send(_ pcm: Data, completion: @escaping (Error?) -> Void) {
        guard budget.reserve(pcm.count) else {
            backlogFailure = true
            let error = ClientError("Recognition send backlog")
            callbacks.error(error); completion(error); return
        }
        accepted.append(pcm); outstanding += 1; peakOutstanding = max(peakOutstanding, outstanding)
        // Preserve asynchronous admission/release. The complete-drain test uses
        // zero delay; the separate mid-drain cancellation fixture retains its delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay) {
            self.budget.release(pcm.count); self.outstanding -= 1; completion(nil)
        }
    }
    func write(_ pcm: Data) { send(pcm) { _ in } }
    @MainActor func writeBuffered(_ pcm: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            send(pcm) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
    func end() { ended = true; callbacks.done("complete utterance"); onDrained() }
    func cancel() { cancelled = true }
}

@Suite @MainActor struct SpeechHealthTests {
    @Test func directNestedAndLegacyContracts() {
        #expect(SpeechModelState.parse(["model": "loaded"]) == .loaded)
        #expect(SpeechModelState.parse(["model": "unloaded"]).isCold)
        #expect(SpeechModelState.parse(["model": "loaded", "upstream": ["model": "loading"]]) == .loading)
        #expect(SpeechModelState.parse(["status": "ok"]) == .unknown)
        #expect(ServiceChecks.healthURL("wss://bridge:8794/floating-voice/asr/v1/transcribe?partials=1")?.absoluteString == "https://bridge:8794/floating-voice/asr/health")
        #expect(ServiceChecks.healthURL("http://bridge:8794/floating-voice/tts/v1/audio/speech")?.absoluteString == "http://bridge:8794/floating-voice/tts/health")
    }
    @Test func closedEnvelopeAndExactPrincipalWording() {
        for service in ["asr", "tts"] {
            let error = HTTPError.status(503, "{\"error\":\"speech_unavailable\",\"service\":\"\(service)\",\"endpoint\":\"127.0.0.1:8446\"}")
            let message = SpeechServiceError.describe(url: "https://bridge:8794", error: error)
            #expect(message == "Speech service at 127.0.0.1:8446 isn't running")
            #expect(PrincipalError.message(message, captureRunning: true) == message)
        }
        #expect(SpeechServiceError.notRunning("https://speech.example/x") == "Speech service at speech.example:443 isn't running")
        #expect(SpeechServiceError.describe(url: "ws://speech:8446/x", error: URLError(.cannotConnectToHost)) == "Speech service at speech:8446 isn't running")
    }
    @Test func recognitionColdBudgetBuffersEndAndCancellationCannotResurrect() async {
        let warmup = SpeechWarmup()
        var warming = false, inner: FakeRecognition?
        warmup.onChange = { warming = $0 }
        let callbacks = RecognitionCallbacks(partial: { _ in }, error: { _ in }, done: { _ in })
        let rec = HealthCheckedRecognition(endpoint: "ws://speech/x", key: nil, callbacks: callbacks, warmup: warmup, probe: { _, _ in .unloaded }) {
            let fake = FakeRecognition($0, transcript: "words"); fake.silentEnd = true; inner = fake; return fake
        }
        rec.start(); rec.write(Data([1, 2])); rec.end()
        #expect(await rec.finalBudget(ordinary: 8) == 60)
        #expect(await waitUntil { inner?.ended == true })
        #expect(warming && inner?.written == 1 && inner?.ended == true)
        rec.cancel(); #expect(!warming && inner?.cancelled == true)
        var opened = false
        let stopped = HealthCheckedRecognition(endpoint: "ws://speech/x", key: nil, callbacks: callbacks, warmup: warmup, probe: { _, _ in
            try? await Task.sleep(nanoseconds: 10_000_000); return .loading
        }) { opened = true; return FakeRecognition($0, transcript: "") }
        stopped.start(); stopped.cancel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(!opened && !warming)
    }
    @Test(arguments: [SpeechModelState.loaded, .unknown]) func warmAndLegacyFinalsStayEightSeconds(_ state: SpeechModelState) async {
        let rec = HealthCheckedRecognition(endpoint: "ws://speech/x", key: nil,
            callbacks: .init(partial: { _ in }, error: { _ in }, done: { _ in }), warmup: SpeechWarmup(), probe: { _, _ in state }) {
                FakeRecognition($0, transcript: "")
            }
        rec.start(); #expect(await rec.finalBudget(ordinary: 8) == 8); rec.cancel()
    }
    @Test func coldSynthesisIndicatorEndsAtAudioAndWarmupTokensAreIndependent() async throws {
        let warmup = SpeechWarmup(); var warming = false, cold = false
        warmup.onChange = { warming = $0 }
        let synth = HealthCheckedSynthesizer(config: { VoiceConfig() }, warmup: warmup, probe: { _, _ in .loading }) { text, _, isCold in
            cold = isCold; return FakeTicket(text)
        }
        let ticket = synth.prepare("Hello")
        _ = try await ticket.audio()
        #expect(cold && !warming); ticket.cancel()
        let a = UUID(), b = UUID(); warmup.begin(a); warmup.begin(b); warmup.end(a)
        #expect(warming); warmup.end(b); #expect(!warming)
    }
    @Test func coldSynthesisDeadlineCancelsWorkAndClearsIndicator() async {
        let warmup = SpeechWarmup(), delayed = DelayedSpeechTicket()
        var warming = false
        warmup.onChange = { warming = $0 }
        let synth = HealthCheckedSynthesizer(config: { VoiceConfig() }, warmup: warmup, probe: { _, _ in .unloaded }, coldBudget: 0.02) { _, _, _ in delayed }
        let ticket = synth.prepare("cold")
        let began = Date()
        do { _ = try await ticket.audio(); Issue.record("Cold work should time out") }
        catch { #expect(error.localizedDescription.contains("did not warm up within 60 s")) }
        #expect(Date().timeIntervalSince(began) < 1 && delayed.cancelled && !warming)
        ticket.cancel()
    }
    @Test func recoveryClearsOnlyTheServiceThatActuallyRecovered() async throws {
        let rig = Rig(configure: { $0.asrUrl = "ws://speech:8446/v1/transcribe" })
        await rig.start(); defer { rig.controller.stop() }
        rig.input.frames(30, voiced: true)
        let rec = try #require(rig.recognitions.first)
        rec.callbacks.error(URLError(.cannotConnectToHost))
        #expect(rig.controller.status.lastError == "Speech service at speech:8446 isn't running")
        // The failed socket is retired; only a fresh utterance may establish recovery.
        rig.input.frames(60, voiced: false); rig.speak()
        #expect(await waitUntil { rig.controller.status.lastError == nil })
        rig.input.frames(60, voiced: false); rig.input.frames(30, voiced: true)
        let next = try #require(rig.recognitions.last)
        next.callbacks.error(URLError(.cannotConnectToHost))
        rig.reply(id: "recovery", one)
        #expect(await waitUntil { !rig.output.plays.isEmpty })
        #expect(rig.controller.status.lastError == "Speech service at speech:8446 isn't running")
        rig.input.frames(60, voiced: false); rig.speak()
        #expect(await waitUntil { rig.controller.status.lastError == nil })
    }
    @Test(arguments: [SpeechModelState.loaded, .unloaded])
    func delayedHealthDrainsPrerollWithRealSendBudgetAndPreservesEveryFrame(_ state: SpeechModelState) async throws {
        enum DrainResult: Equatable, Sendable { case drained, timedOut }
        let drain = AsyncStream<DrainResult>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // Separate fixture liveness bound, not a production recognition deadline.
        let liveness = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            drain.continuation.yield(.timedOut); drain.continuation.finish()
        }
        defer { liveness.cancel(); drain.continuation.finish() }
        var inner: BudgetEnforcedRecognition?, errors: [String] = [], finals: [String] = []
        let health = AsyncStream<SpeechModelState>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let rec = HealthCheckedRecognition(endpoint: "ws://speech/x", key: nil,
            callbacks: .init(partial: { _ in }, error: { errors.append($0.localizedDescription) }, done: { finals.append($0) }),
            warmup: SpeechWarmup(), probe: { _, _ in
                // A continuation gates health, not wall-clock scheduling. It
                // cannot open recognition before the entire backlog is queued.
                for await result in health.stream { return result }
                return .unknown
            }) {
                inner = BudgetEnforcedRecognition($0, releaseDelay: 0, onDrained: {
                    drain.continuation.yield(.drained); drain.continuation.finish()
                })
                return inner!
            }
        rec.start(); defer { health.continuation.finish(); rec.cancel() }
        let frames = (0..<130).map { Data(repeating: UInt8($0), count: 640) }
        for frame in frames.prefix(50) { rec.write(frame) } // retained one-second onset preroll
        var peakPending = rec.pendingBytes
        for frame in frames.dropFirst(50) {
            rec.write(frame); peakPending = max(peakPending, rec.pendingBytes)
        }
        rec.end()
        #expect(rec.pendingBytes == frames.count * 640 && inner == nil)
        health.continuation.yield(state); health.continuation.finish()
        var completed = drain.stream.makeAsyncIterator()
        let result = await completed.next()
        try #require(result == .drained, "fixture did not finish draining within its 30s liveness bound")
        let sent = try #require(inner)
        #expect(sent.ended && sent.outstanding == 0)
        #expect(peakPending > 100 * 640 && peakPending <= HealthCheckedRecognition.pendingByteLimit)
        #expect(sent.accepted == frames && sent.peakOutstanding == 1 && !sent.backlogFailure)
        #expect(errors.isEmpty && finals == ["complete utterance"])
        #expect(await rec.finalBudget(ordinary: 8) == (state.isCold ? 60 : 8))
    }
    @Test func stalledHealthStorageIsBoundedAndNeverSilentlyEvictsTheOnset() async {
        var opened = false, errors: [String] = [], finals: [String] = []
        let rec = HealthCheckedRecognition(endpoint: "ws://speech/x", key: nil,
            callbacks: .init(partial: { _ in }, error: { errors.append($0.localizedDescription) }, done: { finals.append($0) }),
            warmup: SpeechWarmup(), probe: { _, _ in try? await Task.sleep(nanoseconds: 50_000_000); return .loaded }) {
                opened = true; return FakeRecognition($0, transcript: "must not send a truncated utterance")
            }
        rec.start()
        for _ in 0..<HealthCheckedRecognition.pendingFrameLimit { rec.write(Data(count: 640)) }
        #expect(rec.pendingBytes == HealthCheckedRecognition.pendingByteLimit)
        rec.write(Data(count: 640))
        #expect(rec.pendingBytes == 0 && errors.count == 1 && errors[0].contains("audio backlog"))
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(!opened && finals == [""])
        rec.cancel()
    }
    @Test func cancellingDuringDrainCannotSendLaterFramesOrEndMarker() async throws {
        var inner: BudgetEnforcedRecognition?
        let rec = HealthCheckedRecognition(endpoint: "ws://speech/x", key: nil,
            callbacks: .init(partial: { _ in }, error: { _ in Issue.record("Cancelled drain reported a failure") }, done: { _ in }),
            warmup: SpeechWarmup(), probe: { _, _ in .loaded }) {
                inner = BudgetEnforcedRecognition($0); return inner!
            }
        rec.start()
        for _ in 0..<50 { rec.write(Data(count: 640)) }
        #expect(await rec.finalBudget(ordinary: 8) == 8)
        #expect(await waitUntil { inner?.accepted.isEmpty == false })
        let session = try #require(inner)
        rec.cancel()
        let count = session.accepted.count
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(session.accepted.count == count && session.cancelled && !session.ended && rec.pendingBytes == 0)
    }
    @Test func aggregateWarmupOnlyNotifiesOnTransitions() {
        let warmup = SpeechWarmup(), a = UUID(), b = UUID()
        var changes: [Bool] = []
        warmup.onChange = { changes.append($0) }
        warmup.begin(a); warmup.begin(a); warmup.begin(b); warmup.end(b); warmup.end(b)
        #expect(changes == [true])
        warmup.end(a); warmup.reset()
        #expect(changes == [true, false])
    }
    @Test(arguments: [false, true]) func firstWordsClearDisplayButRetainColdBudget(_ live: Bool) async {
        let warmup = SpeechWarmup(); var warming = false, inner: FakeRecognition?, words: [String] = []
        warmup.onChange = { warming = $0 }
        let rec = HealthCheckedRecognition(endpoint: "ws://speech/x", key: nil,
            callbacks: .init(partial: { words.append($0) }, error: { _ in }, done: { _ in }, live: { words.append($0) }),
            warmup: warmup, probe: { _, _ in .loading }) { inner = FakeRecognition($0, transcript: "final"); return inner! }
        rec.start(); #expect(await rec.finalBudget(ordinary: 8) == 60)
        #expect(warming && rec.isWarming)
        if live { inner?.callbacks.live("   ") } else { inner?.callbacks.partial("   ") }
        #expect(warming)
        if live { inner?.callbacks.live("first words") } else { inner?.callbacks.partial("first words") }
        #expect(!warming && !rec.isWarming && words.last == "first words")
        #expect(await rec.finalBudget(ordinary: 8) == 60)
        rec.cancel()
    }
    @Test func overlappingTTSWarmupCannotEraseFreshASRFailure() async throws {
        let warmup = SpeechWarmup(), tts = UUID(), anotherTTS = UUID()
        let backend = FakeBackend(), input = FakeInput()
        var settings = LoadedSettings(app: AppSettings(), voice: VoiceConfig(), voiceFile: nil,
            appFile: "/nonexistent", chiefFile: "/nonexistent")
        settings.app.target = "ses_A"; settings.voice.asrUrl = "ws://speech:8446/v1/transcribe"
        var inner: FakeRecognition?
        let controller = ConversationController(settings: settings, backend: backend, synth: FakeSynth(),
            output: FakeOutput(), input: input, makeRecognition: { cbs in
                HealthCheckedRecognition(endpoint: settings.voice.asrUrl, key: nil, callbacks: cbs,
                    warmup: warmup, probe: { _, _ in .unloaded }) {
                        inner = FakeRecognition($0, transcript: "recovered"); return inner!
                    }
            }, speechWarmup: warmup)
        await controller.start(); defer { controller.stop() }
        #expect(await waitUntil { controller.currentLease != nil && controller.status.phase == "ready" })
        warmup.begin(tts)
        input.frames(30, voiced: true)
        #expect(await waitUntil { inner != nil })
        inner?.callbacks.error(URLError(.cannotConnectToHost))
        let failure = "Speech service at speech:8446 isn't running"
        #expect(controller.status.lastError == failure && controller.status.warmingSpeech)
        warmup.begin(anotherTTS); warmup.end(anotherTTS)
        controller.setSpeechWarming(true) // Even a stale/duplicate display notification cannot clear errors.
        #expect(controller.status.lastError == failure)
        warmup.end(tts)
        #expect(controller.status.lastError == failure && !controller.status.warmingSpeech)
        // Only ASR words from a fresh recognition prove that ASR recovered.
        inner = nil; input.frames(60, voiced: false); input.frames(30, voiced: true)
        #expect(await waitUntil { inner != nil })
        inner?.callbacks.live("recovered words")
        #expect(controller.status.lastError == nil && !controller.status.warmingSpeech)
    }
    @Test func cancellationSchemaIsClosedAndRoundTrips() throws {
        let diagnostics = StageDiagnostics()
        for cause in [StreamCancellationCause.pathChange, .watchdog, .selection, .background, .explicit, .ownerChanged, .lifecycle, .consumer] {
            diagnostics.record(.events, .cancelled, status: -999, reason: .cancelled, cancellationCause: cause)
        }
        let entries = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(diagnostics.export().utf8))
        #expect(entries.count == 8 && entries.first?.cancellationCause == .pathChange)
        #expect(entries.allSatisfy { $0.status == -999 })
    }
}
