import AVFoundation
import SwiftUI
import OSLog

/// A launch-only harness around the real model/controller, never a second voice loop.
@MainActor final class PhoneLoopProbe {
    static let shared = PhoneLoopProbe()
    static let target = "ses_example0000000000000000000"
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-FVPhoneLoopProbe") }
    static var lockedMode: Bool { ProcessInfo.processInfo.arguments.contains("-FVLockedCallProbe") }
    static let showHistory = Notification.Name("FVPhoneLoopHistory")
    static func install() {
        let evidence = ProbeEventFile()
        VoiceTrace.shared.configure { event, fields in
            var row = fields
            row["event"] = event; row["unixMs"] = String(Int(Date().timeIntervalSince1970 * 1000))
            if let bytes = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys), let line = String(data: bytes, encoding: .utf8) {
                evidence.append(bytes)
                print(line); fflush(stdout)
                Logger(subsystem: "org.example.voicestack", category: "PhoneLoop").notice("\(line, privacy: .public)")
            }
        }
    }
    var fixture: TapSpeechFixture?
    private var began = false, admitted = false, ended = false
    private var partials = 0
    private var lastState = ""
    private var baseline = Set<String>()
    private var pictures = Set<String>()
    func observe(_ backend: RemoteSessionBackend) {
        backend.promptAdmission = { [weak self, weak backend] target, text in
            guard let self, target.sessionID == Self.target, backend?.lease == target, !self.admitted,
                  text.lowercased().contains("automated"), text.lowercased().contains("test") else {
                VoiceTrace.shared.event("prompt.refused"); throw ClientError("Phone loop target/text/count guard refused delivery")
            }
            self.admitted = true
            VoiceTrace.shared.event("prompt.admitted", ["target": target.sessionID, "text": text])
        }
        backend.onActivity = { [weak backend] event, count in
            guard backend?.lease?.sessionID == Self.target else { return }
            VoiceTrace.shared.event(event, ["count": String(count)])
        }
        backend.onRemoteEvent = { event in
            guard event.sessionID == Self.target else { return }
            var fields = ["type": event.type]
            for key in ["delta", "text", "messageID", "assistantMessageID", "userMessageID", "status"] {
                if let value = event.data[key] as? String { fields[key] = value }
            }
            VoiceTrace.shared.event("remote.event", fields)
        }
    }
    func loadFixture(_ format: AVAudioFormat) throws {
        guard fixture == nil else { return }
        fixture = try TapSpeechFixture(format: format)
    }
    func status(_ model: PhoneModel) {
        guard model.backend?.lease?.sessionID == Self.target else { return }
        let state = model.surface.state
        guard state != lastState else { return }; lastState = state
        VoiceTrace.shared.event("ui.state", ["state": state, "phase": model.status.phase, "speaking": String(model.status.speaking), "hearing": String(model.status.hearing)])
        if state.lowercased().contains("listening") { picture("listening") }
        if state.lowercased().contains("thinking") { picture("thinking") }
        if state.lowercased().contains("sending") { picture("sending", delay: 16_000_000) }
    }
    func caption(_ event: CaptionEvent, model: PhoneModel) {
        guard model.backend?.lease?.sessionID == Self.target else { return }
        switch event {
        case .youLive(let text):
            partials += 1; VoiceTrace.shared.event("asr.partial", ["count": String(partials), "text": text]); picture("captions")
        case .youFinal(let text): VoiceTrace.shared.event("asr.final", ["text": text, "partials": String(partials)])
        case .posted(let text): VoiceTrace.shared.event("composer.posted", ["text": text])
        case .chiefQueued(_, let text): VoiceTrace.shared.event("reply.queued", ["text": text])
        case .chiefStarted(_, let text): VoiceTrace.shared.event("reply.started", ["text": text]); picture("speaking")
        case .chiefEnded(_, let text, let outcome):
            VoiceTrace.shared.event("reply.ended", ["text": text, "outcome": outcome]); ended = true
        case .countdown(let total, let elapsed, _):
            if elapsed == 0 { VoiceTrace.shared.event("endpoint.wait", ["totalMs": String(total)]) }
        default: break
        }
    }
    func visible(_ id: String, model: PhoneModel) {
        guard model.backend?.lease?.sessionID == Self.target, !baseline.contains(id) else { return }
        VoiceTrace.shared.event("history.visible", ["id": id])
    }
    /// Capture only our actual foreground UIWindow, never another app or private screen.
    private func picture(_ name: String, delay: UInt64 = 300_000_000) {
        guard !pictures.contains(name) else { return }; pictures.insert(name)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard UIApplication.shared.applicationState == .active,
                  let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first(where: { $0.isKeyWindow }) else { return }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let file = "loop-\(name).png"
            if let png = image.pngData() {
                try? png.write(to: URL.documentsDirectory.appendingPathComponent(file))
                VoiceTrace.shared.event("screenshot.saved", ["file": file])
            }
        }
    }
    func run(_ model: PhoneModel) async {
        guard !began else { return }; began = true
        let originalSpeaker = model.coordinator.speaker
        defer { model.coordinator.speaker = originalSpeaker }
        let liveness = Task { @MainActor in
            while !Task.isCancelled {
                model.recordProbeLiveness()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { liveness.cancel() }
        do {
            let preparing = Date().addingTimeInterval(12)
            while !model.paired || model.backend?.connection != "connected" {
                guard Date() < preparing else { throw ClientError("Probe preparation timeout") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard model.selection == Self.target, let backend = model.backend, backend.lease?.sessionID == Self.target,
                  try await backend.activeSessions().isEmpty else { throw ClientError("Probe target must be selected and idle") }
            baseline = Set((backend.store?.records ?? []).compactMap(MessageRow.init).map(\.id))
            VoiceTrace.shared.event("loop.begin", ["target": Self.target, "historyRows": String(baseline.count)])
            model.coordinator.speaker = false
            await model.startVoice()
            if Self.lockedMode {
                try await proveLockedCall(model)
            } else {
            let deadline = Date().addingTimeInterval(42)
            while !(ended && !model.status.speaking && backend.store?.active == false) {
                guard Date() < deadline, UIApplication.shared.isProtectedDataAvailable else { throw ClientError("Voice loop timeout/locked") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await backend.reconcile(backend.lease!)
            model.historyVisible = true; model.updateConversation()
            let added = model.messages.filter { !baseline.contains($0.id) }
            for row in added { VoiceTrace.shared.event("history.new", ["id": row.id, "role": row.role, "text": row.text]) }
            VoiceTrace.shared.event("history.rows", ["total": String(model.messages.count), "new": String(added.count)])
            NotificationCenter.default.post(name: Self.showHistory, object: nil)
            try await Task.sleep(nanoseconds: 2_000_000_000); picture("history")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            VoiceTrace.shared.event("loop.completed")
            }
        } catch { VoiceTrace.shared.event("loop.failed", ["code": String((error as NSError).code)]) }
        let cleanup = UIApplication.shared.beginBackgroundTask(withName: "ProbeCallCleanup")
        defer { if cleanup != .invalid { UIApplication.shared.endBackgroundTask(cleanup) } }
        await model.stopVoiceByUser()
        do {
            try await model.select("chief")
            guard let backend = model.backend, model.selection == "chief", backend.lease?.sessionID == (try await backend.chief()) else { throw ClientError("Chief restore verification failed") }
            let deadline = Date().addingTimeInterval(8)
            while backend.connection != "connected" {
                guard Date() < deadline else { throw ClientError("Chief connection did not recover") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            _ = try await backend.activeSessions()
            VoiceTrace.shared.event("selection.restored", ["mode": "chief", "verified": "true"])
        } catch { VoiceTrace.shared.event("selection.restoreFailed", ["code": String((error as NSError).code)]) }
        fixture = nil
        do { try FileManager.default.removeItem(at: URL.documentsDirectory.appendingPathComponent("phone-loop.wav")); VoiceTrace.shared.event("fixture.removed") }
        catch { VoiceTrace.shared.event("fixture.removeFailed") }
        VoiceTrace.shared.event("loop.finished")
    }
    private func proveLockedCall(_ model: PhoneModel) async throws {
        let readyDeadline = Date().addingTimeInterval(20)
        while !(model.hasCall && model.calls.lifecycle.state == .active && model.status.phase == "ready") {
            guard Date() < readyDeadline else { throw ClientError("Locked probe call readiness timeout") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        VoiceTrace.shared.event("lock.ready")
        let lockDeadline = Date().addingTimeInterval(15)
        while UIApplication.shared.applicationState != .background {
            guard Date() < lockDeadline, model.hasCall else { throw ClientError("Runner did not lock the active call") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        VoiceTrace.shared.event("lock.backgroundBegin")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard model.hasCall, model.calls.lifecycle.mayRunMedia else { throw ClientError("Locked call lost activation") }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        VoiceTrace.shared.event("lock.completed")
    }
}

/// Owned fixture text/counts only, so evidence survives a runner launch and a locked screen.
private final class ProbeEventFile: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle?
    init() {
        let url = URL.documentsDirectory.appendingPathComponent("loop-events.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        file = try? FileHandle(forWritingTo: url)
    }
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; try? file?.write(contentsOf: bytes + Data([10])) }
}

/// Exactly one producer: the real hardware input tap. No timer feeds capture.
final class TapSpeechFixture: @unchecked Sendable {
    private let samples: [Float]
    private let format: AVAudioFormat
    private var offset = 0
    private var callbacks = 0
    init(format: AVAudioFormat) throws {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw ClientError("Probe requires float noninterleaved tap") }
        self.format = format
        let bytes = try Data(contentsOf: URL.documentsDirectory.appendingPathComponent("phone-loop.wav"))
        let (pcm, rate) = try WAV.decodeToS16Mono(bytes)
        let resampled = resampleS16(pcm, from: rate, to: Int(format.sampleRate))
        samples = resampled.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
        VoiceTrace.shared.event("fixture.loaded", ["frames": String(samples.count), "rate": String(format.sampleRate), "channels": String(format.channelCount)])
    }
    func replace(_ buffer: AVAudioPCMBuffer) {
        guard offset < samples.count, buffer.format.isEqual(format), let channels = buffer.floatChannelData else { return }
        let count = min(Int(buffer.frameLength), samples.count - offset)
        for c in 0..<Int(format.channelCount) { for i in 0..<count { channels[c][i] = samples[offset + i] } }
        offset += count
        callbacks += 1
        if callbacks == 1 || callbacks % 50 == 0 {
            VoiceTrace.shared.event("fixture.tap", ["callbacks": String(callbacks), "replacedFrames": String(offset)])
        }
        if offset == samples.count { VoiceTrace.shared.event("fixture.exhausted.realMicResumed") }
    }
}
