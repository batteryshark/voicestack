import Foundation

/// Mac-only observer of existing main-actor lifecycle callbacks. Never an audio-thread sink.
@MainActor public final class AudioLifecycleDiagnostics {
    public enum Stage: String {
        case connected, disconnected, resync, resyncFailed, stopEntry, localSilence, interrupted, idle, interruptFailed
        case playStart, playEnd, graphReady, graphConfig
    }
    private let now: () -> TimeInterval
    private let write: (String) -> Void
    private var remaining = 0, skipped = 0
    private var last = -TimeInterval.infinity
    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, write: @escaping (String) -> Void) {
        self.now = now; self.write = write
    }
    /// Only the app's explicit Start action resets the budget, never reconnect/device restart.
    public func beginVoiceRun() { remaining = 120; skipped = 0; last = -.infinity }
    public func record(_ stage: Stage, audio: MacAudio, active: Bool, busy: Bool, queued: Int) {
        let time = now()
        guard remaining > 0, time - last >= 1 else { skipped = min(65535, skipped + 1); return }
        remaining -= 1; last = time
        write("audio_diag stage=\(stage.rawValue) remaining=\(remaining) skipped=\(skipped) active=\(active) busy=\(busy) queued=\(min(255, max(0, queued))) \(audio.diagnosticSnapshot())")
        skipped = 0
    }
    /// Only fixed producer prefixes select an enum; no input content is copied into diagnostics.
    public static func stage(for line: String) -> Stage? {
        if line.hasPrefix("connected ") { return .connected }
        if line == "event stream ended" || line.hasPrefix("event stream error:") || line.hasPrefix("reconnecting in ") { return .disconnected }
        if line.hasPrefix("resync (") { return .resync }
        if line.hasPrefix("error: Could not read session state:") { return .resyncFailed }
        if line.hasPrefix("playback silenced (stop control)") { return .localSilence }
        if line.hasPrefix("interrupt "), line.hasSuffix(" -> interrupted=true") { return .interrupted }
        if line.hasPrefix("interrupt "), line.hasSuffix(" -> interrupted=false") { return .idle }
        if line.hasPrefix("error: Stop:") { return .interruptFailed }
        if line.hasPrefix("speak start [") { return .playStart }
        if line.hasPrefix("speak end [") { return .playEnd }
        if line == "audio: ready" { return .graphReady }
        return nil
    }
    static func gain(_ value: Float) -> String {
        if value == 0 { return "zero" }
        if value == 0.25 { return "duck25" }
        if value == 1 { return "unity" }
        return "other"
    }
    static func safeGraph(_ eligible: Bool, read: () -> String) -> String { eligible ? read() : "graph=unavailable" }
}
