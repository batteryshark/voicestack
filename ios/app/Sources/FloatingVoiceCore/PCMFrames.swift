import Foundation

/// Shared headless-testable framing boundary after AVAudioConverter's hardware conversion.
public struct PCMFrames {
    private var carry = Data()
    public init() {}
    public mutating func push(_ pcm: Data) -> [Data] {
        carry.append(pcm)
        var frames: [Data] = []
        while carry.count >= 640 { frames.append(Data(carry.prefix(640))); carry = Data(carry.dropFirst(640)) }
        return frames
    }
    public mutating func reset() { carry.removeAll(keepingCapacity: true) }
    public static func monoS16(_ channels: [[Float]]) -> Data {
        guard let count = channels.first?.count, !channels.isEmpty, channels.allSatisfy({ $0.count == count }) else { return Data() }
        var bytes = Data()
        for i in 0..<count {
            let sample = channels.reduce(Float(0)) { $0 + $1[i] } / Float(channels.count)
            let safe = sample.isFinite ? max(-1, min(1, sample)) : 0
            let value = Int16(clamping: Int((safe * 32767).rounded()))
            bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return bytes
    }
}
