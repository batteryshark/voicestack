import Foundation

/// Text parts are paragraphs, not fragments to concatenate. Shared by History and the live log.
public enum ReplyText {
    public static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
