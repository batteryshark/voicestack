import Foundation

/// The ambient noise level of the room, from 20 ms frame RMS values, so a fixed threshold does not mistake a fan, a
/// noisy webcam mic or a TV for speech (which keeps an utterance "voiced" and its pause timer from ever running out).
///
/// - It is a low percentile (10th) of the last ~5 s of non-speech frames: speech and the odd bump do not raise it.
/// - It falls quickly (a quieter room is believed within a second) and rises slowly (about 2 s time constant), and only
///   from frames outside an utterance. Inside an utterance it can only sink, from the quiet gaps between words.
/// - The first ~1 s after Start is calibration: the floor follows the percentile directly, up or down.
public struct NoiseFloor: Sendable {
    public static let windowFrames = 250
    public static let calibrationFrames = 50
    /// Too few frames say nothing about the room (the first moments might be speech): the floor stays 0 until this many.
    static let minCalibrationFrames = 15
    /// The floor is recomputed every this many frames (100 ms).
    static let stepFrames = 5
    static let percentile = 0.10
    static let fall = 0.5
    static let rise = 0.05
    static let inUtteranceFall = 0.05
    /// Never above this: a very loud start (speaking during calibration) must not deafen the threshold.
    public static let maxFloor = 0.04

    public private(set) var value = 0.0
    private var ring: [Double] = []
    private var seen = 0

    public init() {}

    public var calibrating: Bool { seen < Self.calibrationFrames }

    /// Feed one frame's RMS. `inUtterance`: an utterance is open (the frame is speech or a pause inside it).
    /// `learnNoise`: the sound inside it has not dipped for a long time, so it is noise, not speech: the floor may rise.
    public mutating func add(_ rms: Double, inUtterance: Bool, learnNoise: Bool = false) {
        if inUtterance && !learnNoise {
            if rms < value { value += (rms - value) * Self.inUtteranceFall }
            return
        }
        ring.append(rms)
        if ring.count > Self.windowFrames { ring.removeFirst() }
        seen += 1
        guard seen % Self.stepFrames == 0 else { return }
        let target = Self.lowPercentile(ring)
        if calibrating {
            if seen >= Self.minCalibrationFrames { value = target }
        } else if target < value {
            value += (target - value) * Self.fall
        } else {
            value += (target - value) * Self.rise
        }
        value = min(value, Self.maxFloor)
    }

    /// Sound that was confirmed to be noise (an utterance with no words): take its level as the floor at once, and
    /// remember it for the window, so the noise stops counting as voice.
    public mutating func learn(level: Double) {
        let l = min(level, Self.maxFloor)
        value = max(value, l)
        ring = [Double](repeating: l, count: Self.windowFrames)
        seen = max(seen, Self.calibrationFrames)
    }

    static func lowPercentile(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * percentile))]
    }

    /// The level a frame must exceed to count as voice: the fixed threshold, or the floor times `factor`, whichever
    /// is higher.
    public func threshold(base: Double, factor: Double) -> Double { max(base, value * factor) }
}

public enum Sensitivity: String, Sendable, CaseIterable {
    case low, normal, high

    /// Multiplier of the noise floor for the voiced threshold: low hears less (a higher threshold in noise).
    public var factor: Double {
        switch self {
        case .low: return 3.0
        case .normal: return 2.0
        case .high: return 1.4
        }
    }
}
