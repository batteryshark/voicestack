import Foundation

public enum RouteRecoverySource: String, Codable, Sendable { case unexpected, appToggle, systemChoice, retry, initialPreference }
public struct RouteRecoveryContext: Codable, Sendable, Equatable {
    public let generation: Int
    public let source: RouteRecoverySource
    public let route: PhoneAudioRoute
    public var deliberate: Bool { source != .unexpected }
}

/// Short, exact-route tickets, scoped to one call. A toggle request is NOT proof:
/// only a matching notification can give its graph repair a deliberate ticket.
public struct RouteRecoveryTracker {
    private struct Ticket {
        let context: RouteRecoveryContext
        let until: TimeInterval
    }
    private var next = 0
    private var expected: Ticket?
    private var matched: Ticket?
    private var lastRoute: PhoneAudioRoute = .external
    private var builtInOverrideObserved = false
    public init() {}
    public mutating func begin(route: PhoneAudioRoute) { expected = nil; matched = nil; lastRoute = route; builtInOverrideObserved = false }
    private mutating func make(_ source: RouteRecoverySource, _ route: PhoneAudioRoute) -> RouteRecoveryContext {
        next += 1
        return RouteRecoveryContext(generation: next, source: source, route: route)
    }
    public mutating func expect(_ route: PhoneAudioRoute, now: TimeInterval, source: RouteRecoverySource = .appToggle) -> RouteRecoveryContext {
        let context = make(source, route)
        expected = Ticket(context: context, until: now + 2); matched = nil
        return context
    }
    public mutating func cancel(_ context: RouteRecoveryContext) {
        if expected?.context == context { expected = nil }
        if matched?.context == context { matched = nil }
    }
    public mutating func notification(route: PhoneAudioRoute, reason: UInt, now: TimeInterval) -> RouteRecoveryContext {
        defer { lastRoute = route; if !route.isBuiltIn { builtInOverrideObserved = false } }
        // Real device evidence: our setCategory emits reason 3, not necessarily 4.
        if [3, 4, 8].contains(reason), let ticket = expected, now <= ticket.until, ticket.context.route == route {
            matched = ticket
            if route.isBuiltIn { builtInOverrideObserved = true }
            return ticket.context
        }
        // Reason 4 is an explicit system port override. Reason 8 alone is NOT
        // evidence of user intent (it also occurs during startup/engine churn).
        // iOS can report clearing an established built-in override as category
        // change, even many seconds later. External moves/startup are NOT intent.
        if route != lastRoute, reason == 4 || (reason == 3 && builtInOverrideObserved && lastRoute.isBuiltIn && route.isBuiltIn) {
            let context = make(.systemChoice, route)
            if route.isBuiltIn { builtInOverrideObserved = true }
            expected = nil; matched = Ticket(context: context, until: now + 2)
            return context
        }
        // Coalesced category/config notifications for the same proved action.
        if [3, 4, 8].contains(reason), let ticket = matched, now <= ticket.until, ticket.context.route == route {
            return ticket.context
        }
        matched = nil
        return make(.unexpected, route)
    }
    public mutating func engine(route: PhoneAudioRoute, now: TimeInterval) -> RouteRecoveryContext {
        if let ticket = matched, now <= ticket.until, ticket.context.route == route { return ticket.context }
        return make(.unexpected, route)
    }
    public mutating func retry(route: PhoneAudioRoute, now: TimeInterval) -> RouteRecoveryContext {
        let context = make(.retry, route)
        expected = nil; matched = Ticket(context: context, until: now + 2)
        return context
    }
}

/// Only unexpected repairs spend the bounded 3/10s allowance. Exhaustion is a
/// nonterminal microphone pause; only a deliberate Retry can reopen admission.
public struct RouteRecoveryBudget {
    public private(set) var paused = false
    public private(set) var unexpected: [TimeInterval] = []
    public init() {}
    public mutating func admit(_ context: RouteRecoveryContext, now: TimeInterval) -> Bool {
        guard !paused else { return false }
        unexpected.removeAll { now - $0 >= 10 }
        if context.deliberate { return true }
        guard unexpected.count < 3 else { paused = true; return false }
        unexpected.append(now)
        return true
    }
    public mutating func suspend() { paused = true }
    public mutating func retry() { paused = false; unexpected = [] }
}

public enum RouteRecoveryNotice {
    public static let paused = "Audio paused. The call is still connected. Tap Retry audio."
}

public enum CaptureFailureDisposition { case stale, routePaused, standaloneFailure }

/// The production error-delivery seam. Call-owned conversion errors cannot enter
/// the generic failure callback, even while a replacement tap awaits readiness.
public enum CaptureFailureDelivery {
    @discardableResult public static func deliver(capture: Bool, graph: Bool, call: Bool, media: Bool,
        speech: Bool = true, callOwned: Bool, pause: () -> Void, fail: () -> Void) -> CaptureFailureDisposition {
        guard capture, graph, call, media, speech else { return .stale }
        if callOwned { pause(); return .routePaused }
        fail(); return .standaloneFailure
    }
}
