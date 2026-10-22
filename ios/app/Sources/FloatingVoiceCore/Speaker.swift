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

/// Converted and owner-eligible 20-ms blocks, not RMS or speech recognition.
/// Used only by the candidate's capture-path watchdog; quiet PCM is progress.
public struct CaptureProgress {
    public let producedFrames: Int, deliveredFrames: Int
    public init(producedFrames: Int, deliveredFrames: Int) {
        self.producedFrames = producedFrames; self.deliveredFrames = deliveredFrames
    }
}
@MainActor public protocol CaptureProgressReporting: AudioInput {
    var captureProgress: CaptureProgress { get }
}

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
    struct Item { let text: String; let label: String; let epoch: Int; var ticket: SpeechTicket?; var retries = 0; var prepared = false; var hold = false; var holdEnd: ((Bool) -> Void)?; var cue = false
        /// Local comfort audio: no captions, no reply semantics, no error surface.
        var local: Bool { hold || cue }
    }

    private let synth: SpeechSynthesizer
    private let output: AudioOutput
    private let onError: (Error) -> Void
    private var queue: [Item] = []
    private var current: Item?
    private var pump: Task<Void, Never>?
    private(set) var epoch = 0
    public private(set) var playing = false
    private var paused = false
    private var automaticCutInPaused = false
    private var repairGeneration = 0
    /// Called when playing/queued state changes (status line).
    public var onChange: (() -> Void)?
    /// Called when a sentence starts playing (captions in later milestones; logs now).
    public var onSentence: ((String, String) -> Void)?
    /// Called when a sentence that started playing ends: (label, text, "played" | "stopped" | "failed").
    public var onSentenceEnd: ((String, String, String) -> Void)?
    public var onReplyEnqueue: (() -> Void)?
    public var isHolding: Bool { current?.hold == true || queue.contains { $0.hold } }
    public func enqueueHold(_ ticket: SpeechTicket, completion: ((Bool) -> Void)? = nil) {
        guard !active, !paused else { ticket.cancel(); return }
        queue.append(Item(text:"",label:"hold-music",epoch:epoch,ticket:ticket,prepared:true,hold:true,holdEnd:completion))
        startPump(); onChange?()
    }
    public func stopHold() { if isHolding { stop() } }
    /// Chief reply audio that automatic cut-in may duck/pause; never hold music or a pickup cue.
    public var playingReply: Bool { playing && current?.local != true }
    public var cuePlaying: Bool { current?.cue == true }

    /// Same synth as replies, fully buffered before it can play.
    public func prepareCue(_ text: String) -> SpeechTicket { BufferedCueTicket(synth.prepare(text)) }
    /// A pickup cue: plays through the normal output, is NOT a reply (no onReplyEnqueue,
    /// no captions), and replies queue behind it. `ended` runs once it finishes in this epoch.
    public func enqueueCue(_ ticket: SpeechTicket, label: String = "pickup-cue", ended: ((Bool) -> Void)? = nil) {
        guard !paused, queue.count < 128 else { ticket.cancel(); return }
        stopHold()
        queue.append(Item(text:ticket.text,label:label,epoch:epoch,ticket:ticket,prepared:true,holdEnd:ended,cue:true))
        startPump(); onChange?()
    }

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

    public func duckForAutomaticCutIn(_ ducked: Bool) {
        (output as? AutomaticCutInOutput)?.setCutInGain(ducked ? AutomaticCutInTuning.duckGain : 1)
    }
    @discardableResult public func commitAutomaticCutIn() -> Bool {
        guard playing, let reversible = output as? AutomaticCutInOutput else { return false }
        automaticCutInPaused = true; paused = true
        return reversible.pauseForAutomaticCutIn()
    }
    public func restoreAutomaticCutIn(ducked: Bool = false) {
        duckForAutomaticCutIn(ducked)
        if automaticCutInPaused {
            do { try (output as? AutomaticCutInOutput)?.resumeAfterAutomaticCutIn() }
            catch { onError(error) }
            automaticCutInPaused = false; paused = false
            startPump()
        }
    }
    public func cancelAutomaticCutIn() {
        automaticCutInPaused = false
        duckForAutomaticCutIn(false)
    }

    public func enqueue(_ text: String, label: String = "") {
        onReplyEnqueue?()
        stopHold()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard queue.count < 128 else { onError(ClientError("Speech queue full")); return }
        queue.append(Item(text: text, label: label, epoch: epoch, ticket: nil))
        if current == nil && queue.count == 1 { queue[0].ticket = synth.prepare(text) }
        startPump()
        onChange?()
    }
    /// Already generated media. Never routes received text back through synthesis.
    public func enqueuePrepared(_ ticket: SpeechTicket, label: String) {
        onReplyEnqueue?()
        stopHold()
        guard queue.count < 128 else { ticket.cancel(); onError(ClientError("Speech queue full")); return }
        queue.append(Item(text:ticket.text,label:label,epoch:epoch,ticket:ticket,prepared:true))
        startPump(); onChange?()
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
        if !queue.isEmpty && queue[0].ticket == nil && !queue[0].prepared { queue[0].ticket = synth.prepare(queue[0].text) }
    }

    private func run() async {
        while !queue.isEmpty && !paused {
            var item = queue.removeFirst()
            var holdSucceeded = false
            if item.ticket == nil && !item.prepared { item.ticket = synth.prepare(item.text) }
            current = item
            let repair = repairGeneration
            defer { if current?.epoch == item.epoch && current?.text == item.text { current = nil } }
            do {
                let audio: SpeechAudio
                do {
                    guard let ticket = item.ticket else { throw ClientError("Prepared speech unavailable; no replay") }
                    audio = try await ticket.audio()
                }
                catch {
                    if repair != repairGeneration { throw PlaybackInterruption.recoverable }
                    throw error
                }
                guard item.epoch == epoch else { continue }
                if repair != repairGeneration { throw PlaybackInterruption.recoverable }
                if paused {
                    if item.cue { item.ticket?.cancel(); break }
                    if !item.prepared { item.ticket?.cancel(); item.ticket = nil }
                    queue.insert(item, at: 0); break
                }
                // Headers are in: fetch the next sentence while this one plays.
                prepareNext()
                playing = true
                onChange?()
                var started = false
                do {
                    try await output.play(audio, label: item.label) { [weak self] in
                        guard let self, item.epoch == self.epoch else { return }
                        started = true
                        if !item.local { self.onSentence?(item.label, item.text) }
                    }
                } catch PlaybackInterruption.recoverable {
                    if started && !item.local { onSentenceEnd?(item.label, item.text, "interrupted") }
                    throw PlaybackInterruption.recoverable
                } catch {
                    if repair != repairGeneration, item.epoch == epoch {
                        if started && !item.local { onSentenceEnd?(item.label, item.text, "interrupted") }
                        throw PlaybackInterruption.recoverable
                    }
                    if started && !item.local { onSentenceEnd?(item.label, item.text, item.epoch == epoch ? "failed" : "stopped") }
                    throw error
                }
                if started && !item.local { onSentenceEnd?(item.label, item.text, item.epoch == epoch ? "played" : "stopped") }
                holdSucceeded = true
                playing = false
            } catch PlaybackInterruption.recoverable {
                playing = false
                item.ticket?.cancel()
                if item.prepared {
                    if item.local { if item.epoch == epoch { item.holdEnd?(false) }; onChange?(); continue }
                    if item.epoch == epoch { onError(ClientError("Prepared speech interrupted; delivery unknown, no replay")) }
                    onChange?(); continue
                }
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
                if !item.local && item.epoch == epoch && !(error is CancellationError) && (error as? URLError)?.code != .cancelled { onError(error) }
            }
            if item.local && item.epoch == epoch { item.holdEnd?(holdSucceeded) }
            onChange?()
        }
        current = nil
        onChange?()
    }

    /// Stop playback and drop everything queued or being fetched.
    public func stop() {
        cancelAutomaticCutIn()
        paused = false
        epoch += 1
        let prepared = current?.prepared == true
        if prepared { output.stopPlayback() } // sample native cursor BEFORE invalidating its ticket observer
        for item in queue { item.ticket?.cancel() }
        queue = []
        current?.ticket?.cancel()
        current = nil
        if !prepared { output.stopPlayback() }
        playing = false
        onChange?()
    }

    /// Keep sentence position and queued text. Native output invalidates playback as recoverable.
    /// A queued pickup cue is never replayed after a pause/route recovery.
    public func pause() {
        paused = true
        queue.removeAll { if $0.cue { $0.ticket?.cancel(); return true }; return false }
    }
    public func resume() { paused = false; startPump() }
}

/// Collects the whole synthesized cue as soon as it is prepared, so playback never waits on the network.
final class BufferedCueTicket: SpeechTicket {
    let text: String
    private let inner: SpeechTicket
    private var work: Task<SpeechAudio, Error>!
    init(_ inner: SpeechTicket) {
        self.inner = inner; text = inner.text
        work = Task { @MainActor in
            let audio = try await inner.audio()
            var pcm = Data()
            for try await chunk in audio.chunks { pcm.append(chunk); try Task.checkCancellation() }
            guard !pcm.isEmpty else { throw ClientError("Empty cue audio") }
            return .whole(pcm, sampleRate: audio.sampleRate, diagnosticAttempt: audio.diagnosticAttempt)
        }
    }
    func audio() async throws -> SpeechAudio { try await work.value }
    func cancel() { work.cancel(); inner.cancel() }
}
