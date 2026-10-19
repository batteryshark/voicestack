import AVFoundation
import Foundation
import Testing
@testable import FloatingVoiceAudio

@Suite(.serialized) @MainActor struct AudioLifecycleDiagnosticTests {
    @Test func cadenceBudgetAndDisabledGraphRead() {
        let audio = MacAudio(config: { .init() })
        var clock = 0.0, lines: [String] = []
        let diag = AudioLifecycleDiagnostics(now: { clock }, write: { lines.append($0) })
        func emit() { diag.record(.disconnected, audio: audio, active: false, busy: true, queued: 1000) }
        emit(); #expect(lines.isEmpty) // disabled until explicit Start
        diag.beginVoiceRun()
        for _ in 0..<200 { emit() }
        #expect(lines.count == 1)
        clock = 0.999; emit(); #expect(lines.count == 1)
        clock = 1; emit()
        #expect(lines.count == 2 && lines[1].contains("skipped=200"))
        for _ in 0..<200 { clock += 1; emit() }
        #expect(lines.count == 120)
        #expect(lines.last?.contains("remaining=0") == true)
        clock += 1000; emit(); #expect(lines.count == 120)
        diag.beginVoiceRun(); emit(); #expect(lines.count == 121)
        #expect(lines.allSatisfy { $0.contains("queued=255") && $0.contains("graph=unavailable") })
        var reads = 0
        #expect(AudioLifecycleDiagnostics.safeGraph(false) { reads += 1; return "forbidden" } == "graph=unavailable")
        #expect(reads == 0)
    }

    @Test func closedProducerMappingNeverCopiesContent() {
        let secret = "ses_PRIVATE https://private.invalid/device UID_PRIVATE transcript_PRIVATE"
        let inputs: [(String, AudioLifecycleDiagnostics.Stage)] = [
            ("connected " + secret, .connected), ("event stream error: " + secret, .disconnected),
            ("resync (connected): " + secret, .resync), ("playback silenced (stop control) " + secret, .localSilence),
            ("error: Could not read session state: " + secret, .resyncFailed),
            ("interrupt " + secret + " -> interrupted=false", .idle),
            ("interrupt " + secret + " -> interrupted=true", .interrupted),
            ("error: Stop: " + secret, .interruptFailed), ("speak start [" + secret, .playStart),
            ("speak end [" + secret, .playEnd), ("audio: ready", .graphReady)]
        var clock = 0.0, lines: [String] = []
        let diag = AudioLifecycleDiagnostics(now: { clock }, write: { lines.append($0) })
        let audio = MacAudio(config: { .init() })
        diag.beginVoiceRun()
        for (input, expected) in inputs {
            #expect(AudioLifecycleDiagnostics.stage(for: input) == expected)
            diag.record(expected, audio: audio, active: true, busy: false, queued: 2)
            clock += 1
        }
        #expect(AudioLifecycleDiagnostics.stage(for: secret) == nil)
        let allowed = Set(["stage", "remaining", "skipped", "active", "busy", "queued", "generation", "ready", "capturing", "running", "paused", "graph"])
        for line in lines {
            #expect(!line.contains("PRIVATE") && !line.contains("https:") && !line.contains("transcript"))
            #expect(line.split(separator: " ").dropFirst().allSatisfy { allowed.contains(String($0.split(separator: "=")[0])) })
        }
    }

    @Test func knownOfflineVolumeSnapshotsAreStateNotAcousticProof() throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        try engine.start(); defer { engine.stop() }
        let audio = MacAudio(offlineEngine: engine, player: player)
        engine.mainMixerNode.outputVolume = 0
        audio.setCutInGain(0.25)
        #expect(audio.diagnosticSnapshot().contains("gain=duck25 mixer=zero"))
        engine.mainMixerNode.outputVolume = 1
        audio.setCutInGain(1)
        #expect(audio.diagnosticSnapshot().contains("gain=unity mixer=unity"))
        #expect(audio.pauseForAutomaticCutIn())
        #expect(audio.diagnosticSnapshot().contains("paused=true"))
        audio.stopPlayback()
        #expect(audio.diagnosticSnapshot().contains("generation=1"))
        engine.stop()
        #expect(audio.diagnosticSnapshot().contains("graph=stopped engine=false"))
        audio.stop()
        #expect(audio.diagnosticSnapshot().contains("graph=unavailable"))
        #expect(AudioLifecycleDiagnostics.gain(.nan) == "other")
    }
}
