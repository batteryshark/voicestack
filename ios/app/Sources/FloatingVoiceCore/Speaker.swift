import Foundation

/// Sample-accurate device-fixture boundaries, independent of hardware tap sizes.
/// The gap is a routing instruction, NOT a buffer of synthetic silence.
public struct SpeechGapSchedule {
    public enum Source: Equatable { case first(Int), gap, second(Int), finished }
    public let firstFrames: Int, gapFrames: Int, secondFrames: Int
    public init(firstFrames: Int, gapFrames: Int, secondFrames: Int) {
        self.firstFrames = firstFrames; self.gapFrames = gapFrames; self.secondFrames = secondFrames
    }
    public func source(at frame: Int) -> Source {
        if frame < 0 { return .finished }
        if frame < firstFrames { return .first(frame) }
        if frame < firstFrames + gapFrames { return .gap }
        let index = frame - firstFrames - gapFrames
        return index < secondFrames ? .second(index) : .finished
    }
}

/// A graph repair is not successful playback. Speaker retries the sentence, never the model turn.
public enum PlaybackInterruption: Error { case recoverable }

/// Launch-gated device suite only; substitution still enters through the hardware tap.
@MainActor public protocol VoiceTurnProbeInput: AudioInput {
    func probeInterjection() throws
}

/// Where speech is played. MacAudio plays it on the voice-processing engine; the harness records it to a file.
@MainActor
public protocol AudioOutput: AnyObject {
    /// Play one sentence as its chunks arrive. Returns once it has been played back, or soon after stopPlayback().
    /// `onStart` runs when the first audio is scheduled.
    func play(_ audio: SpeechAudio, label: String, onStart: @escaping () -> Void) async throws
    /// Stop what is playing now (the caller clears its own queue).
    func stopPlayback()
    func waitUntilReady() async throws
}

public extension AudioOutput { func waitUntilReady() async throws {} }

/// Cancels the old TTS ticket promptly, including when playback is awaiting a network chunk.
@MainActor public protocol PlaybackRepairReporting: AnyObject {
    var onPlaybackRepair: (() -> Void)? { get set }
}

/// Microphone: 16 kHz mono s16le PCM delivered on the main thread.
@MainActor
public protocol AudioInput: AnyObject {
    func discardPendingAudio()
    var onPCM: ((Data) -> Void)? { get set }
    /// Called if capture fails after it started (device unplugged, route change).
    var onFailure: ((Error) -> Void)? { get set }
    func start() async throws
    /// Release the microphone.
    func stop()
    /// False when the mic would hear the speakers (echo cancellation off, output not headphones).
    var duplexSafe: Bool { get }
}

/// Current route safety, not a cached activation-time echo-canceller flag.
@MainActor public protocol DuplexReporting: AudioInput {
    var onDuplexChange: (() -> Void)? { get set }
    var captureGraphReady: Bool { get }
}
public extension DuplexReporting { var captureGraphReady: Bool { true } }

/// A route repair has two phases: no old generation may reopen admission during
/// debounce; only delivery by the installed replacement generation can do so.
public struct CaptureGraphAdmission {
    public private(set) var ready = false
    private var expected: Int?
    public init() {}
    public mutating func beginRepair() { ready = false; expected = nil }
    public mutating func installed(_ generation: Int) { ready = false; expected = generation }
    public mutating func delivered(_ generation: Int) {
        if expected == generation { ready = true }
    }
}

/// Provenance captured at the hardware tap, before its hop to the main actor.
/// A queued playback buffer must not become ambient merely because playback ended.
@MainActor public protocol CaptureOriginReporting: AudioInput {
    var lastCaptureRendered: Bool { get }
    var lastCaptureDuplexSafe: Bool { get }
}

public extension AudioInput {
    func discardPendingAudio() {}
    /// False when the mic would hear the speakers (echo cancellation off, output not headphones): run half duplex.
    var duplexSafe: Bool { true }
}

/// Cross-thread fence for PCM queued from a capture callback to the main actor.
public final class CaptureEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    public init() {}
    public var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    public func advance() { lock.lock(); value += 1; lock.unlock() }
}

/// Sentence queue with one-ahead prefetch, ported from agent-voice's Speaker. Sentences play in order; a new
/// reply's sentences wait behind the ones already queued. Only stop() cuts playback, and it bumps the epoch so
/// any sentence still being fetched for the old epoch is dropped.
@MainActor
public final class Speaker {
    struct Item { let text: String; let label: String; let epoch: Int; var ticket: SpeechTicket?; var retries = 0 }

    private let synth: SpeechSynthesizer
    private let output: AudioOutput
    private let onError: (Error) -> Void
    private var queue: [Item] = []
    private var current: Item?
    private var pump: Task<Void, Never>?
    private(set) var epoch = 0
    public private(set) var playing = false
    private var paused = false
    private var repairGeneration = 0
    /// Called when playing/queued state changes (status line).
    public var onChange: (() -> Void)?
    /// Called when a sentence starts playing (captions in later milestones; logs now).
    public var onSentence: ((String, String) -> Void)?
    /// Called when a sentence that started playing ends: (label, text, "played" | "stopped" | "failed").
    public var onSentenceEnd: ((String, String, String) -> Void)?

    public init(synth: SpeechSynthesizer, output: AudioOutput, onError: @escaping (Error) -> Void) {
        self.synth = synth; self.output = output; self.onError = onError
        if let reporting = output as? PlaybackRepairReporting {
            reporting.onPlaybackRepair = { [weak self] in
                guard let self else { return }
                self.repairGeneration += 1
                self.current?.ticket?.cancel()
            }
        }
    }

    /// Something is playing, being fetched or queued.
    public var active: Bool { playing || current != nil || !queue.isEmpty }
    public var queuedCount: Int { queue.count }

    public func enqueue(_ text: String, label: String = "") {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard queue.count < 128 else { onError(ClientError("Speech queue full")); return }
        queue.append(Item(text: text, label: label, epoch: epoch, ticket: nil))
        if current == nil && queue.count == 1 { queue[0].ticket = synth.prepare(text) }
        startPump()
        onChange?()
    }

    private func startPump() {
        guard pump == nil, !paused else { return }
        pump = Task { [weak self] in
            await self?.run()
            self?.pump = nil
            if let self, !self.queue.isEmpty { self.startPump() }
        }
    }

    private func prepareNext() {
        if !queue.isEmpty && queue[0].ticket == nil { queue[0].ticket = synth.prepare(queue[0].text) }
    }

    private func run() async {
        while !queue.isEmpty && !paused {
            var item = queue.removeFirst()
            if item.ticket == nil { item.ticket = synth.prepare(item.text) }
            current = item
            let repair = repairGeneration
            defer { if current?.epoch == item.epoch && current?.text == item.text { current = nil } }
            do {
                let audio: SpeechAudio
                do { audio = try await item.ticket!.audio() }
                catch {
                    if repair != repairGeneration { throw PlaybackInterruption.recoverable }
                    throw error
                }
                guard item.epoch == epoch else { continue }
                if repair != repairGeneration { throw PlaybackInterruption.recoverable }
                if paused { item.ticket?.cancel(); item.ticket = nil; queue.insert(item, at: 0); break }
                // Headers are in: fetch the next sentence while this one plays.
                prepareNext()
                playing = true
                onChange?()
                var started = false
                do {
                    try await output.play(audio, label: item.label) { [weak self] in
                        guard let self, item.epoch == self.epoch else { return }
                        started = true
                        self.onSentence?(item.label, item.text)
                    }
                } catch PlaybackInterruption.recoverable {
                    if started { onSentenceEnd?(item.label, item.text, "interrupted") }
                    throw PlaybackInterruption.recoverable
                } catch {
                    if repair != repairGeneration, item.epoch == epoch {
                        if started { onSentenceEnd?(item.label, item.text, "interrupted") }
                        throw PlaybackInterruption.recoverable
                    }
                    if started { onSentenceEnd?(item.label, item.text, item.epoch == epoch ? "failed" : "stopped") }
                    throw error
                }
                if started { onSentenceEnd?(item.label, item.text, item.epoch == epoch ? "played" : "stopped") }
                playing = false
            } catch PlaybackInterruption.recoverable {
                playing = false
                item.ticket?.cancel()
                if item.epoch == epoch {
                    if item.retries == 0 {
                        item.retries += 1; item.ticket = nil
                        // Readiness belongs to the replacement graph / activation grant.
                        do {
                            if !paused { try await output.waitUntilReady() }
                            if item.epoch == epoch { queue.insert(item, at: 0) }
                        } catch {
                            if item.epoch == epoch {
                                if paused { queue.insert(item, at: 0) } else { onError(error) }
                            }
                        }
                    } else { onError(ClientError("Speech interrupted again; sentence available in History")) }
                }
            } catch {
                playing = false
                if item.epoch == epoch && !(error is CancellationError) && (error as? URLError)?.code != .cancelled { onError(error) }
            }
            onChange?()
        }
        current = nil
        onChange?()
    }

    /// Stop playback and drop everything queued or being fetched.
    public func stop() {
        paused = false
        epoch += 1
        for item in queue { item.ticket?.cancel() }
        queue = []
        current?.ticket?.cancel()
        current = nil
        output.stopPlayback()
        playing = false
        onChange?()
    }

    /// Keep sentence position and queued text. Native output invalidates playback as recoverable.
    public func pause() { paused = true }
    public func resume() { paused = false; startPump() }
}
