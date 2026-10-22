import AVFoundation
import SwiftUI
import OSLog

/// Launch-only, no transport/controller/credential construction and no audio persistence.
@MainActor enum DeviceAudioProbe {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-FVDeviceProbe") }
    /// With -FVDeviceProbe: real IOSAudio + voice processing playing a Mac-rendered Voicestack
    /// TTS reply (Documents/probe-reply.pcm, s16le 24 kHz), hold music exactly as calls play it,
    /// then the reply again. Records main-mixer render output (pre-hardware) to Documents.
    static var playbackEnabled: Bool { enabled && ProcessInfo.processInfo.arguments.contains("-FVPlaybackProbe") }
    static func run() async {
        if playbackEnabled { await runPlayback(); return }
        let coordinator = AudioSessionCoordinator()
        let audio = IOSAudio(coordinator: coordinator)
        let began = Date()
        var cycle = 0
        func emit(_ event: String) {
            var row = audio.probeMetrics()
            row["event"] = event; row["cycle"] = cycle
            row["elapsedMs"] = Int(Date().timeIntervalSince(began) * 1000)
            if let data = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys),
               let line = String(data: data, encoding: .utf8) {
                print(line); fflush(stdout)
                Logger(subsystem: "org.example.voicestack", category: "DeviceProbe").notice("\(line, privacy: .public)")
            }
        }
        audio.onProbeEvent = { emit($0) }
        audio.onFailure = { _ in emit("captureFailure") }
        let ticks = Task { @MainActor in
            while !Task.isCancelled {
                emit("tick")
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        let cycles = ProcessInfo.processInfo.arguments.contains("-FVCycles") ? 3 : 1
        for index in 1...cycles {
            cycle = index
            emit("start")
            do {
                try await audio.start(); emit("ready")
                for second in 0..<16 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if second == 4 && ProcessInfo.processInfo.arguments.contains("-FVRecovery") {
                        audio.probeConfigurationChange()
                    }
                    if cycles == 1 && ProcessInfo.processInfo.arguments.contains("-FVSwitches") && [4, 9].contains(second) {
                        try coordinator.toggleLiveRoute(); emit("switch")
                    }
                }
            } catch { emit("startFailed") }
            emit("beforeStop"); audio.stop(); emit("stopped")
        }
        ticks.cancel(); emit("summary")
        audio.onProbeEvent = nil; audio.onFailure = nil
    }
}

extension DeviceAudioProbe {
    private final class ReplyTicket: SpeechTicket {
        let text = "probe reply"; let pcm: Data
        init(_ pcm: Data) { self.pcm = pcm }
        func audio() async throws -> SpeechAudio { .whole(pcm, sampleRate: 24000) }
        func cancel() {}
    }
    private final class NoSynth: SpeechSynthesizer {
        func prepare(_ text: String) -> SpeechTicket { ReplyTicket(Data()) }
    }
    static func runPlayback() async {
        let docs = URL.documentsDirectory
        let coordinator = AudioSessionCoordinator()
        let audio = IOSAudio(coordinator: coordinator)
        let recorder = ProbeRenderRecorder()
        audio.probeRecorder = recorder
        var marks: [String: Any] = [:], errors: [String] = []
        func log(_ row: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys), let line = String(data: data, encoding: .utf8) {
                print(line); fflush(stdout)
                Logger(subsystem: "org.example.voicestack", category: "PlaybackProbe").notice("\(line, privacy: .public)")
            }
        }
        func mark(_ name: String) { marks[name] = recorder.frames; log(["event": name, "frame": recorder.frames]) }
        guard let reply = try? Data(contentsOf: docs.appendingPathComponent("probe-reply.pcm")), reply.count > 2, reply.count % 2 == 0 else {
            log(["event": "missingReplyPCM"]); return
        }
        let speaker = Speaker(synth: NoSynth(), output: audio) { errors.append($0.localizedDescription) }
        func waitIdle(_ seconds: Double) async {
            let end = Date().addingTimeInterval(seconds)
            while speaker.active && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        do {
            try await audio.start()
            try? await Task.sleep(nanoseconds: 500_000_000)
            marks["formatsStart"] = audio.probeIOFormats(); log(["event": "formats", "io": audio.probeIOFormats()])
            mark("reply1Enqueued"); speaker.enqueuePrepared(ReplyTicket(reply), label: "probe-reply")
            await waitIdle(30); mark("reply1Done")
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let music = BundledHoldMusicTicket() else { throw ClientError("HoldMusic.pcm missing") }
            mark("holdEnqueued"); speaker.enqueueHold(music)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            mark("holdStopRequested"); speaker.stopHold()
            try? await Task.sleep(nanoseconds: 700_000_000)
            mark("reply2Enqueued"); speaker.enqueuePrepared(ReplyTicket(reply), label: "probe-reply")
            await waitIdle(30); mark("reply2Done")
            try? await Task.sleep(nanoseconds: 500_000_000)
            marks["formatsEnd"] = audio.probeIOFormats()
        } catch { errors.append(error.localizedDescription) }
        speaker.stop(); audio.stop()
        marks["sampleRate"] = recorder.sampleRate; marks["tapChannels"] = recorder.channels
        marks["errors"] = errors; marks["tap"] = "AVAudioEngine.mainMixerNode bus 0 (pre-hardware, pre-voice-processing output)"
        let wav = WAV.encode(recorder.pcm16(), sampleRate: Int(recorder.sampleRate))
        do {
            try wav.write(to: docs.appendingPathComponent("playback-probe.wav"))
            try JSONSerialization.data(withJSONObject: marks, options: [.prettyPrinted, .sortedKeys]).write(to: docs.appendingPathComponent("playback-probe.json"))
        } catch { log(["event": "writeFailed", "error": error.localizedDescription]) }
        log(["event": "summary", "frames": recorder.frames, "rate": recorder.sampleRate, "errors": errors])
    }
}

struct DeviceAudioProbeView: View {
    var body: some View {
        Text(DeviceAudioProbe.playbackEnabled ? "Local playback diagnostic — app output only, saved on this phone"
             : "Local microphone diagnostic — no audio saved or sent")
            .padding().task { await DeviceAudioProbe.run() }
    }
}
