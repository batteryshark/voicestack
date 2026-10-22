import Foundation

public enum CallEndInitiator: String, Codable, Sendable {
    case app, systemEndAction, providerReset, reportFailure, ringDeadline, answerDeadline
    case readinessDeadline, actionTimeout, mediaFailure, mediaReset, policyChange, targetChange
}
public enum CallTerminationReason: String, Codable, Sendable {
    case requested, declined, ringExpired, admissionRejected, reportRejected, providerReset
    case answerTimeout, answerFailed, readinessTimeout, actionTimeout, mediaFailed, mediaReset, policyRestricted, targetChanged
}
public enum IncomingReportFailure: String, Codable, Sendable {
    case filteredByDoNotDisturb, filteredByBlockList, callUUIDAlreadyExists, maximumCallGroupsReached, unentitled, other
    public static func classify(_ error: Error) -> Self { (error as? IncomingReportError)?.failure ?? .other }
}
public struct IncomingReportError: Error, Sendable {
    public let code: Int
    public let failure: IncomingReportFailure
    public init(code: Int, failure: IncomingReportFailure) { self.code = code; self.failure = failure }
}
public enum CallDiagnosticEvent: String, Codable, Sendable {
    case coordinatorCreated, providerCreated, providerInvalidated, providerDeallocated, providerReset, pushAdmission
    case reportRequested, reportSucceeded, reportFailed, ringing, deadlineArmed, endRequested, ended
    case deactivated, systemEndAction, actionTimedOut, scenePreserved, receiptQueued, receiptAcknowledged, receiptDeferred
    case providerReleased, controlRejected
    case activationRequested, activationGranted, activationReleased
    case callAdmitted
    case elided
}
public struct CallReceipt: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable {
        case reported, ringing, answered, declined, ended, reportFailed = "report-failed", notificationOpened = "notification-opened"
    }
    public let event: Event
    public var endReason: CallTerminationReason?
    public var endInitiator: CallEndInitiator?
    public var reportedRinging: Bool?
    public var reportFailure: IncomingReportFailure?
    public var reportErrorCode: Int?
    /// Phone-declared quiet decline only; never a server admission policy.
    public var quietUntil: Double?
    public var quietEnd: String?
    public init(_ event: Event, reason: CallTerminationReason? = nil, initiator: CallEndInitiator? = nil,
                reportedRinging: Bool? = nil, reportFailure: IncomingReportFailure? = nil, reportErrorCode: Int? = nil) {
        self.event = event; endReason = reason; endInitiator = initiator
        self.reportedRinging = reportedRinging; self.reportFailure = reportFailure; self.reportErrorCode = reportErrorCode
    }
}
