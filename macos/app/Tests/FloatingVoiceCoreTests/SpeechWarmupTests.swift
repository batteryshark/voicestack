import Foundation
import Testing
@testable import FloatingVoiceCore

private final class DelayedSpeech: SpeechTicket {
    let text = "test"
    var cancelled = false
    var delay: UInt64 = 80_000_000
    var error: Error?
    var holdAudio = false
    var audioGate: CheckedContinuation<Void, Never>?
    func releaseAudio() { let gate = audioGate; audioGate = nil; gate?.resume() }
    func audio() async throws -> SpeechAudio {
        if holdAudio { await withCheckedContinuation { audioGate = $0 } }
        else { try await Task.sleep(nanoseconds: delay) }
        if let error { throw error }
        return .whole(Data([1, 2]), sampleRate: 24000)
    }
    func cancel() { cancelled = true }
}

private final class FakeHealthProtocol: URLProtocol {
    // Each case has a distinct hostname, so parallel tests never share mutable fixtures.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        if host == "refused" || host == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(host == "refused" ? .cannotConnectToHost : .timedOut)); return
        }
        let status = host == "bad" ? 502 : host == "legacy" ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"status\":\"ok\",\"model\":\"unloaded\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Suite struct SpeechWarmupTests {
    @Test func healthStatesAndLegacyIdentity() {
        for state in [SpeechModelState.loaded, .loading, .unloaded] {
            #expect(SpeechModelState.parse(["status": "ok", "model": state.rawValue]) == state)
        }
        #expect(SpeechModelState.parse(["model": "Breeze-TTS-2"]) == .loaded)
        #expect(SpeechModelState.parse([:]) == .unknown)
        #expect(!SpeechModelState.loaded.isCold)
    }

    @Test func nestedTTSHealthAndPartialsCapability() {
        #expect(SpeechModelState.parse(["model": "loaded", "upstream": ["model": "unloaded", "http_status": 200]]) == .unloaded)
        #expect(SpeechModelState.parse(["upstream": ["model": "loading"]]) == .loading)
        #expect(ServiceChecks.advertisesPartials(["model": "unloaded", "streaming_partials": true,
                                                "partials": ["enabled": true, "ready": false, "state": "unloaded"]]))
        #expect(ServiceChecks.healthURL("https://tts:8444/v1/audio/speech?x=y#z")?.absoluteString == "https://tts:8444/health")
    }

    @Test func networkFreeHealthProbePreservesOutageAnd502() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeHealthProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        #expect(try await SpeechHealth.inspect("http://good:8444/v1/audio/speech", nil, session: session) == .unloaded)
        #expect(try await SpeechHealth.inspect("http://legacy/x", nil, session: session) == .unknown)
        #expect(try await SpeechHealth.inspect("http://timeout/x", nil, session: session) == .unknown)
        do {
            _ = try await SpeechHealth.inspect("http://refused:8450/x", nil, session: session)
            Issue.record("Refused listener succeeded")
        } catch { #expect(error.localizedDescription == "Speech service at refused:8450 isn't running") }
        do {
            _ = try await SpeechHealth.inspect("http://bad:8444/x", nil, session: session)
            Issue.record("502 succeeded")
        } catch { #expect(error.localizedDescription.contains("502")) }
    }

    @Test func coldSpeechSuccessAndRecoveryWithCalmPill() async throws {
        let rig = Rig()
        let warmup = rig.controller.speechWarmup
        let pill = PillModel()
        rig.controller.onStatus = { pill.update(status: $0) }
        await rig.start()
        var probes = 0, requests = 0
        let inner = DelayedSpeech()
        let synth = HealthCheckedSynthesizer(config: { rig.controller.voice }, warmup: warmup,
                                            probe: { _, _ in probes += 1; return .unloaded },
                                            make: { _, _, cold in requests += 1; #expect(cold); return inner })
        #expect(probes == 0 && requests == 0) // construction/idle never loads anything
        let ticket = synth.prepare("test")
        #expect(await waitUntil { pill.status.warmingSpeech })
        #expect(pill.stateLine == "Warming up speech…")
        #expect(pill.expanded && !pill.hasError && pill.status.notice == nil)
        let audio = try await ticket.audio()
        var bytes = Data()
        for try await chunk in audio.chunks { bytes.append(chunk) }
        #expect(bytes == Data([1, 2]))
        #expect(!pill.status.warmingSpeech)
        #expect(probes == 1 && requests == 1)
        rig.controller.stop()
    }

    @Test func warmSpeechDoesNotWarmOrExtend() async throws {
        var warming = false, sawCold = true
        let warmup = SpeechWarmup(); warmup.onChange = { warming = $0 }
        let synth = HealthCheckedSynthesizer(config: { VoiceConfig() }, warmup: warmup,
                                            probe: { _, _ in .loaded }, make: { _, _, cold in sawCold = cold; return FakeTicket("warm") })
        _ = try await synth.prepare("warm").audio()
        #expect(!warming && !sawCold)
    }

    @Test func coldSpeechTimeoutIsRetryableAndNotRetried() async {
        var warming = false, count = 0
        let warmup = SpeechWarmup(); warmup.onChange = { warming = $0 }
        let inner = DelayedSpeech(); inner.delay = 2_000_000_000
        let synth = HealthCheckedSynthesizer(config: { VoiceConfig() }, warmup: warmup, probe: { _, _ in .loading },
                                            coldBudget: 0.02, make: { _, _, _ in count += 1; return inner })
        do { _ = try await synth.prepare("test").audio(); Issue.record("No timeout") }
        catch { #expect(error.localizedDescription.contains("did not warm up within 60 s. Try again.")) }
        #expect(count == 1 && inner.cancelled && !warming)
    }

    @Test func cancelBeforeProbeCompletesDoesNotRequestOrResurrect() async {
        var warming = false, requests = 0
        let warmup = SpeechWarmup(); warmup.onChange = { warming = $0 }
        let synth = HealthCheckedSynthesizer(config: { VoiceConfig() }, warmup: warmup,
                                            probe: { _, _ in try? await Task.sleep(nanoseconds: 40_000_000); return .unloaded },
                                            make: { _, _, _ in requests += 1; return FakeTicket("bad") })
        let ticket = synth.prepare("test"); ticket.cancel()
        do { _ = try await ticket.audio(); Issue.record("Cancelled request succeeded") } catch {}
        #expect(requests == 0 && !warming)
    }

    @Test func stopCancelsColdPrefetchAndClearsWarmup() async {
        let rig = Rig(); await rig.start()
        let inner = DelayedSpeech(); inner.delay = 2_000_000_000
        let synth = HealthCheckedSynthesizer(config: { VoiceConfig() }, warmup: rig.controller.speechWarmup,
                                            probe: { _, _ in .unloaded }, make: { _, _, _ in inner })
        let speaker = Speaker(synth: synth, output: rig.output, onError: { _ in Issue.record("Cancel showed error") })
        speaker.enqueue("test")
        #expect(await waitUntil { rig.controller.status.warmingSpeech })
        speaker.stop()
        #expect(!rig.controller.status.warmingSpeech && inner.cancelled)
        rig.controller.stop()
    }

    @Test func coldFailureClearsAndNextRequestRecoversWithoutReplay() async throws {
        var warming = false, count = 0
        let warmup = SpeechWarmup(); warmup.onChange = { warming = $0 }
        let synth = HealthCheckedSynthesizer(config: { VoiceConfig() }, warmup: warmup, probe: { _, _ in .loading },
                                            make: { _, _, _ in
            count += 1
            return FakeTicket("test", error: count == 1 ? ClientError("Speech service at localhost:8444 returned 502: worker failed") : nil)
        })
        do { _ = try await synth.prepare("first").audio(); Issue.record("502 succeeded") }
        catch { #expect(error.localizedDescription.contains("502")) }
        #expect(count == 1 && !warming)
        _ = try await synth.prepare("second").audio()
        #expect(count == 2 && !warming)
    }

    @Test func coldRecognitionBuffersAudioAndEndThenFinalClearsWarmup() async {
        let warmup = SpeechWarmup()
        var warming = false, result = "", inner: FakeRecognition?
        warmup.onChange = { warming = $0 }
        let cbs = RecognitionCallbacks(partial: { _ in }, error: { _ in Issue.record("Unexpected ASR error") }, done: { result = $0 })
        let recognition = HealthCheckedRecognition(endpoint: "ws://fake:8446/v1/transcribe", key: nil, callbacks: cbs, warmup: warmup,
                                                   probe: { _, _ in try await Task.sleep(nanoseconds: 20_000_000); return .unloaded }) {
            let r = FakeRecognition($0, transcript: "Final words."); inner = r; return r
        }
        recognition.start(); recognition.write(Data([1])); recognition.write(Data([2])); recognition.end()
        #expect(inner == nil)
        #expect(await recognition.finalBudget(ordinary: 8) == 60)
        #expect(await waitUntil { result == "Final words." })
        #expect(inner?.written == 2 && inner?.ended == true && !warming)
    }

    @Test func warmRecognitionBudgetStaysEightAndCancelKeepsWordsSafe() async {
        let warmup = SpeechWarmup()
        let cbs = RecognitionCallbacks(partial: { _ in }, error: { _ in }, done: { _ in })
        for state in [SpeechModelState.loaded, .unknown, .loading] {
            var inner: FakeRecognition?
            let recognition = HealthCheckedRecognition(endpoint: "ws://fake", key: nil, callbacks: cbs, warmup: warmup,
                                                       probe: { _, _ in state }) {
                let r = FakeRecognition($0, transcript: ""); r.silentEnd = true; inner = r; return r
            }
            recognition.start()
            #expect(await recognition.finalBudget(ordinary: 8) == (state.isCold ? 60 : 8))
            recognition.cancel()
            #expect(inner?.cancelled == true)
        }
        let taker = TurnTaker(config: VoiceConfig(), callbacks: TurnCallbacks(), makeRecognition: { FakeRecognition($0, transcript: "") })
        #expect(taker.finalTimeout == 8)
    }

    @Test func recognitionProbeOutageNeverStartsSpeech() async {
        var started = false, message = ""
        let cbs = RecognitionCallbacks(partial: { _ in }, error: { message = $0.localizedDescription }, done: { _ in })
        let recognition = HealthCheckedRecognition(endpoint: "ws://fake:8446", key: nil, callbacks: cbs, warmup: SpeechWarmup(),
                                                   probe: { url, _ in throw ClientError(SpeechServiceError.notRunning(url)) }) { cbs in
            started = true; return FakeRecognition(cbs, transcript: "")
        }
        recognition.start()
        #expect(await waitUntil { !message.isEmpty })
        #expect(message == "Speech service at fake:8446 isn't running" && !started)
    }

    @Test func coldPreflightUsesOrdinaryRequestAndWaitsForAudio() async throws {
        var requests = 0, warming = false
        var config = VoiceConfig(); config.ttsUrl = "http://fake:8444/v1/audio/speech"
        let warmup = SpeechWarmup(); warmup.onChange = { warming = $0 }
        let inner = DelayedSpeech()
        inner.holdAudio = true
        defer { inner.releaseAudio() }
        let check = ServiceChecks.speech(config, timeout: 0.001, warmup: warmup, probe: { _, _ in .unloaded }, make: { text, _, cold in
            #expect(text == "Ready." && cold); requests += 1; return inner
        })
        let work = Task { try await check.run() }
        try #require(await waitUntil { warming && inner.audioGate != nil })
        inner.releaseAudio()
        try await work.value
        #expect(await waitUntil { !warming })
        #expect(requests == 1 && inner.cancelled)
    }

    @Test func coldFinalWatchActuallyTimesOutAndClearsWarmup() async {
        var message = "", warming = false, inner: FakeRecognition?
        let warmup = SpeechWarmup(); warmup.onChange = { warming = $0 }
        var callbacks = TurnCallbacks(); callbacks.error = { message = $0.localizedDescription }
        let taker = TurnTaker(config: VoiceConfig(), callbacks: callbacks) { cbs in
            HealthCheckedRecognition(endpoint: "ws://fake", key: nil, callbacks: cbs, warmup: warmup,
                                     probe: { _, _ in .loading }, coldBudget: 0.05) {
                let r = FakeRecognition($0, transcript: ""); r.silentEnd = true; inner = r; return r
            }
        }
        taker.finalTimeout = 0.001 // known cold must not use this ordinary budget
        taker.push(Data(repeating: 0, count: 640 * 50))
        for _ in 0..<12 { taker.push(FakeInput.tone) }
        #expect(await waitUntil { warming })
        taker.endNow()
        #expect(await waitUntil { !message.isEmpty })
        #expect(message.contains("No final transcript") && inner?.cancelled == true && !warming)
        #expect(!taker.inUtterance)
        taker.stop()
    }

    @Test func coldModelDoesNotMistakeBufferedWordsForNoise() async {
        let warmup = SpeechWarmup()
        var inner: FakeRecognition?
        let taker = TurnTaker(config: VoiceConfig(), callbacks: TurnCallbacks()) { cbs in
            HealthCheckedRecognition(endpoint: "ws://fake", key: nil, callbacks: cbs, warmup: warmup,
                                     probe: { _, _ in .unloaded }) {
                let r = FakeRecognition($0, transcript: "Kept words"); r.silentEnd = true; inner = r; return r
            }
        }
        taker.expectLiveWords = true
        for _ in 0..<12 { taker.push(FakeInput.tone) }
        #expect(await waitUntil { inner != nil })
        for _ in 0..<300 { taker.push(FakeInput.tone) } // >5 s with no partial during model loading
        #expect(taker.inUtterance && inner?.cancelled == false)
        taker.stop()
    }

    @Test func stopDuringColdStartPreflightCannotSetReadyLater() async {
        let rig = Rig(preflight: [PreflightCheck(name: "pending cold", run: {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        })])
        let start = Task { await rig.controller.start() }
        #expect(await waitUntil { rig.controller.status.running })
        let id = UUID(); rig.controller.speechWarmup.begin(id)
        #expect(rig.controller.status.warmingSpeech)
        rig.controller.stop()
        await start.value
        #expect(!rig.controller.status.running && !rig.controller.status.warmingSpeech)
        #expect(rig.controller.status.phase != "ready")
    }

    @Test func abnormalASRCloseIsAnErrorNotASuccess() {
        var message = "", completions = 0
        let cbs = RecognitionCallbacks(partial: { _ in }, error: { message = $0.localizedDescription }, done: { _ in completions += 1 })
        let recognition = WebSocketRecognition(url: "ws://fake", apiKey: nil, callbacks: cbs)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: URL(string: "ws://fake")!) // never resumed: no network
        recognition.urlSession(session, webSocketTask: task, didCloseWith: .internalServerError, reason: nil)
        #expect(message.contains("1011") && message.contains("Try again") && completions == 1)
    }

    @Test func overlappingWarmupsNeverEraseANewGenuineFailure() async {
        let rig = Rig(); await rig.start()
        let first = UUID(), second = UUID()
        rig.controller.speechWarmup.begin(first)
        let message = "Speech service at fake:8444 returned 502: worker failed"
        rig.controller.speechServiceFailed(ClientError(message))
        rig.controller.speechWarmup.begin(second)
        rig.controller.speechWarmup.end(first)
        #expect(rig.controller.status.warmingSpeech)
        #expect(rig.controller.status.lastError == message)
        rig.controller.speechWarmup.end(second)
        #expect(!rig.controller.status.warmingSpeech && rig.controller.status.lastError == message)
        rig.controller.stop()
    }
}
