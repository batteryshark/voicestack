import Foundation
import Combine

public enum VoiceCaptureState: Sendable { case off, starting, running, repairing, failed }

/// Production voice state + light on-phone turn log. History owns older pages and tool detail.
@MainActor public final class VoiceSurface: ObservableObject {
    public let pill: PillModel
    @Published public var preparing = false
    @Published public var submitting = false
    @Published public private(set) var connection = "off"
    @Published public private(set) var active = false
    @Published public private(set) var user = ""
    @Published public private(set) var reply = ""
    public private(set) var target: TargetLease?
    public private(set) var binding = UUID()
    @Published public private(set) var capture: VoiceCaptureState?
    @Published public private(set) var connectionNotice: String?
    public var discardConfirmation: Bool { pill.you.discarded }
    private let now: () -> Double
    private var connectedOnce = false
    private var disconnectedAt: Double?
    private var latestUserID: String?
    private var userIsLive = false
    @Published public private(set) var log = ConversationVoiceLog()
    private var lastLogRecords: [Data] = []
    public init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 }, pill: PillModel? = nil) {
        self.now = now; self.pill = pill ?? PillModel(); self.pill.thinkingSwell = false
    }
    public var captureRunning: Bool { capture == .running || (capture == nil && pill.status.running && pill.status.phase == "ready") }
    public func updateCapture(_ state: VoiceCaptureState, owner: UUID) {
        guard owner == binding else { return }
        capture = state; refreshConnectionNotice()
    }
    public func tick() { pill.tick(); refreshConnectionNotice() }
    private func refreshConnectionNotice() {
        connectionNotice = disconnectedAt.map { now()-$0 >= 5000 || !captureRunning ? "Connection lost" : nil } ?? nil
    }
    private func refreshConnectionState() {
        if connection == "off" { connectedOnce = false; disconnectedAt = nil }
        else if connection == "connected" && (!pill.status.running || pill.status.connection == "connected") { connectedOnce = true; disconnectedAt = nil }
        else if connectedOnce && disconnectedAt == nil { disconnectedAt = now() }
        refreshConnectionNotice()
    }
    /// Explicit selection/controller replacement invalidates callbacks even for A→B→A
    /// or the same session with a new generation. Stable refreshes do not call this.
    @discardableResult public func replaceBinding(target: TargetLease?) -> UUID {
        let retainReply = target != nil && self.target == target
        binding = UUID(); self.target = target; latestUserID = nil; userIsLive = false
        active = false; connection = "off" // Activity belongs to the retired binding, not the next call.
        capture = nil; connectedOnce = false; disconnectedAt = nil; connectionNotice = nil
        user = ""; reply = ""; pill.resetCaptions()
        if !retainReply { log = ConversationVoiceLog(); lastLogRecords = [] }
        var status = ConversationController.Status()
        status.micMuted = pill.status.micMuted; status.outputMuted = pill.status.outputMuted
        pill.update(status: status)
        return binding
    }
    public func handle(_ event: CaptionEvent, owner: UUID) {
        guard owner == binding else { return }
        switch event {
        case .youLive, .youFinal: userIsLive = true
        case .posted, .discarded: userIsLive = false
        default: break
        }
        pill.handle(event)
        switch event {
        case .youStarted, .youLive, .youFinal, .posted, .discarded, .chiefQueued, .chiefFinalReceived, .chiefStarted, .chiefEnded, .chiefUnavailable:
            log.handle(event, userText: pill.you.text)
        default: break // Meter ticks must not rebuild/publish the conversation log.
        }
    }
    public func update(status: ConversationController.Status, owner: UUID) {
        guard owner == binding else { return }
        if status.newConversation { connection = status.connection; active = false }
        let voiceChanged = pill.status.running != status.running || pill.status.outputMuted != status.outputMuted
        pill.update(status: status)
        if voiceChanged { log.setVoice(running: status.running, muted: status.outputMuted) }
        refreshConnectionState()
    }
    public func typedPosted(_ text: String, owner: UUID) {
        guard owner == binding else { return }
        log.beginUser()
        pill.resetUserCaption()
        handle(.youFinal(text), owner: owner); handle(.posted(text), owner: owner)
    }
    public func update(records: [Data], connection: String, active: Bool) {
        self.connection = connection; self.active = active
        refreshConnectionState()
        var latestUser = "", userID: String?, replies: [String] = []
        for raw in records.reversed() {
            guard let row = MessageRow(raw) else { continue }
            if row.isPrincipal { latestUser = row.text; userID = row.id; break }
            if row.role == "Chief", !row.text.isEmpty { replies.append(row.text) }
        }
        if userID != latestUserID && !userIsLive { pill.resetUserCaption() }
        latestUserID = userID
        user = latestUser; reply = replies.reversed().joined(separator: "\n\n")
        if records != lastLogRecords { log.update(records: records); lastLogRecords = records }
    }
    public var state: String {
        if capture == .failed { return "Microphone stopped · try Start voice" }
        if capture == .repairing { return "Switching audio…" }
        if pill.status.newConversation && pill.status.running &&
            (!captureRunning || pill.status.phase != "ready" || pill.status.connection != "connected") {
            return "Preparing microphone…"
        }
        if !captureRunning && (preparing || (pill.status.running && pill.status.phase != "ready")) { return "Preparing microphone…" }
        if submitting || pill.status.sending { return "Sending message…" }
        if pill.status.speaking { return "\(AgentPresentation.name) speaking" }
        if pill.status.hearing { return "Listening" }
        if pill.you.holding { return pill.status.manualSend ? "Holding · tap Send now" : "Holding your thought" }
        switch pill.wait {
        case .countdown(let seconds, _): return "Sending in \(seconds)s · Send now"
        case .sending: return "Waiting for final words…"
        default: break
        }
        if active || pill.status.busy { return "\(AgentPresentation.name) thinking" }
        if !captureRunning && !pill.status.running { return "Voice off" }
        return pill.status.micMuted ? "Microphone muted" : "Listening"
    }
    public var userCaption: String { pill.you.isEmpty ? user : pill.you.text }
    public var chiefCaption: String { log.turns.last { $0.role == .chief }?.spoken ?? "" }
    public var chiefDetails: String { log.turns.last { $0.role == .chief }?.details ?? "" }
    public func beginTypedTurn(_ text: String, owner: UUID) {
        guard owner == binding else { return }
        log.beginUser(); log.handle(.youFinal(text), userText: text)
    }
}
