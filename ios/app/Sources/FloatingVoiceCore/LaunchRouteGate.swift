import Foundation

/// A launch probe may mount before the scene is active or startup owns a backend.
/// Wait without starting another preparation. Claim once before the first await:
/// SwiftUI task remounts, cancellation and route failure must never replay a route.
@MainActor public final class LaunchRouteGate {
    public struct Readiness {
        public var active: Bool, unlocked: Bool, paired: Bool, preparing: Bool, hasBackend: Bool, hasCall: Bool
        public init(active: Bool, unlocked: Bool, paired: Bool, preparing: Bool, hasBackend: Bool, hasCall: Bool) {
            self.active = active; self.unlocked = unlocked; self.paired = paired
            self.preparing = preparing; self.hasBackend = hasBackend; self.hasCall = hasCall
        }
        public var ready: Bool { active && unlocked && paired && !preparing && hasBackend && !hasCall }
    }
    public private(set) var claimed = false
    public init() {}
    @discardableResult public func run(timeout: TimeInterval = 30,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: () async throws -> Void = { try await Task.sleep(nanoseconds: 50_000_000) },
        readiness: () -> Readiness, route: () async throws -> Void) async throws -> Bool {
        guard !claimed else { return false }
        claimed = true
        let deadline = now() + timeout
        while true {
            try Task.checkCancellation()
            let state = readiness()
            guard !state.hasCall else { throw NotificationRouteFailure.targetChanged }
            if state.ready { break }
            guard now() < deadline else { throw NotificationRouteFailure.preparation }
            try await sleep()
        }
        try Task.checkCancellation()
        try await route()
        return true
    }
}
