import Foundation

/// Transient routing identity only; never logs interface names, addresses or SSIDs.
/// Ordered candidates are filtered to types NWPath reports using, not all
/// inventory. Type usage/ranking is a routing proxy, not per-socket ownership.
public struct NetworkPathSnapshot: Equatable, Sendable {
    public enum Kind: Hashable, Sendable { case wifi, cellular, wiredEthernet, loopback, other }
    public struct Interface: Hashable, Sendable {
        public let kind: Kind
        public let index: Int
        public init(_ kind: Kind, index: Int) { self.kind = kind; self.index = index }
    }
    public let satisfied: Bool
    public let interfaces: Set<Interface>
    public let primary: Interface?
    public init(satisfied: Bool, usedInterfaces: [Interface]) {
        self.satisfied = satisfied; interfaces = Set(usedInterfaces); primary = usedInterfaces.first
    }
}

/// Satisfied callbacks are notifications, not proof that a working SSE is stale.
/// Meaningful handovers still retire the old socket promptly; same-interface
/// failures remain bounded by transport errors and the existing idle watchdog.
public struct EventPathPolicy {
    public enum Action: Equatable { case none, wakeRetry, reconnect }
    private var previous: NetworkPathSnapshot?
    public init() {}
    public mutating func observe(_ path: NetworkPathSnapshot) -> Action {
        let old = previous; previous = path
        if !path.satisfied { return old?.satisfied == false ? .none : .reconnect }
        guard let old, old.satisfied else { return .wakeRetry }
        if old.interfaces != path.interfaces || old.primary != path.primary { return .reconnect }
        return .wakeRetry
    }
}

public struct StreamIdleWatchdog {
    private var lastByte: TimeInterval
    public init(now: TimeInterval) { lastByte = now }
    public mutating func received(now: TimeInterval) { lastByte = now }
    public func age(now: TimeInterval) -> TimeInterval { max(0, now - lastByte) }
    public func expired(now: TimeInterval) -> Bool { now - lastByte >= 75 }
}

/// Clock-independent policy; transports supply monotonic seconds.
public struct ReconnectBackoff {
    private var failures = 0
    public init() {}
    public mutating func next(healthyFor seconds: TimeInterval, jitter: Double) -> TimeInterval {
        if seconds >= 30 { failures = 0 }
        let base = [1.0, 2, 4, 8, 15][min(failures, 4)]
        failures = min(failures + 1, 4)
        return base * (0.8 + 0.4 * min(1, max(0, jitter)))
    }
}

public struct PingWatchdog {
    private var lastPing: TimeInterval
    private var awaiting: TimeInterval?
    public init(now: TimeInterval) { lastPing = now }
    public enum Action { case none, ping, timeout }
    public mutating func tick(now: TimeInterval) -> Action {
        if let awaiting { return now - awaiting >= 10 ? .timeout : .none }
        guard now - lastPing >= 20 else { return .none }
        lastPing = now; awaiting = now; return .ping
    }
    public mutating func pong() { awaiting = nil }
}

public struct PCMSendBudget {
    private var count = 0, bytes = 0
    public init() {}
    public mutating func reserve(_ size: Int) -> Bool {
        guard size >= 0, count < 100, size <= 64000 - bytes else { return false }
        count += 1; bytes += size; return true
    }
    public mutating func release(_ size: Int) { count = max(0, count - 1); bytes = max(0, bytes - size) }
}

/// Stop only at the newest *previously known* message, never an arbitrary
/// overlapping old record. Ten 40-message pages bound catch-up work/memory.
public struct HistoryCatchUp {
    public let boundary: String?
    public private(set) var complete = false
    public private(set) var pages = 0
    private var cursors = Set<String>()
    public init(boundary: String?) { self.boundary = boundary }
    public mutating func accept(ids: [String], next: String?) -> Bool {
        pages += 1
        complete = boundary == nil || ids.contains(boundary!) || next == nil
        guard !complete, pages < 10, let next, cursors.insert(next).inserted else { return false }
        return true
    }
}
