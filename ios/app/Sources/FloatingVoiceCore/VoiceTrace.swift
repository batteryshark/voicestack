import Foundation

/// Opt-in observation seam. No sink in ordinary launches; never changes audio or delivery.
public final class VoiceTrace: @unchecked Sendable {
    public static let shared = VoiceTrace()
    private let lock = NSLock()
    private var sink: (@Sendable (String, [String: String]) -> Void)?
    public func configure(_ sink: @escaping @Sendable (String, [String: String]) -> Void) {
        lock.lock(); defer { lock.unlock() }; self.sink = sink
    }
    public func event(_ name: String, _ fields: [String: String] = [:]) {
        lock.lock(); let emit = sink; lock.unlock(); emit?(name, fields)
    }
}
