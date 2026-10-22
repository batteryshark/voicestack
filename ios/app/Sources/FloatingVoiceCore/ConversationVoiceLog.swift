import Foundation

public struct VoiceLogTurn: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case you, chief, system }
    public var id: String
    public var role: Role
    /// Display prose (including explicitly received final text), never audio evidence.
    public var spoken: String
    public var details: String
    public var pending = false
    public var panelMessageIDs: [String] = []
    public var sender: MessageSender? = nil
    /// Source snapshots approved for rich display only while voice is off or muted.
    public var markdownSources: [String] = []
    public var spokenBlocks: [MarkdownBlock] = []
    public var isPrincipal: Bool { role == .you && (sender ?? .principal).isPrincipal }
    public var displayLabel: String { role == .chief ? AgentPresentation.name : role == .system ? VoiceEndedNote.label : (sender ?? .principal).label }
    public var accessibilityLabel: String { role == .chief ? AgentPresentation.name : role == .system ? "From " + VoiceEndedNote.label : (sender ?? .principal).accessibilityLabel }
}

/// Latest on-phone conversation + live words. No extra history fetches, tools or blank bubbles.
public struct ConversationVoiceLog {
    private struct Source { let id: String; let role: VoiceLogTurn.Role; let text: String; var hasCanvas = false; var sender: MessageSender? = nil; var receivedFinal = false }
    private var sources: [Source] = []
    private var captions: [String: ChiefCaptionState] = [:]
    private var voiceRunning = false, voiceMuted = false
    private var liveWords = "", liveBaseUserID: String?, liveAcknowledged = false
    private var liveTurn = false
    private var latestSpeechID: String?
    private var cachedPage: [Data] = []
    private var cachedSources: [Source?] = []
    public private(set) var turns: [VoiceLogTurn] = []
    private var richSources: [String: String] = [:]
    private var displayCache: [String: VoiceLogTurn] = [:]
    var renderDisplay: (String, [String]) -> [MarkdownBlock] = VoiceLogMarkdown.blocks
    public init() {}

    private mutating func refreshTurns() {
        let previous = displayCache, render = renderDisplay
        var updated: [String: VoiceLogTurn] = [:]
        var result: [VoiceLogTurn] = []
        func append(_ value: VoiceLogTurn) {
            var turn = value
            guard !turn.spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !turn.details.isEmpty || !turn.panelMessageIDs.isEmpty else { return }
            if let old = previous[turn.id], old.role == turn.role, old.spoken == turn.spoken, old.markdownSources == turn.markdownSources { turn.spokenBlocks = old.spokenBlocks } else {
                turn.spokenBlocks = render(turn.spoken, turn.markdownSources)
            }
            updated[turn.id] = turn
            // Several records in the same speaker's turn remain one growing bubble.
            if let last = result.last, turn.role != .system, last.role == turn.role, last.pending == turn.pending, last.sender == turn.sender {
                result[result.count-1].spoken = [last.spoken, turn.spoken].filter { !$0.isEmpty }.joined(separator: "\n\n")
                result[result.count-1].details = [last.details, turn.details].filter { !$0.isEmpty }.joined(separator: "\n\n")
                result[result.count-1].pending = turn.pending
                result[result.count-1].panelMessageIDs += turn.panelMessageIDs
                result[result.count-1].markdownSources += turn.markdownSources
                result[result.count-1].spokenBlocks += turn.spokenBlocks
            } else { result.append(turn) }
        }
        for source in sources {
            if source.role == .system { append(VoiceLogTurn(id: source.id, role: .system, spoken: source.text, details: "", sender: source.sender)) }
            else if source.role == .you { append(VoiceLogTurn(id: source.id, role: .you, spoken: source.text, details: "", sender: source.sender)) }
            else if source.receivedFinal {
                // This separate display event is NOT sentence-start/heard progression.
                // No source record/history fabrication or playback callback is involved.
                let content = ChiefReplyContent(source.text)
                append(VoiceLogTurn(id:source.id,role:.chief,spoken:content.spoken,details:content.details))
            }
            else if let caption = captions[source.id] {
                let rich = (!voiceRunning || voiceMuted) && !source.text.isEmpty && richSources[source.id] == source.text
                append(VoiceLogTurn(id: source.id, role: .chief, spoken: caption.spoken, details: caption.details, panelMessageIDs: source.hasCanvas ? [source.id] : [], markdownSources: rich ? [source.text] : []))
            }
        }
        if liveTurn, !liveWords.isEmpty, !liveIsRecorded {
            append(VoiceLogTurn(id: "voice-live-user", role: .you, spoken: liveWords, details: "", pending: !liveAcknowledged))
        }
        turns = result; displayCache = updated
    }
    private mutating func revealKnownRecords() {
        for source in sources where source.role == .chief { richSources[source.id] = source.text }
    }
    private var latestUser: Source? { sources.last { $0.role == .you && $0.sender?.isPrincipal == true } }
    private var liveIsRecorded: Bool {
        guard let latestUser, latestUser.id != liveBaseUserID else { return false }
        return latestUser.text.trimmingCharacters(in: .whitespacesAndNewlines) == liveWords.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public mutating func beginUser() {
        if !liveTurn || liveAcknowledged { liveBaseUserID = latestUser?.id; liveWords = "" }
        liveTurn = true; liveAcknowledged = false
        refreshTurns()
    }
    public mutating func setVoice(running: Bool, muted: Bool) {
        guard voiceRunning != running || voiceMuted != muted else { return }
        voiceRunning = running; voiceMuted = muted
        if muted || !running {
            for id in Array(captions.keys) { captions[id]?.mute(true) }
            revealKnownRecords()
        }
        refreshTurns()
    }
    public mutating func update(records: [Data]) {
        let page = Array(records.suffix(40))
        let previous = Dictionary(cachedSources.compactMap { $0 }.map { ($0.id, $0.text) }, uniquingKeysWith: { _, new in new })
        let projected: [Source?] = page.enumerated().map { index, raw in
            if index < cachedPage.count && raw == cachedPage[index] { return cachedSources[index] }
            guard let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any], let id = obj["id"] as? String else { return nil }
            if ["user", "synthetic"].contains(obj["type"] as? String ?? ""), let row = MessageRow(raw), !row.text.isEmpty { return Source(id: id, role: row.isSystemNote ? .system : .you, text: row.text, sender: row.sender) }
            guard obj["type"] as? String == "assistant" else { return nil }
            let text = ReplyText.join((obj["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String })
            let hasCanvas = (obj["content"] as? [[String: Any]] ?? []).contains { block in
                block["type"] as? String == "tool" && (block["name"] as? String ?? "").hasSuffix("canvas_show")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasCanvas else { return nil }
            return Source(id: id, role: .chief, text: text, hasCanvas: hasCanvas)
        }
        sources = projected.compactMap { $0 }
        cachedPage = page; cachedSources = projected
        for source in sources where source.role == .chief {
            if previous[source.id] == source.text && captions[source.id] != nil { continue }
            var caption = captions[source.id] ?? ChiefCaptionState()
            caption.source(source.text, id: source.id, live: voiceRunning, muted: voiceMuted || !voiceRunning)
            captions[source.id] = caption
        }
        let retained = Set(sources.map(\.id)).union(latestSpeechID.map { [$0] } ?? [])
        captions = captions.filter { retained.contains($0.key) }
        richSources = richSources.filter { retained.contains($0.key) }
        if !voiceRunning || voiceMuted { revealKnownRecords() }
        if liveAcknowledged && liveIsRecorded { liveTurn = false; liveWords = "" }
        refreshTurns()
    }
    public mutating func handle(_ event: CaptionEvent, userText: String) {
        switch event {
        case .youStarted: beginUser()
        case .youLive, .youFinal:
            if !liveTurn { beginUser() }
            liveWords = userText
        case .posted(let text):
            if !liveTurn { beginUser() }
            liveWords = text; liveAcknowledged = true
            if liveIsRecorded { liveTurn = false; liveWords = "" }
        case .discarded: liveTurn = false; liveWords = ""
        case .chiefFinalReceived(let id, let text):
            guard !sources.contains(where:{ $0.id == id && $0.receivedFinal }) else { return }
            latestSpeechID = id
            let source = Source(id:id,role:.chief,text:text,receivedFinal:true)
            if let index = sources.firstIndex(where:{ $0.id == id }) { sources[index] = source }
            else { sources.append(source) }
        case .chiefQueued(let label, let text), .chiefStarted(let label, let text), .chiefEnded(let label, let text, _):
            let id = label.lastIndex(of: ":").map { String(label[..<$0]) } ?? label
            latestSpeechID = id
            var caption = captions[id] ?? ChiefCaptionState()
            switch event {
            case .chiefQueued: caption.queued(label: label, text: text)
            case .chiefStarted: caption.started(label: label, text: text)
            case .chiefEnded(_, _, let outcome): caption.ended(label: label, text: text, outcome: outcome)
            default: break
            }
            captions[id] = caption
            // Narration callbacks can precede ConversationStore's onChange in this same turn.
            if !sources.contains(where: { $0.id == id }) { sources.append(Source(id: id, role: .chief, text: "")) }
        case .chiefUnavailable:
            if let id = latestSpeechID ?? sources.last(where: { $0.role == .chief })?.id { captions[id]?.unavailable() }
        default: break
        }
        refreshTurns()
    }
}

/// No partial source mapping: active narration uses exactly the old caption
/// renderer. Approved full snapshots reuse History; fences remain in details.
private enum VoiceLogMarkdown {
    static func blocks(_ revealed: String, _ sources: [String]) -> [MarkdownBlock] {
        guard !sources.isEmpty else { return BlockMarkdown.renderBlocks(revealed) }
        return sources.flatMap { BlockMarkdown.parse($0) }.compactMap { block in
            switch block {
            case .code, .markdown: return nil // Already shown, unchanged, in turn.details.
            default: return block
            }
        }
    }
}
