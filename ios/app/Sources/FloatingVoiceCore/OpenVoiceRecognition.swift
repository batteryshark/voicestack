import Foundation

/// Rational 3/2 causal windowed-sinc interpolator, mono s16le. 33 taps/phase,
/// Blackman-windowed 7.2 kHz low pass, unity DC per phase. Group delay 16 input
/// samples (1 ms). Zero startup padding and length-preserving end truncation;
/// not lossless. Only 33 input samples, one odd byte and rational phase persist.
/// Output count is floor(totalInputSamples * 3/2), independent of chunking.
public struct OpenVoiceInputConverter {
    private var history = [Double](repeating: 0, count: 34)
    private var inputCount = 0, outputCount = 0
    private var odd: UInt8?
    private var drained = false
    private static let phases: [[Double]] = (0..<3).map { phase in
        let fraction = Double(phase) / 3
        var taps = (0..<33).map { j -> Double in
            let x = Double(j) + fraction - 16
            let sinc = abs(x) < 1e-12 ? 0.9 : sin(Double.pi * 0.9 * x) / (Double.pi * x)
            let window = abs(x) > 16 ? 0 : 0.42 + 0.5 * cos(Double.pi * x / 16) + 0.08 * cos(2 * Double.pi * x / 16)
            return sinc * window
        }
        let sum = taps.reduce(0,+); for j in taps.indices { taps[j] /= sum }; return taps
    }
    public init() {}
    public mutating func append(_ data: Data) throws -> Data {
        try OpenVoiceWire.check(!drained && data.count <= 3200, "invalid_audio")
        var bytes = [UInt8](data), output = Data()
        if let b = odd { bytes.insert(b, at: 0); odd = nil }
        if bytes.count % 2 != 0 { odd = bytes.removeLast() }
        for i in stride(from: 0, to: bytes.count, by: 2) {
            history.removeLast(); history.insert(Double(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i+1]) << 8)), at: 0)
            inputCount += 1
            while outputCount < inputCount * 3 / 2 {
                let numerator = outputCount * 2
                let sourceIndex = numerator / 3, phase = numerator % 3
                let lag = inputCount - 1 - sourceIndex
                var value = 0.0
                for j in 0..<33 { value += history[j + lag] * Self.phases[phase][j] }
                let sample = Int16(max(-32768, min(32767, value.rounded())))
                let bits = UInt16(bitPattern: sample); output.append(UInt8(bits & 255)); output.append(UInt8(bits >> 8))
                outputCount += 1
            }
        }
        return output
    }
    /// Exactly once per fenced segment. No invented tail duration; odd PCM fails visibly.
    public mutating func drain() throws -> Data {
        try OpenVoiceWire.check(!drained && odd == nil, "invalid_audio"); drained = true; return Data()
    }
}

/// Adapter implements only RecognitionSession. Its client must be driven by a later
/// owner-controlled pump. All methods run on the main executor, like TurnTaker's
/// capture/composition owner; protocol entry points assert that executor explicitly.
public final class OpenVoiceRecognition: RecognitionSession {
    private let client: OpenVoiceClient
    private let callbacks: RecognitionCallbacks
    private let epoch = UUID()
    private var converter = OpenVoiceInputConverter()
    private var frame = Data()
    private var started = false, finishing = false, terminal = false
    private var committedItem: String?
    private let discardUnsentOnCancel: Bool
    private var waiting = false, finishAfterAcquire = false
    private var waitingPCM = Data()
    @MainActor public init(client: OpenVoiceClient, callbacks: RecognitionCallbacks, discardUnsentOnCancel: Bool = false) {
        self.client = client; self.callbacks = callbacks
        self.discardUnsentOnCancel = discardUnsentOnCancel
    }
    public var hasBufferedAudio: Bool { MainActor.assumeIsolated { !terminal && (!waitingPCM.isEmpty || !frame.isEmpty || (started && client.hasPendingInput)) } }
    public var isWarming: Bool { MainActor.assumeIsolated { waiting || client.state != .ready } }
    public func setCold(_ cold: Bool) {}
    public func prepareContinuation() {}
    public func finalBudget(ordinary: TimeInterval) async -> TimeInterval { ordinary }
    public func start() { MainActor.assumeIsolated { begin() } }
    @MainActor private func begin() {
        guard !started && !terminal else { return }
        do {
            if discardUnsentOnCancel {
                let admitted = try client.acquireCandidateSegment(epoch,ready:{ [weak self] in self?.activate() },failed:{ [weak self] in self?.finishFailure() })
                if !admitted { waiting = true; return }
            } else { try client.acquireSegment(epoch) }
            activate()
        } catch { finishFailure() }
    }
    @MainActor private func activate() {
        guard !terminal else { return }
        waiting = false; started = true
        client.recognitionEvent = { [weak self] e in self?.event(e) }
        client.recognitionFailure = { [weak self] in self?.finishFailure() }
        let pcm = waitingPCM; waitingPCM.removeAll()
        do {
            if !pcm.isEmpty { try accept(pcm,fromWaiting:true) }
            if finishAfterAcquire { finishAfterAcquire = false; end() }
        } catch { finishFailure(); client.abortSegment(epoch) }
    }
    public func write(_ pcm: Data) { MainActor.assumeIsolated {
        do { try accept(pcm) } catch { finishFailure(); client.abortSegment(epoch) }
    } }
    @MainActor public func writeBuffered(_ pcm: Data) async throws {
        try Task.checkCancellation()
        do { try accept(pcm); try await client.flush() }
        catch { finishFailure(); client.abortSegment(epoch); throw OpenVoiceFailure("local_failure") }
    }
    @MainActor private func accept(_ pcm: Data, fromWaiting: Bool = false) throws {
        try OpenVoiceWire.check((started || waiting) && !finishing && (!finishAfterAcquire || fromWaiting) && !terminal, "local_failure")
        // Reject an oversized producer batch; never allocate a segment-sized conversion buffer.
        try OpenVoiceWire.check(pcm.count <= 64_000, "invalid_audio")
        if waiting {
            try OpenVoiceWire.check(waitingPCM.count + pcm.count <= 64_000, "invalid_audio")
            waitingPCM.append(pcm); return
        }
        var offset = 0
        while offset < pcm.count {
            let end = min(pcm.count, offset + 640)
            frame.append(try converter.append(pcm.subdata(in: offset..<end))); offset = end
            try sendFrames(final: false)
        }
    }
    @MainActor private func sendFrames(final: Bool) throws {
        while frame.count >= 960 || (final && !frame.isEmpty) {
            let count = min(960,frame.count); try client.append(Data(frame.prefix(count)), owner: epoch); frame.removeFirst(count)
        }
    }
    public func end() { MainActor.assumeIsolated {
        if waiting && !terminal { finishAfterAcquire = true; return }
        guard started && !finishing && !terminal else { return }
        do { finishing = true; frame.append(try converter.drain()); try sendFrames(final: true); try client.commit(epoch) }
        catch { finishFailure(); client.abortSegment(epoch) }
    } }
    public func cancel() { MainActor.assumeIsolated {
        guard !terminal else { return }
        if discardUnsentOnCancel {
            terminal = true; frame.removeAll(); waitingPCM.removeAll()
            if waiting { client.cancelWaitingSegment(epoch); waiting = false }
            else if started {
                do { try client.retireUnsentSegment(epoch) } catch { client.fail() }
            }
            callbacks.done("") // explicit discard, no manufactured recognition success/words
        } else { finishFailure(); client.abortSegment(epoch) }
    } }
    @MainActor private func event(_ e: OpenVoiceEvent) {
        guard started && !terminal else { return }
        if e.kind == .committed {
            guard finishing && committedItem == nil else { finishFailure(); client.abortSegment(epoch); return }
            committedItem = e["item_id"].string
        }
        if e.kind == .transcriptionCompleted || e.kind == .transcriptionFailed {
            guard finishing && committedItem != nil && committedItem == e["item_id"].string else { return }
            if e.kind == .transcriptionFailed { finishFailure() }
            else { finishSuccess(e["transcript"].string!) }
        }
    }
    @MainActor private func detach() {
        frame.removeAll(); waitingPCM.removeAll(); client.recognitionEvent = nil; client.recognitionFailure = nil; client.releaseSegment(epoch)
    }
    @MainActor private func finishSuccess(_ text: String) {
        guard !terminal else { return }; terminal = true; detach(); callbacks.done(text)
    }
    @MainActor private func finishFailure() {
        guard !terminal else { return }; terminal = true
        if waiting { client.cancelWaitingSegment(epoch); waiting = false; waitingPCM.removeAll() }
        // Do not detach another adapter if acquisition failed.
        if started { client.fail(origin: .recognition); detach() }
        callbacks.error(OpenVoiceFailure("local_failure")); callbacks.done("")
    }
}
