import Foundation
import AVFoundation
import Testing
@testable import FloatingVoiceCore
@testable import FloatingVoiceAudio
import FloatingVoiceUI

/// Replaces only hardware startup with a manual graph; all playback is real MacAudio.
@MainActor private final class OfflineVoiceGraph: AudioInput, AutomaticCutInOutput {
    @MainActor final class Graph {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let audio: MacAudio
        init() throws {
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
            try engine.start()
            audio = MacAudio(offlineEngine: engine, player: player)
            player.play(at: AVAudioTime(sampleTime: 0, atRate: 48000))
        }
        func render(tag: Int?, offset: Int = 0, frames: Int = 240) throws {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
            let before = engine.manualRenderingSampleTime
            for start in stride(from: 0, to: frames, by: 240) {
                let count = min(240, frames - start)
                #expect(try engine.renderOffline(AVAudioFrameCount(count), to: buffer) == .success)
                for i in 0..<count {
                    let expected = tag.map { Float($0 * 2048 + (offset + start + i) % 1024) / 32768 } ?? 0
                    #expect(abs(buffer.floatChannelData![0][i] - expected) < 0.0000001)
                }
            }
            #expect(engine.manualRenderingSampleTime == before + Int64(frames))
        }
    }
    let input = FakeInput()
    var graphs: [Graph] = []
    var graph: Graph { graphs.last! }
    var onPCM: ((Data) -> Void)? { get { input.onPCM } set { input.onPCM = newValue } }
    var onFailure: ((Error) -> Void)? { get { input.onFailure } set { input.onFailure = newValue } }
    var duplexSafe: Bool { true }
    func start() async throws { graphs.append(try Graph()); try await input.start() }
    func stop() { input.stop(); graphs.last?.audio.stop() }
    func play(_ audio: SpeechAudio, label: String, onStart: @escaping () -> Void) async throws {
        try await graph.audio.play(audio, label: label, onStart: onStart)
    }
    func stopPlayback() { graphs.last?.audio.stopPlayback() }
    func setCutInGain(_ gain: Float) { graph.audio.setCutInGain(gain) }
    func pauseForAutomaticCutIn() -> Bool { graph.audio.pauseForAutomaticCutIn() }
    func resumeAfterAutomaticCutIn() throws { try graph.audio.resumeAfterAutomaticCutIn() }
}

@Suite(.serialized) @MainActor struct FirstReplyReconnectTests {
    private func field(_ object: Any, _ name: String) -> Any {
        Mirror(reflecting: object).children.first { $0.label == name }!.value
    }
    private func absent(_ object: Any, _ name: String) -> Bool {
        let mirror = Mirror(reflecting: field(object, name))
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }
    private func idle(_ speaker: Speaker) -> Bool {
        !speaker.active && !speaker.playing && speaker.queuedCount == 0 && absent(speaker, "pump") && absent(speaker, "current")
    }
    private func unpaused(_ speaker: Speaker) -> Bool {
        field(speaker, "paused") as? Bool == false && field(speaker, "automaticCutInPaused") as? Bool == false
    }

    @Test(arguments: ["error", "false", "true"])
    func firstNewReplyAfterReconnectAndFullVoiceRestart(interruptMode: String) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = tempDir(), process = Process(), stdout = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent("scripts/reconnect-fixture.mjs").path, dir + "/settings.json"]
        process.standardOutput = stdout; process.standardInput = stdin
        try process.run()
        defer { try? stdin.fileHandleForWriting.close(); process.waitUntilExit() }
        let port = try #require(Int(String(decoding: stdout.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        try #require(![8444, 8446, 8450].contains(port))
        let base = "http://127.0.0.1:\(port)"
        func request(_ path: String) async throws -> [String: Any] {
            var req = URLRequest(url: URL(string: base + path)!); req.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: req)
            try #require((response as? HTTPURLResponse)?.statusCode == 200)
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func statsUntil(_ predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
            for _ in 0..<100 {
                let stats = try await request("/stats")
                if predicate(stats) { return stats }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ClientError("Fixture stats deadline")
        }
        _ = try await request("/interrupt-mode/" + interruptMode)
        let backend = OpenChamberClient(env: ["HOME":"/nonexistent", "OPENCHAMBER_DATA_DIR":dir])
        backend.sendPolicy = { guard $0 == "ses_fixture" else { throw ClientError("Not fixture") } }
        var app = AppSettings(); app.target = "ses_fixture"; app.sendMode = .manual
        var voice = VoiceConfig(); voice.ttsUrl = base + "/v1/audio/speech"; voice.ttsStream = true
        let io = OfflineVoiceGraph()
        let settings = LoadedSettings(app: app, voice: voice, voiceFile:nil, appFile:"/nonexistent", chiefFile:"/nonexistent")
        var resyncs = 0, starts: [String] = []
        let controller = ConversationController(settings: settings, backend: backend, synth: HTTPSpeechSynthesizer(config: { voice }), output: io, input: io,
            makeRecognition: { FakeRecognition($0, transcript:"Keep this manual thought.") }, reconnectDelay:0.05,
            log: { if $0.hasPrefix("resync (connected):") { resyncs += 1 } })
        defer { controller.stop() }
        controller.speaker.onSentence = { label, _ in starts.append(label) }
        await controller.start()
        try #require(await waitUntil { resyncs == 1 && controller.status.connection == "connected" })
        io.input.frames(40, voiced:true); io.input.frames(200, voiced:false)
        try #require(await waitUntil { controller.status.holding == "Keep this manual thought." })
        // Begin already idle: manual-render .dataPlayedBack completion is NOT
        // supplied/faked, forced via Stop, or treated as a real-device defect.
        try #require(idle(controller.speaker) && unpaused(controller.speaker))
        #expect(Mirror(reflecting: field(controller, "blocks")).children.isEmpty)
        let initial = try await request("/stats")
        #expect((initial["speech"] as? [String])?.isEmpty == true && starts.isEmpty)
        let graphBefore = io.graph, epochBefore = controller.speaker.epoch
        let originalPort = try #require((SettingsStore.readJSON(dir + "/settings.json")?["desktopLocalPort"] as? NSNumber)?.intValue)
        let restarted = try await request("/restart")
        #expect(restarted["port"] as? Int != originalPort)
        try #require(await waitUntil(5) { resyncs == 2 && controller.status.connection == "connected" })
        #expect(!controller.status.busy && idle(controller.speaker) && unpaused(controller.speaker))
        #expect(io.graph === graphBefore && controller.speaker.epoch == epochBefore)
        #expect(io.graph.player.volume == 1 && io.graph.engine.mainMixerNode.outputVolume == 1)
        #expect(Mirror(reflecting: field(controller, "blocks")).children.isEmpty)
        #expect(controller.status.holding == "Keep this manual thought.")
        let reconnected = try await request("/stats")
        #expect((reconnected["speech"] as? [String])?.isEmpty == true && starts.isEmpty)
        // FIRST NEW reply after readiness/resync: new block, new request, tagged nonconstant PCM.
        _ = try await request("/tagged/fresh")
        try #require(await waitUntil { starts.count == 1 })
        let active = try await statsUntil { Set($0["taggedActive"] as? [String] ?? []) == Set(["fresh", "pending"]) }
        #expect(active["connects"] as? Int == 2 && active["maxPeers"] as? Int == 1)
        #expect(unpaused(controller.speaker) && controller.speaker.queuedCount == 1)
        #expect(!absent(controller.speaker, "pump"))
        #expect(io.graph.audio.diagnosticSnapshot().contains("paused=false graph=current engine=true player=true gain=unity mixer=unity"))
        try io.graph.render(tag:2, frames:2400) // every sample and exact manual-render position
        let generation = try #require(field(io.graph.audio, "generation") as? Int)
        var actions = PillActions(), stopTask: Task<Void, Never>?
        actions.stopReply = { stopTask = Task { await controller.stopReply() } }
        actions.stopReply(); await stopTask?.value // direct wiring, NOT mounted SwiftUI
        try #require(await waitUntil { idle(controller.speaker) })
        #expect(unpaused(controller.speaker) && controller.speaker.epoch > epochBefore)
        #expect(field(io.graph.audio, "generation") as? Int == generation + 1)
        #expect(io.graph.player.volume == 1)
        #expect(field(io.graph.audio, "automaticCutInPaused") as? Bool == false)
        #expect(Mirror(reflecting: field(io.graph.audio, "producerWaiters")).children.isEmpty)
        #expect(Mirror(reflecting: field(io.graph.audio, "waiters")).children.isEmpty)
        try io.graph.render(tag:nil, frames:960)
        #expect(controller.status.running && controller.status.holding == "Keep this manual thought.")
        let stopped = try await statsUntil { ($0["taggedActive"] as? [String])?.isEmpty == true }
        #expect(Set(stopped["taggedCancelled"] as? [String] ?? []) == Set(["fresh", "pending"]))
        #expect((stopped["posts"] as? [Any])?.isEmpty == true && stopped["interrupts"] as? Int == 1)
        #expect(starts == ["tagged_fresh:0"])
        // Settings' full Stop voice / Start voice, not keepHeld device restart.
        controller.endVoice()
        #expect(await controller.waitForPosts(timeout:2))
        _ = try await statsUntil { $0["peers"] as? Int == 0 }
        #expect(!graphBefore.engine.isRunning && !graphBefore.engine.attachedNodes.contains(graphBefore.player))
        #expect(io.input.stops == 1 && controller.status.holding == nil) // deliberate manual Stop discards
        await controller.start()
        try #require(await waitUntil { resyncs == 3 && controller.status.connection == "connected" })
        #expect(io.graph !== graphBefore && io.graph.engine !== graphBefore.engine && io.graph.audio !== graphBefore.audio)
        #expect(io.input.starts == 2 && idle(controller.speaker) && unpaused(controller.speaker))
        #expect(field(io.graph.audio, "generation") as? Int == 0)
        #expect(io.graph.player.volume == 1 && io.graph.engine.mainMixerNode.outputVolume == 1)
        #expect(Mirror(reflecting: field(controller, "blocks")).children.isEmpty)
        _ = try await request("/tagged/rebuilt")
        try #require(await waitUntil { starts.count == 2 })
        try io.graph.render(tag:3, frames:960)
        // Exact finite source is rendered; natural .dataPlayedBack drain remains
        // outside this offline seam. Normal deferred teardown stops it explicitly.
        let final = try await request("/stats")
        #expect(final["connects"] as? Int == 3 && final["maxPeers"] as? Int == 1 && final["peers"] as? Int == 1)
        #expect(final["activeReads"] as? Int == 3)
        #expect(final["speech"] as? [String] == ["Tagged fresh reply begins after the fixture restart.", "Pending tagged prefetch must never play after Stop.", "Tagged rebuilt graph reply has a distinct sample ramp."])
        #expect(starts == ["tagged_fresh:0", "tagged_rebuilt:0"])
        let posts = try #require(final["posts"] as? [[String: Any]])
        #expect(posts.count == 1 && posts[0]["text"] as? String == "[voice] ended" && posts[0]["resume"] as? Bool == false)
        print("first-new-reply mode=\(interruptMode): initially idle, exact native samples fresh=2400 rebuilt=960, SSE=3 max=1 TTS=3, Stop cancelled stream+prefetch")
    }
}
