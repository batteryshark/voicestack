import Foundation

public enum RouteGuard: String, Codable, Sendable { case allowed, inactive, mediaBlocked, externalRoute }
public enum RouteAction: String, Codable, Sendable { case none, speaker, receiver }
public enum RouteResult: String, Codable, Sendable { case requested, rejected, applied, failed, confirmed, notChanged, superseded, paused, recovered }
public enum RouteEvent: String, Codable, Sendable { case toggle, notification, activation, engine, recovery, retry }
public struct RouteDiagnostic: Codable, Sendable {
    public var event: RouteEvent
    public var gate: RouteGuard
    public var before: PhoneAudioRoute
    public var after: PhoneAudioRoute
    public var action: RouteAction
    public var result: RouteResult
    public var recovery: RouteRecoveryContext?
    public init(event: RouteEvent, gate: RouteGuard = .allowed, before: PhoneAudioRoute, after: PhoneAudioRoute, action: RouteAction = .none, result: RouteResult = .confirmed) {
        self.event = event; self.gate = gate; self.before = before; self.after = after; self.action = action; self.result = result
    }
}
public enum RouteSwitchError: Error, LocalizedError {
    case unavailable, failed
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Audio route can be changed once the call connects."
        case .failed: return "Audio route couldn't change. Try iPhone's audio controls."
        }
    }
}

/// The production toggle transaction, independent of AVAudioSession. Never claims
/// activation, silently returns, saves Settings, or commits an unsuccessful choice.
public struct LiveRouteSwitch {
    public var policy: BuiltInRoutePolicy
    public init(defaultSpeaker: Bool) { policy = BuiltInRoutePolicy(defaultSpeaker: defaultSpeaker) }
    public mutating func observe(_ route: PhoneAudioRoute, systemSelection: Bool) {
        // Engine/category churn must not replace a live receiver choice with a
        // saved speaker default. External routing always wins without an override.
        if systemSelection || !route.isBuiltIn { policy.observe(route) }
    }
    public static func gate(active: Bool, mayRunMedia: Bool, current: PhoneAudioRoute) -> RouteGuard {
        if !active { return .inactive }
        if !mayRunMedia { return .mediaBlocked }
        return current.isBuiltIn ? .allowed : .externalRoute
    }
    @discardableResult public mutating func toggle(active: Bool, mayRunMedia: Bool, current: () -> PhoneAudioRoute,
        apply: (Bool) throws -> Void, diagnostic: (RouteDiagnostic) -> Void) throws -> PhoneAudioRoute {
        let before = current(), gate = Self.gate(active: active, mayRunMedia: mayRunMedia, current: before)
        let speaker = before != .speaker, action: RouteAction = speaker ? .speaker : .receiver
        diagnostic(RouteDiagnostic(event: .toggle, gate: gate, before: before, after: before,
            action: gate == .allowed ? action : .none, result: gate == .allowed ? .requested : .rejected))
        guard gate == .allowed else { throw RouteSwitchError.unavailable }
        do { try apply(speaker) }
        catch {
            diagnostic(RouteDiagnostic(event: .toggle, before: before, after: current(), action: action, result: .failed))
            throw RouteSwitchError.failed
        }
        _ = policy.explicitOverride(current: before, speaker: speaker)
        diagnostic(RouteDiagnostic(event: .toggle, before: before, after: current(), action: action, result: .applied))
        return speaker ? .speaker : .phone
    }
}
