import Foundation
import AVFoundation
import Testing
@testable import FloatingVoiceCore
@testable import FloatingVoiceAudio
import FloatingVoiceUI

@Suite(.serialized) @MainActor struct RestartStopTests {
    /// A player-node meter is not proof of audible downstream output. This is a
    /// controlled counterexample, NOT a claim that the principal's mixer was muted.
    @Test func playerTapCanMoveWhileNativeDownstreamOutputIsSilent() async throws {
        final class Meter: @unchecked Sendable {
            let lock = NSLock()
            var peak: Float = 0
            func record(_ value: Float) { lock.withLock { peak = max(peak, value) } }
            var value: Float { lock.withLock { peak } }
        }
        let meter = Meter(), engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        player.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            if let samples = buffer.floatChannelData, buffer.frameLength > 0 { meter.record(abs(samples[0][0])) }
        }
        defer { player.removeTap(onBus: 0); engine.stop() }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 2400)
        engine.mainMixerNode.outputVolume = 0
        try engine.start()
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600)!
        pcm.frameLength = 9600
        for i in 0..<9600 { pcm.floatChannelData![0][i] = 0.25 }
        player.scheduleBuffer(pcm, completionHandler: nil); player.play(at: AVAudioTime(sampleTime: 0, atRate: 48000))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        for _ in 0..<3 {
            #expect(try engine.renderOffline(2400, to: buffer) == .success)
            #expect((0..<2400).allSatisfy { buffer.floatChannelData![0][$0] == 0 })
        }
        #expect(await waitUntil { meter.value == 0.25 })
    }

    @Test func productionReconnectPreservesNativePCMAndStopWorksWithFailedInterrupt() async throws {
        let dir = tempDir()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), stdout = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent("scripts/reconnect-fixture.mjs").path, dir + "/settings.json"]
        process.standardOutput = stdout; process.standardInput = stdin
        try process.run()
        defer { try? stdin.fileHandleForWriting.close(); process.waitUntilExit() }
        let port = try #require(Int(String(decoding: stdout.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        try #require(![8444, 8446, 8450].contains(port))
        let admin = "http://127.0.0.1:\(port)"
        func request(_ path: String) async throws -> [String: Any] {
            let (data, response) = try await URLSession.shared.data(from: URL(string: admin + path)!)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        let backend = OpenChamberClient(env: ["HOME":"/nonexistent", "OPENCHAMBER_DATA_DIR":dir])
        backend.sendPolicy = { guard $0 == "ses_fixture" else { throw ClientError("Not fixture") } }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        try engine.start(); defer { engine.stop() }
        let output = MacAudio(offlineEngine: engine, player: player)
        // MacAudio's normal startup starts its player; the injected offline graph does not.
        player.play(at: AVAudioTime(sampleTime: 0, atRate: 48000))
        var app = AppSettings(); app.target = "ses_fixture"; app.sendMode = .manual
        var voice = VoiceConfig(); voice.ttsUrl = admin + "/v1/audio/speech"; voice.ttsStream = true
        let input = FakeInput()
        let settings = LoadedSettings(app: app, voice: voice, voiceFile: nil, appFile:"/nonexistent", chiefFile:"/nonexistent")
        var diagnosticTime = 0.0, diagnosticLines: [String] = [], normalStopLogs = 0
        let diagnostics = AudioLifecycleDiagnostics(now: { diagnosticTime }, write: { diagnosticLines.append($0) })
        diagnostics.beginVoiceRun()
        var observe: ((AudioLifecycleDiagnostics.Stage) -> Void)?
        let controller = ConversationController(settings: settings, backend: backend, synth: HTTPSpeechSynthesizer(config: { voice }), output: output, input: input,
            makeRecognition: { FakeRecognition($0, transcript:"Retain my unsent words.") }, reconnectDelay: 0.05, log: { line in
                diagnosticTime += 0.25
                if line.hasPrefix("playback silenced (stop control)") { normalStopLogs += 1 }
                if let stage = AudioLifecycleDiagnostics.stage(for: line) { observe?(stage) }
            })
        observe = { [weak controller] stage in
            guard let controller else { return }
            diagnostics.record(stage, audio: output, active: controller.speaker.active, busy: controller.status.busy, queued: controller.speaker.queuedCount)
        }
        defer { controller.stop() }
        await controller.start()
        try #require(await waitUntil { controller.status.connection == "connected" })
        input.frames(40, voiced: true); input.frames(200, voiced: false)
        try #require(await waitUntil { controller.status.holding != nil })
        _ = try await request("/reply")
        var starts = 0
        controller.speaker.onSentence = { _, _ in starts += 1 }
        try #require(await waitUntil { starts == 1 })
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
        func render(_ value: Float) throws {
            #expect(try engine.renderOffline(240, to: buffer) == .success)
            #expect((0..<240).allSatisfy { abs(buffer.floatChannelData![0][$0] - value) < 0.000001 })
        }
        try render(0.25)
        _ = try await request("/restart")
        try #require(await waitUntil(5) { controller.status.connection == "connected" && controller.status.lastError == nil })
        // No graph reset on transport failure: the SAME partial source remains exact.
        try render(0.25)
        #expect(input.starts == 1 && input.stops == 0)
        #expect(controller.status.holding == "Retain my unsent words.")
        // Pause/duck state and remaining scheduled audio must be cleared before failed interrupt returns.
        controller.speaker.duckForAutomaticCutIn(true)
        #expect(controller.speaker.commitAutomaticCutIn())
        var actions = PillActions()
        var stopTask: Task<Void, Never>?
        actions.stopReply = { observe?(.stopEntry); stopTask = Task { await controller.stopReply() } }
        actions.stopReply()
        await stopTask?.value
        #expect(!controller.speaker.active && controller.speaker.queuedCount == 0)
        try render(0)
        #expect(controller.status.running && controller.status.lastError?.hasPrefix("Stop:") == true)
        #expect(controller.status.holding == "Retain my unsent words.")
        let stats = try await request("/stats")
        #expect(stats["interrupts"] as? Int == 1)
        #expect((stats["posts"] as? [Any])?.isEmpty == true) // no end note or implicit Send
        #expect(stats["speech"] as? [String] == ["Synthetic reply."])
        #expect(stats["connects"] as? Int == 2)
        #expect(starts == 1) // no narration replay after reconnect
        // Also cancel real HTTP synthesis while waiting for headers, and while
        // streaming PCM. Neither local stop depends on server busy/interrupt success.
        for (path, expectedStarts) in [("/reply-pending", 1), ("/reply-stream", 2)] {
            _ = try await request(path)
            try #require(await waitUntil { controller.speaker.active && controller.speaker.queuedCount > 0 })
            var fetched: [String] = []
            for _ in 0..<100 {
                fetched = (try await request("/stats"))["speech"] as? [String] ?? []
                if fetched.contains(where: { $0.hasPrefix(path == "/reply-pending" ? "Pending headers" : "Streaming audio") }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(fetched.contains(where: { $0.hasPrefix(path == "/reply-pending" ? "Pending headers" : "Streaming audio") }))
            if path == "/reply-stream" {
                try #require(await waitUntil { starts == expectedStarts })
                try render(0.25)
            }
            actions.stopReply(); await stopTask?.value
            try #require(await waitUntil { !controller.speaker.active })
            try render(0)
            #expect(starts == expectedStarts)
        }
        let stopped = try await request("/stats")
        #expect(stopped["interrupts"] as? Int == 3)
        #expect(stopped["cancelledSpeech"] as? Int == 2)
        #expect(input.starts == 1 && input.stops == 0 && controller.status.running)
        #expect(controller.status.holding == "Retain my unsent words.")
        // Same exact lifecycle admission contract, once, no normal prompt.
        controller.endVoice()
        #expect(await controller.waitForPosts(timeout: 2))
        let final = try await request("/stats")
        let posts = try #require(final["posts"] as? [[String:Any]])
        #expect(posts.count == 1 && posts[0]["text"] as? String == "[voice] ended" && posts[0]["resume"] as? Bool == false)
        #expect(normalStopLogs == 3) // ordinary Stop evidence is not throttled
        #expect(!diagnosticLines.isEmpty && diagnosticLines.count <= 120)
        #expect(diagnosticLines.allSatisfy { $0.hasPrefix("audio_diag stage=") && !$0.contains("ses_fixture") && !$0.contains("Synthetic") && !$0.contains("127.0.0.1") })
    }
}
