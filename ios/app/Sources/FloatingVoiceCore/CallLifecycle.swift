import Foundation

/// Separate from capture/graph generations. Async callbacks must carry the call epoch.
@MainActor public final class CallLifecycle {
    public enum State: String { case idle, starting, ringing, connecting, active, held, ending, ended }
    public private(set) var state: State = .idle
    public private(set) var epoch = 0
    public private(set) var id: UUID?
    public private(set) var target: TargetLease?
    public private(set) var activationGranted = false
    public private(set) var muted = false
    public var hasCall: Bool { ![.idle, .ending, .ended].contains(state) }
    public var mayRunMedia: Bool { [.connecting, .active].contains(state) && activationGranted }
    public init() {}
    @discardableResult public func begin(target: TargetLease, id: UUID = UUID()) -> Int? {
        guard !hasCall else { return nil }
        epoch += 1; self.id = id; self.target = target; state = .starting
        activationGranted = false; muted = false
        return epoch
    }
    public func admits(_ owner: Int) -> Bool { hasCall && epoch == owner }
    @discardableResult public func incoming(id: UUID) -> Int? {
        guard !hasCall else { return nil }
        epoch += 1; self.id = id; target = nil; state = .ringing
        activationGranted = false; muted = false
        return epoch
    }
    public func bindIncoming(_ target: TargetLease, owner: Int) -> Bool {
        guard admits(owner), state == .ringing else { return false }
        self.target = target; state = .connecting; return true
    }
    @discardableResult public func connecting(_ owner: Int) -> Bool {
        guard admits(owner), state == .starting else { return false }
        state = .connecting; return true
    }
    @discardableResult public func activate(_ owner: Int) -> Bool {
        guard admits(owner), state != .held else { return false }
        activationGranted = true; return mayRunMedia
    }
    public func deactivate() { activationGranted = false }
    @discardableResult public func ready(_ owner: Int) -> Bool {
        guard admits(owner), mayRunMedia else { return false }
        state = .active; return true
    }
    @discardableResult public func hold(_ value: Bool, owner: Int) -> Bool {
        guard admits(owner), (state == .held) != value else { return false }
        activationGranted = false // neither Hold nor Unhold is a CallKit activation grant
        state = value ? .held : .connecting; return true
    }
    @discardableResult public func mute(_ value: Bool, owner: Int) -> Bool {
        guard admits(owner), muted != value else { return false }
        muted = value; return true
    }
    /// Fence first. End/reset/timeout converge without duplicate cleanup.
    @discardableResult public func end(_ owner: Int) -> Bool {
        guard admits(owner) else { return false }
        state = .ending; activationGranted = false; epoch += 1
        state = .ended; return true
    }
}
