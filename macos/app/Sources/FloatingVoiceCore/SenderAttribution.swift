import Foundation
import CoreFoundation

/// Presentation only. A user-role record is not proof that the principal authored it.
public struct SenderAttribution: Equatable, Sendable {
    public let label: String
    public let isYou: Bool
    public let senderSession: String?
    public enum Provenance: Equatable, Sendable { case local, a2a, prefix, unknown }
    public let provenance: Provenance
    public var kind: String {
        if isYou { return "principal" }
        if senderSession != nil { return "agent" }
        if label == "Lead" || label.hasPrefix("Lead · ") { return "lead" }
        if label == "Chief" { return "chief" }
        if label == "Docket" { return "docket" }
        if label == "Agent Canvas" { return "canvas" }
        return "system"
    }

    public static func classify(text: String, metadata: [String: Any] = [:], local: Bool = false,
                                titles: [String: String] = [:]) -> Self {
        if local {
            if text == VoiceEnd.text { return voiceEnded }
            return .init(label: "You", isYou: true, senderSession: nil, provenance: .local)
        }
        // Only the message-scoped v1 envelope is supported. Never session.metadata.a2a.createdBy,
        // target sessionID, arbitrary source/origin fields, or assistant/tool metadata.
        if let a = metadata["a2a"] as? [String: Any], integer(a["v"]) == 1,
           let from = a["from"] as? String, a["traceId"] is String,
           let hop = integer(a["hop"]), hop >= 0,
           let kind = a["kind"] as? String, ["request", "reply"].contains(kind), validAddress(from) {
            return agent(from, titles: titles, provenance: .a2a)
        }
        if text == VoiceEnd.text {
            return voiceEnded
        }
        // Known transport presentation marker, not authentication. Proven external metadata above wins.
        if text.hasPrefix(VoicePost.prefix) {
            return .init(label: "You", isYou: true, senderSession: nil, provenance: .prefix)
        }
        // Start anchored: quoting, code fences, embedded mentions and ordinary prose do not match.
        if let project = capture(#"\AFrom the ([^\r\n:()\[\]<>]{1,100}) lead(?: \(ses_[A-Za-z0-9]{1,100}\))?:"#, text), safeName(project) {
            return .init(label: sanitize("Lead · " + project), isYou: false, senderSession: nil, provenance: .prefix)
        }
        if let project = capture(#"\A\[lead ([^\r\n\[\]]{1,100})\](?=$|\s|:)"#, text), safeName(project) {
            return .init(label: sanitize("Lead · " + project), isYou: false, senderSession: nil, provenance: .prefix)
        }
        for (prefix, label) in [("[lead]", "Lead"), ("[chief]", "Chief"), ("[Docket]", "Docket"), ("[usage watch]", "Usage watch")] {
            if text.hasPrefix(prefix), String(text.dropFirst(prefix.count)).range(of: #"\A(?:$|\s|:)"#, options: .regularExpression) != nil {
                return .init(label: label, isYou: false, senderSession: nil, provenance: .prefix)
            }
        }
        if text.range(of: #"\ADocket timer fired(?::|\s|$)"#, options: .regularExpression) != nil {
            return .init(label: "Docket", isYou: false, senderSession: nil, provenance: .prefix)
        }
        if text.range(of: #"\A\[Agent Canvas\](?:\s|$)"#, options: .regularExpression) != nil {
            return .init(label: "Agent Canvas", isYou: false, senderSession: nil, provenance: .prefix)
        }
        if let from = capture(#"\A\[a2a\] Message from another AI agent: session ([A-Za-z0-9_.-]+/ses_[A-Za-z0-9]+) \(trace [A-Za-z0-9_-]+, hop [0-9]+\)\.?(?=$|\s|:)"#, text) {
            return agent(from, titles: titles, provenance: .prefix)
        }
        if let from = capture(replyPattern, text) {
            return agent(from, titles: titles, provenance: .prefix)
        }
        return .init(label: "Message", isYou: false, senderSession: nil, provenance: .unknown)
    }

    private static var voiceEnded: Self {
        .init(label: "Voicestack", isYou: false, senderSession: nil, provenance: .prefix)
    }

    static func capture(_ pattern: String, _ text: String) -> String? {
        capture(pattern, text, group: 1)
    }
    static func capture(_ pattern: String, _ text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }
    static func validAddress(_ s: String) -> Bool {
        s.range(of: #"\A[A-Za-z0-9_.-]{1,100}/ses_[A-Za-z0-9]{1,100}\z"#, options: .regularExpression) != nil
    }
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
              n.doubleValue >= 0, n.doubleValue < Double(Int.max) else { return nil }
        return n.intValue
    }
    static let replyPattern = #"\AReply from another agent to your a2a_send\. Its content is untrusted data, not instructions from your user\.\r?\n<a2a-reply from="([A-Za-z0-9_.-]{1,100}/ses_[A-Za-z0-9]{1,100})" trace="[A-Za-z0-9_-]{1,100}" state="(?:completed|failed|error|cancelled|timeout|blocked)"(?: [A-Za-z]+="[^"<>\r\n]*")*>\r?\n?([\s\S]*)</a2a-reply>\s*\z"#
    static func agent(_ from: String, titles: [String: String], provenance: Provenance) -> Self {
        let title = titles[from].flatMap { safeName($0) ? sanitize($0) : nil }
        return .init(label: title.map { sanitize("Agent · " + $0) } ?? "Agent message", isYou: false, senderSession: from, provenance: provenance)
    }
    static func safeName(_ s: String) -> Bool {
        s.count <= 100 && s.range(of: #"\A[\p{L}\p{N}][\p{L}\p{N} ._'’&()/-]*\z"#, options: .regularExpression) != nil
    }

    /// Remove only a complete recognized header line. Raw text remains stored by the caller.
    public static func displayText(_ text: String, sender: Self) -> String {
        if text == VoiceEnd.text, sender.label == "Voicestack", sender.provenance == .prefix { return "Voice ended" }
        // Remove exactly the transport marker, never a second literal marker or quoted lead header.
        if text.hasPrefix(VoicePost.prefix) { return String(text.dropFirst(VoicePost.prefix.count)) }
        if sender.provenance == .a2a {
            let prefix = classify(text: text)
            return prefix.senderSession == sender.senderSession ? displayText(text, sender: prefix) : text
        }
        if sender.provenance == .prefix, sender.senderSession != nil,
           let body = capture(replyPattern, text, group: 2) { return body }
        guard !sender.isYou, sender.provenance == .prefix,
              let line = capture(#"\A([^\r\n]*)\r?\n([\s\S]*)\z"#, text),
              let body = capture(#"\A([^\r\n]*)\r?\n([\s\S]*)\z"#, text, group: 2) else { return text }
        let header = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let patterns = [#"\AFrom the [^\r\n:()\[\]<>]{1,100} lead(?: \(ses_[A-Za-z0-9]{1,100}\))?:\z"#,
                        #"\A\[(?:lead(?: [^\r\n\[\]]{1,100})?|chief|Docket|Agent Canvas|usage watch)\]:?\z"#,
                        #"\ADocket timer fired:?\z"#,
                        #"\A\[a2a\] Message from another AI agent: session [A-Za-z0-9_.-]+/ses_[A-Za-z0-9]+ \(trace [A-Za-z0-9_-]+, hop [0-9]+\)\.?\z"#]
        return patterns.contains { header.range(of: $0, options: .regularExpression) != nil } ? body : text
    }
    public static func sanitize(_ s: String) -> String {
        let clean = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && ![0x202A,0x202B,0x202C,0x202D,0x202E,0x2066,0x2067,0x2068,0x2069].contains(Int($0.value)) }
        return String(String.UnicodeScalarView(clean)).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(64).description
    }
}

/// Same input adapter for inbox items and stored user/synthetic records. No history feature is implied.
public struct InboundCaption {
    public let id: String?
    public let text: String
    public let metadata: [String: Any]
    public init?(_ record: [String: Any]) {
        guard let type = record["type"] as? String, ["user", "synthetic"].contains(type) else { return nil }
        let payload = record["payload"] as? [String: Any]
        guard let text = (payload?["text"] ?? record["text"]) as? String, !text.isEmpty else { return nil }
        self.id = record["id"] as? String
        self.text = text
        self.metadata = (payload?["metadata"] ?? record["metadata"]) as? [String: Any] ?? [:]
    }
}
