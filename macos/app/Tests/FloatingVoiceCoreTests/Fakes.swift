import Foundation
@testable import FloatingVoiceCore

/// Speech whose "audio" is the sentence text itself, so playback records can be read back as text.
final class FakeTicket: SpeechTicket {
    let text: String
    let error: Error?
    var cancelled = false
    init(_ text: String, error: Error? = nil) { self.text = text; self.error = error }
    func audio() async throws -> SpeechAudio {
        if let error { throw error }
        return .whole(Data(text.utf8), sampleRate: 1000)
    }
    func cancel() { cancelled = true }
}

final class FakeSynth: SpeechSynthesizer {
    var prepared: [String] = []
    /// When set, the next prepared ticket fails with this error (a request that cannot reach the speech service).
    var failWith: Error?
    func prepare(_ text: String) -> SpeechTicket {
        prepared.append(text)
        if let e = failWith { failWith = nil; return FakeTicket(text, error: e) }
        return FakeTicket(text)
    }
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
final class FakeInput: AudioInput {
    var onPCM: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    var started = false, stopped = false
    var starts = 0, stops = 0
    var duplexSafe = true
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
    /// When set, start() reports this error (a connection that failed) and finishes with no text.
    var failWith: Error?
    var written = 0, ended = false, cancelled = false
    init(_ callbacks: RecognitionCallbacks, transcript: String, partialAfterFrames: Int? = nil, live: [(Int, String)] = []) {
        self.callbacks = callbacks; self.transcript = transcript; self.partialAfterFrames = partialAfterFrames; self.live = live
    }
    func start() {
        if let failWith {
            let cb = callbacks
            DispatchQueue.main.async { cb.error(failWith); cb.done("") }
        }
    }
    func write(_ pcm: Data) {
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
    var receiptID: String?
    var receiptEcho: (() -> Void)?
    func postWithReceipt(sessionID: String, text: String, delivery: BusyDelivery?, admit: Bool) async throws -> String? {
        if admit { try await self.admit(sessionID: sessionID, text: text) }
        else { try await prompt(sessionID: sessionID, text: text, delivery: delivery) }
        receiptEcho?()
        await Task.yield()
        return receiptID
    }
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
    func prompt(sessionID: String, text: String, delivery: BusyDelivery?) async throws {
        if promptDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(promptDelay * 1_000_000_000)) }
        prompts.append(Prompt(session: sessionID, text: text, delivery: delivery))
    }
    /// What interrupt reports: true when a turn was running and got interrupted.
    var interruptResult = true
    func interrupt(sessionID: String) async throws -> Bool { interrupts.append(sessionID); return interruptResult }
    var admits: [String] = []
    var admitError: Error?
    func admit(sessionID: String, text: String) async throws {
        if let admitError { throw admitError }
        admits.append(text)
    }
    var sessions: [SessionSummary] = []
    var sessionListFails = false
    func listSessions() async throws -> [SessionSummary] {
        if sessionListFails { throw URLError(.cannotConnectToHost) }
        return sessions
    }
    private let titleLock = NSLock()
    private var storedTitles: [String: String] = [:]
    private var storedTitleReads: [String] = []
    private var storedTitleDelay: Duration = .zero
    var titles: [String: String] {
        get { titleLock.withLock { storedTitles } }
        set { titleLock.withLock { storedTitles = newValue } }
    }
    var titleReads: [String] {
        get { titleLock.withLock { storedTitleReads } }
        set { titleLock.withLock { storedTitleReads = newValue } }
    }
    var titleDelay: Duration {
        get { titleLock.withLock { storedTitleDelay } }
        set { titleLock.withLock { storedTitleDelay = newValue } }
    }
    func sessionTitle(_ id: String) async -> String? {
        let delay = titleLock.withLock { storedTitleReads.append(id); return storedTitleDelay }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return titles[id]
    }

    func send(_ type: String, _ session: String, _ data: [String: Any] = [:]) {
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
