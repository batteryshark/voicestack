import AVFoundation
import UIKit

/// Launch-only, bounded acoustic measurement. No transcript, token, URL or room recording.
@MainActor final class SpeakerEchoProbe {
    static let shared = SpeakerEchoProbe()
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-FVSpeakerEchoProbe") }
    private var began = false
    private var phase = 0
    private var onsets = 0, barges = 0
    private var lastSample = 0.0
    func activity(barge: Bool) { if barge { barges += 1 } else { onsets += 1 } }
    func sample(mic: Double, mix: Double, idle: Bool, voiceProcessing: Bool, speaker: Bool, micLinkedToOutput: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard phase > 0, now-lastSample >= 0.2 else { return }; lastSample = now
        StageDiagnostics.shared.record(.echo, .complete, audio: CaptureSnapshot([
            .micRMS: mic, .mixRMS: mix, .playerIdle: idle ? 1 : 0,
            .voiceProcessing: voiceProcessing ? 1 : 0, .speakerRoute: speaker ? 1 : 0,
            .vadOnsets: Double(onsets), .bargeIns: Double(barges), .echoPhase: Double(phase), .inputToOutput: micLinkedToOutput ? 1 : 0]))
    }
    func run(_ model: PhoneModel) async {
        guard Self.enabled, !began else { return }; began = true
        let originalRoute = model.coordinator.speaker
        var originalMode: SendMode?
        defer { phase = 0; model.coordinator.speaker = originalRoute }
        do {
            let deadline = Date().addingTimeInterval(15)
            while !model.paired || model.backend?.connection != "connected" {
                guard Date() < deadline else { throw ClientError("Echo preparation timeout") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard model.backend?.lease?.sessionID == PhoneLoopProbe.target,
                  try await model.backend?.activeSessions().isEmpty == true else { throw ClientError("Echo target unavailable") }
            // No room words may be posted. Manual mode is in-memory only, restored below.
            model.backend?.promptAdmission = { _, _ in throw ClientError("Echo probe never sends") }
            model.coordinator.speaker = true
            await model.startVoice()
            let ready = Date().addingTimeInterval(20)
            while model.calls.lifecycle.state != .active {
                guard Date() < ready, model.hasCall else { throw ClientError("Echo call failed") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let controller = model.controller else { throw ClientError("Echo controller unavailable") }
            originalMode = controller.app.sendMode; controller.app.sendMode = .manual
            controller.onEchoActivity = { [weak self] in self?.activity(barge: $0) }
            model.calls.mute(true)
            phase = 1
            // Meter real voice-processed room input and the real main mixer with no player buffers.
            try await Task.sleep(nanoseconds: 6_000_000_000)
            model.calls.mute(false)
            onsets = 0; barges = 0; phase = 2
            // Real TTS + player + speaker, without prompting the chief or fabricating recognition.
            controller.speaker.enqueue("This is the authorized speaker echo check. The microphone is listening while this sentence plays. The test measures the speaker and microphone; it does not send your words.", label: "echo-check")
            try await Task.sleep(nanoseconds: 12_000_000_000)
            phase = 0
            StageDiagnostics.shared.record(.echo, .complete, status: 99)
        } catch { StageDiagnostics.shared.record(.echo, .failed, status: StageDiagnostics.code(error)) }
        if let originalMode { model.controller?.app.sendMode = originalMode }
        model.controller?.onEchoActivity = nil
        // The probe's room recognition is never kept as a draft or sent.
        model.controller?.onReviewDraft = nil
        model.controller?.stop(discardUnfinished: true)
        await model.stopVoiceByUser()
        model.backend?.promptAdmission = nil
        do { try await model.select("chief") }
        catch { StageDiagnostics.shared.record(.echo, .failed, status: 1) }
    }
}
