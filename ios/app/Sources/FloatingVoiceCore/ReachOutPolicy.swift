import Foundation

/// Phone-local settings, shared with the bridge's v1 policy wire contract.
/// Calls are ON by principal decision, but require a fresh server acknowledgement.
public struct ReachOutPolicy: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var callsEnabled: Bool
    public var quietHoursEnabled: Bool
    public var quietStart: String
    public var quietEnd: String
    public var timeZone: String
    public var policyVersion: Int
    public var revision: Int

    public init(callsEnabled: Bool = true, quietHoursEnabled: Bool = true,
                quietStart: String = "22:00", quietEnd: String = "09:00",
                timeZone: String = TimeZone.current.identifier, revision: Int = 1) {
        self.callsEnabled = callsEnabled
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStart = quietStart
        self.quietEnd = quietEnd
        self.timeZone = timeZone
        self.policyVersion = Self.currentVersion
        self.revision = revision
    }

    private func minutes(_ value: String) -> Int? {
        let bytes = Array(value.utf8)
        guard bytes.count == 5, bytes[2] == 58,
              [bytes[0], bytes[1], bytes[3], bytes[4]].allSatisfy({ (48...57).contains($0) }) else { return nil }
        let hour = Int(bytes[0] - 48) * 10 + Int(bytes[1] - 48)
        let minute = Int(bytes[3] - 48) * 10 + Int(bytes[4] - 48)
        guard hour < 24, minute < 60 else { return nil }
        return hour * 60 + minute
    }

    public var isValid: Bool {
        policyVersion == Self.currentVersion && revision > 0 &&
        (TimeZone.knownTimeZoneIdentifiers.contains(timeZone) || timeZone == "UTC" || timeZone == "GMT") &&
        minutes(quietStart) != nil && minutes(quietEnd) != nil
    }

    /// Half-open phone-wall-clock interval; equal endpoints conservatively mean all day.
    /// Invalid settings are quiet (fail closed). Calendar handles repeated/skipped DST hours.
    public func isQuiet(at date: Date) -> Bool {
        guard isValid, let zone = TimeZone(identifier: timeZone),
              let start = minutes(quietStart), let end = minutes(quietEnd) else { return true }
        guard quietHoursEnabled else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start == end || (start < end ? now >= start && now < end : now >= start || now < end)
    }

    /// Local display/eligibility only: never authorizes PushKit handling or replaces server policy.
    /// Restrictive edits apply immediately; enabling waits for an identical, fresh acknowledgement.
    public func callsEligible(at date: Date, acknowledged: ReachOutPolicy?, syncedAt: Date?) -> Bool {
        guard isValid, callsEnabled, !isQuiet(at: date), acknowledged == self,
              let syncedAt, date.timeIntervalSince(syncedAt) >= 0,
              date.timeIntervalSince(syncedAt) < 86_400 else { return false }
        return true
    }

    public func acceptsUpdate(_ other: ReachOutPolicy) -> Bool {
        other.isValid && (other.revision > revision || other == self)
    }
}
