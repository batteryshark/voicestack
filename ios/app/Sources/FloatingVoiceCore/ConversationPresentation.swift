import Foundation

/// Native view input in source order. Unknown structures remain available in the separate raw fallback.
public struct MessageBody {
    public let label: String?
    public let markdown: String
    public let command: String?
    public var reference: ContentReference? = nil
    public var rawDetail: String? = nil
    /// The native renderer consumes this exact projection, not a parallel plain-text path.
    public var blocks: [MarkdownBlock] { BlockMarkdown.renderBlocks(markdown) }
}

public struct MessageRow: Identifiable {
    public let id: String
    public let role: String
    public let sender: MessageSender?
    public let isSystemNote: Bool
    public var isPrincipal: Bool { role == "You" && sender?.isPrincipal == true }
    public var displayLabel: String { isSystemNote ? VoiceEndedNote.label : role == "You" ? (sender?.label ?? MessageSender.unknownLabel) : AgentPresentation.roleLabel(role) }
    public var accessibilityLabel: String { isSystemNote ? "From " + VoiceEndedNote.label : role == "You" ? (sender ?? .unknown).accessibilityLabel : displayLabel }
    public let text: String
    public let steps: Int
    public let detail: String
    public let body: [MessageBody]
    public init?(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = obj["id"] as? String else { return nil }
        let kind = obj["type"] as? String ?? "unknown"
        let incoming = kind == "user" || kind == "synthetic"
        if ["idle", "execution", "lifecycle", "session"].contains(kind) { return nil }
        self.id = id
        sender = incoming ? MessageSender(projected: obj["sender"]) : nil
        isSystemNote = incoming && obj["text"] as? String == VoiceEndedNote.text && sender?.kind == .system && sender?.label == VoiceEndedNote.label
        role = isSystemNote ? "System" : ["user": "You", "synthetic": "You", "assistant": "Chief", "system": "System", "error": "Error", "tool": "Tool"][kind] ?? "Other record"
        let blocks = obj["content"] as? [[String: Any]] ?? []
        steps = blocks.filter { $0["type"] as? String == "tool" }.count
        let original = obj["text"] as? String ?? ""
        let display = (obj["displayText"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        text = incoming ? (sender?.isPrincipal == false ? (display ?? VoiceOrigin.displayText(original)) : VoiceOrigin.displayText(original)) : ReplyText.join(blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String })
        var projected: [MessageBody] = []
        if incoming, !text.isEmpty { projected.append(MessageBody(label: nil, markdown: text, command: nil)) }
        for (ordinal, file) in (obj["files"] as? [[String: Any]] ?? []).enumerated() {
            projected.append(MessageBody(label: nil, markdown: file["name"] as? String ?? "Attachment", command: nil, reference: .init(kind: "userFile", blockOrdinal: ordinal)))
        }
        for (ordinal, block) in blocks.enumerated() {
            if block["type"] as? String == "text", !incoming, let value = block["text"] as? String {
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    projected += ContentReference.markdownParts(value, ordinal: ordinal)
                }
            } else if block["type"] as? String == "tool" {
                let state = block["state"] as? [String: Any] ?? [:]
                let name = block["name"] as? String ?? block["tool"] as? String ?? "Tool"
                let status = state["status"] as? String ?? "details"
                if name.hasSuffix("canvas_show") {
                    projected.append(MessageBody(label: nil, markdown: "Canvas panel", command: nil, reference: .init(kind: "canvas", blockOrdinal: ordinal, format: "canvas_show")))
                    continue
                }
                let contents = state["content"] as? [[String: Any]] ?? []
                let input = state["input"] as? [String: Any] ?? block["input"] as? [String: Any] ?? [:]
                let command = input["command"] as? String
                var values = ["text", "prompt", "markdown", "content"].compactMap { input[$0] as? String }
                values += (input["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                var pendingCommand = command
                for (item, content) in contents.enumerated() {
                    if content["type"] as? String == "text", let text = content["text"] as? String { values.append(text) }
                    else if content["type"] as? String == "file" {
                        if !values.isEmpty || pendingCommand != nil {
                            projected.append(MessageBody(label: "\(name) · \(status)", markdown: values.joined(separator: "\n\n"), command: pendingCommand))
                            values = []; pendingCommand = nil
                        }
                        projected.append(MessageBody(label: nil, markdown: content["name"] as? String ?? "Tool attachment", command: nil, reference: .init(kind: "toolFile", blockOrdinal: ordinal, itemOrdinal: item)))
                    } else {
                        if !values.isEmpty || pendingCommand != nil {
                            projected.append(MessageBody(label: "\(name) · \(status)", markdown: values.joined(separator: "\n\n"), command: pendingCommand))
                            values = []; pendingCommand = nil
                        }
                        let raw = (try? JSONSerialization.data(withJSONObject: content, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "Unsupported tool result"
                        projected.append(MessageBody(label: "\(name) · result \(item + 1)", markdown: "", command: nil, rawDetail: raw))
                    }
                }
                if !values.isEmpty || pendingCommand != nil || contents.isEmpty { projected.append(MessageBody(label: "\(name) · \(status)", markdown: values.joined(separator: "\n\n"), command: pendingCommand)) }
                if name.hasSuffix("canvas_present") {
                    projected.append(MessageBody(label: nil, markdown: "Canvas panel", command: nil, reference: .init(kind: "canvas", blockOrdinal: ordinal)))
                }
            } else {
                projected.append(MessageBody(label: block["type"] as? String ?? "Unsupported block", markdown: block["text"] as? String ?? "See raw record for full details", command: nil))
            }
        }
        if projected.isEmpty && kind == "assistant" && !blocks.isEmpty && blocks.allSatisfy({ $0["type"] as? String == "text" && ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true }) { return nil }
        if projected.isEmpty { projected.append(MessageBody(label: "Record details", markdown: "See raw record", command: nil)) }
        var paragraphs: [MessageBody] = []
        for part in projected {
            if let previous = paragraphs.last, previous.label == nil, previous.command == nil,
               previous.reference == nil, previous.rawDetail == nil,
               part.label == nil, part.command == nil, part.reference == nil, part.rawDetail == nil {
                paragraphs[paragraphs.count-1] = MessageBody(label: nil, markdown: ReplyText.join([previous.markdown, part.markdown]), command: nil)
            } else { paragraphs.append(part) }
        }
        body = paragraphs
        detail = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "Unsupported record"
    }
}

public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String), heading(Int, String), list(String), quote(String)
    case code(String, String), markdown(String), table([[String]])
}
public enum BlockMarkdown {
    /// Fenced md is a document, never a code/plain-text fallback or a hidden disclosure.
    public static func renderBlocks(_ text: String, depth: Int = 0) -> [MarkdownBlock] {
        parse(text).flatMap { block -> [MarkdownBlock] in
            if case .markdown(let value) = block {
                return depth < 8 ? renderBlocks(value, depth: depth + 1) : [.code("markdown", value)]
            }
            return [block]
        }
    }
    /// Dependency-free display parser. Never executes or downloads fenced content.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var result: [MarkdownBlock] = [], i = 0
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = trimmed.first!
                let marker = String(trimmed.prefix { $0 == fence }), language = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces).lowercased()
                i += 1; var body: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(marker) { body.append(lines[i]); i += 1 }
                if i < lines.count { i += 1 }
                result.append(["md", "markdown"].contains(language) ? .markdown(body.joined(separator: "\n")) : .code(language, body.joined(separator: "\n")))
                continue
            }
            if i + 1 < lines.count, line.contains("|"), isSeparator(lines[i+1]) {
                var rows = [cells(line)]; i += 2
                while i < lines.count && lines[i].contains("|") && !lines[i].isEmpty { rows.append(cells(lines[i])); i += 1 }
                result.append(.table(rows)); continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") { result.append(.heading(hashes, String(trimmed.dropFirst(hashes+1)))) }
            else if trimmed.hasPrefix(">") { result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))) }
            else if trimmed.range(of: "^(?:[-*+] |[0-9]+[.)] )", options: .regularExpression) != nil { result.append(.list(trimmed)) }
            else { result.append(.paragraph(line)) }
            i += 1
        }
        return result
    }
    public static func cells(_ line: String) -> [String] {
        var cells: [String] = [], current = "", escaped = false, codeTicks = 0, lastDelimiter = false
        let characters = Array(line.trimmingCharacters(in: .whitespaces)); var index = 0
        while index < characters.count {
            let char = characters[index]; index += 1
            lastDelimiter = false
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "`" {
                var count = 1
                while index < characters.count && characters[index] == "`" { count += 1; index += 1 }
                if codeTicks == 0 { codeTicks = count } else if codeTicks == count { codeTicks = 0 }
                current += String(repeating: "`", count: count); continue
            }
            if char == "|" && codeTicks == 0 { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; lastDelimiter = true }
            else { current.append(char) }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { cells.removeFirst() }
        if lastDelimiter, !cells.isEmpty { cells.removeLast() }
        return cells
    }
    private static func isSeparator(_ line: String) -> Bool {
        let values = cells(line)
        return !values.isEmpty && values.allSatisfy { $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }
    }
}

public struct BottomFollow {
    public private(set) var following = true
    public init() {}
    public mutating func userScrolled(bottomVisible: Bool) { following = bottomVisible }
    public mutating func selected() { following = true }
}

public enum CompactPicker {
    public static func sessions(_ sessions: [SessionSummary], search: String) -> [SessionSummary] {
        sessions.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }
}
