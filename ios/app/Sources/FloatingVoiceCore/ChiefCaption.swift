import Foundation

public struct ChiefReplyContent: Equatable {
    public let spoken: String
    public let details: String
    public init(_ raw: String) {
        var prose: [String] = [], detail: [String] = []
        var fence: Character?, fenceLength = 0, markdown = false
        for line in raw.components(separatedBy: "\n") {
            let trim = line.trimmingCharacters(in: .whitespaces)
            let char = trim.first
            let count = char.map { c in trim.prefix(while: { $0 == c }).count } ?? 0
            if let open = fence {
                if char == open && count >= fenceLength && trim.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    if !markdown { detail.append(line) }
                    fence = nil; detail.append(""); continue
                }
                detail.append(line); continue
            }
            if (char == "`" || char == "~") && count >= 3 {
                prose.append("")
                fence = char; fenceLength = count
                let language = trim.dropFirst(count).trimmingCharacters(in: .whitespaces).lowercased()
                markdown = ["md", "markdown"].contains(language)
                if !markdown { detail.append(line) }
            } else if trim == "`" || trim == "``" || trim == "~" || trim == "~~" {
                // A partial streaming fence is not caption text.
                continue
            } else { prose.append(line) }
        }
        var paragraphs: [String] = [], paragraph: [String] = []
        func flush() {
            let value = cleanSpeech(paragraph.joined(separator: " "))
            if !value.isEmpty { paragraphs.append(value) }; paragraph = []
        }
        for line in prose {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush() }
            else if trimmed.range(of: "^(?:#{1,6} |[-*+] |[0-9]+[.)] |>)", options: .regularExpression) != nil {
                flush(); paragraph = [line]; flush()
            } else { paragraph.append(line) }
        }
        flush()
        spoken = ReplyText.join(paragraphs)
        details = detail.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Keep display paragraph boundaries while revealing only words whose audio has started.
    public func displayPrefix(for audible: String) -> String {
        let heard = audible.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !heard.isEmpty else { return "" }
        let regex = try! NSRegularExpression(pattern: "\\S+")
        let source = spoken as NSString
        let ranges = regex.matches(in: spoken, range: NSRange(location: 0, length: source.length)).map(\.range)
        guard ranges.count >= heard.count,
              zip(ranges.prefix(heard.count), heard).allSatisfy({ source.substring(with: $0.0) == $0.1 }) else { return audible }
        return source.substring(to: NSMaxRange(ranges[heard.count-1]))
    }
}

/// One chief message's speech-start progression. The running log retains one per message ID.
public struct ChiefCaptionState {
    private struct Sentence { let label: String; let text: String; var started = false }
    private var sentences: [Sentence] = []
    private var sourceID: String?
    private var content = ChiefReplyContent("")
    private var mutedReveal = ""
    private var historicalReveal = ""
    private var interrupted: (String, String)?
    private var audioUnavailable = false
    public init() {}
    public var spoken: String {
        let heard = sentences.filter(\.started)
        var started = "", previousLabel: String?
        for sentence in heard {
            if !started.isEmpty { started += previousLabel == sentence.label ? " " : "\n\n" }
            started += sentence.text; previousLabel = sentence.label
        }
        started = content.displayPrefix(for: started)
        // Switching mute OFF can never retract text already revealed while muted.
        return [started, mutedReveal, historicalReveal].max(by: { $0.count < $1.count }) ?? ""
    }
    public var details: String { content.details }
    public mutating func source(_ raw: String, id: String?, live: Bool, muted: Bool) {
        if sourceID != id {
            let belongsToIncoming = id.map { id in sentences.contains { $0.label.hasPrefix(id + ":") } } ?? false
            if !belongsToIncoming { sentences = []; interrupted = nil; audioUnavailable = false }
            sourceID = id; mutedReveal = ""; historicalReveal = ""
        }
        content = ChiefReplyContent(raw)
        if muted || audioUnavailable { mutedReveal = content.spoken }
        else if !live && sentences.isEmpty { historicalReveal = content.spoken }
    }
    public mutating func mute(_ muted: Bool) { if muted { mutedReveal = content.spoken } }
    public mutating func unavailable() { audioUnavailable = true; mutedReveal = content.spoken }
    public mutating func queued(label: String, text: String) {
        let messageID = label.lastIndex(of: ":").map { String(label[..<$0]) }
        if let messageID, let sourceID, messageID != sourceID {
            sentences = []; mutedReveal = ""; historicalReveal = ""; interrupted = nil
            audioUnavailable = false
            content = ChiefReplyContent(""); self.sourceID = messageID
        }
        sentences.append(Sentence(label: label, text: text))
    }
    public mutating func started(label: String, text: String) {
        if let interrupted, interrupted.0 == label && interrupted.1 == text { self.interrupted = nil; return }
        if let index = sentences.firstIndex(where: { !$0.started && $0.label == label && $0.text == text }) { sentences[index].started = true }
        else { sentences.append(Sentence(label: label, text: text, started: true)) }
    }
    public mutating func ended(label: String, text: String, outcome: String) {
        interrupted = outcome == "interrupted" ? (label, text) : nil
    }
}
