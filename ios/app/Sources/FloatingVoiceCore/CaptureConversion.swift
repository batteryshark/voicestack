import AVFoundation
import Foundation

/// Accessed only on the serial audio tap callback. AVAudioConverter handles actual hardware
/// rates/channels with stateful resampling rather than restarting interpolation each callback.
final class CaptureConversion: @unchecked Sendable {
#if DEBUG && (targetEnvironment(simulator) || os(macOS))
    /// Owned recorded source only. The returned buffer enters the same production converter.
    /// Do not read AVAudioFile again at EOF: Core Audio can return eofErr (-39).
    static func fixtureBuffer(_ file: AVAudioFile, capacity: AVAudioFrameCount = 960) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { throw ClientError("Fixture allocation failed") }
        if file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), file.length - file.framePosition)))
        }
        if buffer.frameLength == 0 {
            buffer.frameLength = capacity
            for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
            }
        }
        return buffer
    }
#endif
    let converter: AVAudioConverter
    let target: AVAudioFormat
    private var frames = PCMFrames()
    init(converter: AVAudioConverter, target: AVAudioFormat) {
        self.converter = converter; self.target = target
        // Defined downmix rather than selecting just one hardware channel.
        converter.downmix = true
    }
    func convert(_ input: AVAudioPCMBuffer) throws -> [Data] {
        guard input.frameLength > 0, input.format.isEqual(converter.inputFormat) else { throw ClientError("Capture input format changed; restart required") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw ClientError("Capture allocation failed") }
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard status != .error else { throw ClientError("Hardware conversion failed") }
        let audio = output.audioBufferList.pointee.mBuffers
        guard let data = audio.mData else { return [] }
        return frames.push(Data(bytes: data, count: Int(output.frameLength) * 2))
    }
}

/// One converter/framer per capture owner, derived from the actual first buffer, not a
/// pre-start node-format snapshot. Invalidation fences late callbacks and discards carry.
final class CaptureIngress: @unchecked Sendable {
    struct Counts {
        var callbacks = 0, hardwareCallbacks = 0, validBuffers = 0, inputFrames = 0, frames = 0
        var conversionErrors = 0, formatChanges = 0
        var rms = 0.0
        var format: AVAudioFormat?
        var ready: Bool { frames > 0 }
        var failureCode: Int { callbacks == 0 ? 1 : (validBuffers == 0 ? 2 : 3) }
        var failureMessage: String {
            switch failureCode {
            case 1: return "Microphone supplied no tap callbacks within 5 seconds"
            case 2: return "Microphone callbacks supplied no valid input frames within 5 seconds"
            default: return "Microphone input arrived but conversion supplied no complete PCM frames within 5 seconds"
            }
        }
    }
    private let lock = NSLock()
    private var active = true
    private var conversion: CaptureConversion?
    private let speechEpoch = CaptureEpoch()
    private var counts = Counts()
    func invalidate() { lock.lock(); defer { lock.unlock() }; active = false; conversion = nil }
    func snapshot() -> Counts { lock.lock(); defer { lock.unlock() }; return counts }
    var speechGeneration: Int { speechEpoch.current }
    func admitsSpeech(_ epoch: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return active && epoch == speechEpoch.current }
    /// Keep the capture graph live, but retire queued deliveries and converter/framer carry together.
    func discardPendingAudio() {
        lock.lock(); defer { lock.unlock() }
        speechEpoch.advance(); conversion = nil
    }
    func consume(_ buffer: AVAudioPCMBuffer, hardware: Bool, speechGeneration: Int? = nil) throws -> [Data] {
        lock.lock(); defer { lock.unlock() }
        guard active else { return [] }
        if let speechGeneration, speechGeneration != speechEpoch.current { return [] }
        counts.callbacks += 1
        if hardware { counts.hardwareCallbacks += 1 }
        counts.format = buffer.format
        guard buffer.frameLength > 0, buffer.format.sampleRate.isFinite,
              buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else { return [] }
        counts.validBuffers += 1; counts.inputFrames += Int(buffer.frameLength)
        if conversion == nil {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: buffer.format, to: target) else { throw ClientError("Unsupported actual microphone format") }
            conversion = CaptureConversion(converter: converter, target: target)
        }
        if !buffer.format.isEqual(conversion!.converter.inputFormat) { counts.formatChanges += 1 }
        let frames: [Data]
        do { frames = try conversion!.convert(buffer) }
        catch { counts.conversionErrors += 1; throw error }
        counts.frames += frames.count
        if let last = frames.last { counts.rms = TurnTaker.rms(last) }
        return frames
    }
}
