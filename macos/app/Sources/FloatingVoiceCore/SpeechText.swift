import Foundation

// Port of agent-voice speech.mjs. Indices are UTF-16 offsets, as in JavaScript.

private func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: options)
}

private let cleaners: [(NSRegularExpression, String)] = [
    (regex("```[\\s\\S]*?(?:```|\\z)"), " "),            // fenced code, including an unfinished fence
    (regex("!\\[[^\\]]*\\]\\([^)]*\\)"), " "),             // images
    (regex("\\[([^\\]]+)\\]\\([^)]*\\)"), "$1"),           // links keep their label
    (regex("https?://\\S+"), "the linked page"),
    (regex("`([^`]+)`"), "$1"),
    (regex("^\\s*[#>*-]+\\s*", [.anchorsMatchLines]), ""), // headings, quotes, bullets
    (regex("[*_~]"), ""),
    (regex("\\s+"), " "),
]

public func cleanSpeech(_ text: String) -> String {
    var s = text
    for (re, template) in cleaners {
        s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

private let sentenceEnd = regex("[.!?](?=\\s|$)")
/// Abbreviations whose period is not a sentence end even when a space follows.
private let abbreviation = regex("(?:^|[\\s(])(?:e\\.g|i\\.e|etc|vs|cf|approx|Mr|Mrs|Ms|Dr|St|No)\\.$", [.caseInsensitive])

/// Index just past the first sentence end in 35..<260 of `text`. A period counts only when whitespace follows
/// it, or when it is the last character and `atEnd` (the text is finished or more whitespace already arrived);
/// a chunk ending right after a period ("in a." + "txt …") is held until more text arrives.
func sentenceCut(_ text: NSString, atEnd: Bool) -> Int? {
    for m in sentenceEnd.matches(in: text as String, range: NSRange(location: 0, length: text.length)) where m.range.location >= 35 && m.range.location < 260 {
        let end = m.range.location + 1
        if end == text.length && !atEnd { return nil }
        let head = text.substring(with: NSRange(location: max(0, end - 12), length: min(12, end)))
        if abbreviation.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) != nil { continue }
        return end
    }
    return nil
}

/// Splits streamed reply text into speakable sentences. Re-evaluates the full text on every update so an
/// incomplete fenced code block is never narrated.
public final class SpeechSegments {
    public private(set) var raw = ""
    private var spoken = 0
    private let emit: (String) -> Void

    public init(emit: @escaping (String) -> Void) { self.emit = emit }

    public func push(_ delta: String) { raw += delta; flush(final: false) }
    /// For hosts that report the whole text on each update (and for repairing missed deltas from text.ended).
    public func update(_ text: String) { raw = text; flush(final: false) }

    public func flush(final: Bool) {
        let clean = cleanSpeech(raw) as NSString
        if spoken > clean.length { spoken = clean.length }
        var remaining = clean.substring(from: spoken) as NSString
        // Whitespace after the last period has arrived (it is trimmed from the clean text), so the end is a boundary.
        let atEnd = final || raw.last.map { $0.isWhitespace } == true
        while remaining.length > 0 {
            var cut = sentenceCut(remaining, atEnd: atEnd) ?? -1
            if cut < 0 && remaining.length > 260 {
                let space = remaining.range(of: " ", options: .backwards, range: NSRange(location: 0, length: min(241, remaining.length))).location
                cut = space != NSNotFound && space > 0 ? space : 240
            }
            if cut < 0 && final { cut = remaining.length }
            if cut <= 0 { break }
            let segment = remaining.substring(to: cut).trimmingCharacters(in: .whitespacesAndNewlines)
            spoken += cut
            if !segment.isEmpty { emit(segment) }
            remaining = clean.substring(from: spoken) as NSString
        }
    }

    /// Treat everything received so far as spoken (barge-in, mute): later text is spoken from here on.
    public func skipToEnd() { spoken = (cleanSpeech(raw) as NSString).length }

    public func reset() { raw = ""; spoken = 0 }
}
