import Foundation

/// Local first-failure boundary, not an inferred remote root cause. Stable numeric
/// diagnostics only; never serialize arbitrary error bodies or transport details.
public enum OpenVoiceFailureOrigin: Int {
    case unspecified = 0, inputAdmission = 1, send = 2, receive = 3, serverEvent = 4
    case serverError = 5, recognition = 6, inputCreditTimeout = 7, playbackTimeout = 8
    case clearTimeout = 9, socketClosed = 10, ownerClose = 11
}

/// Transport ownership is injected. Implementations must reject redirects, bound their
/// receive message to 64 KiB and writable bytes to 256 KiB, and never log headers.
/// No URLSession/network connection is created by this slice.
@MainActor public protocol OpenVoiceWebSocket: AnyObject {
    var writableBytes: Int { get }
    /// Return successfully only after transport handoff, not enqueue/reservation.
    /// The peer's receive path may race this completion. Failure/cancellation must throw.
    func send(text: String) async throws
    func receive() async throws -> Data
    func close()
}

public struct OpenVoiceMediaFence: Equatable {
    public let call: UUID
    public let media: String
    public init(call: UUID, media: String) { self.call = call; self.media = media }
}

public struct OpenVoicePreparedPCM: Equatable {
    public let fence: OpenVoiceMediaFence
    public let responseID: String
    public let itemID: String
    public let playbackEpoch: UUID
    public let sourceOffset: Int
    public let pcm: Data
    public let sampleRate = 24_000
}

/// Single main-executor media facade. Owner explicitly drives flush/receiveOne/tick;
/// there is no reconnect, fallback, automatic response request or unbounded task fanout.
@MainActor public final class OpenVoiceClient {
    public enum State: Equatable { case awaitingCreated, created, configured, ready, failed, closed }
    public private(set) var state: State = .awaitingCreated
    public let fence: OpenVoiceMediaFence
    public private(set) var effectiveSession: OpenVoiceJSON?
    public private(set) var sentSamples = 0
    public private(set) var admittedSamples = 0
    public private(set) var consumedSamples = 0
    public private(set) var renderedSamples = 0
    public private(set) var generatedSamples = 0
    public private(set) var activeResponseID: String?
    public private(set) var outputItemID: String?
    public private(set) var playbackEpoch = UUID()
    public private(set) var failure: OpenVoiceFailure?
    private let diagnostics: StageDiagnostics
    private let diagnosticCall: Int
    /// Synchronous bounded delivery, not an AsyncStream with an unbounded buffer.
    public var onEvent: ((OpenVoiceEvent) -> Void)?
    public var onResponse: ((OpenVoiceEvent) -> Void)?
    public var onState: ((State) -> Void)?
    private let socket: OpenVoiceWebSocket
    private var activated = false, flushing = false, receiving = false
    private let mediaOwnerToken: UUID
    private var acceptedReadySession: String?
    private(set) var readinessEpoch = UUID()
    private var flushJoiner: CheckedContinuation<Void, Error>?
    private var flushJoinerID: UUID?
    private var sendInFlight = false
    /// Configuration/native activation alone cannot authorize media writes.
    public var mediaReadyAccepted: Bool {
        state == .ready && acceptedReadySession != nil && acceptedReadySession == effectiveSession?["id"].string
    }
    private var pending: [(event: OpenVoiceEvent, data: Data, samples: Int)] = []
    private var pendingBytes = 0, pendingPCMBytes = 0, segmentSamples = 0
    private var output: [OpenVoicePreparedPCM] = []
    private var outputBytes = 0
    private var canonical: OpenVoiceJSON?
    private var responsePending = false, exchangeClaimed = false
    private var responseMetadata: OpenVoiceJSON?
    private var itemOpen = false, partOpen = false, audioClosed = false, textClosed = false
    private var transcriptClosed = false, partType: String?
    private var outputStopped = false
    private var lastProgress = 0.0, lastPlaybackSend = -Double.infinity
    private var lastPlaybackState: String?
    private var inputStalledSince: TimeInterval?
    // Bound ID tracking: fail closed on exhaustion; never evict and accept replay.
    private var serverIDs = Set<String>()
    private var segmentOwner: UUID?
    private var retiringSegment: UUID?, clearSendOwner: UUID?
    private var clearSent = false
    private var heldClear: OpenVoiceEvent?
    private var clearStalledSince: TimeInterval?
    private var waitingSegment: (owner: UUID, ready: () -> Void, failed: () -> Void)?
    private var segmentCommitted = false
    private var segmentCommitSent = false
    private struct CommitSend { let id: UUID; let owner: UUID }
    private var commitSend: CommitSend?
    private var heldRecognition: [(event: OpenVoiceEvent, now: TimeInterval)] = []
    private var heldRecognitionBytes = 0
    private let committedItemLimit: Int
    // Media/client-lifetime ownership, not event-ID deduplication. Never evict.
    private var committedItemOwners: [String: UUID] = [:]
    public static let maxCommittedItems = 4096
    static let maxHeldRecognitionEvents = 16, maxHeldRecognitionBytes = 65_536
    var recognitionEvent: ((OpenVoiceEvent) -> Void)?
    var recognitionFailure: (() -> Void)?
    public var queuedPCMBytes: Int { pendingPCMBytes + outputBytes }
    public var hasPendingInput: Bool { segmentSamples > 0 || pendingPCMBytes > 0 }

    public convenience init(socket: OpenVoiceWebSocket, fence: OpenVoiceMediaFence) throws {
        try self.init(socket: socket, fence: fence, committedItemLimit: Self.maxCommittedItems)
    }
    // Smaller limit is available to deterministic exhaustion tests, never a larger production allowance.
    init(socket: OpenVoiceWebSocket, fence: OpenVoiceMediaFence, committedItemLimit: Int, mediaOwnerToken: UUID = UUID(), diagnostics: StageDiagnostics = .shared) throws {
        try OpenVoiceWire.check((1...Self.maxCommittedItems).contains(committedItemLimit))
        self.committedItemLimit = committedItemLimit
        self.mediaOwnerToken = mediaOwnerToken
        self.diagnostics = diagnostics; diagnosticCall = diagnostics.playbackCallToken
        try OpenVoiceWire.id(.string(fence.media)); self.socket = socket; self.fence = fence
    }
    /// Recipient media bearer only. This constructs a request; it does NOT connect.
    /// `origin` must come from trusted paired configuration, not a lease/event URL.
    public static func mediaRequest(origin: URL, endpoint: URL, recipientMediaLease: String) throws -> URLRequest {
        guard let o = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let e = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw OpenVoiceFailure() }
        try OpenVoiceWire.check(o.scheme == "https" && e.scheme == "wss" && o.host != nil && e.host == o.host && (e.port ?? 443) == (o.port ?? 443))
        try OpenVoiceWire.check(o.user == nil && o.password == nil && o.query == nil && o.fragment == nil && (o.path.isEmpty || o.path == "/"))
        try OpenVoiceWire.check(e.user == nil && e.password == nil && e.fragment == nil && e.percentEncodedPath == "/floating-voice/v1/realtime" && e.percentEncodedQuery == "model=local-chain-m1")
        try OpenVoiceWire.check(!recipientMediaLease.isEmpty && recipientMediaLease.utf8.count <= 4096 && recipientMediaLease.utf8.allSatisfy { $0 >= 33 && $0 <= 126 })
        var r = URLRequest(url: endpoint); r.setValue("Bearer \(recipientMediaLease)", forHTTPHeaderField: "Authorization"); return r
    }
    private func transition(_ s: State) { state = s; onState?(s) }
    // Module-internal owner capability: no grant method/token is exposed through
    // the pump's public client. Tests must explicitly establish the same precondition.
    func acceptMediaReady(owner: UUID, fence: OpenVoiceMediaFence, sessionID: String, epoch: UUID) throws {
        try OpenVoiceWire.check(owner == mediaOwnerToken && fence == self.fence && epoch == readinessEpoch && state == .ready && effectiveSession?["id"].string == sessionID)
        acceptedReadySession = sessionID
        try activateWaitingSegment()
    }
    private func revokeMediaReady() { acceptedReadySession = nil; readinessEpoch = UUID() }
    public func setNativeActivated(_ value: Bool, fence: OpenVoiceMediaFence) {
        guard fence == self.fence, state != .closed, state != .failed else { return }
        activated = value
        if !value { revokeMediaReady() }
        if effectiveSession != nil && [.configured,.ready].contains(state) { transition(value ? .ready : .configured) }
    }
    public func fail(_ error: OpenVoiceFailure = OpenVoiceFailure("local_failure"), origin: OpenVoiceFailureOrigin = .unspecified) {
        guard state != .failed && state != .closed else { return }
        // Record synchronously BEFORE socket closure/onState can tear down capture
        // or reenter fail. Sent is reserved/handoff-attempted, NOT remote receipt;
        // consumed is ingress credit, NOT recognizer acceptance or heard speech.
        diagnostics.record(.call, .failed, audio: CaptureSnapshot([
            .openVoiceFailureOrigin: Double(origin.rawValue),
            .openVoiceAdmittedSamples: Double(admittedSamples),
            .openVoiceSentSamples: Double(sentSamples),
            .openVoiceConsumedSamples: Double(consumedSamples)
        ]), callBank: diagnosticCall)
        revokeMediaReady(); finishFlushJoiner(.failure(error))
        failure = error; pending.removeAll(); output.removeAll(); pendingBytes = 0; pendingPCMBytes = 0; outputBytes = 0
        clearCommitHandoff()
        let waitingFailure = waitingSegment?.failed; waitingSegment = nil
        retiringSegment = nil; clearSendOwner = nil; heldClear = nil; clearStalledSince = nil
        socket.close(); transition(.failed); recognitionFailure?()
        waitingFailure?()
    }
    /// Even normal socket closure is not successful ASR/response finalization.
    public func socketClosed(fence: OpenVoiceMediaFence) {
        guard fence == self.fence else { return }; fail(origin: .socketClosed)
    }
    public func close() {
        guard state != .closed else { return }
        revokeMediaReady(); finishFlushJoiner(.failure(OpenVoiceFailure("local_failure")))
        if segmentOwner != nil || waitingSegment != nil || activeResponseID != nil || responsePending { fail(origin: .ownerClose); return }
        socket.close(); pending.removeAll(); output.removeAll(); pendingBytes = 0; pendingPCMBytes = 0; outputBytes = 0; transition(.closed)
        clearCommitHandoff()
    }
    func acquireSegment(_ owner: UUID) throws {
        try OpenVoiceWire.check(state == .ready && segmentOwner == nil, "local_failure")
        segmentOwner = owner; segmentCommitted = false; segmentCommitSent = false; segmentSamples = 0
    }
    /// Candidate-only continuation slot while the preceding clear is in flight.
    /// Exactly one waiting recognizer; no Task/waiter array or cross-segment PCM append.
    func acquireCandidateSegment(_ owner: UUID, ready: @escaping () -> Void, failed: @escaping () -> Void) throws -> Bool {
        try OpenVoiceWire.check(waitingSegment == nil)
        if segmentOwner == nil { try acquireSegment(owner); return true }
        try OpenVoiceWire.check(retiringSegment != nil && waitingSegment == nil && state != .failed && state != .closed)
        waitingSegment = (owner,ready,failed); return false
    }
    func cancelWaitingSegment(_ owner: UUID) {
        if waitingSegment?.owner == owner { waitingSegment = nil }
    }
    func retireUnsentSegment(_ owner: UUID) throws {
        try OpenVoiceWire.check(segmentOwner == owner && retiringSegment == nil && (state == .ready || state == .configured))
        // Preserve a send already handed to the socket. Drop only unsent append/commit
        // records; a clear goes AFTER the retained send, never into a prior committed item.
        var retained: [(event: OpenVoiceEvent, data: Data, samples: Int)] = []
        var removedCommit = false
        for (index,p) in pending.enumerated() {
            if [.append,.commit].contains(p.event.kind) && !(index == 0 && sendInFlight) {
                pendingBytes -= p.data.count; pendingPCMBytes -= p.samples * 2
                if p.event.kind == .commit { removedCommit = true }
            } else { retained.append(p) }
        }
        pending = retained
        if removedCommit { segmentCommitted = false }
        retiringSegment = owner; clearSent = false; clearStalledSince = nil
        recognitionEvent = nil; recognitionFailure = nil
        try enqueue(.object(["type":.string("input_audio_buffer.clear")]))
    }
    private func finishRetirement() throws {
        guard let owner = retiringSegment else { return }
        try OpenVoiceWire.check(clearSent && segmentOwner == owner)
        retiringSegment = nil; clearSendOwner = nil; heldClear = nil; clearStalledSince = nil
        releaseSegment(owner)
        try activateWaitingSegment()
    }
    private func activateWaitingSegment() throws {
        if segmentOwner == nil, mediaReadyAccepted, let waiting = waitingSegment {
            waitingSegment = nil
            do { try acquireSegment(waiting.owner); waiting.ready() }
            catch { waiting.failed(); throw error }
        }
    }
    func releaseSegment(_ owner: UUID) {
        guard segmentOwner == owner else { return }; segmentOwner = nil; segmentCommitted = false; segmentSamples = 0
        clearCommitHandoff()
    }
    private func clearCommitHandoff() {
        commitSend = nil; segmentCommitSent = false
        heldRecognition.removeAll(); heldRecognitionBytes = 0
    }
    func append(_ pcm: Data, owner: UUID) throws {
        try OpenVoiceWire.check(segmentOwner == owner && !segmentCommitted, "local_failure")
        try enqueue(.object(["type":.string("input_audio_buffer.append"),"audio":.string(pcm.base64EncodedString())]))
    }
    func commit(_ owner: UUID) throws {
        try OpenVoiceWire.check(segmentOwner == owner && !segmentCommitted, "local_failure")
        try enqueue(.object(["type":.string("input_audio_buffer.commit")])); segmentCommitted = true
    }
    func abortSegment(_ owner: UUID) {
        guard segmentOwner == owner else { return }
        // Cannot safely undo partially flushed PCM without a clear ACK and new owner fence.
        fail(origin: .recognition)
    }
    public func enqueue(_ body: OpenVoiceJSON) throws {
        do {
            try OpenVoiceWire.check(state != .failed && state != .closed, "local_failure")
            let c: OpenVoiceJSON = .object(["effectiveSession": effectiveSession ?? .null,
                "bufferSamples":.number(Double(segmentSamples)), "canonicalItem":canonical ?? .null,
                "activeResponseId": activeResponseID.map(OpenVoiceJSON.string) ?? (responsePending ? .string("pending") : .null),
                "truncateTarget":.object(["item_id":outputItemID.map(OpenVoiceJSON.string) ?? .null,"generatedSamples":.number(Double(generatedSamples))])])
            let e = try OpenVoiceWire.client(body, context: c)
            if e.kind == .sessionUpdate { try OpenVoiceWire.check(state == .created || state == .configured || state == .ready) }
            else { try OpenVoiceWire.check(state == .ready || (e.kind == .clear && state == .configured), "local_failure") }
            if e.kind == .responseCreate { try OpenVoiceWire.check(!exchangeClaimed, "operation_conflict") }
            let samples = e.kind == .append ? try OpenVoiceWire.pcm(e["audio"]).count / 2 : 0
            try OpenVoiceWire.check(segmentSamples + samples <= OpenVoiceWire.maxSegmentSamples, "invalid_audio")
            let d = try body.encoded()
            try OpenVoiceWire.check(pending.count < 256 && pendingBytes + d.count + socket.writableBytes <= OpenVoiceWire.maxWritableBytes, "local_failure")
            try OpenVoiceWire.check(pendingPCMBytes + samples * 2 <= OpenVoiceWire.maxQueueBytes && queuedPCMBytes + samples * 2 <= OpenVoiceWire.maxAggregateBytes, "local_failure")
            pending.append((e,d,samples)); pendingBytes += d.count; pendingPCMBytes += samples * 2
            segmentSamples += samples; admittedSamples += samples
            if e.kind == .clear { segmentSamples = 0 }
            if e.kind == .itemCreate { canonical = e["item"] }
            if e.kind == .responseCreate { responsePending = true; exchangeClaimed = true; responseMetadata = e["response"]["metadata"] }
        } catch { let e = error as? OpenVoiceFailure ?? OpenVoiceFailure("local_failure"); fail(e, origin: .inputAdmission); throw e }
    }
    /// At most one writer/send, plus one bounded joining caller (pump + buffered
    /// recognition). Blocked readiness/credit returns bounded queue admission, not
    /// proof of handoff. Concurrent callers never start a competing socket send.
    public func flush() async throws {
        try OpenVoiceWire.check(state != .failed && state != .closed, "local_failure")
        if flushing { try await joinFlush(); return }
        flushing = true
        defer { flushing = false; sendInFlight = false; finishFlushJoiner(.success(())) }
        do {
            try Task.checkCancellation()
            while state != .closed && state != .failed, let p = pending.first {
                // This is the shared boundary for EVERY flush caller. Only the
                // configuration exchange may precede exact-owner readiness ACK.
                if p.event.kind != .sessionUpdate && !mediaReadyAccepted { return }
                if p.samples > 0 && (state != .ready || sentSamples + p.samples - consumedSamples > OpenVoiceWire.windowSamples) { return }
                try OpenVoiceWire.check(socket.writableBytes + p.data.count <= OpenVoiceWire.maxWritableBytes, "local_failure")
                // Reserve before await so a synchronous peer's credit can never exceed sent cursor.
                sentSamples += p.samples
                let handoff = p.event.kind == .commit ? segmentOwner.map { CommitSend(id: UUID(), owner: $0) } : nil
                if let handoff { commitSend = handoff }
                let clearOwner = p.event.kind == .clear ? retiringSegment : nil
                if let clearOwner { clearSendOwner = clearOwner }
                sendInFlight = true
                try await socket.send(text: String(decoding: p.data, as: UTF8.self))
                sendInFlight = false
                try Task.checkCancellation()
                guard state != .closed && state != .failed else { return }
                if let handoff {
                    try OpenVoiceWire.check(commitSend?.id == handoff.id && segmentOwner == handoff.owner)
                    commitSend = nil; segmentCommitSent = true
                }
                pending.removeFirst(); pendingBytes -= p.data.count; pendingPCMBytes -= p.samples * 2
                if let clearOwner {
                    try OpenVoiceWire.check(retiringSegment == clearOwner && clearSendOwner == clearOwner)
                    clearSendOwner = nil; clearSent = true
                    if let held = heldClear { heldClear = nil; try handle(held,now:0) }
                }
                if let handoff {
                    let held = heldRecognition; heldRecognition.removeAll(); heldRecognitionBytes = 0
                    for h in held {
                        // A final callback may release A and synchronously start B. Never
                        // deliver the remainder of A's held batch to B's observer.
                        guard state != .failed && state != .closed && segmentOwner == handoff.owner else { break }
                        try handle(h.event, now: h.now)
                    }
                }
            }
        } catch { fail(origin: .send); throw OpenVoiceFailure("local_failure") }
    }
    private func finishFlushJoiner(_ result: Result<Void, Error>) {
        let waiter = flushJoiner; flushJoiner = nil; flushJoinerID = nil; waiter?.resume(with: result)
    }
    private func joinFlush() async throws {
        try OpenVoiceWire.check(flushJoiner == nil, "local_failure")
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                flushJoinerID = id; flushJoiner = continuation
            }
            try Task.checkCancellation()
        }, onCancel: { [weak self] in DispatchQueue.main.async {
            guard let self, self.flushJoinerID == id else { return }; self.fail()
        } })
    }
    public func receiveOne(clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) async throws {
        guard !receiving else { throw OpenVoiceFailure("local_failure") }; receiving = true; defer { receiving = false }
        do { let d = try await socket.receive(); try receive(d, fence: fence, now: clock()) }
        catch { fail(origin: .receive); throw OpenVoiceFailure("local_failure") }
    }
    public func receive(_ data: Data, fence: OpenVoiceMediaFence, now: TimeInterval) throws {
        guard fence == self.fence, state != .failed, state != .closed else { return }
        do {
            let e = try OpenVoiceWire.server(OpenVoiceWire.parse(data))
            let id = e["event_id"].string!
            try OpenVoiceWire.check(serverIDs.count < 65_536 && serverIDs.insert(id).inserted)
            if e.kind == .cleared && clearSendOwner != nil {
                try OpenVoiceWire.check(heldClear == nil); heldClear = e; return
            }
            if let handoff = commitSend, segmentOwner == handoff.owner, isRecognition(e) {
                try OpenVoiceWire.check(heldRecognition.count < Self.maxHeldRecognitionEvents && heldRecognitionBytes + data.count <= Self.maxHeldRecognitionBytes, "local_failure")
                heldRecognition.append((e,now)); heldRecognitionBytes += data.count
                return // No ACK binding, transcript callback or public recognition event before handoff.
            }
            try handle(e, now: now)
        } catch { let e = error as? OpenVoiceFailure ?? OpenVoiceFailure("local_failure"); fail(e, origin: .serverEvent); throw e }
    }
    private func isRecognition(_ e: OpenVoiceEvent) -> Bool {
        switch e.kind {
        case .committed,.transcriptionCompleted,.transcriptionFailed: return true
        case .itemAdded,.itemDone: return e["item"]["role"] == .string("user")
        default: return false
        }
    }
    private func handle(_ e: OpenVoiceEvent, now: TimeInterval) throws {
            if state == .awaitingCreated { try OpenVoiceWire.check(e.kind == .sessionCreated) }
            switch e.kind {
            case .sessionCreated:
                try OpenVoiceWire.check(state == .awaitingCreated); effectiveSession = e["session"]; transition(.created)
            case .sessionUpdated:
                try OpenVoiceWire.check(state != .awaitingCreated && activeResponseID == nil && !responsePending)
                try OpenVoiceWire.check(e["session"]["id"] == effectiveSession?["id"])
                effectiveSession = e["session"]; transition(activated ? .ready : .configured)
            case .flow:
                // Old media callbacks are ignored, not credit for this owner.
                if e["media_epoch"].string != self.fence.media { return }
                let n = Int(e["input_consumed_samples"].number!)
                try OpenVoiceWire.check(n <= sentSamples, "invalid_position")
                if n > consumedSamples { inputStalledSince = nil }
                consumedSamples = max(consumedSamples,n)
            case .committed:
                if segmentOwner != nil { try OpenVoiceWire.check(segmentCommitted && segmentCommitSent) }
                let item = e["item_id"].string!
                try OpenVoiceWire.check(committedItemOwners[item] == nil, "item_mismatch")
                try OpenVoiceWire.check(committedItemOwners.count < committedItemLimit, "local_failure")
                committedItemOwners[item] = segmentOwner ?? UUID()
            case .cleared:
                try finishRetirement()
            case .responseCreated:
                try OpenVoiceWire.check(responsePending && activeResponseID == nil)
                try OpenVoiceWire.check(e["response"]["metadata"] == responseMetadata)
                activeResponseID = e["response"]["id"].string; responsePending = false
                generatedSamples = 0; renderedSamples = 0; playbackEpoch = UUID(); outputItemID = nil
                outputStopped = false
                lastProgress = now; itemOpen = false; partOpen = false; partType = nil; audioClosed = false; transcriptClosed = false; textClosed = false
            case .outputItemAdded:
                try matching(e); try OpenVoiceWire.check(!itemOpen && outputItemID == nil)
                outputItemID = e["item"]["id"].string; itemOpen = true
            case .partAdded:
                try matching(e, item: true); try OpenVoiceWire.check(itemOpen && !partOpen && partType == nil)
                partType = e["part"]["type"].string; partOpen = true
            case .audioDelta,.audioDone,.transcriptDelta,.transcriptDone,.textDelta,.textDone:
                try matching(e, item: true); try OpenVoiceWire.check(partOpen)
                if e.kind == .textDelta || e.kind == .textDone { try OpenVoiceWire.check(partType == "text" && !textClosed); if e.kind == .textDone { textClosed = true } }
                else if e.kind == .transcriptDelta || e.kind == .transcriptDone { try OpenVoiceWire.check(partType == "audio" && !transcriptClosed); if e.kind == .transcriptDone { transcriptClosed = true } }
                else {
                    try OpenVoiceWire.check(partType == "audio" && !audioClosed)
                    if e.kind == .audioDone { audioClosed = true }
                    else {
                         // A configured same-call socket may receive already-in-flight
                         // prepared PCM during a real native graph repair. Existing
                         // source-window bounds remain in force; no new write grant.
                         try OpenVoiceWire.check(state == .ready || state == .configured, "local_failure")
                        let pcm = try OpenVoiceWire.pcm(e["delta"])
                        try OpenVoiceWire.check(output.count < 256 && outputBytes + pcm.count <= OpenVoiceWire.maxQueueBytes && queuedPCMBytes + pcm.count <= OpenVoiceWire.maxAggregateBytes, "local_failure")
                        try OpenVoiceWire.check(generatedSamples + pcm.count / 2 - renderedSamples <= OpenVoiceWire.windowSamples, "invalid_position")
                        output.append(OpenVoicePreparedPCM(fence: self.fence, responseID: activeResponseID!, itemID: outputItemID!, playbackEpoch: playbackEpoch, sourceOffset: generatedSamples, pcm: pcm))
                        if generatedSamples == renderedSamples { lastProgress = now }
                        outputBytes += pcm.count; generatedSamples += pcm.count / 2
                    }
                }
            case .partDone:
                try matching(e, item: true); try OpenVoiceWire.check(partOpen && e["part"]["type"].string == partType)
                try OpenVoiceWire.check(partType == "audio" ? audioClosed && transcriptClosed : textClosed); partOpen = false
            case .outputItemDone:
                try matching(e); try OpenVoiceWire.check(itemOpen && !partOpen && e["item"]["id"].string == outputItemID); itemOpen = false
            case .responseDone:
                try OpenVoiceWire.check(e["response"]["id"].string == activeResponseID && activeResponseID != nil && !itemOpen && !partOpen)
                try OpenVoiceWire.check(e["response"]["metadata"] == responseMetadata)
                completedResponseID = activeResponseID
                activeResponseID = nil // Does not modify renderedSamples or mark delivery complete.
            case .error: fail(OpenVoiceFailure(e["error"]["code"].string!), origin: .serverError)
            default: break
            }
            recognitionEvent?(e); onEvent?(e)
            if e.kind.rawValue.hasPrefix("response.") { onResponse?(e) }
    }
    private func matching(_ e: OpenVoiceEvent, item: Bool = false) throws {
        try OpenVoiceWire.check(activeResponseID != nil && e["response_id"].string == activeResponseID)
        if item { try OpenVoiceWire.check(outputItemID != nil && e["item_id"].string == outputItemID) }
    }
    public func takePreparedPCM() -> OpenVoicePreparedPCM? {
        guard !output.isEmpty else { return nil }; let p = output.removeFirst(); outputBytes -= p.pcm.count; return p
    }
    /// Explicit local narration stop only. No delivery credit or generated-duration rewrite.
    func discardPreparedOutput(fence: OpenVoiceMediaFence, playbackEpoch: UUID) {
        guard fence == self.fence && playbackEpoch == self.playbackEpoch else { return }
        output.removeAll(); outputBytes = 0; outputStopped = true
    }
    /// Explicit conservative source-render evidence only; never called by receive/dequeue.
    /// Caller must supply contiguous source positions, not skipped/scheduled bytes.
    public func reportRendered(fence: OpenVoiceMediaFence, responseID: String, itemID: String, playbackEpoch: UUID,
                               samples: Int, state playbackState: String, now: TimeInterval) throws {
        guard fence == self.fence && playbackEpoch == self.playbackEpoch && responseID == (activeResponseID ?? completedResponseID) && itemID == outputItemID else { return }
        guard state == .ready else { return }
        try OpenVoiceWire.check(samples >= renderedSamples && samples <= generatedSamples, "invalid_position")
        if playbackState == "unknown" { try OpenVoiceWire.check(samples == renderedSamples, "invalid_position") }
        if playbackState == "completed" { try OpenVoiceWire.check(samples == generatedSamples, "invalid_position") }
        if samples > renderedSamples { renderedSamples = samples; lastProgress = now }
        if now - lastPlaybackSend < 0.25 && playbackState == lastPlaybackState { return }
        try enqueue(.object(["type":.string("vs.playback"),"media_epoch":.string(fence.media),"response_id":.string(responseID),
            "item_id":.string(itemID),"content_index":.number(0),"playback_epoch":.string(playbackEpoch.uuidString),
            "rendered_samples":.number(Double(renderedSamples)),"state":.string(playbackState)]))
        lastPlaybackSend = now; lastPlaybackState = playbackState
    }
    private var completedResponseID: String?
    /// Owner supplies monotonic time and invokes at least once/second during media work.
    public func tick(now: TimeInterval, fence: OpenVoiceMediaFence) {
        guard fence == self.fence else { return }
        if retiringSegment != nil && (clearSent || clearSendOwner != nil) {
            if clearStalledSince == nil { clearStalledSince = now }
            if now - clearStalledSince! >= 10 { fail(origin: .clearTimeout) }
        }
        if mediaReadyAccepted, let p = pending.first, p.samples > 0 && sentSamples + p.samples - consumedSamples > OpenVoiceWire.windowSamples {
            if inputStalledSince == nil { inputStalledSince = now }
            if now - inputStalledSince! >= 15 { fail(origin: .inputCreditTimeout) }
        } else { inputStalledSince = nil }
        if !outputStopped && generatedSamples > renderedSamples && now - lastProgress >= 15 { fail(origin: .playbackTimeout) }
    }
}
