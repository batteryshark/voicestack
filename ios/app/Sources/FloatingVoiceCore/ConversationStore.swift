import Foundation

/// Immutable authority captured at the beginning of a draft, ASR utterance or typed send.
public struct TargetLease: Equatable, Sendable {
    public let sessionID: String
    public let generation: String
    public init(sessionID: String, generation: String) { self.sessionID = sessionID; self.generation = generation }
}

public struct BoundDraft: Equatable, Sendable {
    public let target: TargetLease
    public var text: String
    /// Stable identity permits an ASR final to replace its recoverable partial, never append a duplicate.
    public let recoveryID: UUID?
    public let nonAuthoritative: Bool
    public init(target: TargetLease, text: String = "", recoveryID: UUID? = nil, nonAuthoritative: Bool = false) {
        self.target = target; self.text = text; self.recoveryID = recoveryID; self.nonAuthoritative = nonAuthoritative
    }
    /// A selection change cannot re-authorize an old draft. UI must offer explicit review, never silent redirect.
    public func validate(current: TargetLease) throws {
        guard current == target else { throw ClientError("Draft belongs to an earlier target/generation; review before sending") }
    }
}

public struct NarrationUpdate: Equatable, Sendable {
    public let blockKey: String
    /// Diagnostic delta only. Feed the update to SpeechSegments.consume, not push(suffix): Markdown needs context.
    public let suffix: String
    public let context: String
    public let silentUTF16: Int
    public let final: Bool
}

/// Capture once before a logical history fetch and reuse across its cursor pages. Responses from
/// a previous reconnect cannot mutate this store. Sequence orders requests, not server revisions.
public struct HistorySnapshot: Equatable, Sendable {
    fileprivate let epoch: Int
    fileprivate let sequence: Int
    fileprivate let executionRevision: Int
}

/// Full upstream records live here, independent of the voice controller and its cleaned captions.
/// This is a reconciliation primitive; the future remote conversation lifecycle owns fetch/SSE ordering.
@MainActor
public final class ConversationStore {
    public private(set) var target: TargetLease
    public private(set) var records: [Data] = []
    public private(set) var liveBlocks: [String: String] = [:]
    public private(set) var active = false
    private var order: [String] = []
    private var byID: [String: Data] = [:]
    private var coveredText: [String: String] = [:]
    private var seenEvents: Set<String> = []
    private var eventOrder: [String] = []
    private var completedBlocks: Set<String> = []
    private var reconciled = false
    private var historyEpoch = 0
    private var historySequence = 0
    private var executionRevision = 0
    private var activeSnapshotSequence = -1
    private var snapshotRanks: [String: Int] = [:]
    private var liveOwned: Set<String> = []
    private var reconnectOwned: Set<String> = []
    private var speechContext: [String: String] = [:]
    private var silentUTF16: [String: Int] = [:]

    public init(target: TargetLease) { self.target = target }

    public func beginReconnect() {
        historyEpoch += 1; activeSnapshotSequence = -1; reconciled = false
        // Only current-connection live ownership can outrank its snapshots. An
        // interrupted block may have finished entirely while we were offline.
        reconnectOwned.formUnion(liveOwned.subtracting(completedBlocks))
        liveOwned.subtract(reconnectOwned)
    }

    public func beginHistorySnapshot() -> HistorySnapshot {
        historySequence += 1
        return HistorySnapshot(epoch: historyEpoch, sequence: historySequence, executionRevision: executionRevision)
    }

    /// Merge a page by stable message id, retaining *every* source field and content block.
    /// Ordinary history is silent. Only interrupted, previously live-owned blocks
    /// return catch-up narration, preserving their already-covered speech context.
    /// Async callers must capture/pass a HistorySnapshot; nil is for immediate, unversioned imports.
    @discardableResult
    public func reconcile(history: Data, active: Bool, for lease: TargetLease, snapshot: HistorySnapshot? = nil) throws -> [NarrationUpdate] {
        guard lease == target else { throw ClientError("History target/generation mismatch") }
        let snapshot = snapshot ?? HistorySnapshot(epoch: historyEpoch, sequence: 0, executionRevision: executionRevision)
        guard snapshot.epoch == historyEpoch else { throw ClientError("Stale history epoch") }
        guard let obj = try JSONSerialization.jsonObject(with: history) as? [String: Any],
              let messages = obj["data"] as? [[String: Any]] else { throw ClientError("Unexpected history DTO") }
        // Validate the entire page before modifying state.
        let entries: [(String, Data)] = try messages.map { record in
            guard let id = record["id"] as? String, !id.isEmpty else { throw ClientError("Message lacks id") }
            return (id, try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
        }
        for (id, raw) in entries {
            if byID[id] == nil { order.append(id) }
            let incoming = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
            let existing = byID[id].flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            // Live wins over snapshots; completed records never regress. Unversioned overlaps are
            // first-observation-wins. Explicit request order permits newer snapshot corrections.
            let ended = (existing?["time"] as? [String: Any])?["completed"] != nil
            let hasLive = liveOwned.contains { $0.hasPrefix("\(id):") }
            let newer = snapshot.sequence > (snapshotRanks[id] ?? -1)
            let preferIncoming = existing == nil || (!ended && !hasLive && newer)
            var merged = mergeRecord(preferIncoming ? incoming : (existing ?? [:]),
                                     fallback: preferIncoming ? (existing ?? [:]) : incoming)
            if !preferIncoming, var time = merged["time"] as? [String: Any],
               (existing?["time"] as? [String: Any])?["completed"] == nil {
                time.removeValue(forKey: "completed"); merged["time"] = time
            }
            byID[id] = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
            snapshotRanks[id] = max(snapshotRanks[id] ?? -1, snapshot.sequence)
        }
        // Installed DTO time.created is milliseconds; id breaks ties deterministically across overlaps/pages.
        var timestamps: [String: Double] = [:]
        for (id, raw) in byID {
            let record = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
            timestamps[id] = ((record?["time"] as? [String: Any])?["created"] as? NSNumber)?.doubleValue ?? 0
        }
        order.sort { left, right in
            let l = timestamps[left] ?? 0, r = timestamps[right] ?? 0
            return l == r ? left < right : l < r
        }
        var narration: [NarrationUpdate] = []
        for raw in order.compactMap({ byID[$0] }) {
            guard let record = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any], record["type"] as? String == "assistant" else { continue }
            guard let id = record["id"] as? String, let blocks = record["content"] as? [[String: Any]] else { continue }
            let completed = (record["time"] as? [String: Any])?["completed"] != nil
            for (ordinal, block) in blocks.enumerated() where block["type"] as? String == "text" {
                let key = "\(id):\(ordinal)"
                let text = block["text"] as? String ?? ""
                if liveOwned.contains(key) { continue }
                if reconnectOwned.contains(key) {
                    let previous = coveredText[key] ?? ""
                    let suffix = text.hasPrefix(previous) ? String(text.dropFirst(previous.count)) : ""
                    speechContext[key, default: ""] += suffix
                    // A non-prefix repair may correct display, but must not move
                    // the speech frontier backward and later repeat covered words.
                    if text.hasPrefix(previous) { coveredText[key] = text }
                    liveBlocks[key] = text
                    if !suffix.isEmpty || completed {
                        narration.append(NarrationUpdate(blockKey: key, suffix: suffix, context: speechContext[key] ?? "",
                                                         silentUTF16: silentUTF16[key] ?? 0, final: completed))
                    }
                    if completed { completedBlocks.insert(key); reconnectOwned.remove(key) }
                    continue
                }
                coveredText[key] = text
                liveBlocks[key] = text
                speechContext[key] = text
                silentUTF16[key] = (text as NSString).length
                if completed { completedBlocks.insert(key) }
            }
        }
        records = order.compactMap { byID[$0] }
        if snapshot.sequence >= activeSnapshotSequence, snapshot.executionRevision == executionRevision {
            self.active = active; activeSnapshotSequence = snapshot.sequence
        }
        reconciled = true
        return narration
    }

    /// Returns full speech context plus its silent boundary and final-flush signal.
    /// Missing-id/duplicate events are ignored; reconnect catch-up uses the same
    /// speech context, so a buffered end cannot repeat a snapshot-recovered suffix.
    public func receive(_ event: ServerEvent, eventID: String?, for lease: TargetLease) -> NarrationUpdate? {
        guard lease == target, event.sessionID == target.sessionID, reconciled else { return nil }
        guard let eventID, !eventID.isEmpty, !seenEvents.contains(eventID) else { return nil }
        seenEvents.insert(eventID); eventOrder.append(eventID)
        if eventOrder.count > 4096 { seenEvents.remove(eventOrder.removeFirst()) }
        if event.type == "session.execution.started" { active = true; executionRevision += 1 }
        if ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].contains(event.type) { active = false; executionRevision += 1 }
        guard event.data["assistantMessageID"] is String else { return nil }
        let key = event.blockKey
        guard !completedBlocks.contains(key) else { return nil }
        let previous = coveredText[key] ?? ""
        var final = false
        switch event.type {
        case "session.text.started": if liveBlocks[key] == nil { liveBlocks[key] = "" }; return nil
        case "session.text.delta": liveBlocks[key, default: ""] += event.delta ?? ""
        case "session.text.ended":
            if let text = event.text { liveBlocks[key] = text }
            completedBlocks.insert(key)
            final = true
        default: return nil
        }
        let text = liveBlocks[key] ?? ""
        liveOwned.insert(key)
        reconnectOwned.remove(key)
        coveredText[key] = text
        updateRecordText(key: key, event: event, text: text)
        // An authoritative non-append repair changes display, not already-covered speech. Still
        // deliver completion so the segmenter's pending short continuation is flushed exactly once.
        let suffix = text.hasPrefix(previous) ? String(text.dropFirst(previous.count)) : ""
        speechContext[key, default: ""] += suffix
        guard !suffix.isEmpty || final else { return nil }
        return NarrationUpdate(blockKey: key, suffix: suffix, context: speechContext[key] ?? "",
                               silentUTF16: silentUTF16[key] ?? 0, final: final)
    }

    /// Preserve unknown metadata recursively, including fields inside raw tool/attachment arrays.
    private func mergeRecord(_ preferred: [String: Any], fallback: [String: Any]) -> [String: Any] {
        var result = fallback
        for (key, value) in preferred {
            if let a = value as? [String: Any], let b = fallback[key] as? [String: Any] {
                result[key] = mergeRecord(a, fallback: b)
            } else if let a = value as? [[String: Any]], let b = fallback[key] as? [[String: Any]] {
                result[key] = (0..<max(a.count, b.count)).map { i in
                    i < a.count ? mergeRecord(a[i], fallback: i < b.count ? b[i] : [:]) : b[i]
                }
            } else { result[key] = value }
        }
        return result
    }

    private func updateRecordText(key: String, event: ServerEvent, text: String) {
        guard let id = event.data["assistantMessageID"] as? String,
              let ordinal = event.data["ordinal"] as? Int, ordinal >= 0 else { return }
        var record = byID[id].flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            ?? ["id": id, "type": "assistant"]
        var content = record["content"] as? [[String: Any]] ?? []
        while content.count <= ordinal { content.append([:]) }
        content[ordinal]["type"] = "text"; content[ordinal]["text"] = text
        record["content"] = content
        if byID[id] == nil { order.append(id) }
        byID[id] = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        records = order.compactMap { byID[$0] }
    }
}
