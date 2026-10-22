import Foundation

/// Immutable authority from the answered invitation, never recaptured after a lookup.
public struct IncomingCallOwner: Equatable, Sendable {
    public let epoch: Int
    public let id: UUID
    @MainActor public init(lifecycle: CallLifecycle, invitation: PushInvitation) throws {
        epoch = lifecycle.epoch; id = invitation.id
        try validate(lifecycle)
    }
    @MainActor public func validate(_ lifecycle: CallLifecycle) throws {
        try Task.checkCancellation()
        guard lifecycle.admits(epoch), lifecycle.id == id else { throw ClientError("Call ended") }
    }
}

@MainActor public enum IncomingCallResolution {
    /// Keep the network/mutation boundary shared with deterministic delayed-lookup tests.
    public static func resolve(invitation: PushInvitation, lifecycle: CallLifecycle,
                               lookup: () async throws -> ReachOutContext,
                               join: (ReachOutContext, IncomingCallOwner) async throws -> TargetLease) async throws -> TargetLease {
        let owner = try IncomingCallOwner(lifecycle: lifecycle, invitation: invitation)
        let context = try await lookup()
        try owner.validate(lifecycle) // MUST precede any draft/controller/backend mutation.
        let target = try await join(context, owner)
        try owner.validate(lifecycle)
        return target
    }
}

public struct PushInvitation: Equatable {
    public let reachoutID: String?
    public let id: UUID
    public let expiry: Date?
    public let deadline: Date?
    public var valid: Bool { reachoutID != nil && expiry != nil && deadline != nil }
    public init(payload: [String: Any], fallbackID: UUID = UUID()) {
        reachoutID = (payload["reachoutID"] as? String).flatMap { Self.validID($0) ? $0 : nil }
        id = (payload["callUUID"] as? String).flatMap(UUID.init(uuidString:)) ?? fallbackID
        func date(_ key: String) -> Date? {
            guard let n = payload[key] as? Double, n.isFinite, n > 0 else { return nil }
            return Date(timeIntervalSince1970: n / 1000)
        }
        // A fabricated UUID is only for mandatory reporting, never for admission.
        expiry = (payload["callUUID"] as? String).flatMap(UUID.init(uuidString:)) == nil ? nil : date("expiry")
        deadline = date("ringDeadline")
    }
    public static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// Persisted desired state and acknowledged state are deliberately distinct.
public struct PushPolicySync: Codable {
    public private(set) var desired: ReachOutPolicy
    public private(set) var acknowledged: ReachOutPolicy?
    public private(set) var syncedAt: Date?
    public init(policy: ReachOutPolicy = ReachOutPolicy()) { desired = policy }
    public mutating func edit(_ policy: ReachOutPolicy) {
        var next = policy; next.revision = desired.revision
        guard next != desired else { return }
        next.revision += 1; desired = next
    }
    @discardableResult public mutating func acknowledge(_ policy: ReachOutPolicy, at date: Date) -> Bool {
        guard policy == desired else { return false }
        acknowledged = policy; syncedAt = date; return true
    }
    public var synced: Bool { desired == acknowledged }
    public func allowsCall(at date: Date) -> Bool {
        desired.callsEligible(at: date, acknowledged: acknowledged, syncedAt: syncedAt)
    }
    /// Pilot admission retains the acknowledged policy and current-zone fence.
    public func allowsPilotCall(at date: Date, timeZone: String) -> Bool {
        desired.timeZone == timeZone && allowsCall(at: date)
    }
}

public struct ReachOutContext {
    public let session: String
    public let messageID: String?
    public init(record: [String: Any], reachoutID: String, now: Date = Date(), invitation: PushInvitation? = nil) throws {
        guard record["reachoutID"] as? String == reachoutID,
              let session = record["session"] as? String, session.hasPrefix("ses_"),
              session.dropFirst(4).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), session.count > 4, session.count <= 104,
              let expiry = record["expiry"] as? Double, expiry.isFinite, expiry > now.timeIntervalSince1970 * 1000 else {
            throw ClientError("This reach-out is expired or unavailable.")
        }
        if let invitation {
            guard record["kind"] as? String == "urgent-call",
                  ["decision", "goal-risk"].contains(record["reason"] as? String ?? ""),
                  (record["callUUID"] as? String).flatMap(UUID.init(uuidString:)) == invitation.id,
                  let expiry = record["callExpiry"] as? Double, expiry.isFinite,
                  expiry > now.timeIntervalSince1970 * 1000 else { throw ClientError("This call has expired.") }
        }
        self.session = session
        messageID = record["messageID"] as? String
    }
}
