import XCTest
@testable import FloatingVoiceCore

private typealias J = OpenVoiceJSON

@MainActor private final class OpenVoiceFakeSocket: OpenVoiceWebSocket {
    var writableBytes = 0
    var sent: [J] = []
    var closed = false
    func send(text: String) async throws { sent.append(try OpenVoiceWire.parse(Data(text.utf8))) }
    func receive() async throws -> Data { throw OpenVoiceFailure("local_failure") }
    func close() { closed = true }
}

/// No timing sleeps/polls: the test controls transmission and send completion separately.
@MainActor private final class OpenVoiceSuspendedSocket: OpenVoiceWebSocket {
    enum Suspension { case beforeTransmission, afterTransmission }
    let suspension: Suspension
    var writableBytes = 0, transmittedCommits = 0
    var closed = false
    private var sendWaiter: CheckedContinuation<Void, Error>?
    private var entryWaiter: CheckedContinuation<Void, Never>?
    init(_ suspension: Suspension) { self.suspension = suspension }
    func send(text: String) async throws {
        let e = try OpenVoiceWire.parse(Data(text.utf8))
        guard e["type"] == .string("input_audio_buffer.commit") else { return }
        if suspension == .afterTransmission { transmittedCommits += 1 }
        try await withCheckedThrowingContinuation { continuation in
            sendWaiter = continuation; entryWaiter?.resume(); entryWaiter = nil
        }
    }
    func waitForCommit() async {
        if sendWaiter != nil { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func completeSend(success: Bool) {
        guard let waiter = sendWaiter else { XCTFail("no suspended send"); return }
        sendWaiter = nil
        if success {
            if suspension == .beforeTransmission { transmittedCommits += 1 }
            waiter.resume()
        } else { waiter.resume(throwing: OpenVoiceFailure("local_failure")) }
    }
    func receive() async throws -> Data { throw OpenVoiceFailure("local_failure") }
    // Leave the injected send pending to exercise a late old completion after closure.
    func close() { closed = true }
}

final class OpenVoiceTests: XCTestCase {
    private func fixture() throws -> J {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Own checkout, not root bridge writer's live files. No production bundle resource.
        return try JSONDecoder().decode(J.self, from: Data(contentsOf: root.appendingPathComponent("bridge/fixtures/open-voice/vectors.json")))
    }
    private func json(_ text: String) throws -> J { try OpenVoiceWire.parse(Data(text.utf8)) }
    func testSharedVectors() throws {
        let f = try fixture()
        XCTAssertEqual(f["profile"].string, OpenVoiceWire.profile)
        XCTAssertEqual(f["client"].array?.count, 30); XCTAssertEqual(f["server"].array?.count, 37)
        XCTAssertEqual(f["updates"].array?.count, 13); XCTAssertEqual(f["futureState"].array?.count, 9)
        XCTAssertEqual(try OpenVoiceWire.createSession("sess_fixture"), f["defaultSession"])
        for family in ["client","server","updates"] {
            for v in f[family].array! {
                let name = v["name"].string!, expected = v["expected"]
                let original = f["defaultSession"]
                do {
                    if family == "updates" {
                        let s = try OpenVoiceWire.applySessionUpdate(original,v["patch"],context: v["context"].object == nil ? .object([:]) : v["context"])
                        XCTAssertEqual(s["output_modalities"],expected["output_modalities"],name)
                    } else {
                        let input = v["input"].string != nil ? try OpenVoiceWire.parse(Data(v["input"].string!.utf8)) : v["input"]
                        let event = try family == "client" ? OpenVoiceWire.client(input,context: v["context"].object == nil ? .object([:]) : v["context"]) : OpenVoiceWire.server(input)
                        if expected["effect"] != .null { XCTAssertEqual(event.effect,expected["effect"].string,name) }
                    }
                    XCTAssertEqual(expected["ok"], .bool(true),name)
                } catch let e as OpenVoiceFailure {
                    XCTAssertEqual(expected["ok"], .bool(false),"\(name): \(e.code)")
                    XCTAssertEqual(e.code,expected["code"].string,name)
                }
                XCTAssertEqual(original,f["defaultSession"],"atomic \(name)")
            }
        }
        // futureState entries are obligations, not executed authority/ledger evidence.
        XCTAssertTrue(f["futureState"].array!.allSatisfy { $0["enforcement"] == .string("future-state") })
    }
    func testWhitespaceDeltaAndPrimitiveErrorCodes() throws {
        for type in ["response.output_text.delta","response.output_audio_transcript.delta"] {
            for s in [""," ","\n","\t"," a "] {
                let e: J = .object(["type":.string(type),"event_id":.string("evt"),"response_id":.string("r"),"item_id":.string("i"),"output_index":.number(0),"content_index":.number(0),"delta":.string(s)])
                XCTAssertEqual(try OpenVoiceWire.server(e)["delta"], .string(s))
            }
        }
        for type in ["error","conversation.item.input_audio_transcription.failed"] {
            for bad: J in [.array([.string("local_failure")]),.object([:]),.null,.number(0),.bool(false)] {
                var e: [String:J] = ["type":.string(type),"event_id":.string("evt"),"error":.object(["type":.string("server_error"),"code":bad,"message":.string("Local processing failed."),"param":.null])]
                if type != "error" { e["item_id"] = .string("i"); e["content_index"] = .number(0) }
                XCTAssertThrowsError(try OpenVoiceWire.server(.object(e)))
            }
        }
    }
    func testWireBoundsAndUnicode() throws {
        XCTAssertThrowsError(try OpenVoiceWire.parse(Data(repeating: 32,count:65537)))
        XCTAssertThrowsError(try json("{\"type\":\"x\",\"\\u0074ype\":\"x\"}"))
        XCTAssertThrowsError(try json("{\"x\":\"\\ud800\"}"))
        let thought = String(repeating:"🐟",count:16000)
        try OpenVoiceWire.text(.string(thought))
        XCTAssertThrowsError(try OpenVoiceWire.text(.string(thought + "🐟")))
        XCTAssertThrowsError(try OpenVoiceWire.userItem(try json(#"{"id":"i","type":"message","role":"user","content":[{"type":"input_text","text":" "}]}"#)))
        let composed = try OpenVoiceCanonicalItem(id:"i",text:"Café"), decomposed = try OpenVoiceCanonicalItem(id:"i",text:"Cafe\u{301}")
        XCTAssertNotEqual(composed,decomposed)
        XCTAssertThrowsError(try OpenVoiceWire.client(decomposed.responseEvent(operationID:UUID()),context:.object(["canonicalItem":composed.json]))) { e in
            XCTAssertEqual((e as? OpenVoiceFailure)?.code,"item_mismatch")
        }
    }
    private func pcm(_ samples: [Int16]) -> Data {
        var d = Data(); for s in samples { let v = UInt16(bitPattern:s); d.append(UInt8(v & 255)); d.append(UInt8(v >> 8)) }; return d
    }
    private func samples(_ data: Data) -> [Int16] {
        let b = [UInt8](data); return stride(from:0,to:b.count,by:2).map { Int16(bitPattern:UInt16(b[$0]) | UInt16(b[$0+1]) << 8) }
    }
    private func convert(_ d: Data, chunk: Int) throws -> Data {
        var c = OpenVoiceInputConverter(), out = Data(), i = 0
        while i < d.count { let n = min(d.count,i+chunk); out.append(try c.append(d.subdata(in:i..<n))); i = n }
        out.append(try c.drain()); XCTAssertThrowsError(try c.drain()); XCTAssertThrowsError(try c.append(Data())); return out
    }
    func testConverterChunkPhaseOddCarryDCAndCount() throws {
        let d = pcm((0..<1601).map { Int16(($0 * 157) % 50000 - 25000) })
        let reference = try convert(d,chunk:3200)
        for n in [1,3,17,639,640,1023] { XCTAssertEqual(try convert(d,chunk:n),reference) }
        XCTAssertEqual(reference.count, 1601 * 3 / 2 * 2)
        let dc = samples(try convert(pcm([Int16](repeating:12000,count:1600)),chunk:639))
        XCTAssertTrue(dc.dropFirst(60).allSatisfy { abs(Int($0)-12000) <= 1 })
        var c = OpenVoiceInputConverter(); _ = try c.append(Data([1])); XCTAssertThrowsError(try c.drain())
    }
    func testConverterGoldenSilenceImpulseClippingAndAntiImage() throws {
        XCTAssertEqual(try convert(Data(repeating:0,count:640),chunk:7),Data(repeating:0,count:960))
        let impulse = samples(try convert(pcm([32767] + [Int16](repeating:0,count:99)),chunk:13))
        XCTAssertEqual(impulse.count,150)
        // Integer phase at 16-input-sample delay: normalized 0.9 sinc centre.
        XCTAssertEqual(Double(impulse[24]),29491,accuracy:10)
        let dc = samples(try convert(pcm([Int16](repeating:32767,count:500)),chunk:23))
        XCTAssertEqual(dc.last,32767)
        let alternating = pcm((0..<1600).map { $0 % 2 == 0 ? Int16(12000) : Int16(-12000) })
        let filtered = samples(try convert(alternating,chunk:639)).dropFirst(100)
        let rms = sqrt(filtered.map { Double($0)*Double($0) }.reduce(0,+)/Double(filtered.count))
        XCTAssertLessThan(rms,1500) // 8 kHz boundary attenuated; no chunk-reset impulses.
    }
    @MainActor private func ready(diagnostics: StageDiagnostics = .shared) throws -> (OpenVoiceClient,OpenVoiceFakeSocket) {
        let socket = OpenVoiceFakeSocket(), fence = OpenVoiceMediaFence(call:UUID(),media:"media_1")
        let owner = UUID()
        let c = try OpenVoiceClient(socket:socket,fence:fence,committedItemLimit:4096,mediaOwnerToken:owner,diagnostics:diagnostics)
        try emit(c,"session.created",["session":try OpenVoiceWire.createSession("s")])
        XCTAssertEqual(c.state,.created)
        try emit(c,"session.updated",["session":try OpenVoiceWire.createSession("s")])
        XCTAssertEqual(c.state,.configured); c.setNativeActivated(true,fence:fence); XCTAssertEqual(c.state,.ready)
        try c.acceptMediaReady(owner:owner,fence:fence,sessionID:"s",epoch:c.readinessEpoch)
        return (c,socket)
    }
    @MainActor private func emit(_ c: OpenVoiceClient, _ type: String, _ fields: [String:J] = [:], now: Double = 0) throws {
        var o = fields; o["type"] = .string(type); o["event_id"] = .string(UUID().uuidString)
        try c.receive(J.object(o).encoded(),fence:c.fence,now:now)
    }
    @MainActor func testActivationGateAndNoImplicitNetwork() throws {
        let s = OpenVoiceFakeSocket(), f = OpenVoiceMediaFence(call:UUID(),media:"m")
        let c = try OpenVoiceClient(socket:s,fence:f)
        c.setNativeActivated(true,fence:f)
        XCTAssertEqual(c.state,.awaitingCreated); XCTAssertTrue(s.sent.isEmpty)
        XCTAssertThrowsError(try c.enqueue(try json("{\"type\":\"input_audio_buffer.append\",\"audio\":\"AAA=\"}")))
        XCTAssertEqual(c.state,.failed)
    }
    @MainActor func testEarlyStopRetainsFirstBoundaryAndCursorsBeforeTeardown() async throws {
        let diagnostics = StageDiagnostics(); diagnostics.beginCall()
        let (c, socket) = try ready(diagnostics: diagnostics)
        let owner = UUID(); try c.acquireSegment(owner)
        // Same 134-block duration as the pilot, but synthetic data/flow only.
        for n in 1...134 {
            try c.append(Data(repeating: 0, count: 960), owner: owner); try await c.flush()
            try emit(c, "vs.flow", ["media_epoch": .string("media_1"), "input_consumed_samples": .number(Double(n * 480))])
        }
        c.onState = { state in
            if state == .failed { c.fail(origin: .ownerClose) }
        }
        try emit(c, "error", ["error": .object(["type": .string("server_error"), "code": .string("local_failure"),
            "message": .string("Local processing failed."), "param": .null])])
        XCTAssertEqual(c.state, .failed); XCTAssertTrue(socket.closed)
        c.fail(origin: .recognition); c.socketClosed(fence: c.fence)
        // Late callbacks and subsequent-call noise cannot overwrite first origin
        // or attribute this old client's failure to the new diagnostic call.
        diagnostics.beginCall()
        for _ in 0..<300 { diagnostics.record(.other, .complete) }
        let rows = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(diagnostics.export().utf8))
        let failures = rows.filter { $0.audio?.values["openVoiceFailureOrigin"] != nil }
        XCTAssertEqual(failures.count, 1)
        let first = try XCTUnwrap(failures.first)
        XCTAssertEqual(first.diagnosticCall, 1)
        XCTAssertEqual(first.category, .failed)
        XCTAssertEqual(first.audio?.values, ["openVoiceFailureOrigin": 5, "openVoiceAdmittedSamples": 64320,
            "openVoiceSentSamples": 64320, "openVoiceConsumedSamples": 64320])
        let exported = diagnostics.export()
        for privateValue in ["local_failure", "Local processing failed", "media_1", c.fence.call.uuidString] {
            XCTAssertFalse(exported.contains(privateValue))
        }
    }
    @MainActor func testEarlyStopDistinguishesInvalidEventFromReceiveFailure() async throws {
        for malformed in [true, false] {
            let diagnostics = StageDiagnostics()
            let (c, _) = try ready(diagnostics: diagnostics)
            if malformed { XCTAssertThrowsError(try c.receive(Data("{}".utf8), fence: c.fence, now: 0)) }
            else { do { try await c.receiveOne(); XCTFail("fake transport must fail") } catch {} }
            let rows = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(diagnostics.export().utf8))
            XCTAssertEqual(rows.compactMap { $0.audio?.values["openVoiceFailureOrigin"] }, [malformed ? 4 : 3])
        }
    }
    @MainActor func testCumulativeCreditAndBoundedQueue() async throws {
        let (c,s) = try ready()
        let append: J = .object(["type":.string("input_audio_buffer.append"),"audio":.string(Data(repeating:0,count:4800).base64EncodedString())])
        for _ in 0..<20 { try c.enqueue(append) }; try await c.flush()
        XCTAssertEqual(c.sentSamples,48000); XCTAssertEqual(s.sent.count,20)
        try c.enqueue(append); try await c.flush(); XCTAssertEqual(c.sentSamples,48000)
        for _ in 0..<2 { try emit(c,"vs.flow",["media_epoch":.string("media_1"),"input_consumed_samples":.number(2400)]) }
        try await c.flush(); XCTAssertEqual(c.sentSamples,50400); XCTAssertEqual(c.consumedSamples,2400)
        for _ in 0..<20 { try c.enqueue(append) }
        XCTAssertThrowsError(try c.enqueue(append)); XCTAssertEqual(c.state,.failed)
    }
    @MainActor func testFlowWrongEpochAndImpossibleCursor() async throws {
        let (c,_) = try ready()
        try emit(c,"vs.flow",["media_epoch":.string("old"),"input_consumed_samples":.number(100000)])
        XCTAssertEqual(c.consumedSamples,0)
        XCTAssertThrowsError(try emit(c,"vs.flow",["media_epoch":.string("media_1"),"input_consumed_samples":.number(1)]))
    }
    @MainActor func testRecognitionCommitFinalEmptyAndZeroHarnessMutation() async throws {
        let (c,s) = try ready(); var finals:[String] = [], errors = 0
        let r = OpenVoiceRecognition(client:c,callbacks:RecognitionCallbacks(partial:{ _ in XCTFail("no additive partial") },error:{ _ in errors += 1 },done:{ finals.append($0) }))
        r.start(); r.write(Data(repeating:0,count:640)); r.end(); try await c.flush()
        XCTAssertEqual(s.sent.map { $0["type"].string! },["input_audio_buffer.append","input_audio_buffer.commit"])
        XCTAssertEqual(try OpenVoiceWire.pcm(s.sent[0]["audio"]).count,960)
        try emit(c,"input_audio_buffer.committed",["item_id":.string("i"),"previous_item_id":.null])
        try emit(c,"conversation.item.input_audio_transcription.completed",["item_id":.string("stale"),"content_index":.number(0),"transcript":.string("wrong"),"usage":.object(["type":.string("duration"),"seconds":.number(0.02)])])
        XCTAssertTrue(finals.isEmpty)
        try emit(c,"conversation.item.input_audio_transcription.completed",["item_id":.string("i"),"content_index":.number(0),"transcript":.string(""),"usage":.object(["type":.string("duration"),"seconds":.number(0.02)])])
        XCTAssertEqual(finals,[""]); XCTAssertEqual(errors,0)
        r.end(); r.write(Data([0,0])); XCTAssertEqual(finals.count,1)
        XCTAssertFalse(s.sent.contains { ["response.create","conversation.item.create"].contains($0["type"].string ?? "") })
    }
    @MainActor func testSegmentSerializationAndCloseIsFailure() async throws {
        let (c,_) = try ready(); var errors = 0, finals = 0
        let cb = RecognitionCallbacks(partial:{_ in},error:{_ in errors += 1},done:{_ in finals += 1})
        let a = OpenVoiceRecognition(client:c,callbacks:cb), b = OpenVoiceRecognition(client:c,callbacks:cb)
        a.start(); a.write(Data(repeating:0,count:640)); a.end(); b.start()
        XCTAssertEqual(errors,1); XCTAssertEqual(c.state,.ready)
        c.socketClosed(fence:OpenVoiceMediaFence(call:UUID(),media:"media_1")); XCTAssertEqual(c.state,.ready)
        c.socketClosed(fence:c.fence); XCTAssertEqual(errors,2); XCTAssertEqual(finals,2); XCTAssertEqual(c.state,.failed)
        c.socketClosed(fence:c.fence); XCTAssertEqual(finals,2)
    }
    @MainActor func testStrictRequestDestination() throws {
        let o = URL(string:"https://fixture.tailnet.invalid:8443")!
        let good = "wss://fixture.tailnet.invalid:8443/floating-voice/v1/realtime?model=local-chain-m1"
        let r = try OpenVoiceClient.mediaRequest(origin:o,endpoint:URL(string:good)!,recipientMediaLease:"synthetic-only")
        XCTAssertEqual(r.value(forHTTPHeaderField:"Authorization"),"Bearer synthetic-only")
        XCTAssertNil(r.value(forHTTPHeaderField:"Sec-WebSocket-Protocol"))
        for bad in [good + "&token=x",good + "#x",good.replacingOccurrences(of:"fixture.tailnet",with:"other.tailnet"),good.replacingOccurrences(of:"wss:",with:"ws:"),good.replacingOccurrences(of:"/floating-voice",with:"/%66loating-voice")] {
            XCTAssertThrowsError(try OpenVoiceClient.mediaRequest(origin:o,endpoint:URL(string:bad)!,recipientMediaLease:"synthetic"))
        }
    }
    @MainActor private func startResponse(_ c: OpenVoiceClient) throws -> [String:J] {
        let item = try OpenVoiceCanonicalItem(id:"user",text:"  Reviewed 🐟. ")
        try c.enqueue(item.createEvent)
        try c.enqueue(item.responseEvent(operationID:UUID(uuidString:"11111111-1111-4111-8111-111111111111")!))
        let response = try fixture()["server"].array!.first { $0["name"] == .string("response-started") }!["input"]["response"]
        try emit(c,"response.created",["response":response])
        let assistant = try json(#"{"id":"reply","object":"realtime.item","type":"message","role":"assistant","status":"in_progress","content":[]}"#)
        try emit(c,"response.output_item.added",["response_id":.string("r1"),"output_index":.number(0),"item":assistant])
        let co: [String:J] = ["response_id":.string("r1"),"item_id":.string("reply"),"output_index":.number(0),"content_index":.number(0)]
        var p = co; p["part"] = .object(["type":.string("audio"),"transcript":.string("")])
        try emit(c,"response.content_part.added",p)
        return co
    }
    @MainActor private func audio(_ c: OpenVoiceClient, _ co: [String:J], bytes: Int = 960, now: Double = 0) throws {
        var a = co; a["delta"] = .string(Data(repeating:0,count:bytes).base64EncodedString())
        try emit(c,"response.output_audio.delta",a,now:now)
    }
    @MainActor private func finishResponse(_ c: OpenVoiceClient, _ co: [String:J], status: String = "completed") throws {
        try emit(c,"response.output_audio.done",co)
        var t = co; t["transcript"] = .string("Heard is not inferred."); try emit(c,"response.output_audio_transcript.done",t)
        var p = co; p["part"] = .object(["type":.string("audio"),"transcript":.string("Heard is not inferred.")]); try emit(c,"response.content_part.done",p)
        let i = try json(#"{"id":"reply","object":"realtime.item","type":"message","role":"assistant","status":"completed","content":[{"type":"output_audio","transcript":"Heard is not inferred."}]}"#)
        try emit(c,"response.output_item.done",["response_id":.string("r1"),"output_index":.number(0),"item":i])
        let name = status == "completed" ? "generation-completed-not-heard" : status == "cancelled" ? "generation-cancelled" : "generation-failed"
        let r = try fixture()["server"].array!.first { $0["name"] == .string(name) }!["input"]["response"]
        try emit(c,"response.done",["response":r])
    }
    @MainActor func testPreparedPCMGenerationIsNotPlaybackAndEpochs() async throws {
        let (c,s) = try ready(); let co = try startResponse(c)
        try audio(c,co); let ticket = try XCTUnwrap(c.takePreparedPCM())
        XCTAssertEqual(ticket.pcm.count,960); XCTAssertEqual(ticket.sourceOffset,0); XCTAssertEqual(ticket.sampleRate,24000)
        XCTAssertEqual(c.renderedSamples,0)
        try finishResponse(c,co); XCTAssertNil(c.activeResponseID); XCTAssertEqual(c.renderedSamples,0)
        try await c.flush()
        XCTAssertEqual(s.sent.filter { $0["type"] == .string("conversation.item.create") }.count,1)
        let canonical = s.sent.first { $0["type"] == .string("conversation.item.create") }!["item"]
        XCTAssertEqual(s.sent.first { $0["type"] == .string("response.create") }!["response"]["input"],.array([canonical]))
        XCTAssertFalse(s.sent.contains { $0["type"] == .string("vs.playback") })
        try c.reportRendered(fence:c.fence,responseID:"r1",itemID:"reply",playbackEpoch:UUID(),samples:480,state:"completed",now:1)
        XCTAssertEqual(c.renderedSamples,0)
        try c.reportRendered(fence:c.fence,responseID:"r1",itemID:"reply",playbackEpoch:ticket.playbackEpoch,samples:0,state:"unknown",now:1)
        XCTAssertEqual(c.renderedSamples,0)
        XCTAssertThrowsError(try c.reportRendered(fence:c.fence,responseID:"r1",itemID:"reply",playbackEpoch:ticket.playbackEpoch,samples:480,state:"unknown",now:2))
        try c.reportRendered(fence:c.fence,responseID:"r1",itemID:"reply",playbackEpoch:ticket.playbackEpoch,samples:240,state:"playing",now:2)
        try c.reportRendered(fence:c.fence,responseID:"r1",itemID:"reply",playbackEpoch:ticket.playbackEpoch,samples:240,state:"playing",now:2.1)
        try c.reportRendered(fence:c.fence,responseID:"r1",itemID:"reply",playbackEpoch:ticket.playbackEpoch,samples:240,state:"paused",now:2.11)
        try c.reportRendered(fence:c.fence,responseID:"r1",itemID:"reply",playbackEpoch:ticket.playbackEpoch,samples:480,state:"completed",now:2.12)
        try await c.flush(); XCTAssertEqual(s.sent.filter { $0["type"] == .string("vs.playback") }.count,4)
        c.tick(now:30,fence:c.fence); XCTAssertEqual(c.state,.ready)
    }
    @MainActor func testOutputCreditQueueAndStallFences() throws {
        let (c,_) = try ready(); let co = try startResponse(c)
        for _ in 0..<20 { try audio(c,co,bytes:4800) }
        XCTAssertEqual(c.queuedPCMBytes,96000)
        // Dequeue alone is not credit. At the window even an empty local queue cannot admit more.
        while c.takePreparedPCM() != nil {}
        XCTAssertEqual(c.renderedSamples,0)
        XCTAssertThrowsError(try audio(c,co)); XCTAssertEqual(c.state,.failed)
        let (d,_) = try ready(); let co2 = try startResponse(d); try audio(d,co2,now:5)
        d.tick(now:19.9,fence:d.fence); XCTAssertEqual(d.state,.ready)
        d.tick(now:20,fence:OpenVoiceMediaFence(call:UUID(),media:"media_1")); XCTAssertEqual(d.state,.ready)
        d.tick(now:20,fence:d.fence); XCTAssertEqual(d.state,.failed)
    }
    @MainActor func testInputCreditStallAndWritableCap() async throws {
        let (c,_) = try ready()
        let a: J = .object(["type":.string("input_audio_buffer.append"),"audio":.string(Data(repeating:0,count:4800).base64EncodedString())])
        for _ in 0..<20 { try c.enqueue(a) }; try await c.flush(); try c.enqueue(a)
        c.tick(now:5,fence:c.fence)
        try emit(c,"vs.flow",["media_epoch":.string("media_1"),"input_consumed_samples":.number(0)],now:19.8)
        c.tick(now:19.9,fence:c.fence); XCTAssertEqual(c.state,.ready)
        c.tick(now:20,fence:c.fence); XCTAssertEqual(c.state,.failed)
        let (d,s) = try ready(); s.writableBytes = OpenVoiceWire.maxWritableBytes
        XCTAssertThrowsError(try d.enqueue(a)); XCTAssertEqual(d.state,.failed)
    }
    @MainActor func testLifecycleFailsClosedAndTerminalStatusesNeverHeard() throws {
        let (c,_) = try ready(); let co = try startResponse(c)
        let done = try fixture()["server"].array!.first { $0["name"] == .string("generation-completed-not-heard") }!["input"]["response"]
        XCTAssertThrowsError(try emit(c,"response.done",["response":done])); XCTAssertEqual(c.state,.failed)
        for status in ["cancelled","failed"] {
            let (d,_) = try ready(); let coords = try startResponse(d); try audio(d,coords)
            try finishResponse(d,coords,status:status); XCTAssertEqual(d.renderedSamples,0); XCTAssertEqual(d.state,.ready)
        }
        let (d,_) = try ready(); _ = try startResponse(d)
        var wrong = co; wrong["item_id"] = .string("other")
        XCTAssertThrowsError(try audio(d,wrong)); XCTAssertEqual(d.state,.failed)
    }
    @MainActor func testRecognitionFailedAndOddFinalCannotBecomeSuccess() async throws {
        for odd in [false,true] {
            let (c,_) = try ready(); var errors = 0, finals:[String] = []
            let r = OpenVoiceRecognition(client:c,callbacks:RecognitionCallbacks(partial:{_ in XCTFail()},error:{_ in errors += 1},done:{finals.append($0)}))
            r.start(); r.write(Data(repeating:0,count:odd ? 641 : 640)); r.end()
            if !odd {
                try await c.flush()
                try emit(c,"input_audio_buffer.committed",["item_id":.string("i"),"previous_item_id":.null])
                try emit(c,"conversation.item.input_audio_transcription.failed",["item_id":.string("i"),"content_index":.number(0),"error":.object(["type":.string("server_error"),"code":.string("local_failure"),"message":.string("Local processing failed."),"param":.null])])
            }
            XCTAssertEqual(errors,1); XCTAssertEqual(finals,[""]); XCTAssertEqual(c.state,.failed)
        }
    }
    @MainActor private func configure(_ socket: OpenVoiceWebSocket, itemLimit: Int = 4096) throws -> OpenVoiceClient {
        let owner = UUID()
        let c = try OpenVoiceClient(socket:socket,fence:OpenVoiceMediaFence(call:UUID(),media:"media_1"),committedItemLimit:itemLimit,mediaOwnerToken:owner)
        try emit(c,"session.created",["session":try OpenVoiceWire.createSession("s")])
        try emit(c,"session.updated",["session":try OpenVoiceWire.createSession("s")])
        c.setNativeActivated(true,fence:c.fence)
        try c.acceptMediaReady(owner:owner,fence:c.fence,sessionID:"s",epoch:c.readinessEpoch)
        return c
    }
    @MainActor private func ack(_ c: OpenVoiceClient, item: String) throws {
        try emit(c,"input_audio_buffer.committed",["item_id":.string(item),"previous_item_id":.null])
    }
    @MainActor private func transcript(_ c: OpenVoiceClient, item: String, text: String) throws {
        try emit(c,"conversation.item.input_audio_transcription.completed",["item_id":.string(item),"content_index":.number(0),"transcript":.string(text),"usage":.object(["type":.string("duration"),"seconds":.number(0.02)])])
    }
    @MainActor func testCommittedItemCannotBeReassignedByFreshEventIDs() async throws {
        let (c,_) = try ready(); var aFinal:[String] = [], bFinal:[String] = [], bErrors = 0
        let a = OpenVoiceRecognition(client:c,callbacks:RecognitionCallbacks(partial:{_ in},error:{_ in XCTFail()},done:{aFinal.append($0)}))
        a.start(); a.write(Data(repeating:0,count:640)); a.end(); try await c.flush()
        try ack(c,item:"old"); try transcript(c,item:"old",text:"A's old words")
        XCTAssertEqual(aFinal,["A's old words"])
        let b = OpenVoiceRecognition(client:c,callbacks:RecognitionCallbacks(partial:{_ in},error:{_ in bErrors += 1},done:{bFinal.append($0)}))
        b.start(); b.write(Data(repeating:0,count:640)); b.end(); try await c.flush()
        // Each emit generates a fresh event_id: event-ID uniqueness is insufficient.
        XCTAssertThrowsError(try ack(c,item:"old")) { error in XCTAssertEqual((error as? OpenVoiceFailure)?.code,"item_mismatch") }
        try transcript(c,item:"old",text:"A's old words") // failed session ignores late RX
        XCTAssertEqual(bFinal,[""]); XCTAssertEqual(bErrors,1); XCTAssertEqual(c.state,.failed)
    }
    @MainActor func testLaterNewSegmentIgnoresOldResultsAndUsesNewItem() async throws {
        let (c,_) = try ready(); var finals:[String] = []
        let cb = RecognitionCallbacks(partial:{_ in XCTFail()},error:{_ in XCTFail()},done:{finals.append($0)})
        let a = OpenVoiceRecognition(client:c,callbacks:cb)
        a.start(); a.write(Data(repeating:0,count:640)); a.end(); try await c.flush()
        try ack(c,item:"old"); try transcript(c,item:"old",text:"A")
        let b = OpenVoiceRecognition(client:c,callbacks:cb)
        b.start(); b.write(Data(repeating:0,count:640)); b.end(); try await c.flush()
        try transcript(c,item:"old",text:"old must not finalize B")
        XCTAssertEqual(finals,["A"])
        try ack(c,item:"new"); try transcript(c,item:"old",text:"still old")
        XCTAssertEqual(finals,["A"])
        try transcript(c,item:"new",text:"B"); XCTAssertEqual(finals,["A","B"])
    }
    @MainActor func testCommittedOwnershipExhaustionFailsClosedWithoutEviction() async throws {
        let c = try configure(OpenVoiceFakeSocket(),itemLimit:2); var finals:[String] = [], errors = 0
        for i in 0..<3 {
            let r = OpenVoiceRecognition(client:c,callbacks:RecognitionCallbacks(partial:{_ in},error:{_ in errors += 1},done:{finals.append($0)}))
            r.start(); r.write(Data(repeating:0,count:640)); r.end(); try await c.flush()
            if i < 2 { try ack(c,item:"item_\(i)"); try transcript(c,item:"item_\(i)",text:"\(i)") }
            else { XCTAssertThrowsError(try ack(c,item:"item_2")) }
        }
        XCTAssertEqual(finals,["0","1",""]); XCTAssertEqual(errors,1); XCTAssertEqual(c.state,.failed)
    }
    @MainActor func testCommitACKAndResultWaitForConfirmedHandoffBothRaces() async throws {
        for mode in [OpenVoiceSuspendedSocket.Suspension.beforeTransmission,.afterTransmission] {
            let s = OpenVoiceSuspendedSocket(mode), c = try configure(s)
            var finals:[String] = [], events:[OpenVoiceEventKind] = []
            c.onEvent = { events.append($0.kind) }
            let r = OpenVoiceRecognition(client:c,callbacks:RecognitionCallbacks(partial:{_ in XCTFail()},error:{_ in XCTFail()},done:{finals.append($0)}))
            r.start(); r.write(Data(repeating:0,count:640)); r.end()
            let pump = Task { try await c.flush() }; await s.waitForCommit()
            XCTAssertEqual(s.transmittedCommits,mode == .beforeTransmission ? 0 : 1)
            try ack(c,item:"raced"); try transcript(c,item:"raced",text:"valid after handoff")
            XCTAssertTrue(finals.isEmpty); XCTAssertTrue(events.isEmpty)
            s.completeSend(success:true); try await pump.value
            XCTAssertEqual(s.transmittedCommits,1); XCTAssertEqual(finals,["valid after handoff"])
            XCTAssertEqual(events,[.committed,.transcriptionCompleted]); XCTAssertEqual(c.state,.ready)
        }
    }
    @MainActor func testPendingCommitFailureCancelAndCloseDiscardHeldWords() async throws {
        for termination in ["send_failure","task_cancel","recognition_cancel","socket_close","client_close"] {
            let s = OpenVoiceSuspendedSocket(.beforeTransmission), c = try configure(s)
            var finals:[String] = [], errors = 0
            let r = OpenVoiceRecognition(client:c,callbacks:RecognitionCallbacks(partial:{_ in XCTFail()},error:{_ in errors += 1},done:{finals.append($0)}))
            r.start(); r.write(Data(repeating:0,count:640)); r.end()
            let pump = Task { try await c.flush() }; await s.waitForCommit()
            try ack(c,item:"old"); try transcript(c,item:"old",text:"never assign these words")
            XCTAssertEqual(s.transmittedCommits,0); XCTAssertTrue(finals.isEmpty)
            switch termination {
            case "task_cancel": pump.cancel()
            case "recognition_cancel": r.cancel()
            case "socket_close": c.socketClosed(fence:c.fence)
            case "client_close": c.close()
            default: break
            }
            s.completeSend(success:termination != "send_failure")
            _ = try? await pump.value
            try transcript(c,item:"old",text:"late result after cancelled/failed old send")
            XCTAssertEqual(finals,[""],termination); XCTAssertEqual(errors,1,termination); XCTAssertEqual(c.state,.failed,termination)
        }
    }
    @MainActor func testRacedBatchCannotLeakAcrossReentrantSegmentFinalCallback() async throws {
        let s = OpenVoiceSuspendedSocket(.afterTransmission), c = try configure(s)
        var aFinal:[String] = [], bFinal:[String] = []
        let b = OpenVoiceRecognition(client:c,callbacks:RecognitionCallbacks(partial:{_ in},error:{_ in XCTFail()},done:{bFinal.append($0)}))
        let a = OpenVoiceRecognition(client:c,callbacks:RecognitionCallbacks(partial:{_ in},error:{_ in XCTFail()},done:{ text in
            aFinal.append(text); b.start(); b.write(Data(repeating:0,count:640)); b.end()
        }))
        a.start(); a.write(Data(repeating:0,count:640)); a.end()
        let pump = Task { try await c.flush() }; await s.waitForCommit()
        try ack(c,item:"old"); try transcript(c,item:"old",text:"A")
        try ack(c,item:"old"); try transcript(c,item:"old",text:"must not enter B")
        s.completeSend(success:true)
        // flush may continue into B's commit; handshake with its second suspension.
        await s.waitForCommit()
        XCTAssertEqual(aFinal,["A"]); XCTAssertTrue(bFinal.isEmpty)
        try ack(c,item:"new"); try transcript(c,item:"old",text:"still stale"); try transcript(c,item:"new",text:"B")
        XCTAssertTrue(bFinal.isEmpty)
        s.completeSend(success:true); try await pump.value
        XCTAssertEqual(bFinal,["B"]); XCTAssertEqual(c.state,.ready)
    }
    @MainActor func testHeldRecognitionEventAndByteLimitsFailClosed() async throws {
        for byteOverflow in [false,true] {
            let s = OpenVoiceSuspendedSocket(.beforeTransmission), c = try configure(s)
            var finals:[String] = [], errors = 0
            let r = OpenVoiceRecognition(client:c,callbacks:RecognitionCallbacks(partial:{_ in},error:{_ in errors += 1},done:{finals.append($0)}))
            r.start(); r.write(Data(repeating:0,count:640)); r.end()
            let pump = Task { try await c.flush() }; await s.waitForCommit()
            if byteOverflow {
                let text = String(repeating:"🐟",count:16000)
                try transcript(c,item:"unknown",text:text)
                XCTAssertThrowsError(try transcript(c,item:"unknown",text:text))
            } else {
                for _ in 0..<OpenVoiceClient.maxHeldRecognitionEvents { try transcript(c,item:"unknown",text:"stale") }
                XCTAssertThrowsError(try transcript(c,item:"unknown",text:"overflow"))
            }
            s.completeSend(success:true); _ = try? await pump.value
            XCTAssertEqual(finals,[""]); XCTAssertEqual(errors,1); XCTAssertEqual(c.state,.failed)
        }
    }
    @MainActor func testCommonSendGateRequiresExactReadinessOwnerAndFreshEpoch() async throws {
        let socket = OpenVoiceFakeSocket(), owner = UUID(), fence = OpenVoiceMediaFence(call:UUID(),media:"m")
        let c = try OpenVoiceClient(socket:socket,fence:fence,committedItemLimit:4096,mediaOwnerToken:owner)
        try emit(c,"session.created",["session":try OpenVoiceWire.createSession("s")])
        try c.enqueue(.object(["type":.string("session.update"),"session":.object(["type":.string("realtime")])]))
        try await c.flush(); XCTAssertEqual(socket.sent.count,1) // config before ready still works
        try emit(c,"session.updated",["session":try OpenVoiceWire.createSession("s")])
        c.setNativeActivated(true,fence:fence)
        try c.enqueue(.object(["type":.string("input_audio_buffer.append"),"audio":.string("AAA=")]))
        try await c.flush(); XCTAssertEqual(socket.sent.count,1); XCTAssertFalse(c.mediaReadyAccepted)
        XCTAssertThrowsError(try c.acceptMediaReady(owner:UUID(),fence:fence,sessionID:"s",epoch:c.readinessEpoch))
        XCTAssertThrowsError(try c.acceptMediaReady(owner:owner,fence:fence,sessionID:"other",epoch:c.readinessEpoch))
        let oldEpoch = c.readinessEpoch
        c.setNativeActivated(false,fence:fence); c.setNativeActivated(true,fence:fence)
        XCTAssertThrowsError(try c.acceptMediaReady(owner:owner,fence:fence,sessionID:"s",epoch:oldEpoch))
        try c.acceptMediaReady(owner:owner,fence:fence,sessionID:"s",epoch:c.readinessEpoch)
        try await c.flush(); XCTAssertEqual(socket.sent.count,2)
        try c.enqueue(.object(["type":.string("input_audio_buffer.append"),"audio":.string("AAA=")]))
        c.setNativeActivated(false,fence:fence); c.setNativeActivated(true,fence:fence)
        try await c.flush(); XCTAssertEqual(socket.sent.count,2); XCTAssertFalse(c.mediaReadyAccepted)
        c.close(); XCTAssertFalse(c.mediaReadyAccepted)
    }
}
