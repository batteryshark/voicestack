import Foundation

public enum OpenVoiceMediaCloseOrigin: Int {
    case owner = 0, clientFailure = 1, backendFailure = 2, controllerStop = 3, streamEnd = 4, shutdown = 5
}

/// A fresh per-call conversation projection. Never an OpenChamber raw session,
/// selected chief, history source, remote speech proxy or fallback admission path.
@MainActor public final class OpenVoiceBackend: SessionBackend {
    public let pump: OpenVoiceMediaOwnerPump
    public let invitation: OpenVoiceInvitation
    public let target: TargetLease
    private let control: OpenVoiceRecipientControl
    private let journal: OpenVoiceOperationJournal
    private var operationID: UUID?
    private var stream: AsyncThrowingStream<ServerEvent,Error>.Continuation?
    private var readyWaiter: CheckedContinuation<String,Error>?
    private var readyTimer: DispatchWorkItem?
    private var readinessTask: Task<Void,Never>?
    private var wantsCapture = false, closed = false, busy = false
    private let diagnosticCall = StageDiagnostics.shared.playbackCallToken
    private var controllerStopPending = false
    private var reply: OpenVoicePreparedTicket?
    private var explicitSend = false
    private var narrationStopped = false
    private var endIntent: UUID?, endDispatched = false
    public var onPrepared: ((SpeechTicket,String) -> Void)?
    public var onFinalProjection: ((String,String) -> Void)?
    public var onFailure: ((Error) -> Void)?
    /// Synchronous producer teardown, distinct from transient capture readiness loss.
    var onMediaClosed: (() -> Void)?
    var mediaClosed: Bool { closed }
    public private(set) var mediaCloseOrigin: OpenVoiceMediaCloseOrigin?
    private(set) var fatalInputFailure: CandidateInputFailure?
    public var ready: Bool { !closed && pump.reportedReady }
    func authorizeExplicitSend() { if ready && operationID == nil && !busy { explicitSend = true } }
    public func submitReviewedText(_ text: String) async throws {
        authorizeExplicitSend(); try await prompt(target:target,text:text,delivery:nil,reviewText:text)
    }
    public init(pump: OpenVoiceMediaOwnerPump, invitation: OpenVoiceInvitation, control: OpenVoiceRecipientControl,
                journal: OpenVoiceOperationJournal) throws {
        guard invitation.status == "accepted" else { throw ClientError("Call has not been accepted") }
        self.pump = pump; self.invitation = invitation; self.control = control; self.journal = journal
        target = TargetLease(sessionID:"openvoice_" + invitation.owner.callID.uuidString.lowercased(),
                             generation:invitation.owner.ownerEpoch.uuidString.lowercased() + ":" + String(invitation.owner.bindingRevision) + ":" + pump.fence.media)
        pump.client.onEvent = { [weak self] in self?.event($0) }
        pump.client.onState = { [weak self] state in
            guard let self, !self.closed else { return }
            if state == .failed || state == .closed { self.fail() }
            else { self.tryReadiness() }
        }
    }
    public func startMedia() async throws { guard !closed else { throw OpenVoiceFailure("local_failure") }; try await pump.start() }
    /// Called only by the actual Controller capture/route readiness seam, after input.start.
    public func nativeCaptureChanged(_ ready: Bool) {
        guard !closed, wantsCapture != ready else { return }
        if ready { controllerStopPending = false } // A resumed capture is a new live owner intent.
        wantsCapture = ready; pump.nativeCaptureReady(ready,fence:pump.fence)
        if !ready { emit("remote.disconnected") }
        else { tryReadiness() }
    }
    private func tryReadiness() {
        guard !closed, wantsCapture, !pump.reportedReady, pump.client.state == .ready, readinessTask == nil else { return }
        readinessTask = Task { [weak self] in
            guard let self else { return }
            defer { self.readinessTask = nil; self.tryReadiness() }
            do {
                try await self.pump.reportReadiness(using:self.control)
                guard !self.closed && self.wantsCapture && self.pump.reportedReady else { return }
                self.readyTimer?.cancel(); self.readyTimer = nil
                let waiter = self.readyWaiter; self.readyWaiter = nil; waiter?.resume(returning:self.target.sessionID)
                self.emit("remote.connected")
            } catch {
                guard !self.closed else { return }
                self.fail()
            }
        }
    }
    public func connect() async throws -> String {
        guard !closed else { throw OpenVoiceFailure("local_failure") }
        if ready { return target.sessionID }
        guard readyWaiter == nil else { throw ClientError("Call readiness already pending") }
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                readyWaiter = continuation
                let timer = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.fail() } }
                readyTimer = timer; DispatchQueue.main.asyncAfter(deadline:.now()+12,execute:timer)
            }
        },onCancel:{ [weak self] in DispatchQueue.main.async { self?.fail() } })
    }
    public func events() -> AsyncThrowingStream<ServerEvent,Error> {
        stream?.finish(throwing:OpenVoiceFailure("local_failure"))
        return AsyncThrowingStream(bufferingPolicy:.bufferingOldest(32)) { continuation in
            stream = continuation
            if closed { continuation.finish(throwing:OpenVoiceFailure("local_failure")) }
            else if ready { continuation.yield(ServerEvent(type:"remote.connected",data:["sessionID":target.sessionID])) }
        }
    }
    private func emit(_ type: String) {
        if let result = stream?.yield(ServerEvent(type:type,data:["sessionID":target.sessionID])), case .dropped = result { fail() }
    }
    public func targetLease(sessionID: String) async throws -> TargetLease {
        guard ready, sessionID == target.sessionID else { throw ClientError("Candidate call authority unavailable") }; return target
    }
    public func activeSessions() async throws -> Set<String> {
        guard ready else { throw OpenVoiceFailure("local_failure") }; return busy ? [target.sessionID] : []
    }
    public func sessionTitle(_ id: String) async -> String? { id == target.sessionID ? "New conversation" : nil }
    public func prompt(target: TargetLease, text: String, delivery: BusyDelivery?) async throws {
        try await prompt(target:target,text:text,delivery:delivery,reviewText:text)
    }
    public func prompt(target: TargetLease, text: String, delivery: BusyDelivery?, reviewText: String) async throws {
        guard target == self.target, ready, delivery == nil, operationID == nil, !busy, explicitSend else {
            throw ClientError("Voice exchange unavailable; review retained words, no queue or retry")
        }
        let item = try OpenVoiceCanonicalItem(id:"item_" + UUID().uuidString.replacingOccurrences(of:"-",with:""),text:reviewText)
        let intent = try journal.prepare(owner:invitation.owner,kind:.exchange,item:item.json)
        explicitSend = false
        operationID = intent.id
        do {
            try journal.update(intent.id,state:.dispatching) // durable BEFORE either send can take effect
            try pump.client.enqueue(item.createEvent)
            try pump.client.enqueue(item.responseEvent(operationID:intent.id))
            busy = true; emit("session.execution.started"); pump.signalWrites()
            try await pump.client.flush()
        } catch { try? journal.update(intent.id,state:.uncertain); throw ClientError("Voice delivery uncertain; reconcile without resending") }
    }
    public func admit(target: TargetLease, text: String) async throws { throw ClientError("Candidate calls do not support history/admit mutations") }
    public func admit(target: TargetLease, text: String, reviewText: String) async throws { throw ClientError("Candidate calls do not support history/admit mutations") }
    public func interrupt(target: TargetLease) async throws -> Bool {
        guard target == self.target, !closed else { throw OpenVoiceFailure("local_failure") }
        try cancelNarration(); return true // Never interrupts upstream harness work.
    }
    public func cancelNarration() throws {
        guard !narrationStopped, busy || reply != nil || pump.client.outputItemID != nil else { return }
        narrationStopped = true
        reply?.cancel()
        pump.client.discardPreparedOutput(fence:pump.fence,playbackEpoch:pump.client.playbackEpoch)
        if let id = pump.client.activeResponseID {
            try pump.client.enqueue(.object(["type":.string("response.cancel"),"response_id":.string(id)]))
        } else if busy {
            try pump.client.enqueue(.object(["type":.string("response.cancel")]))
        }
        if let item = pump.client.outputItemID {
            try pump.client.enqueue(.object(["type":.string("conversation.item.truncate"),"item_id":.string(item),"content_index":.number(0),"audio_end_ms":.number(Double(pump.client.renderedSamples / 24))]))
        }
        pump.signalWrites()
    }
    public func reconcile() async throws -> OpenVoiceJSON {
        guard let operationID else { throw ClientError("No candidate operation to reconcile") }
        let value = try await control.operation(owner:invitation.owner,operationID:operationID)
        try journal.update(operationID,state:.reconciled,snapshot:value); return value
    }
    public func deliberateEnd() async throws {
        let id = try prepareDeliberateEnd()
        try await dispatchDeliberateEnd(id)
    }
    /// Synchronous durable intent: call BEFORE CallKit invalidates execution ownership.
    public func prepareDeliberateEnd() throws -> UUID {
        let intent = try journal.prepare(owner:invitation.owner,kind:.deliberateEnd)
        try journal.update(intent.id,state:.dispatching)
        endIntent = intent.id; return intent.id
    }
    public func dispatchDeliberateEnd(_ id: UUID) async throws {
        guard id == endIntent, !endDispatched else { throw ClientError("Call end already attempted; reconcile without retry") }
        endDispatched = true
        do {
            let result = try await control.deliberateEnd(invitation.owner,operationID:id)
            try journal.update(id,state:.reconciled,snapshot:result)
        } catch { try? journal.update(id,state:.uncertain); throw ClientError("Call end delivery uncertain; no retry") }
    }
    private func event(_ event: OpenVoiceEvent) {
        guard !closed else { return }
        switch event.kind {
        case .partAdded:
            if narrationStopped { pump.client.discardPreparedOutput(fence:pump.fence,playbackEpoch:pump.client.playbackEpoch); return }
            if event.contentPart == .audio(transcript:"") || event["part"]["type"] == .string("audio") {
                guard reply == nil, let coordinates = event.coordinates else { fail(); return }
                let ticket = OpenVoicePreparedTicket(client:pump.client,response:coordinates.responseID,item:coordinates.itemID,signal:{ [weak self] in self?.pump.signalWrites() },failure:{ [weak self] in self?.fail() })
                reply = ticket; onPrepared?(ticket,coordinates.itemID)
            }
        case .audioDelta:
            if narrationStopped { pump.client.discardPreparedOutput(fence:pump.fence,playbackEpoch:pump.client.playbackEpoch) }
            else { reply?.wake() }
        case .audioDone: reply?.finish()
        case .transcriptDone,.textDone:
            let text = event[event.kind == .textDone ? "text" : "transcript"].string!
            onFinalProjection?(event["item_id"].string!,text)
        case .responseDone:
            busy = false
            if let operationID { do { try journal.update(operationID,state:.generationEnded,snapshot:event.body) } catch { fail(); return } }
            emit(event.response?.status == .completed ? "session.execution.succeeded" : "session.execution.failed")
        default: break
        }
    }
    private func fail() {
        guard !closed else { return }
        if let operationID { try? journal.update(operationID,state:.uncertain) }
        closeMedia(origin:pump.client.state == .failed ? .clientFailure : .backendFailure)
        onFailure?(OpenVoiceFailure("local_failure"))
    }
    // Set BEFORE cancelling connection/stream tasks. The later close must retain
    // Controller ownership rather than mislabel cancellation as a network fault.
    func controllerWillStop() { if !closed { controllerStopPending = true } }
    func closeForInputFailure(_ failure: CandidateInputFailure) {
        guard !closed else { return }
        fatalInputFailure = failure // Module-owned typed proof, never an arbitrary UI error.
        closeMedia(origin:.controllerStop)
    }
    public func closeMedia() { closeMedia(origin:.owner) }
    // Only module-owned failure/lifecycle paths may label a terminal origin.
    // Public callers can close intentionally, not manufacture fault provenance.
    func closeMedia(origin: OpenVoiceMediaCloseOrigin) {
        guard !closed else { return }; closed = true; wantsCapture = false
        let firstOrigin: OpenVoiceMediaCloseOrigin = controllerStopPending ? .controllerStop : origin
        mediaCloseOrigin = firstOrigin // Freeze before pump/capture callbacks can reenter.
        StageDiagnostics.shared.record(.call, firstOrigin == .clientFailure || firstOrigin == .backendFailure ? .failed : .cancelled,
            audio:CaptureSnapshot([.openVoiceMediaCloseOrigin:Double(firstOrigin.rawValue),
                .openVoiceClientFailed:pump.client.state == .failed ? 1 : 0,
                .openVoiceMediaEpoch:Double(max(0, Int(pump.fence.media) ?? 0)),
                .openVoiceAdmittedSamples:Double(pump.client.admittedSamples),
                .openVoiceSentSamples:Double(pump.client.sentSamples),
                .openVoiceConsumedSamples:Double(pump.client.consumedSamples)]), callBank:diagnosticCall)
        readyTimer?.cancel(); readyTimer = nil; readinessTask?.cancel()
        let waiter = readyWaiter; readyWaiter = nil; waiter?.resume(throwing:OpenVoiceFailure("local_failure"))
        reply?.cancel(); stream?.finish(throwing:OpenVoiceFailure("local_failure")); stream = nil
        pump.stop()
        onMediaClosed?()
    }
    public func shutdown(closeControl: Bool = true) async {
        closeMedia(origin:.shutdown); await readinessTask?.value; readinessTask = nil; await pump.shutdown()
        if closeControl { control.close() }
    }
}

/// Candidate assembly supplies this instead of any network synthesizer. Prepared
/// tickets bypass it; an accidental legacy speech route fails without an HTTP call.
public final class OpenVoicePreparedOnlySynthesizer: SpeechSynthesizer {
    public init() {}
    public func prepare(_ text: String) -> SpeechTicket { OpenVoiceUnavailableTicket(text:text) }
}
private final class OpenVoiceUnavailableTicket: SpeechTicket {
    let text: String
    init(text: String) { self.text = text }
    func audio() async throws -> SpeechAudio { throw ClientError("Only prepared new-conversation audio is available") }
    func cancel() {}
}

/// Pulls from the client's existing bounded PCM queue; no second unbounded stream.
@MainActor private final class OpenVoicePreparedTicket: SpeechTicket {
    var text: String { "" } // final projection has its own verified caption path
    private let client: OpenVoiceClient
    private let response: String, item: String, epoch: UUID
    private let fence: OpenVoiceMediaFence
    private let signal: () -> Void, failure: () -> Void
    private var ended = false, cancelled = false, offset = 0
    private var waiter: CheckedContinuation<Data?,Error>?
    init(client: OpenVoiceClient, response: String, item: String, signal: @escaping () -> Void, failure: @escaping () -> Void) {
        self.client = client; self.response = response; self.item = item; epoch = client.playbackEpoch; fence = client.fence
        self.signal = signal; self.failure = failure
    }
    func audio() async throws -> SpeechAudio {
        SpeechAudio(sampleRate:24000,chunks:AsyncThrowingStream(unfolding:{ [weak self] in try await self?.next() }),sourceProgress:{ [weak self] in self?.progress($0) })
    }
    private func take() throws -> Data? {
        guard let chunk = client.takePreparedPCM() else { return nil }
        guard chunk.fence == fence, chunk.responseID == response, chunk.itemID == item, chunk.playbackEpoch == epoch, chunk.sourceOffset == offset else { throw OpenVoiceFailure("invalid_position") }
        offset += chunk.pcm.count / 2; return chunk.pcm
    }
    private func next() async throws -> Data? {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        if let data = try take() { return data }
        if ended { return nil }
        guard waiter == nil else { throw OpenVoiceFailure("local_failure") }
        return try await withTaskCancellationHandler(operation:{ try await withCheckedThrowingContinuation { waiter = $0 } },onCancel:{ [weak self] in DispatchQueue.main.async { self?.cancel() } })
    }
    func wake() {
        guard let pending = waiter else { return }
        do {
            if let data = try take() { waiter = nil; pending.resume(returning:data) }
            else if ended { waiter = nil; pending.resume(returning:nil) }
        } catch { waiter = nil; pending.resume(throwing:error); failure() }
    }
    func finish() { ended = true; wake() }
    func cancel() { cancelled = true; let pending = waiter; waiter = nil; pending?.resume(throwing:CancellationError()) }
    private func progress(_ value: PlaybackSourceProgress) {
        guard !cancelled else { return }
        do {
            let samples = value.state == .unknown ? client.renderedSamples : value.renderedSamples
            try client.reportRendered(fence:fence,responseID:response,itemID:item,playbackEpoch:epoch,samples:samples,state:value.state.rawValue,now:ProcessInfo.processInfo.systemUptime)
            signal()
        } catch { failure() }
    }
}
