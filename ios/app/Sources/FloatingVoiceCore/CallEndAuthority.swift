import Foundation

public enum CallEndCause: String, Codable, CaseIterable, Hashable, Sendable {
    case userEnd, systemEnd, providerReset, systemFailure
    case admissionRejected, policyRestricted, ringDeadline, answerDeadline, readinessDeadline, setupFailure
    case mediaFailure, routePause, captureFailure, conversionFailure, repairFailure, backendFailure, leaseFailure, mediaReset
}
public enum CallMediaAttempt: String, Codable, Sendable { case initial, recovery }
public enum CallEndDisposition: String, Codable, Sendable { case terminal, pause }
public struct CallAuthorityDiagnostic: Codable, Sendable {
    public let cause: CallEndCause
    public let decision: CallEndDisposition
    public let everReady: Bool
    public let attempt: CallMediaAttempt
    public let rejectedReport: Bool
}

/// The only policy allowed to authorize teardown. Local media/backend failures
/// cannot acquire terminal authority after first readiness or during any Retry.
public enum CallEndAuthority {
    public static func decide(_ cause: CallEndCause, everReady: Bool, attempt: CallMediaAttempt) -> CallEndDisposition {
        switch cause {
        case .userEnd, .systemEnd, .providerReset, .systemFailure: return .terminal
        case .routePause: return .pause // Explicit nonterminal capture quarantine, including initial setup.
        default: return everReady || attempt == .recovery ? .pause : .terminal
        }
    }
}
