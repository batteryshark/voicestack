import Foundation
import Testing
@testable import FloatingVoiceCore

private final class PathKeys: DeviceCredentialStore {
    func load() throws -> String? { String(repeating: "k", count: 43) }
    func save(_ value: String) throws { Issue.record("read-only fixture credential") }
    func clear() throws { Issue.record("must not clear on reconnect") }
}
private final class PathWire: URLProtocol, @unchecked Sendable {
    @MainActor static var respond: ((PathWire) -> Void)?
    @MainActor static var stopped: ((PathWire) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { @MainActor in Self.respond?(self) } }
    override func stopLoading() { Task { @MainActor in Self.stopped?(self) } }
    func headers(_ status: Int = 200, type: String = "text/event-stream") {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":type])!, cacheStoragePolicy: .notAllowed)
    }
    func bytes(_ text: String) { client?.urlProtocol(self, didLoad: Data(text.utf8)) }
    func json(_ value: [String: Any]) {
        headers(type: "application/json")
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value)); finish()
    }
    func finish() { client?.urlProtocolDidFinishLoading(self) }
    func event(_ type: String, _ fields: [String: Any] = [:], id: String? = nil) {
        var value: [String: Any] = ["type":type, "data": fields.merging(["sessionID":"ses_path"]) { _, next in next }]
        if let id { value["id"] = id }
        bytes("data: " + String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)! + "\n\n")
    }
}

@MainActor private final class PathRig {
    let diagnostics = StageDiagnostics()
    let transport: BridgeTransport
    let backend: RemoteSessionBackend
    var streams: [PathWire] = [], stops = 0, selections = 0, mutations = 0
    var history: [[String: Any]] = [], historyReads = 0
    var holdNextHistory = false, heldHistory: PathWire?
    var holdOldPathHistory = false, escapedOldHistory: [PathWire] = []
    var historyAttemptCounts: [Int] = []
    var rejectFirstStream = false
    var holdStreamHeaders = false
    init() throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PathWire.self]
        transport = try BridgeTransport(base: URL(string: "https://p\(UUID().uuidString.lowercased()).fixture/floating-voice")!, credentials: PathKeys(), configuration: config, diagnostics: diagnostics)
        backend = RemoteSessionBackend(transport: transport, monitorNetworkPath: false)
        PathWire.respond = { [weak self] wire in
            guard let self, wire.request.url?.host == transport.base.host else { return }
            let path = wire.request.url!.path
            if path.hasSuffix("selection") { selections += 1; wire.json(["generation":"g"]); return }
            if path.hasSuffix("events") {
                streams.append(wire)
                if rejectFirstStream && streams.count == 1 { wire.headers(503); wire.finish() }
                else if !holdStreamHeaders { wire.headers() }
                return
            }
            if path.hasSuffix("state") { wire.json(["active":false]); return }
            if path.hasSuffix("messages") {
                historyReads += 1
                historyAttemptCounts.append(streams.count)
                if holdNextHistory { holdNextHistory = false; heldHistory = wire }
                else if holdOldPathHistory && streams.count == 1 { escapedOldHistory.append(wire) }
                else { wire.json(["data":history]) }
                return
            }
            if path.hasSuffix("prompt") || path.hasSuffix("interrupt") { mutations += 1 }
            wire.json([:])
        }
        PathWire.stopped = { [weak self] wire in
            guard let self, wire.request.url?.host == transport.base.host else { return }
            if wire.request.url!.path.hasSuffix("events") { stops += 1 }
        }
    }
    func start() async throws {
        backend.networkPathChanged(EventPathTests.wifi)
        try await backend.select("ses_path")
        #expect(await waitUntil { self.backend.connection == "connected" })
    }
    func close() {
        backend.disconnect()
        backend.onChange = nil; backend.onActivity = nil; backend.onError = nil; backend.onNarration = nil
        PathWire.respond = nil; PathWire.stopped = nil
    }
    func entries() throws -> [DiagnosticEntry] { try JSONDecoder().decode([DiagnosticEntry].self, from: Data(diagnostics.export().utf8)) }
}

@Suite(.serialized) @MainActor struct EventPathTests {
    static let wifi = NetworkPathSnapshot(satisfied: true, usedInterfaces: [.init(.wifi, index: 4)])
    @Test func satisfiedDuplicatesAndUsableHintsPreserveHealthyStreamAndSelection() async throws {
        let rig = try PathRig(); defer { rig.close() }; try await rig.start()
        let target = rig.backend.lease
        for _ in 0..<200 { rig.backend.networkPathChanged(Self.wifi); rig.backend.networkPathChanged() }
        var delivered = 0
        rig.backend.onRemoteEvent = { if $0.type == "session.execution.started" { delivered += 1 } }
        rig.streams[0].event("session.execution.started")
        #expect(await waitUntil { delivered == 1 }) // Real transport barrier after all callbacks.
        #expect(rig.streams.count == 1 && rig.stops == 0 && rig.selections == 1 && rig.mutations == 0)
        #expect(rig.backend.lease == target && rig.backend.connection == "connected")
        #expect(try rig.entries().filter { $0.stage == .events && $0.cancellationCause != nil }.isEmpty)
    }
    @Test(arguments: ["cellular", "vpn", "primary", "unsatisfied"])
    func meaningfulPathChangeRetiresSocketAndReconnectsWithoutBackoff(_ mode: String) async throws {
        let rig = try PathRig(); defer { rig.close() }
        let first: NetworkPathSnapshot
        let changed: NetworkPathSnapshot
        switch mode {
        case "vpn":
            first = .init(satisfied: true, usedInterfaces: [.init(.other, index: 8), .init(.wifi, index: 4)])
            changed = .init(satisfied: true, usedInterfaces: [.init(.other, index: 9), .init(.wifi, index: 4)])
        case "primary":
            first = .init(satisfied: true, usedInterfaces: [.init(.wifi, index: 4), .init(.cellular, index: 5)])
            changed = .init(satisfied: true, usedInterfaces: [.init(.cellular, index: 5), .init(.wifi, index: 4)])
        default:
            first = Self.wifi
            changed = .init(satisfied: mode != "unsatisfied", usedInterfaces: mode == "unsatisfied" ? [] : [.init(.cellular, index: 5)])
        }
        rig.backend.networkPathChanged(first)
        try await rig.backend.select("ses_path"); #expect(await waitUntil { rig.backend.connection == "connected" })
        let target = rig.backend.lease
        rig.backend.networkPathChanged(changed)
        for _ in 0..<100 { rig.backend.networkPathChanged(changed) }
        #expect(await waitUntil(0.7) { rig.streams.count == 2 && rig.backend.connection == "connected" })
        #expect(rig.stops == 1 && rig.backend.lease == target && rig.selections == 1 && rig.mutations == 0)
        let rows = try rig.entries().filter { $0.stage == .events && $0.status == -999 }
        #expect(rows.count == 1 && rows[0].cancellationCause == .pathChange && rows[0].initiator == .client)
    }
    @Test func identicalSatisfiedUpdateWakesPendingRetryButNotAnActiveAttempt() async throws {
        let rig = try PathRig(); defer { rig.close() }; rig.rejectFirstStream = true
        rig.backend.networkPathChanged(Self.wifi); try await rig.backend.select("ses_path")
        #expect(await waitUntil { rig.streams.count == 1 && rig.backend.connection == "reconnecting" })
        rig.backend.networkPathChanged(Self.wifi)
        #expect(await waitUntil(0.7) { rig.streams.count == 2 && rig.backend.connection == "connected" })
        #expect(rig.selections == 1 && rig.mutations == 0)
        #expect(try !rig.entries().contains { $0.cancellationCause == .pathChange })
    }
    @Test(arguments: ["headers", "history"])
    func duplicateCallbacksPreserveAnEstablishingStreamAndCatchUpOwner(_ phase: String) async throws {
        let rig = try PathRig(); defer { rig.close() }
        rig.holdStreamHeaders = phase == "headers"; rig.holdNextHistory = phase == "history"
        rig.backend.networkPathChanged(Self.wifi); try await rig.backend.select("ses_path")
        #expect(await waitUntil { rig.streams.count == 1 && (phase == "headers" || rig.heldHistory != nil) })
        for _ in 0..<100 { rig.backend.networkPathChanged(Self.wifi) }
        if phase == "headers" { rig.streams[0].headers() }
        else { rig.heldHistory?.json(["data":[]]); rig.heldHistory = nil }
        #expect(await waitUntil { rig.backend.connection == "connected" })
        #expect(rig.streams.count == 1 && rig.stops == 0 && rig.selections == 1)
    }
    @Test func duplicateUpdatesDuringHealthDoNotBypassBackoffOnLaterPeerEOF() async throws {
        let rig = try PathRig(); defer { rig.close() }; try await rig.start()
        for _ in 0..<100 { rig.backend.networkPathChanged(Self.wifi) }
        rig.streams[0].finish()
        #expect(await waitUntil { rig.backend.connection == "reconnecting" })
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(rig.streams.count == 1)
        #expect(await waitUntil { rig.streams.count == 2 && rig.backend.connection == "connected" })
    }
    @Test func handoverDuringHungCatchUpRetiresOldReadAndReconnectsPromptly() async throws {
        let rig = try PathRig(); defer { rig.close() }
        rig.holdNextHistory = true
        rig.backend.networkPathChanged(Self.wifi); try await rig.backend.select("ses_path")
        #expect(await waitUntil { rig.heldHistory != nil && rig.backend.connection == "catching up" })
        let target = rig.backend.lease
        rig.history = [["id":"recovered", "type":"user", "text":"Fresh new-path history"]]
        rig.backend.networkPathChanged(.init(satisfied: true, usedInterfaces: [.init(.cellular, index: 5)]))
        #expect(await waitUntil(0.7) { rig.streams.count == 2 && rig.backend.connection == "connected" })
        #expect(rig.historyReads == 2 && rig.backend.lease == target && rig.mutations == 0)
        #expect(rig.backend.store?.records.compactMap(MessageRow.init).first?.id == "recovered")
    }
    @Test func handoverFencesFollowQueuedBehindIndependentReadBeforeCreatingAnotherCatchUp() async throws {
        let rig = try PathRig(); defer { rig.close() }
        rig.holdStreamHeaders = true; rig.holdNextHistory = true; rig.holdOldPathHistory = true
        rig.backend.networkPathChanged(Self.wifi); try await rig.backend.select("ses_path")
        #expect(await waitUntil { rig.streams.count == 1 })
        let target = try #require(rig.backend.lease)
        let independent = Task { try await rig.backend.reconcile(target) }
        defer { independent.cancel() }
        #expect(await waitUntil { rig.heldHistory != nil && rig.historyReads == 1 })
        var queued = false
        var errors: [String] = [], readyAttempts: [Int] = []
        rig.backend.onError = { errors.append($0) }
        rig.backend.onChange = { if rig.backend.connection == "connected" { readyAttempts.append(rig.streams.count) } }
        rig.backend.onActivity = { stage, _ in if stage == "history.wait" { queued = true } }
        rig.streams[0].headers()
        #expect(await waitUntil { queued && rig.backend.connection == "catching up" })
        rig.holdStreamHeaders = false
        rig.history = [["id":"new-path", "type":"user", "text":"Replacement catch-up"]]
        rig.backend.networkPathChanged(.init(satisfied: true, usedInterfaces: [.init(.cellular, index: 5)]))
        // A would-be second read on attempt1 remains blocked in the fixture.
        // Replacement SSE must open without releasing either old history response.
        #expect(await waitUntil(0.7) { rig.streams.count == 2 && rig.backend.connection == "connected" })
        #expect(rig.escapedOldHistory.isEmpty && rig.historyAttemptCounts == [1, 2])
        #expect(errors.isEmpty && !readyAttempts.isEmpty && readyAttempts.allSatisfy { $0 == 2 })
        #expect(rig.backend.lease == target && rig.selections == 1 && rig.mutations == 0)
        #expect(rig.backend.store?.records.compactMap(MessageRow.init).first?.id == "new-path")
        do { try await independent.value; Issue.record("old registered read should be cancelled") }
        catch { }
    }
    @Test(arguments: [false, true]) func handoverRepairsOutageAndBufferedEventsWithoutMissingOrDuplicateProse(_ numbered: Bool) async throws {
        let rig = try PathRig(); defer { rig.close() }
        let boundary: [String: Any] = ["id":"boundary", "type":"user", "text":"Earlier user"]
        rig.history = [boundary]
        var updates: [NarrationUpdate] = []
        rig.backend.onNarration = { updates.append($0) }
        try await rig.start()
        let block: [String: Any] = ["assistantMessageID":"m", "ordinal":0]
        let prefix = "Already received. ", suffix = "Completed during outage."
        rig.streams[0].event("session.text.delta", block.merging(["delta":prefix]) { _, n in n }, id: numbered ? "prefix" : nil)
        #expect(await waitUntil { updates.contains { $0.suffix == prefix } })
        rig.history = [boundary, ["id":"outage-user", "type":"user", "text":"Arrived during disconnect"],
            ["id":"m", "type":"assistant", "time":["created":1,"completed":2], "content":[["type":"text", "text":prefix + suffix]]]]
        rig.holdNextHistory = true
        rig.backend.networkPathChanged(.init(satisfied: true, usedInterfaces: [.init(.cellular, index: 5)]))
        #expect(await waitUntil { rig.streams.count == 2 && rig.heldHistory != nil })
        let wire = rig.streams[1]
        wire.event("session.text.delta", block.merging(["delta":prefix]) { _, n in n }, id: numbered ? "prefix" : nil)
        wire.event("session.text.ended", block.merging(["text":prefix + suffix]) { _, n in n }, id: numbered ? "end" : nil)
        let next: [String: Any] = ["assistantMessageID":"live", "ordinal":0]
        wire.event("session.text.delta", next.merging(["delta":"Buffered new reply."]) { _, n in n }, id: numbered ? "new" : nil)
        wire.event("session.text.ended", next.merging(["text":"Buffered new reply."]) { _, n in n }, id: numbered ? "new-end" : nil)
        rig.heldHistory?.json(["data":rig.history]); rig.heldHistory = nil
        #expect(await waitUntil { rig.backend.connection == "connected" && updates.contains { $0.suffix == "Buffered new reply." } })
        try await rig.backend.reconcile(try #require(rig.backend.lease))
        #expect(updates.filter { $0.blockKey == "m:0" }.map(\.suffix).joined() == prefix + suffix)
        #expect(updates.filter { $0.blockKey == "live:0" }.map(\.suffix).joined() == "Buffered new reply.")
        let ids = try (rig.backend.store?.records ?? []).map { (try JSONSerialization.jsonObject(with: $0) as! [String: Any])["id"] as! String }
        #expect(Set(ids) == ["boundary", "outage-user", "m", "live"] && ids.count == 4)
        #expect(!rig.backend.catchUpIncomplete && rig.selections == 1 && rig.mutations == 0)
    }
    @Test func realTransportIdleWatchdogSurvivesHeartbeatsButCancelsSilentDeadStream() async throws {
        let rig = try PathRig(); defer { rig.close() }
        let stream = rig.transport.stream(try rig.transport.request("/v1/sessions/ses_path/events"))
        defer { stream.cancel() }
        _ = try await stream.headers()
        rig.streams[0].bytes(": heartbeat\n\n")
        #expect(await waitUntil { stream.liveness.bytes > 0 })
        stream.checkIdle(now: ProcessInfo.processInfo.systemUptime + 74)
        #expect(rig.stops == 0)
        stream.checkIdle(now: ProcessInfo.processInfo.systemUptime + 76)
        do { _ = try await stream.collect(); Issue.record("silent stream must fail") } catch {}
        #expect(await waitUntil { rig.stops == 1 })
        let entry = try #require(try rig.entries().last { $0.stage == .events && $0.status == -999 })
        #expect(entry.cancellationCause == .watchdog && entry.initiator == .watchdog && entry.reason == .idleTimeout)
    }
    @Test func semanticPolicyIgnoresSecondaryOrderAndTracksUnsatisfiedRecovery() {
        var policy = EventPathPolicy()
        let wifi = NetworkPathSnapshot.Interface(.wifi, index: 4), cell = NetworkPathSnapshot.Interface(.cellular, index: 5), vpn = NetworkPathSnapshot.Interface(.other, index: 8)
        #expect(policy.observe(.init(satisfied: true, usedInterfaces: [wifi, cell, vpn])) == .wakeRetry)
        #expect(policy.observe(.init(satisfied: true, usedInterfaces: [wifi, vpn, cell])) == .wakeRetry)
        #expect(policy.observe(.init(satisfied: false, usedInterfaces: [])) == .reconnect)
        #expect(policy.observe(.init(satisfied: false, usedInterfaces: [])) == .none)
        #expect(policy.observe(Self.wifi) == .wakeRetry)
        var initial = EventPathPolicy()
        #expect(initial.observe(.init(satisfied: false, usedInterfaces: [])) == .reconnect)
    }
}
