import Foundation

public enum NotificationRoutePhase: String, Codable, Sendable {
    case received, lookup, prepare, select, catchUp, message, present, viewport, receipt
}
/// Closed metadata only: no reach-out IDs, session IDs, message text or raw errors.
public enum NotificationRouteFailure: String, Codable, Error, Sendable {
    case invalidContext, preparation, targetChanged, catchUpTimeout, messageUnavailable, olderPageLimit
    case inactive, cancelled, network, http, other, viewportTimeout
    public static func classify(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if error is CancellationError { return .cancelled }
        if error is URLError { return .network }
        if case HTTPError.status = error { return .http }
        return .other
    }
}

@MainActor public enum NotificationRouting {
    public static func step<T>(_ phase: NotificationRoutePhase, diagnostics: StageDiagnostics = .shared,
                               _ action: () async throws -> T) async throws -> T {
        let began = Date()
        diagnostics.record(.notificationRoute, .begin, routePhase: phase)
        do {
            let value = try await action()
            diagnostics.record(.notificationRoute, .complete, since: began, routePhase: phase)
            return value
        } catch {
            diagnostics.record(.notificationRoute, .failed, since: began, status: StageDiagnostics.code(error),
                               routePhase: phase, routeFailure: .classify(error))
            throw error
        }
    }
}

/// A cold-start response may precede active/protected data/model readiness.
/// Keep it until drain is allowed; concurrent foreground/delegate drains cannot duplicate it.
@MainActor public final class NotificationTapQueue {
    public struct Tap: Equatable, Sendable {
        public let id: String
        public let category: String
        public init(id: String, category: String) { self.id = id; self.category = category }
    }
    private var pending: Tap?
    private var draining = false
    public init() {}
    public func enqueue(_ tap: Tap) { pending = tap }
    public func drain(ready: () -> Bool, route: (Tap) async throws -> Void) async throws {
        guard !draining, ready() else { return }
        draining = true; defer { draining = false }
        while ready(), let tap = pending {
            pending = nil
            try await route(tap)
        }
    }
}
