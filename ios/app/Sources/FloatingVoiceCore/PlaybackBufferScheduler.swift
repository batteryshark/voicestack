import Foundation

/// Production player backpressure. Capacity and EOF are different waits: the
/// former leaves a reserve; the latter must not finish a sentence prematurely.
/// Callbacks let an offline virtual player drive the exact same decisions.
@MainActor public final class PlaybackBufferScheduler {
    public struct Token: Hashable, Sendable { fileprivate let owner: UUID; fileprivate let value: Int }
    public static let highWater = 4
    private let lowWater: Int
    private let owner = UUID()
    private var next = 0
    private var pending: Set<Token> = []
    private var capacity: (() -> Void)?
    private var drain: (() -> Void)?
    private var started = false
    public private(set) var cancelled = false
    public var depth: Int { pending.count }
    public var hasStarted: Bool { started }
    public init(lowWater: Int = 1) {
        precondition((0..<Self.highWater).contains(lowWater))
        self.lowWater = lowWater
    }
    /// Same 200 ms maximum for whole PCM and arbitrarily small streaming chunks.
    public static func frameCount(bytes: Int, sampleRate: Int) -> Int {
        min(bytes / 2, sampleRate / 5)
    }
    public func schedule() -> Token? {
        guard !cancelled, depth < Self.highWater else { return nil }
        next += 1
        let token = Token(owner: owner, value: next); pending.insert(token)
        return token
    }
    /// The adapter calls player.play/onStart once, after its first real buffer.
    public func startIfNeeded() -> Bool {
        guard !cancelled, depth > 0, !started else { return false }
        started = true; return true
    }
    /// Duplicate, stopped and stale callbacks cannot decrement a new queue.
    @discardableResult public func played(_ token: Token) -> Bool {
        guard !cancelled, pending.remove(token) != nil else { return false }
        let capacityReady = depth <= lowWater ? capacity : nil
        if capacityReady != nil { capacity = nil }
        let drainReady = depth == 0 ? drain : nil
        if drainReady != nil { drain = nil }
        capacityReady?(); drainReady?()
        return true
    }
    public func whenCapacityAvailable(_ resume: @escaping () -> Void) {
        precondition(capacity == nil, "One producer per playback")
        // Registration may follow a completion that already reduced four to
        // three. Still wait for low water; never lose the earlier completion.
        if cancelled || depth <= lowWater { resume() } else { capacity = resume }
    }
    public func whenDrained(_ resume: @escaping () -> Void) {
        precondition(drain == nil, "One final drain per playback")
        if cancelled || depth == 0 { resume() } else { drain = resume }
    }
    public func cancel() {
        cancelled = true; pending.removeAll()
        let a = capacity, b = drain; capacity = nil; drain = nil
        a?(); b?()
    }
    public func waitForCapacity() async throws {
        try await wait(draining: false)
    }
    public func waitForDrain() async throws {
        try await wait(draining: true)
    }
    private func wait(draining: Bool) async throws {
        try Task.checkCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if draining { whenDrained { continuation.resume() } }
                else { whenCapacityAvailable { continuation.resume() } }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        try Task.checkCancellation()
        // Queue stop only releases the wait. The native epoch check must decide
        // recoverable Hold/repair versus terminal stop; do not erase that cause.
    }
}
