import Foundation

/// Hide exactly one transport marker, never a literal marker inside dictation.
public enum VoiceOrigin {
    public static let prefix = VoicePost.prefix
    public static func displayText(_ text: String) -> String {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }
}

/// Display-only projection. Unknown is intentionally not the principal, even in
/// the chief thread. This is the sole phone fallback-label switch.
public struct MessageSender: Equatable, Sendable {
    public enum Kind: String, Sendable { case principal, lead, chief, docket, canvas, agent, system }
    public static let unknownLabel = "Message"
    public static let principal = MessageSender(kind: .principal, label: "You")
    public static let unknown = MessageSender(kind: .system, label: unknownLabel)
    public let kind: Kind
    public let label: String
    public var isPrincipal: Bool { kind == .principal }
    public var accessibilityLabel: String { isPrincipal ? "You" : "From " + label }
    public init(kind: Kind, label: String) { self.kind = kind; self.label = label }
    public init(projected: Any?) {
        guard let value = projected as? [String: Any], let raw = value["kind"] as? String,
              let kind = Kind(rawValue: raw), let label = value["label"] as? String,
              !label.isEmpty, label.count <= 120,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else { self = .unknown; return }
        self = kind == .principal ? .principal : MessageSender(kind: kind, label: label)
    }
}

/// Exact POST receipt ids, scoped by target. Never match by text, title, timing,
/// a session's creator, or the newest user record. In-memory, client-local only.
public struct LocalSenderReceipts {
    private var ids: [String: Set<String>] = [:]
    public init() {}
    public mutating func record(_ response: Data, sessionID: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
              let data = obj["data"] as? [String: Any], let id = data["id"] as? String,
              id.range(of: "^msg_[A-Za-z0-9]+$", options: .regularExpression) != nil else { return }
        ids[sessionID, default: []].insert(id)
    }
    public func project(_ records: [Data], sessionID: String) -> [Data] {
        records.map { raw in
            guard var obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  obj["type"] as? String == "user", let id = obj["id"] as? String,
                  ids[sessionID]?.contains(id) == true else { return raw }
            if obj["text"] as? String == VoiceEndedNote.text {
                obj["sender"] = ["kind": "system", "label": VoiceEndedNote.label]
                obj["displayText"] = VoiceEndedNote.displayText
                return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? raw
            }
            obj["sender"] = ["kind": "principal", "label": "You"]
            obj.removeValue(forKey: "displayText") // A local quote keeps its entire original text.
            return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? raw
        }
    }
}
