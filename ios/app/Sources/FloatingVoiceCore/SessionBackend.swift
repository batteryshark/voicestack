import Foundation

/// Original OpenChamber event data, not speech-cleaned captions.
public struct ServerEvent {
    public let type: String
    public let data: [String: Any]
    public let created: Double?
    public private(set) var identity: String?
    public init(type: String, data: [String: Any] = [:], created: Double? = nil) {
        self.type = type; self.data = data; self.created = created
    }
    public init?(json: String) {
        guard let bytes = json.data(using: .utf8),
              let envelope = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return nil }
        let obj = envelope["payload"] as? [String: Any] ?? envelope
        guard
              let type = obj["type"] as? String else { return nil }
        self.init(type: type, data: obj["data"] as? [String: Any] ?? [:], created: (obj["created"] as? NSNumber)?.doubleValue)
        identity = obj["id"] as? String
    }
    public var sessionID: String? { data["sessionID"] as? String }
    public var delta: String? { data["delta"] as? String }
    public var text: String? { data["text"] as? String }
    public var blockKey: String { "\(data["assistantMessageID"] as? String ?? "?"):\((data["ordinal"] as? NSNumber)?.intValue ?? 0)" }
}
public protocol SessionBackend: AnyObject {
    func connect() async throws -> String
    func events() -> AsyncThrowingStream<ServerEvent, Error>
    func activeSessions() async throws -> Set<String>
    func targetLease(sessionID: String) async throws -> TargetLease
    func prompt(target: TargetLease, text: String, delivery: BusyDelivery?) async throws
    func prompt(target: TargetLease, text: String, delivery: BusyDelivery?, reviewText: String) async throws
    func interrupt(target: TargetLease) async throws -> Bool
    func sessionTitle(_ id: String) async -> String?
    func admit(target: TargetLease, text: String) async throws
    func admit(target: TargetLease, text: String, reviewText: String) async throws
    func listSessions() async throws -> [SessionSummary]
}
public extension SessionBackend {
    // Backends without review storage need only the wire value. Backends that
    // retain failures override these requirements and keep the raw draft.
    func prompt(target: TargetLease, text: String, delivery: BusyDelivery?, reviewText: String) async throws {
        try await prompt(target: target, text: text, delivery: delivery)
    }
    func admit(target: TargetLease, text: String, reviewText: String) async throws {
        try await admit(target: target, text: text)
    }
    func listSessions() async throws -> [SessionSummary] { [] }
    func sessionTitle(_ id: String) async -> String? { nil }
}
public struct SessionSummary: Equatable, Sendable {
    public let id: String
    public let title: String
    public let updated: Double
    public let directory: String
    public let parentID: String?
    public init(id: String, title: String, updated: Double, directory: String = "", parentID: String? = nil) {
        self.id = id; self.title = title; self.updated = updated; self.directory = directory; self.parentID = parentID
    }
    public static func shortID(_ id: String) -> String { String((id.hasPrefix("ses_") ? id.dropFirst(4) : Substring(id)).prefix(6)) }
    public var shortID: String { Self.shortID(id) }
    public var label: String { "\(title.isEmpty ? "Untitled" : title) · \(shortID)" }
}
public enum ChiefDiscovery {
    public static let title = "Chief of staff"
    public static func pick(from sessions: [SessionSummary]) -> String? {
        sessions.filter { $0.title.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title) == .orderedSame }.max { $0.updated < $1.updated }?.id
    }
}
public struct ClientError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
