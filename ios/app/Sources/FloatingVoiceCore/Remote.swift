import Foundation
#if canImport(Network)
import Network
#endif

public protocol DeviceCredentialStore: AnyObject {
    func authorizePairing() throws
    func load() throws -> String?
    func save(_ credential: String) throws
    func clear() throws
}
public extension DeviceCredentialStore { func authorizePairing() throws {} }

/// All remote HTTP uses the same nonredirecting bounded transport as speech. No cookies,
/// credentials in URLs, desktop settings, or persisted session-control bootstrap.
public final class BridgeTransport {
    public let base: URL
    public let credentials: DeviceCredentialStore
    private let configuration: URLSessionConfiguration
    public init(base: URL, credentials: DeviceCredentialStore, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard base.scheme == "https", base.user == nil, base.password == nil, base.query == nil,
              base.fragment == nil, base.path == "/floating-voice", base.host != nil else { throw ClientError("Secure bridge endpoint required") }
        self.base = base; self.credentials = credentials; self.configuration = configuration
    }
    public func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, lease: TargetLease? = nil, paired: Bool = true) throws -> URLRequest {
        guard path.hasPrefix("/"), !path.contains("://"), !path.contains(".."), !path.contains("#") else { throw ClientError("Invalid bridge route") }
        var request = URLRequest(url: URL(string: base.absoluteString + path)!)
        request.httpMethod = method; request.timeoutInterval = 30
        if paired {
            guard let key = try credentials.load() else { throw ClientError("Pair this device first") }
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        if let lease { request.setValue(lease.generation, forHTTPHeaderField: "X-FV-Generation") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    public func stream(_ request: URLRequest) -> HTTPChunkStream { HTTPChunkStream(request, idleTimeout: 75, configuration: configuration) }
    public func data(_ path: String, method: String = "GET", body: [String: Any]? = nil, lease: TargetLease? = nil, paired: Bool = true) async throws -> Data {
        let started = Date(), stage = StageDiagnostics.stage(path)
        StageDiagnostics.shared.record(stage, .begin)
        do {
        let stream = stream(try request(path, method: method, body: body, lease: lease, paired: paired))
        return try await withTaskCancellationHandler(operation: {
            let head = try await stream.headers()
            StageDiagnostics.shared.record(stage, .ready, since: started, status: head.statusCode)
            guard (200..<300).contains(head.statusCode) else {
                if head.statusCode == 503, path.hasPrefix("/tts/") || path.hasPrefix("/asr/") {
                    let body = (try? await stream.collect(limit: 4096)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let message = SpeechServiceError.describe(url: base.absoluteString + path, error: HTTPError.status(503, body))
                    if message.hasSuffix(" isn't running") { throw ClientError(message) }
                }
                stream.cancel()
                throw HTTPError.status(head.statusCode, "Bridge request refused")
            }
            let bytes = try await stream.collect(limit: 8 * 1024 * 1024)
            StageDiagnostics.shared.record(stage, .complete, since: started, status: head.statusCode)
            return bytes
        }, onCancel: { stream.cancel() })
        } catch {
            StageDiagnostics.shared.record(stage, .failed, since: started, status: StageDiagnostics.code(error))
            throw error
        }
    }
    public func json(_ path: String, method: String = "GET", body: [String: Any]? = nil, lease: TargetLease? = nil, paired: Bool = true) async throws -> [String: Any] {
        let bytes = try await data(path, method: method, body: body, lease: lease, paired: paired)
        guard let obj = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw ClientError("Invalid bridge response") }
        return obj
    }
    public func pair(bootstrap: String) async throws {
        try credentials.authorizePairing()
        let obj = try await json("/v1/pair", method: "POST", body: ["bootstrap": bootstrap], paired: false)
        guard let credential = obj["credential"] as? String, credential.count == 43 else { throw ClientError("Pairing response invalid") }
        try credentials.save(credential)
    }
    /// Persist a device-only proof BEFORE spending bootstrap. Response/save loss can be
    /// recovered only by that proof, for ten minutes, until authenticated acknowledgement.
    public func pair(bootstrap: String, pending: DeviceCredentialStore, makeProof: () throws -> String) async throws {
        try credentials.authorizePairing(); try pending.authorizePairing()
        if try credentials.load() != nil { return }
        let proof: String
        if let saved = try pending.load() { proof = saved }
        else { proof = try makeProof(); try pending.save(proof) }
        let obj = try await json("/v1/pair", method: "POST", body: ["bootstrap": bootstrap, "credential": proof], paired: false)
        guard obj["credential"] as? String == proof else { throw ClientError("Pairing proof mismatch; pending identity preserved") }
        try credentials.save(proof)
        guard try credentials.load() == proof else { throw ClientError("Credential readback failed; pending identity preserved") }
        _ = try await json("/v1/pair/ack", method: "POST", body: [:])
        try pending.clear()
    }
    public func voiceConfig(_ original: VoiceConfig) throws -> VoiceConfig {
        var cfg = original
        cfg.ttsUrl = base.absoluteString + "/tts/v1/audio/speech"
        cfg.asrUrl = base.absoluteString.replacingOccurrences(of: "https://", with: "wss://") + "/asr/v1/transcribe"
        cfg.ttsApiKey = try credentials.load(); cfg.asrApiKey = cfg.ttsApiKey
        return cfg
    }
}

/// Remote conversation lifetime is independent of capture/output. A single SSE connection is
/// opened BEFORE latest-page history. Older pages are merged silently on upward demand;
/// the bounded stream buffers events while the initial latest page is reconciled.
@MainActor
public final class RemoteSessionBackend: SessionBackend {
    public let transport: BridgeTransport
    public private(set) var store: ConversationStore?
    public private(set) var lease: TargetLease?
    public private(set) var review: [BoundDraft] = []
    public private(set) var connection = "off"
    public var onChange: (() -> Void)?
    public var onNarration: ((NarrationUpdate) -> Void)?
    public var onError: ((String) -> Void)?
    /// Observation only; never feeds state or networking. Used for bounded owned proof metrics.
    public var onActivity: ((String, Int) -> Void)?
    public var promptAdmission: ((TargetLease, String) throws -> Void)?
    public var onRemoteEvent: ((ServerEvent) -> Void)?
    public var streamLiveness: (bytes: Int, idleSeconds: TimeInterval)? { currentStream?.liveness }
    private var selected = "chief"
    private var subscribers: [UUID: AsyncThrowingStream<ServerEvent, Error>.Continuation] = [:]
    private var lifecycle: Task<Void, Never>?
    private var serial = 0
    private var overlapping = Set<String>()
    private var seenLive = Set<String>()
    private var liveOrder: [String] = []
    public private(set) var olderCursor: String?
    public private(set) var loadingOlder = false
    public private(set) var catchUpIncomplete = false
    private var olderSeen = Set<String>()
    private var refreshHistory: Task<Void, Never>?
    private var refreshOwner = UUID()
    private var refreshDirty = false
    private var latestRead: Task<Void, Error>?
    private var latestReadOwner = UUID()
    private var missingBoundary: String?
    private var retryWait: Task<Void, Error>?
    private var currentStream: HTTPChunkStream?
    private var pathRevision = 0
    private var localSenders = LocalSenderReceipts()
    private struct PendingSenderDisplay { let target: TargetLease; var count: Int; let records: [Data] }
    private var heldSenderDisplays: [PendingSenderDisplay] = []
    public var displayRecords: [Data] {
        guard let lease else { return [] }
        if let held = heldSenderDisplays.first(where: { $0.target == lease }) { return held.records }
        return localSenders.project(store?.records ?? [], sessionID: lease.sessionID)
    }
    private func beginSenderReceipt(_ target: TargetLease) {
        if let index = heldSenderDisplays.firstIndex(where: { $0.target == target }) { heldSenderDisplays[index].count += 1 }
        else { heldSenderDisplays.append(PendingSenderDisplay(target: target, count: 1, records: target == lease ? displayRecords : [])) }
    }
    private func endSenderReceipt(_ target: TargetLease) {
        guard let index = heldSenderDisplays.firstIndex(where: { $0.target == target }) else { return }
        heldSenderDisplays[index].count -= 1
        if heldSenderDisplays[index].count == 0 { heldSenderDisplays.remove(at: index); if target == lease { onChange?() } }
    }
#if canImport(Network)
    private let pathMonitor = NWPathMonitor()
#endif
    public init(transport: BridgeTransport) {
        self.transport = transport
#if canImport(Network)
        // Ignore initial inventory. Only a subsequent usable path wakes a retry;
        // it never changes selection, draft ownership or mutation delivery.
        var initial = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            if initial { initial = false; return }
            if path.status == .satisfied { Task { @MainActor [weak self] in self?.networkPathChanged() } }
        }
        pathMonitor.start(queue: DispatchQueue(label: "FloatingVoice.path"))
#endif
    }
    deinit {
#if canImport(Network)
        pathMonitor.cancel()
#endif
    }
    public func networkPathChanged() {
        guard lease != nil else { return }
        pathRevision += 1; retryWait?.cancel(); currentStream?.cancel(cause: .pathChange)
    }
    public func connect() async throws -> String { _ = try await transport.json("/v1/health"); return "Authenticated bridge" }
    public func chief() async throws -> String {
        guard let id = try await transport.json("/v1/chief")["sessionID"] as? String else { throw ClientError("Chief unavailable") }; return id
    }
    public func select(_ selection: String) async throws {
        currentStream?.markCancellation(.selection)
        serial += 1; let owner = serial
        latestRead?.cancel()
        lifecycle?.cancel(); refreshHistory?.cancel(); refreshHistory = nil; refreshOwner = UUID(); refreshDirty = false; lease = nil; olderCursor = nil; olderSeen = []
        let id = selection == "chief" ? try await chief() : selection
        let obj = try await transport.json("/v1/selection", method: "POST", body: ["sessionID": id, "mode": selection == "chief" ? "chief" : "explicit"])
        guard owner == serial else { throw CancellationError() }
        guard let generation = obj["generation"] as? String else { throw ClientError("Selection lacks lease") }
        selected = selection; seenLive = []; liveOrder = []
        missingBoundary = nil; catchUpIncomplete = false
        let granted = TargetLease(sessionID: id, generation: generation)
        lease = granted; store = ConversationStore(target: granted); connection = "connecting"; onChange?()
        lifecycle = Task { await self.follow(granted, owner: owner) }
    }
    public func disconnect(cause: StreamCancellationCause = .explicit) { currentStream?.markCancellation(cause); serial += 1; latestRead?.cancel(); lifecycle?.cancel(); refreshHistory?.cancel(); refreshHistory = nil; refreshOwner = UUID(); refreshDirty = false; lifecycle = nil; lease = nil; connection = "off"; onChange?() }
    public func targetLease(sessionID: String) async throws -> TargetLease {
        guard let lease, lease.sessionID == sessionID else { throw ClientError("Select session explicitly") }
        // Server-side chief refresh invalidates the old lease; never auto-authorize held words.
        if selected == "chief", try await chief() != sessionID { throw ClientError("Chief changed. Review drafts and select Chief again.") }
        return lease
    }
    public func activeSessions() async throws -> Set<String> {
        guard let lease else { return [] }
        guard connection == "connected" else { throw ClientError("Conversation stream is catching up or reconnecting") }
        // The bridge validates the full generation and current-chief ownership on this
        // state request. A second chief fetch duplicates resync's targetLease read.
        let active = try await transport.json(route(lease, "state"), lease: lease)["active"] as? Bool ?? false
        guard lease == self.lease, connection == "connected" else { throw ClientError("Conversation changed while reading session state") }
        return active ? [lease.sessionID] : []
    }
    public func listSessions() async throws -> [SessionSummary] {
        let obj = try await transport.json("/v1/sessions")
        return (obj["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return SessionSummary(id: id, title: item["title"] as? String ?? "", updated: (item["time"] as? [String: Double])?["updated"] ?? 0, parentID: item["parentID"] as? String)
        }
    }
    public func sessionTitle(_ id: String) async -> String? { try? await listSessions().first { $0.id == id }?.title }
    private func route(_ target: TargetLease, _ action: String) -> String { "/v1/sessions/\(target.sessionID)/\(action)" }
    public func prompt(target: TargetLease, text: String, delivery: BusyDelivery?) async throws {
        try await prompt(target: target, text: text, delivery: delivery, reviewText: text)
    }
    public func prompt(target: TargetLease, text: String, delivery: BusyDelivery?, reviewText: String) async throws {
        beginSenderReceipt(target); defer { endSenderReceipt(target) }
        do {
            guard target == lease else { throw ClientError("Stale target lease") }
            try promptAdmission?(target, text)
            var body: [String: Any] = ["text": text]
            if let delivery { body["delivery"] = delivery.rawValue }
            let receipt = try await transport.data(route(target, "prompt"), method: "POST", body: body, lease: target)
            localSenders.record(receipt, sessionID: target.sessionID)
            onActivity?("prompt.ack", text.count)
        } catch { review.append(BoundDraft(target: target, text: reviewText)); onChange?(); throw ClientError("Delivery unknown — retained for history review; not retried") }
        // Submission acknowledgement is not a reply. Repair user/inbox projection independently;
        // a failed read must NOT reclassify the acknowledged mutation as unknown delivery.
        scheduleRefresh(target)
    }
    public func admit(target: TargetLease, text: String) async throws {
        try await admit(target: target, text: text, reviewText: text)
    }
    public func admit(target: TargetLease, text: String, reviewText: String) async throws {
        beginSenderReceipt(target); defer { endSenderReceipt(target) }
        do {
            guard target == lease else { throw ClientError("Stale target lease") }
            try promptAdmission?(target, text)
            let receipt = try await transport.data(route(target, "prompt"), method: "POST", body: ["text": text, "resume": false], lease: target)
            localSenders.record(receipt, sessionID: target.sessionID)
        } catch { review.append(BoundDraft(target: target, text: reviewText)); onChange?(); throw ClientError("Admission delivery unknown — retained for review; not retried") }
    }
    public func interrupt(target: TargetLease) async throws -> Bool {
        guard target == lease else { throw ClientError("Stale target lease") }
        let obj = try await transport.json(route(target, "interrupt"), method: "POST", body: [:], lease: target)
        return obj["interrupted"] as? Bool ?? false
    }
    public func events() -> AsyncThrowingStream<ServerEvent, Error> {
        let id = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { c in
            subscribers[id] = c
            // Subscription is not readiness: the independent native stream must have headers
            // and its latest-page catch-up first. No assistant event is needed to become ready.
            if connection == "connected" { c.yield(ServerEvent(type: "remote.connected")) }
            c.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[id] = nil } }
        }
    }
    private func publish(_ event: ServerEvent) {
        // Text uses the full-context narration seam, NOT the legacy suffix/event cleaner.
        guard !event.type.hasPrefix("session.text.") else { return }
        for c in subscribers.values { if case .dropped = c.yield(event) { c.finish(throwing: HTTPError.tooLarge) } }
    }
    public func reconcile(_ target: TargetLease) async throws {
        try await readInLatestLane(target, reconnecting: false)
    }
    private func readInLatestLane(_ target: TargetLease, reconnecting: Bool, older: Bool = false) async throws {
        let epoch = serial
        // Serialize latest-page reads, including typed repair arriving during initial catch-up.
        // Wait for cancellation to unwind too: a replacement target cannot overlap the old read.
        while let pending = latestRead {
            let pendingOwner = latestReadOwner
            _ = try? await pending.value
            if pendingOwner == latestReadOwner { latestRead = nil }
            try Task.checkCancellation()
            guard epoch == serial, target == lease else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard epoch == serial, target == lease else { throw CancellationError() }
        let owner = UUID(); latestReadOwner = owner
        let task = Task {
            try Task.checkCancellation()
            guard epoch == self.serial, target == self.lease else { throw CancellationError() }
            // Advancing the snapshot epoch owns the same lane as its first read.
            // SSE headers must not invalidate an already in-flight explicit read.
            if reconnecting { self.store?.beginReconnect() }
            if older { try await self.readOlderPage(target, epoch: epoch) }
            else { try await self.readLatest(target, epoch: epoch) }
        }
        latestRead = task
        defer { if owner == latestReadOwner { latestRead = nil } }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    /// Readiness means this lease's SSE headers AND authoritative catch-up, not
    /// merely selection, a successful HTTP response or any earlier lease's state.
    public func waitForAuthoritativeCatchUp(_ target: TargetLease, timeout: TimeInterval = 12) async throws {
        let epoch = serial, deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            guard epoch == serial, target == lease else { throw NotificationRouteFailure.targetChanged }
            if connection == "connected", store?.target == target { return }
            guard Date() < deadline else { throw NotificationRouteFailure.catchUpTimeout }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    public func locateMessage(_ messageID: String, target: TargetLease, maxOlderPages: Int = 20) async throws {
        try await waitForAuthoritativeCatchUp(target)
        let epoch = serial
        func containsMessage() -> Bool {
            store?.records.contains { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["id"] as? String == messageID } == true
        }
        var pages = 0
        while !containsMessage() {
            try Task.checkCancellation()
            guard epoch == serial, target == lease else { throw NotificationRouteFailure.targetChanged }
            guard olderCursor != nil else { throw NotificationRouteFailure.messageUnavailable }
            guard pages < maxOlderPages else { throw NotificationRouteFailure.olderPageLimit }
            if loadingOlder { try await Task.sleep(nanoseconds: 20_000_000); continue }
            try await loadOlder(); pages += 1
        }
        guard epoch == serial, target == lease else { throw NotificationRouteFailure.targetChanged }
    }
    private func readLatest(_ target: TargetLease, epoch: Int) async throws {
        guard target == lease, let store else { throw CancellationError() }
        let token = store.beginHistorySnapshot()
        let boundary = missingBoundary ?? (store.records.last.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["id"] as? String)
        missingBoundary = boundary
        var catchUp = HistoryCatchUp(boundary: boundary)
        let active = try await transport.json(route(target, "state"), lease: target)["active"] as? Bool ?? false
        let bytes = try await transport.data(route(target, "messages") + "?limit=40&order=desc", lease: target)
            try Task.checkCancellation()
            guard target == lease, epoch == serial else { throw CancellationError() }
             for update in try store.reconcile(history: bytes, active: active, for: target, snapshot: token) { onNarration?(update) }
        // Preserve the browsing cursor across live latest-page refreshes.
        if olderCursor == nil && olderSeen.isEmpty { olderCursor = try nextCursor(bytes) }
        var page = bytes
        while true {
            let obj = try JSONSerialization.jsonObject(with: page) as? [String: Any]
            let ids = (obj?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            let next = try nextCursor(page)
            guard catchUp.accept(ids: ids, next: next), let next else { break }
            page = try await transport.data(route(target, "messages") + "?limit=40&cursor=\(next)", lease: target)
            try Task.checkCancellation()
            guard target == lease, epoch == serial else { throw CancellationError() }
            for update in try store.reconcile(history: page, active: active, for: target, snapshot: token) { onNarration?(update) }
        }
        catchUpIncomplete = !catchUp.complete
        if catchUp.complete { missingBoundary = nil }
        if catchUpIncomplete { onError?("History catch-up incomplete (bounded pages). Review History and load older messages before relying on this gap.") }
        onChange?()
    }
    private func nextCursor(_ bytes: Data) throws -> String? {
        let obj = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        let cursor = (obj?["cursor"] as? [String: Any])?["next"] as? String
        if let cursor { guard cursor.range(of: "^[A-Za-z0-9_-]{1,1024}$", options: .regularExpression) != nil else { throw ClientError("Invalid history cursor") } }
        return cursor
    }
    public func loadOlder() async throws {
        guard !loadingOlder, olderCursor != nil, let target = lease else { return }
        loadingOlder = true; defer { loadingOlder = false; onChange?() }
        try await readInLatestLane(target, reconnecting: false, older: true)
    }
    private func readOlderPage(_ target: TargetLease, epoch: Int) async throws {
        guard let cursor = olderCursor, let store, target == lease, epoch == serial else { throw NotificationRouteFailure.targetChanged }
        let snapshot = store.beginHistorySnapshot()
        let bytes = try await transport.data(route(target, "messages") + "?limit=40&cursor=\(cursor)", lease: target)
        try Task.checkCancellation(); guard target == lease, epoch == serial else { throw CancellationError() }
        let next = try nextCursor(bytes)
        guard next != cursor, next.map({ !olderSeen.contains($0) }) ?? true else { throw ClientError("Repeated history cursor") }
        try store.reconcile(history: bytes, active: store.active, for: target, snapshot: snapshot)
        olderSeen.insert(cursor); olderCursor = next
    }
    /// After reconnect no client arrival time proves freshness for a snapshot-owned block.
    /// Wait for its authoritative end; absent blocks can stream normally. Test seam also lets
    /// fake integrations inject a buffered event without any real backend or microphone.
    public func receiveRemote(_ event: ServerEvent, identity: String, target: TargetLease) {
        guard target == lease, event.sessionID == target.sessionID, let store else { return }
        if event.type.hasPrefix("session.text."), overlapping.contains(event.blockKey), event.type != "session.text.ended" { return }
        guard !seenLive.contains(identity) else { return }
        onRemoteEvent?(event)
        if event.type == "session.text.delta" { onActivity?("model.delta", 1) }
        seenLive.insert(identity); liveOrder.append(identity)
        if liveOrder.count > 4096 { seenLive.remove(liveOrder.removeFirst()) }
        if let update = store.receive(event, eventID: identity, for: target) { onNarration?(update) }
        publish(event); onChange?()
        StageDiagnostics.shared.record(.liveProjection, .complete)
        if event.type.hasPrefix("session.execution.") || event.type.hasPrefix("session.tool.") || event.type.hasPrefix("session.inbox.") || event.type == "session.text.ended" {
            scheduleRefresh(target)
        }
    }
    private func scheduleRefresh(_ target: TargetLease) {
        guard target == lease else { return }
        // A fixed debounce coalesces arrivals before a read. Arrivals DURING a read dirty
        // the snapshot and earn a trailing read, even when the final SSE event has passed.
        refreshDirty = true
        guard refreshHistory == nil else { return }
        let owner = UUID(), epoch = serial; refreshOwner = owner
        refreshHistory = Task {
            defer { if owner == refreshOwner { refreshHistory = nil } }
            while !Task.isCancelled && owner == refreshOwner && epoch == serial && target == lease {
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
                guard owner == refreshOwner, epoch == serial, target == lease else { return }
                refreshDirty = false
                do { try await reconcile(target) }
                catch {
                    guard !Task.isCancelled, owner == refreshOwner, epoch == serial, target == lease else { return }
                    onError?(error.localizedDescription)
                }
                guard owner == refreshOwner, epoch == serial, target == lease, refreshDirty else { return }
                // Errors alone never retry; only a new qualifying arrival can dirty a read.
            }
        }
    }
    private func follow(_ target: TargetLease, owner: Int) async {
        var backoff = ReconnectBackoff()
        while !Task.isCancelled && owner == serial {
            let pathAtAttempt = pathRevision
            var stream: HTTPChunkStream?
            var healthySince: TimeInterval?
            var healthyOperation = false
            do {
                _ = try await targetLease(sessionID: target.sessionID)
                let s = transport.stream(try transport.request(route(target, "events"), lease: target)); stream = s
                currentStream = s
                let head = try await withTaskCancellationHandler(operation: { try await s.headers() }, onCancel: { s.cancel(cause: .lifecycle) })
                try Task.checkCancellation()
                guard owner == serial, target == lease else { s.cancel(); return }
                guard head.statusCode == 200 else { throw HTTPError.status(head.statusCode, "Event connection refused; credential preserved") }
                connection = "catching up"; onChange?()
                // The previous connection's trailing repair owns the latest-page lane until
                // it finishes. New connection frames remain buffered during catch-up.
                await refreshHistory?.value
                try Task.checkCancellation()
                guard owner == serial, target == lease else { s.cancel(); return }
                try await readInLatestLane(target, reconnecting: true)
                try Task.checkCancellation()
                guard owner == serial, target == lease else { s.cancel(); return }
                overlapping = Set(store?.liveBlocks.keys.map { $0 } ?? [])
                connection = "connected"; publish(ServerEvent(type: "remote.connected")); onChange?()
                healthySince = ProcessInfo.processInfo.systemUptime
                var parser = SSEParser()
                let connectionID = UUID().uuidString
                var arrival = 0
                for try await chunk in s.chunks {
                    try Task.checkCancellation()
                    guard owner == serial else { break }
                    if let healthySince, ProcessInfo.processInfo.systemUptime - healthySince >= 30 { healthyOperation = true }
                    for raw in parser.push(chunk) {
                        guard let event = ServerEvent(json: raw) else { continue }
                        // No SSE id is required by installed v2. Preserve JSON ids when present.
                        // Unnumbered live frames get a connection-local arrival identity, NEVER
                        // a server cursor or a payload hash (identical deltas can be legitimate).
                        arrival += 1
                        let identity = event.identity.flatMap { $0.isEmpty ? nil : $0 } ?? "local:\(connectionID):\(arrival)"
                        receiveRemote(event, identity: identity, target: target)
                    }
                    if parser.exceededLimit { throw HTTPError.tooLarge }
                }
            } catch { if !Task.isCancelled && owner == serial && target == lease { onError?(error.localizedDescription) } }
            stream?.cancel()
            if currentStream === stream { currentStream = nil }
            if Task.isCancelled || owner != serial || target != lease { return }
            connection = "reconnecting"; publish(ServerEvent(type: "remote.disconnected")); onChange?()
            if pathAtAttempt != pathRevision { continue }
            // Bounded reconnect backoff, not a prompt retry.
            let healthyFor: TimeInterval = healthyOperation ? 30 : 0
            let delay = backoff.next(healthyFor: healthyFor, jitter: Double.random(in: 0...1))
            let wait = Task { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            retryWait = wait
            do { try await withTaskCancellationHandler(operation: { try await wait.value }, onCancel: { wait.cancel() }) }
            catch { if Task.isCancelled { return } }
            retryWait = nil
        }
    }
}
