import Foundation

/// Where speech is played. MacAudio plays it on the voice-processing engine; the harness records it to a file.
@MainActor
public protocol AudioOutput: AnyObject {
    /// Play one sentence as its chunks arrive. Returns once it has been played back, or soon after stopPlayback().
    /// `onStart` runs when the first audio is scheduled.
    func play(_ audio: SpeechAudio, label: String, onStart: @escaping () -> Void) async throws
    /// Stop what is playing now (the caller clears its own queue).
    func stopPlayback()
}

/// Microphone: 16 kHz mono s16le PCM delivered on the main thread.
@MainActor
public protocol AudioInput: AnyObject {
    var onPCM: ((Data) -> Void)? { get set }
    /// Called if capture fails after it started (device unplugged, route change).
    var onFailure: ((Error) -> Void)? { get set }
    func start() async throws
    /// Release the microphone.
    func stop()
    /// Invalidate audio captured/queued before Discard without stopping capture or playback.
    func discardPendingAudio()
    /// False when the mic would hear the speakers (echo cancellation off, output not headphones).
    var duplexSafe: Bool { get }
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
    struct Item { let text: String; let label: String; let epoch: Int; var ticket: SpeechTicket? }

    private let synth: SpeechSynthesizer
    private let output: AudioOutput
    private let onError: (Error) -> Void
    private var queue: [Item] = []
    private var current: Item?
    private var pump: Task<Void, Never>?
    private(set) var epoch = 0
    public private(set) var playing = false
    /// Called when playing/queued state changes (status line).
    public var onChange: (() -> Void)?
    /// Called when a sentence starts playing (captions in later milestones; logs now).
    public var onSentence: ((String, String) -> Void)?
    /// Called when a sentence that started playing ends: (label, text, "played" | "stopped" | "failed").
    public var onSentenceEnd: ((String, String, String) -> Void)?

    public init(synth: SpeechSynthesizer, output: AudioOutput, onError: @escaping (Error) -> Void) {
        self.synth = synth; self.output = output; self.onError = onError
    }

    /// Something is playing, being fetched or queued.
    public var active: Bool { playing || current != nil || !queue.isEmpty }
    public var queuedCount: Int { queue.count }

    public func enqueue(_ text: String, label: String = "") {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        queue.append(Item(text: text, label: label, epoch: epoch, ticket: nil))
        if current == nil && queue.count == 1 { queue[0].ticket = synth.prepare(text) }
        startPump()
        onChange?()
    }

    private func startPump() {
        guard pump == nil else { return }
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
        while !queue.isEmpty {
            var item = queue.removeFirst()
            if item.ticket == nil { item.ticket = synth.prepare(item.text) }
            current = item
            defer { if current?.epoch == item.epoch && current?.text == item.text { current = nil } }
            do {
                let audio = try await item.ticket!.audio()
                guard item.epoch == epoch else { continue }
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
                } catch {
                    if started { onSentenceEnd?(item.label, item.text, item.epoch == epoch ? "failed" : "stopped") }
                    throw error
                }
                if started { onSentenceEnd?(item.label, item.text, item.epoch == epoch ? "played" : "stopped") }
                playing = false
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
        epoch += 1
        for item in queue { item.ticket?.cancel() }
        queue = []
        current?.ticket?.cancel()
        current = nil
        output.stopPlayback()
        playing = false
        onChange?()
    }
}
