import Foundation
import Testing
@testable import FloatingVoiceCore

private final class LiveKeys: DeviceCredentialStore {
    func load() throws -> String? { String(repeating: "t", count: 43) }
    func save(_ value: String) throws {}
    func clear() throws { Issue.record("must not clear credential") }
}
private final class LiveWire: URLProtocol, @unchecked Sendable {
    @MainActor static var respond: ((LiveWire) -> Void)?
    @MainActor static var stopped: ((LiveWire) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { @MainActor in Self.respond?(self) } }
    override func stopLoading() { Task { @MainActor in Self.stopped?(self) } }
    func headers(_ type: String = "application/json") {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":type])!, cacheStoragePolicy: .notAllowed)
    }
    func json(_ obj: [String: Any]) { headers(); bytes(try! JSONSerialization.data(withJSONObject: obj)); finish() }
    func bytes(_ data: Data) { client?.urlProtocol(self, didLoad: data) }
    func finish() { client?.urlProtocolDidFinishLoading(self) }
    func event(_ type: String, _ fields: [String: Any] = [:], id: String? = nil, wrapped: Bool = false, session: String = "ses_fixture") {
        var obj: [String: Any] = ["type":type,"created":1,"data":fields.merging(["sessionID":session]) { _, new in new }]
        if let id { obj["id"] = id }
        if wrapped { obj = ["directory":"/synthetic", "payload":obj] }
        let payload = "data: " + String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)! + "\n\n"
        let data = Data(payload.utf8), mid = data.count/2
        bytes(data.prefix(mid)); bytes(data.suffix(from: mid)) // actual transport chunk/parser path
    }
}

@Suite(.serialized) @MainActor struct LiveReplyTests {
    @Test(arguments: ["lead", "docket", "canvas", "agent"], [false, true])
    func externalUserSendersNeverNarrateOrInterruptPlayback(_ sender: String, _ speaking: Bool) async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [LiveWire.self]
        let backend = RemoteSessionBackend(transport: try BridgeTransport(base: URL(string:"https://fixture.test/floating-voice")!, credentials: LiveKeys(), configuration: cfg))
        let text: String
        switch sender {
        case "lead": text = "From the Dream Studio lead:\nExternal lead words must never be spoken."
        case "docket": text = "[Docket]\nExternal timer words must never be spoken."
        case "canvas": text = "[Agent Canvas]\nExternal input must never be spoken."
        default: text = "[a2a] Message from another AI agent: session local/ses_source (trace a2a_fixture, hop 1).\nExternal agent words must never be spoken."
        }
        var wire: LiveWire?, arrived = false
        let external: [String: Any] = ["id":"msg_external", "type":"user", "text":text, "sender":["kind":sender, "label":sender]]
        LiveWire.respond = { p in
            let path = p.request.url!.path
            if path.hasSuffix("selection") { p.json(["generation":"g"]); return }
            if path.hasSuffix("events") { wire = p; p.headers("text/event-stream"); return }
            if path.hasSuffix("state") { p.json(["active":false]); return }
            if path.hasSuffix("messages") { p.json(["data": arrived ? [external] : []]); return }
            p.json([:])
        }
        let synth = FakeSynth(), output = FakeOutput(duration: 10)
        var app = AppSettings(); app.target = "ses_fixture"
        let settings = LoadedSettings(app: app, voice: VoiceConfig(), voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent")
        let controller = ConversationController(settings: settings, backend: backend, synth: synth, output: output, input: FakeInput(), makeRecognition: { FakeRecognition($0, transcript: "") })
        backend.onNarration = { controller.consumeNarration($0) }
        defer { controller.stop(); backend.disconnect(); LiveWire.respond = nil }
        try await backend.select("ses_fixture"); await controller.start()
        #expect(await waitUntil { controller.status.phase == "ready" && backend.connection == "connected" && wire != nil })
        if speaking {
            wire?.event("session.text.delta", ["assistantMessageID":"msg_target", "ordinal":0, "delta":"The target reply keeps speaking."])
            wire?.event("session.text.ended", ["assistantMessageID":"msg_target", "ordinal":0, "text":"The target reply keeps speaking."])
            #expect(await waitUntil { output.playing == ["The target reply keeps speaking."] })
        }
        let prepared = synth.prepared, played = output.plays.map(\.text), stops = output.stops
        arrived = true
        wire?.event("session.inbox.enqueued", ["inboxID":"msg_external", "item":["type":"user", "payload":["text":text, "sender":["kind":sender, "label":sender]]]])
        #expect(await waitUntil { backend.store?.records.compactMap(MessageRow.init).contains { $0.id == "msg_external" } == true })
        // Both live inbox delivery and its real-Remote history repair traversed
        // production narration. External user prose cannot synthesize or play.
        #expect(synth.prepared == prepared && output.plays.map(\.text) == played && output.stops == stops)
        if speaking { #expect(output.playing == ["The target reply keeps speaking."]) }
        else { #expect(synth.prepared.isEmpty && output.plays.isEmpty) }
    }
    @Test(arguments: [false, true]) func nonTargetSessionReplyNeverNarrates(_ speaking: Bool) async {
        let rig = Rig(duration: 10); await rig.start(); defer { rig.controller.stop() }
        if speaking {
            rig.reply(id: "baseline", "The target reply keeps speaking.")
            #expect(await waitUntil { rig.output.playing == ["The target reply keeps speaking."] })
        }
        let prepared = rig.synth.prepared, played = rig.output.plays.map(\.text), stops = rig.output.stops
        rig.reply("ses_other", id: "foreign", "Foreign assistant words must never be spoken.")
        rig.backend.send("session.execution.started", "ses_A") // ordered processing barrier
        #expect(await waitUntil { rig.controller.status.busy })
        #expect(rig.synth.prepared == prepared && rig.output.plays.map(\.text) == played && rig.output.stops == stops)
    }
    @Test(arguments: [false, true]) func targetAssistantNarratesProseButNotFencedOnlyDetail(_ fencedOnly: Bool) async {
        let rig = Rig(duration: 0.01); await rig.start(); defer { rig.controller.stop() }
        let sample = fencedOnly ? "```md\n## Silent detail\nThis belongs in History, not speech.\n```" : "Normal target prose is spoken."
        rig.reply(id: "sample", sample)
        rig.reply(id: "barrier", "Audible processing barrier.")
        let expected = fencedOnly ? ["Audible processing barrier."] : ["Normal target prose is spoken.", "Audible processing barrier."]
        #expect(await waitUntil { rig.output.plays.count == expected.count && rig.output.plays.allSatisfy { $0.outcome == "played" } })
        #expect(rig.synth.prepared == expected && rig.output.plays.map(\.text) == expected)
    }
    @Test func build20ReconnectKeepsReceivedAudioAndSpeaksHistoryRemainderExactlyOnce() async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [LiveWire.self]
        let backend = RemoteSessionBackend(transport: try BridgeTransport(base: URL(string: "https://fixture.test/floating-voice")!, credentials: LiveKeys(), configuration: cfg))
        var wire: LiveWire?, opens = 0
        let first = "Already received audio keeps playing."
        let remainder = "The unheard ending is recovered once."
        let full = first + " " + remainder
        LiveWire.respond = { p in
            let path = p.request.url!.path
            if path.hasSuffix("selection") { p.json(["generation":"g"]); return }
            if path.hasSuffix("events") { opens += 1; wire = p; p.headers("text/event-stream"); return }
            if path.hasSuffix("state") { p.json(["active":false]); return }
            if path.hasSuffix("messages") {
                p.json(["data": opens > 1 ? [["id":"a", "type":"assistant", "time":["created":1,"completed":2], "content":[["type":"text", "text":full]]]] : []]); return
            }
            if path.hasSuffix("sessions") { p.json(["data":[]]); return }
            p.json([:])
        }
        let output = FakeOutput(duration: 2), input = FakeInput()
        var settings = LoadedSettings(app: AppSettings(), voice: VoiceConfig(), voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent")
        settings.app.target = "ses_fixture"
        let controller = ConversationController(settings: settings, backend: backend, synth: FakeSynth(), output: output, input: input, makeRecognition: { FakeRecognition($0, transcript: "") })
        let surface = VoiceSurface()
        controller.onCaption = { surface.handle($0, owner: surface.binding) }
        controller.onStatus = { surface.update(status: $0, owner: surface.binding) }
        backend.onChange = { surface.update(records: backend.store?.records ?? [], connection: backend.connection, active: backend.store?.active == true) }
        backend.onNarration = { controller.consumeNarration($0) }
        defer { controller.stop(); backend.disconnect(); LiveWire.respond = nil }
        try await backend.select("ses_fixture")
        await controller.start()
        #expect(await waitUntil { controller.status.phase == "ready" })
        let block: [String: Any] = ["assistantMessageID":"a", "ordinal":0]
        wire?.event("session.text.started", block)
        wire?.event("session.text.delta", block.merging(["delta":first + " "]) { _, b in b })
        #expect(await waitUntil { output.playing == [first] })
        let stops = output.stops
        wire?.finish()
        #expect(await waitUntil { backend.connection == "reconnecting" })
        #expect(output.playing == [first] && output.stops == stops && input.started)
        #expect(surface.chiefCaption == first)
        #expect(await waitUntil(8) { opens == 2 && backend.connection == "connected" })
        #expect(await waitUntil(8) { output.plays.count == 2 && output.plays.allSatisfy { $0.outcome == "played" } })
        #expect(output.plays.map(\.text) == [first, remainder])
        #expect(surface.chiefCaption == full)
        // Authoritative end + repeated history cannot replay or silently omit either sentence.
        wire?.event("session.text.ended", block.merging(["text":full]) { _, b in b }, id: "end")
        try await backend.reconcile(try #require(backend.lease))
        #expect(output.plays.map(\.text) == [first, remainder] && output.stops == stops)
    }
    @Test func typedRepairDuringInitialCatchupUsesSingleHistoryLane() async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [LiveWire.self]
        let backend = RemoteSessionBackend(transport: try BridgeTransport(base: URL(string:"https://fixture.test/floating-voice")!, credentials: LiveKeys(), configuration: cfg))
        var held: LiveWire?, reads = 0, acknowledged = false
        let surface = VoiceSurface()
        backend.onChange = { surface.update(records: backend.displayRecords, connection: backend.connection, active: false) }
        LiveWire.respond = { p in
            let path = p.request.url!.path
            if path.hasSuffix("selection") { p.json(["generation":"g"]); return }
            if path.hasSuffix("events") { p.headers("text/event-stream"); return }
            if path.hasSuffix("state") { p.json(["active":false]); return }
            if path.hasSuffix("prompt") { acknowledged = true; p.json(["data":["id":"msg_u"]]); return }
            if path.hasSuffix("messages") {
                reads += 1
                if reads == 1 { held = p; return }
                p.json(["data": [["id":"msg_u", "type":"user", "text":"Typed during catchup"]]]); return
            }
            p.json([:])
        }
        defer { backend.disconnect(); LiveWire.respond = nil }
        try await backend.select("ses_fixture")
        #expect(await waitUntil { held != nil })
        try await backend.prompt(target: try #require(backend.lease), text: "Typed during catchup", delivery: nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(acknowledged && reads == 1 && backend.connection == "catching up")
        held?.json(["data":[]]); held = nil
        #expect(await waitUntil { surface.userCaption == "Typed during catchup" && backend.connection == "connected" })
        #expect(reads == 2)
    }
    @Test func senderReceiptRaceBuffersDisplayAndNeverMatchesIdenticalExternalText() async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [LiveWire.self]
        let backend = RemoteSessionBackend(transport: try BridgeTransport(base: URL(string:"https://fixture.test/floating-voice")!, credentials: LiveKeys(), configuration: cfg))
        var receipt: LiveWire?, inbound = false
        LiveWire.respond = { p in
            let path = p.request.url!.path
            if path.hasSuffix("selection") { p.json(["generation":"g"]); return }
            if path.hasSuffix("events") { p.headers("text/event-stream"); return }
            if path.hasSuffix("state") { p.json(["active":false]); return }
            if path.hasSuffix("prompt") { receipt = p; return }
            if path.hasSuffix("messages") {
                p.json(["data": inbound ? [
                    ["id":"msg_own", "type":"user", "text":"[chief]\nQuoted text.", "displayText":"Quoted text.", "sender":["kind":"chief", "label":"Chief"]],
                    ["id":"msg_other", "type":"user", "text":"[chief]\nQuoted text.", "displayText":"Quoted text.", "sender":["kind":"chief", "label":"Chief"]]
                ] : []]); return
            }
            p.json([:])
        }
        defer { backend.disconnect(); LiveWire.respond = nil }
        try await backend.select("ses_fixture")
        #expect(await waitUntil { backend.connection == "connected" })
        let lease = try #require(backend.lease)
        let posting = Task { try await backend.prompt(target: lease, text: "[chief]\nQuoted text.", delivery: nil) }
        #expect(await waitUntil { receipt != nil })
        inbound = true; try await backend.reconcile(lease)
        #expect(backend.store?.records.count == 2 && backend.displayRecords.isEmpty)
        receipt?.json(["data":["id":"msg_own"]]); try await posting.value
        let rows = backend.displayRecords.compactMap(MessageRow.init)
        let own = try #require(rows.first { $0.id == "msg_own" }), other = try #require(rows.first { $0.id == "msg_other" })
        #expect(own.isPrincipal && own.text == "[chief]\nQuoted text.")
        #expect(!other.isPrincipal && other.displayLabel == "Chief" && other.text == "Quoted text.")
    }
    @Test(arguments: ["reconnect", "switch", "cancel", "error"]) func refreshLaneLifetimeAndNoAutonomousErrorRetry(_ mode: String) async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [LiveWire.self]
        let backend = RemoteSessionBackend(transport: try BridgeTransport(base: URL(string:"https://fixture.test/floating-voice")!, credentials: LiveKeys(), configuration: cfg))
        var wire: LiveWire?, held: LiveWire?, reads = 0, opens = 0, activeReads = 0, maxReads = 0, errors = 0
        var generation = 0, stoppedReads = 0
        var errorMessages: [String] = []
        backend.onError = { errors += 1; errorMessages.append($0) }
        LiveWire.stopped = { p in
            if p === held { activeReads -= 1; stoppedReads += 1; held = nil }
        }
        LiveWire.respond = { p in
            let path = p.request.url!.path
            if path.hasSuffix("selection") { generation += 1; p.json(["generation":"g\(generation)"]); return }
            if path.hasSuffix("events") { opens += 1; wire = p; p.headers("text/event-stream"); return }
            if path.hasSuffix("state") { p.json(["active":false]); return }
            if path.hasSuffix("messages") {
                reads += 1; activeReads += 1; maxReads = max(maxReads, activeReads)
                if reads == 2 { held = p; return }
                p.json(["data":[]]); activeReads -= 1; return
            }
            p.json([:])
        }
        defer { backend.disconnect(); LiveWire.respond = nil; LiveWire.stopped = nil }
        try await backend.select("ses_fixture")
        #expect(await waitUntil { backend.connection == "connected" })
        wire?.event("session.execution.started", id:"start")
        #expect(await waitUntil { held != nil })
        if mode != "error" {
            wire?.event("session.execution.succeeded", id:"done")
            #expect(await waitUntil { backend.store?.active == false })
        }
        if mode == "reconnect" {
            wire?.finish()
            #expect(await waitUntil { opens == 2 && backend.connection == "catching up" })
            #expect(reads == 2 && backend.connection == "catching up")
            held?.json(["data":[]]); held = nil; activeReads -= 1
            #expect(await waitUntil { backend.connection == "connected" })
            #expect(reads == 4) // dirty trailing repair, then new-connection snapshot
        } else if mode == "switch" || mode == "cancel" {
            backend.disconnect()
            #expect(await waitUntil { stoppedReads == 1 })
            if mode == "switch" {
                try await backend.select("ses_fixture") // same ID, new generation/epoch
                #expect(await waitUntil { backend.connection == "connected" })
                wire?.event("session.execution.succeeded", id:"new-done")
                #expect(await waitUntil { reads == 4 })
                #expect(backend.lease?.generation == "g2")
            }
        } else {
            held?.client?.urlProtocol(held!, didFailWithError: URLError(.networkConnectionLost))
            held = nil; activeReads -= 1
            #expect(await waitUntil { errors == 1 })
        }
        let settled = reads
        try await Task.sleep(nanoseconds: 650_000_000)
        #expect(reads == settled && maxReads == 1 && activeReads == 0)
        #expect(errors == (mode == "error" ? 1 : 0), "\(errorMessages)")
    }
    @Test(arguments: [false, true]) func finalEventsDuringWithheldHistoryEarnExactlyOneTrailingRepair(_ failOldRead: Bool) async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [LiveWire.self]
        let backend = RemoteSessionBackend(transport: try BridgeTransport(base: URL(string:"https://fixture.test/floating-voice")!, credentials: LiveKeys(), configuration: cfg))
        let surface = VoiceSurface()
        var wire: LiveWire?, held: LiveWire?, reads = 0, final = false, errors = 0, changes = 0
        backend.onChange = { changes += 1; surface.update(records: backend.displayRecords, connection: backend.connection, active: backend.store?.active == true) }
        backend.onError = { _ in errors += 1 }
        LiveWire.respond = { p in
            let path = p.request.url!.path
            if path.hasSuffix("selection") { p.json(["generation":"g"]); return }
            if path.hasSuffix("events") { wire = p; p.headers("text/event-stream"); return }
            if path.hasSuffix("state") { p.json(["active": !final]); return }
            if path.hasSuffix("messages") {
                reads += 1
                if reads == 2 { held = p; return }
                p.json(["data": final ? [["id":"tool", "type":"assistant", "content":[["type":"tool", "name":"test", "state":["status":"completed", "content":[["type":"text", "text":"Final tool result"]]]]]]] : []]); return
            }
            p.json([:])
        }
        defer { backend.disconnect(); LiveWire.respond = nil }
        try await backend.select("ses_fixture")
        #expect(await waitUntil { backend.connection == "connected" })
        // Burst before the fixed debounce earns one read, not a continually reset timer.
        for i in 0..<30 { wire?.event("session.execution.started", id: "start-\(i)") }
        #expect(await waitUntil { held != nil })
        #expect(reads == 2)
        for i in 0..<30 { wire?.event("session.tool.success", id: "tool-\(i)") }
        wire?.event("session.text.ended", ["assistantMessageID":"a", "ordinal":0, "text":"Finished"], id:"text-end")
        wire?.event("session.execution.succeeded", id:"end")
        #expect(await waitUntil { !surface.active }) // proves final SSE was parsed before release
        final = true
        let published = changes
        if failOldRead { held?.client?.urlProtocol(held!, didFailWithError: URLError(.networkConnectionLost)) }
        else { held?.json(["data":[]]) }
        held = nil
        #expect(await waitUntil { backend.store?.records.compactMap(MessageRow.init).contains { $0.body.contains { $0.blocks.contains(.paragraph("Final tool result")) } } == true })
        #expect(changes > published && backend.connection == "connected")
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(reads == 3 && errors == (failOldRead ? 1 : 0))
    }
    @Test func installedWireNoSSEIDLiveOffPublicationToolsTypedRefreshAndReconnect() async throws {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [LiveWire.self]
        let backend = RemoteSessionBackend(transport: try BridgeTransport(base: URL(string:"https://fixture.test/floating-voice")!, credentials: LiveKeys(), configuration: cfg))
        let surface = VoiceSurface()
        var wire: LiveWire?, opens = 0, historyReads = 0, acknowledged = false
        var changes = 0, narrations: [NarrationUpdate] = []
        let reply = "Hello hello. Same Same"
        backend.onChange = { changes += 1; surface.update(records: backend.displayRecords, connection: backend.connection, active: backend.store?.active == true) }
        backend.onNarration = { narrations.append($0) }
        LiveWire.respond = { protocolObject in
            let p = protocolObject.request.url!.path
            if p.hasSuffix("health") { protocolObject.json([:]); return }
            if p.hasSuffix("/v1/sessions") { protocolObject.json(["data":[]]); return } // title lookup is not lease-scoped
            if p.hasSuffix("selection") { protocolObject.json(["generation":"fixture-generation"]); return }
            #expect(protocolObject.request.value(forHTTPHeaderField:"X-FV-Generation") == "fixture-generation")
            if p.hasSuffix("events") { opens += 1; wire = protocolObject; protocolObject.headers("text/event-stream"); return } // no event needed for readiness
            if p.hasSuffix("state") { protocolObject.json(["active":false]); return }
            if p.hasSuffix("prompt") { acknowledged = true; protocolObject.json(["data":["id":"msg_u"]]); return }
            if p.hasSuffix("messages") {
                historyReads += 1
                var records: [[String: Any]] = acknowledged ? [["id":"msg_u","type":"user","text":"Owned synthetic typed message","time":["created":1]]] : []
                if opens > 1 { records += [["id":"a","type":"assistant","content":[["type":"text","text":reply]],"time":["created":2]]] }
                protocolObject.json(["data":records]); return
            }
            Issue.record("unexpected synthetic fixture route: \(p)"); protocolObject.json([:])
        }
        defer { backend.disconnect(); LiveWire.respond = nil }
        try await backend.select("ses_fixture")
        var settings = LoadedSettings(app: AppSettings(), voice: VoiceConfig(), voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent")
        settings.app.target = "ses_fixture"
        let input = FakeInput()
        let controller = ConversationController(settings: settings, backend: backend, synth: FakeSynth(), output: FakeOutput(), input: input,
            makeRecognition: { FakeRecognition($0, transcript: "") })
        await controller.start()
        #expect(await waitUntil { controller.status.phase == "ready" && controller.currentLease != nil })
        #expect(input.started && controller.status.connection == "connected")
        controller.stop() // remainder proves actual reply publication continues with voice OFF
        #expect(await waitUntil { backend.connection == "connected" })
        #expect(narrations.isEmpty && !surface.pill.status.running)
        let lease = try #require(backend.lease)
        try await backend.prompt(target: lease, text: "Owned synthetic typed message", delivery: nil)
        #expect(await waitUntil { surface.user == "Owned synthetic typed message" })
        let block: [String: Any] = ["assistantMessageID":"a", "ordinal":0]
        wire?.event("session.execution.started", id:"evt_start")
        wire?.event("session.text.started", block, id:"evt_text_start")
        wire?.event("session.text.delta", block.merging(["delta":"Hello "]) { _, b in b }, id:"evt_delta", wrapped:true)
        wire?.event("session.text.delta", block.merging(["delta":"Hello "]) { _, b in b }, id:"evt_delta", wrapped:true) // duplicate numbered frame
        // Two identical unnumbered frames are distinct live arrivals, not content-hash duplicates.
        wire?.event("session.text.delta", block.merging(["delta":"hel"]) { _, b in b })
        wire?.event("session.text.delta", block.merging(["delta":"lo."]) { _, b in b })
        wire?.event("session.text.delta", block.merging(["delta":" Same"]) { _, b in b })
        wire?.event("session.text.delta", block.merging(["delta":" Same"]) { _, b in b })
        #expect(await waitUntil { surface.reply == reply && surface.active })
        #expect(changes > 5 && narrations.map(\.suffix).joined() == reply)
        let reads = historyReads
        wire?.event("session.tool.success", ["assistantMessageID":"a", "ordinal":1], id:"evt_tool")
        #expect(await waitUntil { historyReads > reads })
        wire?.event("session.text.ended", block.merging(["text":reply]) { _, b in b }, id:"evt_end")
        wire?.event("session.execution.succeeded", id:"evt_done")
        #expect(await waitUntil { !surface.active && narrations.last?.final == true })
        let spoken = narrations.count
        wire?.finish()
        #expect(await waitUntil { opens == 2 && backend.connection == "connected" })
        // Snapshot-owned deltas stay quarantined, authoritative end doesn't replay historical speech.
        wire?.event("session.text.delta", block.merging(["delta":"AMBIGUOUS"]) { _, b in b })
        wire?.event("session.text.ended", block.merging(["text":reply]) { _, b in b }, id:"evt_reconnect_end")
        wire?.event("session.text.delta", ["assistantMessageID":"other", "ordinal":0,"delta":"PRIVATE"], session:"ses_other")
        wire?.event("session.text.delta", ["assistantMessageID":"new", "ordinal":0,"delta":"Fresh reply."], id:"evt_new")
        #expect(await waitUntil { surface.reply.contains("Fresh reply.") })
        #expect(!surface.reply.contains("AMBIGUOUS") && !surface.reply.contains("PRIVATE"))
        #expect(narrations.dropFirst(spoken).map(\.suffix).joined() == "Fresh reply.")
    }
}
