import Foundation
import CryptoKit
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct LongThoughtWireTests {
    /// Reviewed LiveReply fixture adapted to production Mac HTTP/SSE+health/WS adapters.
    @Test func sequentialRealWebSocketsAndHTTPPostOneJoinedThoughtWithExactPCM() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent("scripts/long-thought-fixture.mjs").path]
        process.standardOutput = pipe
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let port = try #require(Int(String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)))
        try #require(![8444, 8446, 8450].contains(port))
        let endpoint = "http://127.0.0.1:\(port)"
        let backend = OpenChamberClient(env: ["HOME": "/nonexistent", "FV_OPENCHAMBER_URL": endpoint])
        backend.sendPolicy = { target in
            guard target == "ses_fixture" else { throw ClientError("Fixture refuses real target") }
        }
        var app = AppSettings(); app.target = "ses_fixture"
        var voice = VoiceConfig(); voice.asrUrl = "ws://127.0.0.1:\(port)/transcribe"; voice.pauseMs = 3200
        let input = FakeInput(), warmup = SpeechWarmup()
        var sockets = 0
        let settings = LoadedSettings(app: app, voice: voice, voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent")
        let controller = ConversationController(settings: settings, backend: backend, synth: FakeSynth(), output: FakeOutput(), input: input,
            makeRecognition: { callbacks in
                HealthCheckedRecognition(endpoint: voice.asrUrl, key: nil, callbacks: callbacks, warmup: warmup, probe: { _, _ in .loaded }) { cbs in
                    sockets += 1
                    return WebSocketRecognition(url: voice.asrUrl, apiKey: nil, partials: true, callbacks: cbs)
                }
            })
        defer { controller.stop() }
        await controller.start()
        try #require(await waitUntil { controller.status.phase == "ready" && controller.status.connection == "connected" })
        input.frames(4508, voiced: true)
        try #require(await waitUntil(15) { sockets == 2 })
        input.frames(4500, voiced: true)
        try #require(await waitUntil(15) { sockets == 3 })
        input.frames(992, voiced: true); input.frames(160, voiced: false)
        try #require(await controller.waitForPosts(timeout: 15))
        // The transport may still be finalizing before Composer creates its post task.
        try #require(await waitUntil(15) { !controller.utteranceInProgress })
        try #require(await controller.waitForPosts(timeout: 15))
        let (bytes, _) = try await URLSession.shared.data(from: URL(string: endpoint + "/stats")!)
        let stats = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let posts = try #require(stats["posts"] as? [[String: Any]])
        #expect(posts.count == 1 && posts.first?["text"] as? String == "[voice] First segment second segment last segment.")
        let segments = try #require(stats["segments"] as? [[String: Any]])
        #expect(stats["maxActive"] as? Int == 1 && segments.count == 3)
        print("long-thought loopback: sockets=\(sockets) maxActive=\(stats["maxActive"] ?? -1) posts=\(posts.count)")
        let expected = [(4508, 0), (4500, 0), (992, 160)]
        for (segment, (voiced, silent)) in zip(segments, expected) {
            var hash = SHA256()
            for _ in 0..<voiced { hash.update(data: FakeInput.tone) }
            for _ in 0..<silent { hash.update(data: Data(count: 640)) }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            #expect(segment["frames"] as? Int == voiced + silent && segment["ended"] as? Bool == true)
            #expect(segment["digest"] as? String == digest)
            print("long-thought PCM frames=\(voiced + silent) SHA256=\(digest)")
        }
    }
}
