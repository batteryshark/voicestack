import Foundation

/// Headless playback: records each sentence's PCM to one WAV and logs start/stop/end with timestamps. Plays in
/// real time (returns after the audio's duration), so barge-in and Stop land mid-sentence as they would on speakers.
@MainActor
public final class FileAudioOutput: AudioOutput, LevelReporting {
    /// Playback level as the recording "plays" (RMS of the last 40 ms at the current play position).
    public var onLevel: ((Double) -> Void)?
    public struct Record: Sendable {
        public let label: String
        public let started: Double
        public var ended: Double?
        public var seconds: Double
        /// "played" | "stopped"
        public var outcome: String
    }

    public private(set) var records: [Record] = []
    private let wavPath: String?
    private let log: (String) -> Void
    private let clock: () -> Double
    private var pcm = Data()
    private var rate = 24000
    private var generation = 0

    public init(wavPath: String?, clock: @escaping () -> Double, log: @escaping (String) -> Void) {
        self.wavPath = wavPath; self.clock = clock; self.log = log
    }

    public func play(_ audio: SpeechAudio, label: String, onStart: @escaping () -> Void) async throws {
        let gen = generation
        let start = clock()
        rate = audio.sampleRate
        var bytes = 0
        var sentence = Data()
        var index: Int?
        func finish(_ outcome: String) {
            guard let i = index else { return }
            records[i].ended = clock()
            records[i].seconds = Double(bytes) / 2 / Double(audio.sampleRate)
            records[i].outcome = outcome
            log(String(format: "playback %@ [%@] %.2fs of audio, %.2fs wall", outcome, label, records[i].seconds, (clock() - start) / 1000))
        }
        do {
            for try await chunk in audio.chunks {
                if gen != generation { finish("stopped"); return }
                if index == nil {
                    records.append(Record(label: label, started: start, ended: nil, seconds: 0, outcome: "playing"))
                    index = records.count - 1
                    onStart()
                }
                bytes += chunk.count
                pcm.append(chunk)
                sentence.append(chunk)
            }
        } catch {
            // Stopping cancels the speech request, which ends its stream with an error.
            if gen != generation { finish("stopped"); return }
            throw error
        }
        // Wait out the rest of the audio's duration in real time, unless stopped.
        let duration = Double(bytes) / 2 / Double(audio.sampleRate) * 1000
        while clock() - start < duration {
            if gen != generation { finish("stopped"); return }
            if let onLevel {
                let end = min(sentence.count, Int((clock() - start) / 1000 * Double(audio.sampleRate)) * 2)
                let begin = max(0, end - audio.sampleRate / 25 * 2)
                if end > begin { onLevel(TurnTaker.rms(sentence.subdata(in: begin..<end))) }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        onLevel?(0)
        if gen != generation { finish("stopped"); return }
        finish("played")
    }

    public func stopPlayback() { generation += 1 }

    public func writeWAV() {
        guard let wavPath else { return }
        try? WAV.encode(pcm, sampleRate: rate).write(to: URL(fileURLWithPath: wavPath))
    }
}

/// Headless microphone: emits 20 ms frames of 16 kHz s16le in real time, silence unless an utterance is injected.
@MainActor
public final class FileAudioInput: AudioInput {
    public var onPCM: ((Data) -> Void)?
    public var onFailure: ((Error) -> Void)?
    private var pending = Data()
    /// A steady noise bed (white noise at this RMS) under everything the "mic" hears, speech and pauses alike.
    public var noiseRMS = 0.0
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var loop: Task<Void, Never>?
    private var started = 0.0
    private var sent = 0
    private let log: (String) -> Void
    public private(set) var running = false

    public init(log: @escaping (String) -> Void) { self.log = log }

    public func start() async throws {
        running = true
        started = Date().timeIntervalSince1970
        sent = 0
        loop = Task { @MainActor [weak self] in
            while let self, self.running, !Task.isCancelled {
                self.tick()
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    /// Queue 16 kHz mono s16le speech to be "heard" from now on.
    public func inject(_ pcm16k: Data, label: String) {
        log(String(format: "mic input: injecting \"%@\" (%.2fs)", label, Double(pcm16k.count) / 32000))
        pending.append(pcm16k)
    }

    public var injecting: Bool { !pending.isEmpty }

    private func tick() {
        // Catch up by wall clock so timer jitter does not slow the stream.
        let due = Int((Date().timeIntervalSince1970 - started) * 50)
        while sent < due {
            sent += 1
            var frame: Data
            if pending.count >= 640 { frame = pending.prefix(640); pending = Data(pending.dropFirst(640)) }
            else { frame = pending + Data(count: 640 - pending.count); pending = Data() }
            onPCM?(noiseRMS > 0 ? withNoise(Data(frame)) : Data(frame))
        }
    }

    /// Add the noise bed to a 20 ms frame (uniform samples: RMS = amplitude / sqrt 3; fixed seed, so runs repeat).
    private func withNoise(_ frame: Data) -> Data {
        let amplitude = noiseRMS * 3.0.squareRoot() * 32768
        var out = Data(count: frame.count)
        frame.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                let s = src.bindMemory(to: Int16.self), d = dst.bindMemory(to: Int16.self)
                for i in 0..<s.count {
                    rng = rng &* 6364136223846793005 &+ 1442695040888963407
                    let u = Double(rng >> 11) / Double(1 << 53) * 2 - 1
                    d[i] = Int16(clamping: Int((Double(Int16(littleEndian: s[i])) + u * amplitude).rounded()))
                }
            }
        }
        return out
    }

    public func stop() {
        loop?.cancel(); loop = nil
        running = false
        log("mic input released")
    }
}
