import Foundation
@testable import FloatingVoiceCore

/// Speech whose "audio" is the sentence text itself, so playback records can be read back as text.
final class FakeTicket: SpeechTicket {
    let text: String
    var cancelled = false
    init(_ text: String) { self.text = text }
    func audio() async throws -> SpeechAudio { .whole(Data(text.utf8), sampleRate: 1000) }
    func cancel() { cancelled = true }
}

final class FakeSynth: SpeechSynthesizer {
    var prepared: [String] = []
    func prepare(_ text: String) -> SpeechTicket { prepared.append(text); return FakeTicket(text) }
}

/// Plays each sentence for `duration` seconds unless stopped.
@MainActor
final class FakeOutput: AudioOutput {
    struct Play { let text: String; var outcome: String }
    var plays: [Play] = []
    var stops = 0
    var duration: TimeInterval
    private var generation = 0
    init(duration: TimeInterval = 0.25) { self.duration = duration }

    func play(_ audio: SpeechAudio, label: String, onStart: @escaping () -> Void) async throws {
        let gen = generation
        var text = ""
        for try await chunk in audio.chunks { text += String(decoding: chunk, as: UTF8.self) }
        plays.append(Play(text: text, outcome: "playing"))
        let i = plays.count - 1
        onStart()
        let end = Date().addingTimeInterval(duration)
        while Date() < end {
            if gen != generation { plays[i].outcome = "stopped"; return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        plays[i].outcome = gen == generation ? "played" : "stopped"
    }

    func stopPlayback() { generation += 1; stops += 1 }
    var playing: [String] { plays.filter { $0.outcome == "playing" }.map(\.text) }
}

@MainActor
final class FakeInput: AudioInput, DuplexReporting, CaptureOriginReporting {
    var onDuplexChange: (() -> Void)?
    var lastCaptureRendered = false
    var lastCaptureDuplexSafe = true
    var captureGraphReady = true { didSet { onDuplexChange?() } }
    var onPCM: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    var started = false, stopped = false
    var starts = 0, stops = 0
    var speechDiscards = 0
    func discardPendingAudio() { speechDiscards += 1 }
    var duplexSafe = true { didSet { onDuplexChange?() } }
    func start() async throws { started = true; starts += 1 }
    func stop() { stopped = true; started = false; stops += 1 }

    /// 20 ms frames of a tone loud enough to count as speech, or silence.
    func frames(_ count: Int, voiced: Bool) {
        for _ in 0..<count { onPCM?(voiced ? Self.tone : Data(count: 640)) }
    }
    /// 20 ms frames of steady noise at this RMS (a square wave, so its RMS is its amplitude).
    func noise(_ count: Int, rms: Double) {
        let a = Int16(rms * 32768)
        var d = Data()
        for i in 0..<320 { let v = i % 2 == 0 ? a : -a; d.append(UInt8(truncatingIfNeeded: v)); d.append(UInt8(truncatingIfNeeded: v >> 8)) }
        for _ in 0..<count { onPCM?(d) }
    }
    static let tone: Data = {
        var d = Data()
        for i in 0..<320 { let v = Int16(8000 * sin(Double(i) / 320 * 2 * .pi * 8)); d.append(UInt8(truncatingIfNeeded: v)); d.append(UInt8(truncatingIfNeeded: v >> 8)) }
        return d
    }()
}

/// Recognition that returns a fixed transcript when the utterance ends.
final class FakeRecognition: RecognitionSession {
    let callbacks: RecognitionCallbacks
    let transcript: String
    let partialAfterFrames: Int?
    let live: [(Int, String)]
    /// The server never answers input_audio.end (no final transcript).
    var silentEnd = false
    var written = 0, ended = false, cancelled = false
    var recordedPCM: [Data]?
    init(_ callbacks: RecognitionCallbacks, transcript: String, partialAfterFrames: Int? = nil, live: [(Int, String)] = []) {
        self.callbacks = callbacks; self.transcript = transcript; self.partialAfterFrames = partialAfterFrames; self.live = live
    }
    func start() {}
    func write(_ pcm: Data) {
        if recordedPCM != nil { recordedPCM!.append(pcm) }
        written += 1
        if let n = partialAfterFrames, written == n { callbacks.partial(transcript) }
        for (n, text) in live where written == n { callbacks.live(text) }
    }
    func end() {
        ended = true
        if silentEnd { return }
        let cb = callbacks, t = transcript
        DispatchQueue.main.async { cb.done(t) }
    }
    func cancel() { cancelled = true; callbacks.done("") }
}

final class FakeBackend: SessionBackend, @unchecked Sendable {
    struct Prompt: Equatable { let session: String; let text: String; let delivery: BusyDelivery? }
    var prompts: [Prompt] = []
    var interrupts: [String] = []
    var active: Set<String> = []
    var connects = 0
    var continuation: AsyncThrowingStream<ServerEvent, Error>.Continuation?

    func connect() async throws -> String { connects += 1; return "fake" }
    func events() -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { c in
            self.continuation = c
            c.yield(ServerEvent(type: "server.connected"))
        }
    }
    func activeSessions() async throws -> Set<String> { active }
    var promptDelay: TimeInterval = 0
    var generations: [String: String] = [:]
    var sentLeases: [TargetLease] = []
    var leaseGate: (() async throws -> Void)?
    func targetLease(sessionID: String) async throws -> TargetLease {
        try await leaseGate?()
        return TargetLease(sessionID: sessionID, generation: generations[sessionID] ?? "initial")
    }
    private func validate(_ target: TargetLease) async throws {
        guard target == (try await targetLease(sessionID: target.sessionID)) else { throw ClientError("stale generation") }
    }
    func prompt(target: TargetLease, text: String, delivery: BusyDelivery?) async throws {
        try await validate(target)
        if promptDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(promptDelay * 1_000_000_000)) }
        sentLeases.append(target)
        prompts.append(Prompt(session: target.sessionID, text: text, delivery: delivery))
    }
    /// What interrupt reports: true when a turn was running and got interrupted.
    var interruptResult = true
    var interruptGate: (() async throws -> Bool)?
    func interrupt(target: TargetLease) async throws -> Bool {
        try await validate(target); interrupts.append(target.sessionID)
        if let interruptGate { return try await interruptGate() }
        return interruptResult
    }
    var admits: [String] = []
    var admitError: Error?
    func admit(target: TargetLease, text: String) async throws { try await validate(target); admits.append(text); if let admitError { throw admitError } }
    var sessions: [SessionSummary] = []
    var sessionListFails = false
    func listSessions() async throws -> [SessionSummary] {
        if sessionListFails { throw URLError(.cannotConnectToHost) }
        return sessions
    }
    var titles: [String: String] = [:]
    func sessionTitle(_ id: String) async -> String? { titles[id] }

    func send(_ type: String, _ session: String, _ data: [String: Any] = [:]) {
        if type == "session.execution.started" { active.insert(session) }
        if ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].contains(type) { active.remove(session) }
        var d = data
        d["sessionID"] = session
        continuation?.yield(ServerEvent(type: type, data: d))
    }
    /// End the current stream, as a dropped connection does.
    func drop() { continuation?.finish(throwing: URLError(.networkConnectionLost)); continuation = nil }
}

final class FakeMicHolders: MicHolderCheck {
    var holders: [MicHolder] = []
    func otherCapturers() -> [MicHolder] { holders }
}

@MainActor
func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

func tempDir() -> String {
    let dir = NSTemporaryDirectory() + "fv-tests-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func writeChief(_ path: String, _ session: String) {
    try! #"{"session": "\#(session)", "directory": "/tmp"}"#.write(toFile: path, atomically: true, encoding: .utf8)
}
