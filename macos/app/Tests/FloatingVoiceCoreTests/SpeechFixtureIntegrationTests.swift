import Foundation
import Testing
@testable import FloatingVoiceCore

/// Opt in with scripts/test-speech-fixtures.py. Real HTTP/WebSocket transports, fake audio and fake session
/// backend: no microphone, playback, app window, shared speech listener or real session prompt is possible.
@MainActor @Suite struct SpeechFixtureIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FV_FIXTURE_URL"] != nil))
    func coldRequestsCancellationAndListenerRecovery() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = try #require(env["FV_FIXTURE_URL"])
        let recovery = try #require(env["FV_FIXTURE_RECOVERY_URL"])
        for endpoint in [root, recovery] {
            let url = try #require(URL(string: endpoint))
            #expect(url.host == "127.0.0.1")
            guard url.host == "127.0.0.1", let port = url.port, ![8444, 8446, 8450].contains(port) else {
                Issue.record("Only isolated ephemeral loopback fixture ports are permitted"); return
            }
        }
        var config = VoiceConfig()
        config.ttsUrl = root + "/tts"; config.ttsStream = true
        config.asrUrl = root.replacingOccurrences(of: "http:", with: "ws:") + "/asr"
        config.pauseMs = 1000
        var app = AppSettings(); app.target = "ses_fixture_not_a_real_session"; app.sendMode = .manual
        let settings = LoadedSettings(app: app, voice: config, voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent")
        let warmup = SpeechWarmup(), backend = FakeBackend(), input = FakeInput(), output = FakeOutput(duration: 0)
        let synth = HealthCheckedSynthesizer(config: { config }, warmup: warmup)
        let controller = ConversationController(settings: settings, backend: backend, synth: synth, output: output, input: input,
                                                preflight: [ServiceChecks.speech(config, timeout: 0.03, warmup: warmup),
                                                            ServiceChecks.recognition(config, warmup: warmup)], speechWarmup: warmup)
        defer { controller.stop() }
        let pill = PillModel(); pill.attach(controller)
        controller.onStatus = { pill.update(status: $0) }
        let start = Task { await controller.start() }
        #expect(await waitUntil { controller.status.warmingSpeech })
        #expect(pill.stateLine == "Warming up speech…" && !pill.hasError && controller.status.notice == nil)
        await start.value
        #expect(controller.status.running && controller.status.phase == "ready" && controller.status.lastError == nil)
        #expect(!controller.status.warmingSpeech && output.plays.isEmpty) // Start test word is never played

        // Real WS101, binary PCM then end, delayed final and close1000. The ordinary 30 ms final limit would fail.
        controller.turnTaker?.finalTimeout = 0.03
        controller.setOutputMuted(true)
        input.frames(12, voiced: true)
        #expect(await waitUntil { controller.status.warmingSpeech })
        controller.setMicMuted(true) // preserve words already buffered, end and hold them in manual mode
        #expect(await waitUntil { controller.status.holding == "Fixture final words." })
        #expect(controller.status.micMuted && controller.status.outputMuted && controller.status.lastError == nil)
        #expect(!controller.status.warmingSpeech && backend.prompts.isEmpty)

        // Actual synthesis and audio delivery to a fake sink (no hardware output).
        controller.setOutputMuted(false)
        controller.speaker.enqueue("Fixture audio.")
        #expect(await waitUntil { controller.status.warmingSpeech })
        #expect(await waitUntil { !output.plays.isEmpty && !controller.speaker.active })
        #expect(!controller.status.warmingSpeech && controller.status.lastError == nil)
        let played = output.plays.count

        // Muting agent voice and Stop abort outstanding real cold HTTP requests without erasing held final words.
        controller.speaker.enqueue("Cancelled by mute.")
        #expect(await waitUntil { controller.status.warmingSpeech })
        controller.setOutputMuted(true)
        #expect(!controller.status.warmingSpeech && !controller.speaker.active)
        controller.setOutputMuted(false)
        controller.speaker.enqueue("Cancelled by Stop.")
        #expect(await waitUntil { controller.status.warmingSpeech })
        await controller.stopReply()
        #expect(!controller.status.warmingSpeech && !controller.speaker.active)
        #expect(controller.status.micMuted && controller.status.holding == "Fixture final words.")
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(output.plays.count == played && controller.status.lastError == nil && backend.prompts.isEmpty)

        // A genuinely refused loopback listener must retain exact wording, then recover at the same address.
        var unavailable = config
        unavailable.ttsUrl = recovery + "/tts"
        unavailable.asrUrl = recovery.replacingOccurrences(of: "http:", with: "ws:") + "/asr"
        let expected = "Speech service at \(try #require(URL(string: recovery)?.host)):\(try #require(URL(string: recovery)?.port)) isn't running"
        let recoveringSynth = HealthCheckedSynthesizer(config: { unavailable }, warmup: warmup)
        let failed = recoveringSynth.prepare("Listener refused.")
        do { _ = try await failed.audio(); Issue.record("Missing listener succeeded") }
        catch { #expect(error.localizedDescription == expected) }
        failed.cancel()
        var recognitionError = "", final = ""
        // Same normalization used by ConversationController.recognitionMessage for transport-level errors.
        let callbacks = RecognitionCallbacks(partial: { _ in }, error: {
            recognitionError = SpeechServiceError.describe(url: unavailable.asrUrl, error: $0)
        }, done: { final = $0 })
        func recognition() -> HealthCheckedRecognition {
            HealthCheckedRecognition(endpoint: unavailable.asrUrl, key: nil, callbacks: callbacks, warmup: warmup) {
                WebSocketRecognition(url: unavailable.asrUrl, apiKey: nil, callbacks: $0)
            }
        }
        let failedASR = recognition(); failedASR.start()
        #expect(await waitUntil(15) { !recognitionError.isEmpty })
        #expect(recognitionError == expected)
        failedASR.cancel()
        #expect(!controller.status.warmingSpeech)
        var recover = URLRequest(url: try #require(URL(string: root + "/recover")))
        recover.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: recover)
        let recovered = recoveringSynth.prepare("Listener recovered.")
        let audio = try await recovered.audio()
        var audioBytes = 0
        for try await chunk in audio.chunks { audioBytes += chunk.count }
        recovered.cancel()
        #expect(audioBytes == 640)
        recognitionError = ""
        let recoveredASR = recognition(); recoveredASR.start(); recoveredASR.write(Data(repeating: 1, count: 640)); recoveredASR.end()
        #expect(await waitUntil { final == "Fixture final words." })
        #expect(recognitionError.isEmpty && !controller.status.warmingSpeech)
        recoveredASR.cancel()
        // Discard with a real health-checked socket waiting on its delayed final. Neither the held
        // fragment nor that final can reappear; subsequent speech still goes through normally once.
        controller.discardPending()
        controller.setMicMuted(false)
        input.frames(12, voiced: true)
        #expect(await waitUntil { controller.status.warmingSpeech })
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.setMicMuted(true)
        #expect(controller.status.pendingSpeech)
        let interrupts = backend.interrupts.count, stops = output.stops
        controller.discardPending()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(!controller.status.pendingSpeech && controller.status.holding == nil && controller.status.micMuted)
        #expect(backend.prompts.isEmpty && backend.interrupts.count == interrupts && output.stops == stops)
        #expect(controller.status.lastError == nil && !controller.status.warmingSpeech)
        controller.setMicMuted(false)
        input.frames(12, voiced: true)
        controller.setMicMuted(true)
        #expect(await waitUntil { controller.status.holding == "Fixture final words." })
        controller.send()
        #expect(await waitUntil { backend.prompts.count == 1 })
        #expect(backend.prompts.first?.text == "[voice] Fixture final words.")
        // Stop voice also closes an actual in-flight ASR websocket; late callbacks cannot resurrect warm-up.
        controller.setMicMuted(false)
        input.frames(12, voiced: true)
        #expect(await waitUntil { controller.status.warmingSpeech })
        controller.stop()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(!controller.status.running && !controller.status.warmingSpeech && input.stopped)
        #expect(backend.prompts.count == 1)
    }
}
