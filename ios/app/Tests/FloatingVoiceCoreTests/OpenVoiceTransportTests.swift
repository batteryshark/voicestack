import XCTest
@testable import FloatingVoiceCore

private typealias J = OpenVoiceJSON
private final class RecipientURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var replies: [(Int, Data?)] = []
    static var requests: [URLRequest] = []
    static var onRequest: (() -> Void)?
    static func reset(_ replies: [(Int, Data?)]) { lock.lock(); defer { lock.unlock() }; self.replies = replies; requests = []; onRequest = nil }
    static func observe(_ callback: @escaping () -> Void) { lock.lock(); defer { lock.unlock() }; onRequest = callback }
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating:0,count:4097)
            let count = stream.read(&bytes,maxLength:bytes.count)
            if count >= 0 { captured.httpBody = Data(bytes.prefix(count)) }
        }
        Self.lock.lock(); Self.requests.append(captured)
        let reply = Self.replies.isEmpty ? (500,Data()) : Self.replies.removeFirst(), notice = Self.onRequest; Self.lock.unlock(); notice?()
        guard let data = reply.1 else { return } // Explicitly pending until cancellation/watchdog.
        let response = HTTPURLResponse(url:request.url!,statusCode:reply.0,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class AdapterTask: OpenVoiceSocketTask {
    let lifecycle: OpenVoiceSocketLifecycle
    var cancelled = false, opens = true
    var autoSend = false
    var suspendAppends = false
    var suspendClear = false
    var sends: [String] = []
    var sendCompletion: ((Error?) -> Void)?
    var receiveCompletion: ((Result<Data,Error>) -> Void)?
    var sendEntry: CheckedContinuation<Void,Never>?, receiveEntry: CheckedContinuation<Void,Never>?
    var configurationEntry: CheckedContinuation<Void,Never>?
    var appendEntry: (Int,CheckedContinuation<Void,Never>)?
    var appends = 0
    var pings = 0, autoPong = true
    var pingCompletion: ((Error?) -> Void)?
    init(_ lifecycle: OpenVoiceSocketLifecycle) { self.lifecycle = lifecycle }
    func resume() { if opens { lifecycle.opened?() } }
    func send(_ text: String, completion: @escaping (Error?) -> Void) {
        sends.append(text)
        if (try? OpenVoiceWire.parse(Data(text.utf8)))?["type"] == .string("input_audio_buffer.append") {
            appends += 1
            if let (count,waiter) = appendEntry, appends >= count { appendEntry = nil; waiter.resume() }
        }
        if (try? OpenVoiceWire.parse(Data(text.utf8)))?["type"] == .string("session.update") { configurationEntry?.resume(); configurationEntry = nil }
        let kind = (try? OpenVoiceWire.parse(Data(text.utf8)))?["type"]
        if autoSend && kind != .string("input_audio_buffer.commit") && !(suspendAppends && kind == .string("input_audio_buffer.append")) && !(suspendClear && kind == .string("input_audio_buffer.clear")) { completion(nil); return }
        sendCompletion = completion; sendEntry?.resume(); sendEntry = nil
    }
    func receive(completion: @escaping (Result<Data,Error>) -> Void) { XCTAssertNil(receiveCompletion); receiveCompletion = completion; receiveEntry?.resume(); receiveEntry = nil }
    func ping(completion: @escaping (Error?) -> Void) {
        pings += 1; XCTAssertNil(pingCompletion)
        if autoPong { completion(nil) } else { pingCompletion = completion }
    }
    func waitSend() async { if !cancelled && sendCompletion == nil { await withCheckedContinuation { sendEntry = $0 } } }
    func waitReceive() async { if !cancelled && receiveCompletion == nil { await withCheckedContinuation { receiveEntry = $0 } } }
    func waitConfiguration() async {
        if !cancelled && !sends.contains(where:{ $0.contains("session.update") }) { await withCheckedContinuation { configurationEntry = $0 } }
    }
    func waitAppends(_ count: Int) async { if !cancelled && appends < count { await withCheckedContinuation { appendEntry = (count,$0) } } }
    func cancel() {
        cancelled = true; sendEntry?.resume(); sendEntry = nil; receiveEntry?.resume(); receiveEntry = nil; configurationEntry?.resume(); configurationEntry = nil
        appendEntry?.1.resume(); appendEntry = nil
        let pong = pingCompletion; pingCompletion = nil; pong?(OpenVoiceFailure("local_failure"))
    }
    func sent(_ error: Error? = nil) { let c = sendCompletion; sendCompletion = nil; c?(error) }
    func received(_ data: Data) { let c = receiveCompletion; receiveCompletion = nil; c?(.success(data)) }
}

final class OpenVoiceTransportTests: XCTestCase {
    private let origin = URL(string:"https://recipient-fixture.invalid")!
    private func fixture() throws -> J {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(J.self,from:Data(contentsOf:root.appendingPathComponent("bridge/fixtures/open-voice/control-vectors.json")))
    }
    private func change(_ j: J, _ fields: [String:J]) -> J { var o = j.object!; fields.forEach { o[$0] = $1 }; return .object(o) }
    @MainActor private func control(_ responses: [(Int,J?)], timeout: Double = 1) throws -> OpenVoiceRecipientControl {
        RecipientURLProtocol.reset(try responses.map { ($0.0,try $0.1?.encoded()) })
        let http = OpenVoiceControlHTTP(timeout:timeout) { $0.protocolClasses = [RecipientURLProtocol.self] }
        return try OpenVoiceRecipientControl(origin:origin,credential:OpenVoiceDeviceCredential(pairedDeviceBearer:"synthetic-device-only"),http:http,now:{ Date(timeIntervalSince1970:1792429200) })
    }
    @MainActor private func lease() throws -> OpenVoiceMediaLease {
        let f = try fixture(), o = f["owner_body"]
        let owner = OpenVoiceRecipientOwner(callID:UUID(uuidString:f["recipient_response"]["call_id"].string!)!,callUUID:UUID(uuidString:o["call_uuid"].string!)!,ownerEpoch:UUID(uuidString:o["owner_epoch"].string!)!,targetID:UUID(uuidString:o["target_id"].string!)!,bindingRevision:1)
        return OpenVoiceMediaLease(owner:owner,epoch:"1",expiresAt:Date(timeIntervalSince1970:1792429260),origin:origin,bearer:String(repeating:"a",count:43))
    }
    @MainActor private func socket(timeout: Double = 1, heartbeatInterval: Double = 5, pongDeadline: Double = 10) throws -> (OpenVoiceURLSessionSocket,AdapterTask) {
        var fake: AdapterTask!
        let s = try OpenVoiceURLSessionSocket(origin:origin,lease:lease(),now:Date(timeIntervalSince1970:1792429200),timeout:timeout,heartbeatInterval:heartbeatInterval,pongDeadline:pongDeadline) { request, config, lifecycle in
            XCTAssertEqual(request.url?.absoluteString,"wss://recipient-fixture.invalid/floating-voice/v1/realtime?model=local-chain-m1")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer " + String(repeating:"a",count:43))
            XCTAssertNil(request.value(forHTTPHeaderField:"Sec-WebSocket-Protocol"))
            XCTAssertNil(config.urlCredentialStorage); XCTAssertNil(config.httpCookieStorage); XCTAssertNil(config.urlCache)
            fake = AdapterTask(lifecycle); return fake
        }
        return (s,fake)
    }
    @MainActor func testRecipientLookupIsNotAutomaticAcceptAndActorShapesAreClosed() async throws {
        let f = try fixture(), c = try control([(200,f["recipient_response"])])
        defer { c.close() }
        let id = UUID(uuidString:f["recipient_response"]["call_id"].string!)!
        let invitation = try await c.invitation(callID:id)
        XCTAssertEqual(invitation.owner.json,f["owner_body"])
        let r = try XCTUnwrap(RecipientURLProtocol.captured().first)
        XCTAssertEqual(r.httpMethod,"GET"); XCTAssertNil(r.httpBody); XCTAssertEqual(RecipientURLProtocol.captured().count,1)
        XCTAssertEqual(r.value(forHTTPHeaderField:"Authorization"),"Bearer synthetic-device-only")
        XCTAssertTrue(c.attempts.isEmpty)
        c.close()
        for reply in [f["caller_response"],change(f["recipient_response"],["target_session":.string("not-credentials")])] {
            let bad = try control([(200,reply)]); do { _ = try await bad.invitation(callID:id); XCTFail() } catch {}; bad.close()
        }
    }
    @MainActor func testActualHTTPAdapterCapabilityAcceptMediaAndExpiry() async throws {
        let f = try fixture(), accepted = change(f["recipient_response"],["status":.string("accepted")])
        let cap: J = .object(["acknowledged":.bool(true),"expires_at":.number(1792429260000)])
        let c = try control([(200,cap),(200,f["recipient_response"]),(200,accepted),(200,f["media_response"])])
        defer { c.close() }
        _ = try await c.capability(enabled:true,build:"fixture-38",freshnessSeconds:60)
        let invitation = try await c.invitation(callID:UUID(uuidString:f["recipient_response"]["call_id"].string!)!)
        let a = try await c.accept(invitation), l = try await c.mediaLease(a)
        XCTAssertEqual(l.epoch,"1"); XCTAssertEqual(l.owner,a.owner)
        let requests = RecipientURLProtocol.captured(); XCTAssertEqual(requests.count,4)
        XCTAssertEqual(try OpenVoiceWire.parse(requests[0].httpBody!),change(f["capability"],["expires_in":.number(60)]))
        for r in requests.suffix(2) { XCTAssertEqual(try OpenVoiceWire.parse(r.httpBody!),f["owner_body"]) }
        XCTAssertFalse(requests.contains { $0.value(forHTTPHeaderField:"Authorization") == "Bearer " + String(repeating:"a",count:43) })
        XCTAssertEqual(c.attempts.count,3)
    }
    @MainActor func testWrongOwnerLeaseAndNumericEpochRefusedWithoutRetry() async throws {
        let f = try fixture(), accepted = change(f["recipient_response"],["status":.string("accepted")])
        let id = UUID(uuidString:f["recipient_response"]["call_id"].string!)!
        for changes: [String:J] in [["media_epoch":.number(1)],["media_epoch":.string("01")],["expires_at":.number(1792429199999)],["expires_at":.number(1792429260001)],["binding_revision":.number(2)],["model":.string("foreign")],["url":.string("wss://foreign.invalid")],["media_lease":.string("device-token")]] {
            let c = try control([(200,accepted),(200,change(f["media_response"],changes))]); let a = try await c.invitation(callID:id)
            do { _ = try await c.mediaLease(a); XCTFail() } catch {}
            XCTAssertEqual(RecipientURLProtocol.captured().count,2); XCTAssertEqual(c.attempts.last?.outcome,.uncertain); c.close()
        }
        let wrong = change(accepted,["owner_epoch":.string(UUID().uuidString.lowercased())])
        let c = try control([(200,f["recipient_response"]),(200,wrong)]); let i = try await c.invitation(callID:id)
        do { _ = try await c.accept(i); XCTFail() } catch {}; XCTAssertEqual(c.attempts.last?.outcome,.uncertain); c.close()
    }
    @MainActor func testHTTPRefusalTimeoutAndDeliberateEndNeverReposts() async throws {
        let f = try fixture(), id = UUID(uuidString:f["recipient_response"]["call_id"].string!)!
        let c = try control([(200,f["recipient_response"]),(200,nil)],timeout:0.03)
        let i = try await c.invitation(callID:id), op = UUID()
        do { _ = try await c.deliberateEnd(i.owner,operationID:op); XCTFail() } catch {}
        XCTAssertEqual(c.attempts.last?.outcome,.uncertain)
        do { _ = try await c.deliberateEnd(i.owner,operationID:op); XCTFail() } catch {}
        XCTAssertEqual(RecipientURLProtocol.captured().count,2)
        let body = try OpenVoiceWire.parse(RecipientURLProtocol.captured()[1].httpBody!)
        XCTAssertEqual(body["reason"],.string("deliberate-user")); XCTAssertNil(body.object?["text"]); c.close()
        let refused = try control([(403,.object(["error":.string("control_refused")]))])
        do { _ = try await refused.capability(enabled:true,build:"fixture-38"); XCTFail() } catch {}
        XCTAssertEqual(refused.attempts.last?.outcome,.refused); refused.close()
    }
    @MainActor func testProductionSocketHandoffCancellationTimeoutAndLargeFrame() async throws {
        let (s,t) = try socket(); try await s.open()
        let send = Task { try await s.send(text:"{}") }; await t.waitSend()
        XCTAssertEqual(s.writableBytes,2); t.sent(); try await send.value; XCTAssertEqual(s.writableBytes,0)
        let rx = Task { try await s.receive() }; await t.waitReceive(); t.received(Data(repeating:0,count:65537))
        do { _ = try await rx.value; XCTFail() } catch {}; XCTAssertTrue(t.cancelled)
        let (cancelled,ct) = try socket(); try await cancelled.open()
        let pending = Task { try await cancelled.send(text:"{}") }; await ct.waitSend(); pending.cancel()
        do { try await pending.value; XCTFail() } catch {}; ct.sent(); XCTAssertFalse(cancelled.isOpen)
        let (timed,tt) = try socket(timeout:0.03); try await timed.open()
        do { try await timed.send(text:"{}"); XCTFail() } catch {}; XCTAssertTrue(tt.cancelled)
    }
    @MainActor func testRedirectRejectedAndConsumedLeaseExpiryDoesNotCloseActiveSocket() async throws {
        let (s,t) = try socket(); try await s.open()
        // Lease clock only gates construction/NEW attachment. Open socket has no token-TTL timer.
        XCTAssertTrue(s.isOpen)
        let session = URLSession(configuration:.ephemeral); defer { session.invalidateAndCancel() }
        let task = session.dataTask(with:origin)
        let response = HTTPURLResponse(url:origin,statusCode:302,httpVersion:nil,headerFields:nil)!
        var forwarded = true
        t.lifecycle.urlSession(session,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:URL(string:"https://foreign.invalid")!)) { forwarded = $0 != nil }
        XCTAssertFalse(forwarded); XCTAssertFalse(s.isOpen); XCTAssertTrue(t.cancelled)
        XCTAssertThrowsError(try OpenVoiceURLSessionSocket(origin:origin,lease:lease(),now:Date(timeIntervalSince1970:1792429261),timeout:1) { _,_,l in AdapterTask(l) })
    }
    @MainActor private func deliver(_ task: AdapterTask, _ type: String, fields: [String:J]) async throws {
        await task.waitReceive()
        var body = fields; body["type"] = .string(type); body["event_id"] = .string(UUID().uuidString)
        task.received(try J.object(body).encoded())
        await task.waitReceive() // Exact synchronization with the next serialized RX operation.
    }
    @MainActor func testOwnerPumpReadinessAndProductionCommitReceiveReentrancy() async throws {
        for finishMode in ["success","failure","close"] {
            let f = try fixture(), accepted = change(f["recipient_response"],["status":.string("accepted")])
            let c = try control([(200,accepted),(200,f["media_response"]),(200,f["media_ready_response"])])
            let i = try await c.invitation(callID:UUID(uuidString:f["recipient_response"]["call_id"].string!)!), l = try await c.mediaLease(i)
            var task: AdapterTask!
            let socket = try OpenVoiceURLSessionSocket(origin:origin,lease:l,now:Date(timeIntervalSince1970:1792429200),timeout:2) { _,_,lifecycle in task = AdapterTask(lifecycle); task.autoSend = true; return task }
            let pump = try OpenVoiceMediaOwnerPump(socket:socket,lease:l,localCallEpoch:UUID())
            try await pump.start()
            do { try await pump.reportReadiness(using:c); XCTFail("no config/native activation") } catch {}
            try await deliver(task,"session.created",fields:["session":try OpenVoiceWire.createSession("sess_fixture")])
            await task.waitConfiguration()
            try await deliver(task,"session.updated",fields:["session":try OpenVoiceWire.createSession("sess_fixture")])
            XCTAssertEqual(pump.client.state,.configured)
            pump.nativeCaptureReady(true,fence:OpenVoiceMediaFence(call:UUID(),media:l.epoch)); XCTAssertEqual(pump.client.state,.configured)
            pump.nativeCaptureReady(true,fence:pump.fence); XCTAssertEqual(pump.client.state,.ready)
            var finals:[String] = [], errors = 0
            let done = expectation(description:"recognition finalized after actual adapter handoff or visible failure")
            let recognition = OpenVoiceRecognition(client:pump.client,callbacks:RecognitionCallbacks(partial:{_ in XCTFail()},error:{_ in errors += 1},done:{ finals.append($0); done.fulfill() }))
            recognition.start(); recognition.write(Data(repeating:0,count:640)); recognition.end(); pump.signalWrites()
            XCTAssertFalse(task.sends.contains { $0.contains("input_audio_buffer.append") })
            try await pump.reportReadiness(using:c)
            XCTAssertTrue(pump.reportedReady)
            let request = RecipientURLProtocol.captured().last!
            XCTAssertEqual(try OpenVoiceWire.parse(request.httpBody!),f["media_ready_body"])
            await task.waitSend() // Commit is held; session.update and append used the real adapter completion path.
            try await deliver(task,"input_audio_buffer.committed",fields:["item_id":.string("new_item"),"previous_item_id":.null])
            try await deliver(task,"conversation.item.input_audio_transcription.completed",fields:["item_id":.string("new_item"),"content_index":.number(0),"transcript":.string("received, not heard"),"usage":.object(["type":.string("duration"),"seconds":.number(0.02)])])
            XCTAssertTrue(finals.isEmpty); XCTAssertEqual(pump.client.renderedSamples,0)
            if finishMode == "close" { await pump.shutdown() }
            task.sent(finishMode == "failure" ? OpenVoiceFailure("local_failure") : nil)
            await fulfillment(of:[done],timeout:2)
            XCTAssertEqual(finals,finishMode == "success" ? ["received, not heard"] : [""]); XCTAssertEqual(errors,finishMode == "success" ? 0 : 1)
            await pump.shutdown(); c.close(); XCTAssertFalse(pump.running); XCTAssertTrue(task.cancelled)
            XCTAssertFalse(RecipientURLProtocol.captured().contains { $0.url!.path.contains("speech") || $0.url!.path.contains("prompt") })
        }
    }
    @MainActor func testExpiryGatesNewOpenNotConsumedAttachmentAuthority() async throws {
        var clock = Date(timeIntervalSince1970:1792429200), task: AdapterTask!
        let socket = try OpenVoiceURLSessionSocket(origin:origin,lease:lease(),now:clock,timeout:1,clock:{ clock }) { _,_,l in task = AdapterTask(l); return task }
        try await socket.open(); clock = Date(timeIntervalSince1970:1792429300)
        XCTAssertTrue(socket.isOpen); XCTAssertFalse(task.cancelled); socket.close()
        clock = Date(timeIntervalSince1970:1792429200)
        let unattached = try OpenVoiceURLSessionSocket(origin:origin,lease:lease(),now:clock,timeout:1,clock:{ clock }) { _,_,l in AdapterTask(l) }
        clock = Date(timeIntervalSince1970:1792429300)
        do { try await unattached.open(); XCTFail("expired token reused") } catch {}; unattached.close()
    }
    @MainActor func testHistoricalEndReadOnlyAndHTTPRedirectLargeResponse() async throws {
        let f = try fixture(), id = UUID(uuidString:f["recipient_response"]["call_id"].string!)!, op = UUID()
        let record: J = .object(["operation_id":.string(op.uuidString.lowercased()),"kind":.string("end"),"hash":.string(String(repeating:"b",count:64)),"state":.string("uncertain")])
        let c = try control([(200,f["recipient_response"]),(200,record)])
        let i = try await c.invitation(callID:id), result = try await c.operation(owner:i.owner,operationID:op)
        XCTAssertEqual(result,record); XCTAssertTrue(c.attempts.isEmpty)
        XCTAssertTrue(RecipientURLProtocol.captured().allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil }); c.close()
        for reply in [(302,Data("{}".utf8)),(200,Data(repeating:32,count:65537))] {
            RecipientURLProtocol.reset([reply])
            let http = OpenVoiceControlHTTP(timeout:1) { $0.protocolClasses = [RecipientURLProtocol.self] }
            let client = try OpenVoiceRecipientControl(origin:origin,credential:OpenVoiceDeviceCredential(pairedDeviceBearer:"synthetic-device"),http:http,now:Date.init)
            do { _ = try await client.invitation(callID:id); XCTFail() } catch {}
            XCTAssertEqual(RecipientURLProtocol.captured().count,1); client.close()
        }
    }
    @MainActor func testAlphabeticOperationUUIDUsesIdenticalCanonicalWireGETAndStrictDTOIdentity() async throws {
        let op = UUID(uuidString:"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let canonical = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let item = try OpenVoiceCanonicalItem(id:"reviewed",text:"One reviewed input")
        let event = item.responseEvent(operationID:op)
        _ = try OpenVoiceWire.client(event,context:.object(["canonicalItem":item.json]))
        XCTAssertEqual(event["response"]["metadata"]["operation_id"],.string(canonical))
        XCTAssertEqual(UUID(uuidString:event["response"]["metadata"]["operation_id"].string!),op)
        let record: J = .object(["operation_id":.string(canonical),"kind":.string("exchange"),
            "hash":.string(String(repeating:"a",count:64)),"state":.string("uncertain"),
            "response_id":.string("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),"planned_inbox_id":.string("msg_planned")])
        let c = try control([(200,record),(200,change(record,["operation_id":.string(op.uuidString)]))])
        defer { c.close() }
        let owner = try lease().owner
        let received = try await c.operation(owner:owner,operationID:op)
        XCTAssertEqual(received,record); XCTAssertEqual(UUID(uuidString:received["operation_id"].string!),op)
        let request = try XCTUnwrap(RecipientURLProtocol.captured().first)
        XCTAssertEqual(request.url?.lastPathComponent,event["response"]["metadata"]["operation_id"].string)
        XCTAssertEqual(request.httpMethod,"GET"); XCTAssertNil(request.httpBody)
        do { _ = try await c.operation(owner:owner,operationID:op); XCTFail("Uppercase DTO must remain refused, not normalized") } catch {}
        XCTAssertEqual(RecipientURLProtocol.captured().count,2); XCTAssertTrue(c.attempts.isEmpty)
    }
    @MainActor func testHistoricalAlphabeticIntent404StaysUncertainWithoutMigrationOrResubmission() async throws {
        // Isolated synthetic journal fixture only; no real/interop ledger is read or changed.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/fv-uuid-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("synthetic-intents.json"), owner = try lease().owner
        let op = UUID(uuidString:"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let item = try OpenVoiceCanonicalItem(id:"historical_reviewed",text:"Historical uncertain input")
        let history: J = .array([.object(["id":.string(op.uuidString),"callID":.string(owner.callID.uuidString),
            "callUUID":.string(owner.callUUID.uuidString),"ownerEpoch":.string(owner.ownerEpoch.uuidString),
            "targetID":.string(owner.targetID.uuidString),"bindingRevision":.number(Double(owner.bindingRevision)),
            "kind":.string("exchange"),"item":item.json,"state":.string("uncertain")])])
        try history.encoded().write(to:file)
        let journal = OpenVoiceOperationJournal(file:file)
        XCTAssertFalse(journal.failed); XCTAssertEqual(journal.records.first?.id,op)
        let before = try Data(contentsOf:file)
        let c = try control([(404,.object(["error":.string("control_refused")]))]); defer { c.close() }
        do { _ = try await journal.reconcile(op,using:c); XCTFail() } catch {}
        XCTAssertEqual(journal.records.first?.id,op); XCTAssertEqual(journal.records.first?.state,.uncertain)
        XCTAssertThrowsError(try journal.prepare(owner:owner,kind:.exchange,item:item.json))
        XCTAssertEqual(try Data(contentsOf:file),before)
        let requests = RecipientURLProtocol.captured()
        XCTAssertEqual(requests.count,1); XCTAssertEqual(requests.first?.httpMethod,"GET")
        XCTAssertEqual(requests.first?.url?.lastPathComponent,"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        XCTAssertNil(requests.first?.httpBody); XCTAssertTrue(c.attempts.isEmpty)
    }
    @MainActor func testHTTPCancelFencesOldTaskAndStillAllowsReadOnlyReconciliation() async throws {
        let op = UUID(), owner = try lease().owner
        let record: J = .object(["operation_id":.string(op.uuidString.lowercased()),"kind":.string("end"),"hash":.string(String(repeating:"b",count:64)),"state":.string("uncertain")])
        let c = try control([(200,nil),(200,record)])
        let entered = expectation(description:"HTTP request entered injected URLProtocol")
        RecipientURLProtocol.observe { entered.fulfill() }
        let pending = Task { try await c.capability(enabled:true,build:"fixture-38") }
        await fulfillment(of:[entered],timeout:1); RecipientURLProtocol.observe {}
        pending.cancel(); do { _ = try await pending.value; XCTFail() } catch {}
        XCTAssertEqual(c.attempts.last?.outcome,.uncertain)
        let reconciled = try await c.operation(owner:owner,operationID:op); XCTAssertEqual(reconciled,record)
        c.close()
        let failed = try control([(503,.object(["error":.string("control_refused")]))])
        do { _ = try await failed.capability(enabled:true,build:"fixture-38"); XCTFail() } catch {}
        XCTAssertEqual(failed.attempts.last?.outcome,.uncertain); failed.close()
    }
    @MainActor func testSocketHandshakeAndMissingPongWatchdogsAndMismatchedPumpOwner() async throws {
        var task: AdapterTask!
        let neverOpen = try OpenVoiceURLSessionSocket(origin:origin,lease:lease(),now:Date(timeIntervalSince1970:1792429200),timeout:0.03) { _,_,l in task = AdapterTask(l); task.opens = false; return task }
        do { try await neverOpen.open(); XCTFail() } catch {}; XCTAssertTrue(task.cancelled)
        let (s,t) = try socket(timeout:0.03,heartbeatInterval:0.01,pongDeadline:0.03); t.autoPong = false; try await s.open()
        do { _ = try await s.receive(); XCTFail() } catch {}; XCTAssertTrue(t.cancelled); XCTAssertEqual(t.pings,1)
        let (other,_) = try socket(), l = try lease()
        let replaced = OpenVoiceMediaLease(owner:l.owner,epoch:"2",expiresAt:l.expiresAt,origin:l.origin,bearer:l.bearer)
        XCTAssertThrowsError(try OpenVoiceMediaOwnerPump(socket:other,lease:replaced,localCallEpoch:UUID())); other.close()
    }
    @MainActor func testHealthyPongsPermitApplicationSilenceAndCannotCreateReadiness() async throws {
        let (socket,task) = try self.socket(timeout:0.02,heartbeatInterval:0.01,pongDeadline:0.03)
        let client = try OpenVoiceClient(socket:socket,fence:OpenVoiceMediaFence(call:UUID(),media:"1"))
        try await socket.open()
        let rx = Task { try await socket.receive() }; await task.waitReceive()
        // Deliberate bounded silence, not progress polling: exceeds the open/send deadline.
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertTrue(socket.isOpen); XCTAssertGreaterThanOrEqual(task.pings,2)
        XCTAssertEqual(client.state,.awaitingCreated); XCTAssertEqual(client.consumedSamples,0)
        XCTAssertEqual(client.renderedSamples,0); XCTAssertEqual(client.generatedSamples,0)
        socket.close()
        do { _ = try await rx.value; XCTFail() } catch {}
        XCTAssertTrue(task.cancelled)
    }
    @MainActor func testPumpCreditBackpressureAndCoalescedSignals() async throws {
        let f = try fixture(), accepted = change(f["recipient_response"],["status":.string("accepted")])
        let control = try self.control([(200,accepted),(200,f["media_response"]),(200,f["media_ready_response"])])
        let invitation = try await control.invitation(callID:UUID(uuidString:f["recipient_response"]["call_id"].string!)!), l = try await control.mediaLease(invitation)
        var task: AdapterTask!
        let socket = try OpenVoiceURLSessionSocket(origin:origin,lease:l,now:Date(timeIntervalSince1970:1792429200),timeout:2) { _,_,life in task = AdapterTask(life); task.autoSend = true; return task }
        let pump = try OpenVoiceMediaOwnerPump(socket:socket,lease:l,localCallEpoch:UUID()); try await pump.start()
        try await deliver(task,"session.created",fields:["session":try OpenVoiceWire.createSession("sess_fixture")]); await task.waitConfiguration()
        try await deliver(task,"session.updated",fields:["session":try OpenVoiceWire.createSession("sess_fixture")])
        pump.nativeCaptureReady(true,fence:pump.fence); try await pump.reportReadiness(using:control)
        let append: J = .object(["type":.string("input_audio_buffer.append"),"audio":.string(Data(repeating:0,count:4800).base64EncodedString())])
        for _ in 0..<20 { try pump.client.enqueue(append) }; pump.signalWrites(); await task.waitAppends(20)
        try pump.client.enqueue(append)
        for _ in 0..<1000 { pump.signalWrites() }
        // A real RX operation yields control to the writer without sleeps/polling.
        try await deliver(task,"vs.flow",fields:["media_epoch":.string("1"),"input_consumed_samples":.number(0)])
        XCTAssertEqual(task.appends,20); XCTAssertEqual(pump.client.sentSamples,48000)
        try await deliver(task,"vs.flow",fields:["media_epoch":.string("1"),"input_consumed_samples":.number(2400)])
        await task.waitAppends(21); XCTAssertEqual(pump.client.sentSamples,50400)
        XCTAssertEqual(pump.client.renderedSamples,0)
        await pump.shutdown(); control.close(); XCTAssertFalse(pump.running)
    }
    @MainActor private func configuredPump(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) async throws -> (OpenVoiceMediaOwnerPump,AdapterTask,OpenVoiceRecipientControl) {
        let f = try fixture(), accepted = change(f["recipient_response"],["status":.string("accepted")])
        let control = try self.control([(200,accepted),(200,f["media_response"]),(200,f["media_ready_response"])])
        let invitation = try await control.invitation(callID:UUID(uuidString:f["recipient_response"]["call_id"].string!)!), lease = try await control.mediaLease(invitation)
        var task: AdapterTask!
        let socket = try OpenVoiceURLSessionSocket(origin:origin,lease:lease,now:Date(timeIntervalSince1970:1792429200),timeout:2) { _,_,life in task = AdapterTask(life); task.autoSend = true; return task }
        let pump = try OpenVoiceMediaOwnerPump(socket:socket,lease:lease,localCallEpoch:UUID(),clock:clock)
        try await pump.start()
        try await deliver(task,"session.created",fields:["session":try OpenVoiceWire.createSession("sess_fixture")]); await task.waitConfiguration()
        try await deliver(task,"session.updated",fields:["session":try OpenVoiceWire.createSession("sess_fixture")])
        pump.nativeCaptureReady(true,fence:pump.fence)
        return (pump,task,control)
    }
    @MainActor func testBufferedRecognitionAndPumpShareReadinessGateAndSingleDelayedWriter() async throws {
        for loseReadiness in [false,true] {
            let (pump,task,control) = try await configuredPump()
            var errors = 0
            let recognition = OpenVoiceRecognition(client:pump.client,callbacks:RecognitionCallbacks(partial:{_ in XCTFail()},error:{_ in errors += 1},done:{_ in}))
            recognition.start()
            try await recognition.writeBuffered(Data(repeating:0,count:640))
            pump.signalWrites(); try await pump.client.flush() // public access cannot bypass readiness
            XCTAssertFalse(pump.reportedReady); XCTAssertEqual(task.appends,0); XCTAssertEqual(errors,0)
            task.suspendAppends = true
            try await pump.reportReadiness(using:control); await task.waitSend()
            XCTAssertEqual(task.appends,1)
            let entered = expectation(description:"buffered producer joins active pump send")
            let joining = Task { entered.fulfill(); try await recognition.writeBuffered(Data(repeating:0,count:640)) }
            await fulfillment(of:[entered],timeout:1)
            XCTAssertEqual(pump.client.admittedSamples,960); XCTAssertEqual(errors,0)
            if loseReadiness {
                pump.client.setNativeActivated(false,fence:pump.fence) // same gate even through public client
                XCTAssertFalse(pump.reportedReady)
            }
            task.suspendAppends = false; task.sent()
            try await joining.value
            XCTAssertEqual(task.appends,loseReadiness ? 1 : 2); XCTAssertEqual(errors,0)
            XCTAssertEqual(pump.client.state,loseReadiness ? .configured : .ready)
            if loseReadiness {
                pump.client.setNativeActivated(true,fence:pump.fence)
                try await pump.client.flush(); XCTAssertEqual(task.appends,1); XCTAssertFalse(pump.reportedReady)
            }
            await pump.shutdown(); control.close()
        }
    }
    @MainActor func testPostReceiveClockStartsFreshAudioStallAfterLongApplicationIdle() async throws {
        var now: TimeInterval = 0
        let (pump,task,control) = try await configuredPump(clock:{ now })
        try await pump.reportReadiness(using:control)
        let operation = UUID(), item = try OpenVoiceCanonicalItem(id:"reviewed",text:"Synthetic reviewed thought.")
        try pump.client.enqueue(item.createEvent); try pump.client.enqueue(item.responseEvent(operationID:operation)); pump.signalWrites()
        try await deliver(task,"response.created",fields:["response":.object(["id":.string("r"),"object":.string("realtime.response"),"status":.string("in_progress"),"status_details":.null,"output":.array([]),"metadata":.object(["operation_id":.string(operation.uuidString.lowercased())])])])
        try await deliver(task,"response.output_item.added",fields:["response_id":.string("r"),"output_index":.number(0),"item":.object(["id":.string("reply"),"object":.string("realtime.item"),"type":.string("message"),"role":.string("assistant"),"status":.string("in_progress"),"content":.array([])])])
        let co: [String:J] = ["response_id":.string("r"),"item_id":.string("reply"),"output_index":.number(0),"content_index":.number(0)]
        var part = co; part["part"] = .object(["type":.string("audio"),"transcript":.string("")])
        try await deliver(task,"response.content_part.added",fields:part)
        // The pump is now inside an actual adapter receive begun at time zero.
        now = 16
        var audio = co; audio["delta"] = .string(Data(repeating:0,count:960).base64EncodedString())
        try await deliver(task,"response.output_audio.delta",fields:audio)
        pump.client.tick(now:16.4,fence:pump.fence)
        XCTAssertEqual(pump.client.state,.ready); XCTAssertEqual(pump.client.generatedSamples,480)
        XCTAssertEqual(pump.client.renderedSamples,0)
        now = 30.9
        try await deliver(task,"vs.flow",fields:["media_epoch":.string("1"),"input_consumed_samples":.number(0)])
        pump.client.tick(now:30.9,fence:pump.fence); XCTAssertEqual(pump.client.state,.ready)
        now = 31
        pump.client.tick(now:now,fence:pump.fence); XCTAssertEqual(pump.client.state,.failed)
        await pump.shutdown(); control.close()
    }
    @MainActor func testBufferedFlushJoinerCancellationAndCloseRevokeReadiness() async throws {
        for cancelJoiner in [true,false] {
            let (pump,task,control) = try await configuredPump()
            try await pump.reportReadiness(using:control)
            var errors = 0, done = 0
            let recognition = OpenVoiceRecognition(client:pump.client,callbacks:RecognitionCallbacks(partial:{_ in XCTFail()},error:{_ in errors += 1},done:{_ in done += 1}))
            recognition.start(); task.suspendAppends = true
            recognition.write(Data(repeating:0,count:640)); pump.signalWrites(); await task.waitSend()
            let entered = expectation(description:"joining producer entered")
            let joining = Task { entered.fulfill(); try await recognition.writeBuffered(Data(repeating:0,count:640)) }
            await fulfillment(of:[entered],timeout:1)
            XCTAssertEqual(pump.client.admittedSamples,960)
            if cancelJoiner { joining.cancel() } else { await pump.shutdown() }
            do { try await joining.value; XCTFail("cancelled/closed joiner succeeded") } catch {}
            await pump.shutdown(); task.sent() // stale completion after the common writer was fenced
            XCTAssertFalse(pump.reportedReady); XCTAssertFalse(pump.client.mediaReadyAccepted)
            XCTAssertEqual(task.appends,1); XCTAssertEqual(errors,1); XCTAssertEqual(done,1)
            control.close()
        }
    }
    @MainActor private func candidateRig(readinessReplies: Int = 2, extra: [(Int,J?)] = []) async throws -> (OpenVoiceBackend,AdapterTask,OpenVoiceOperationJournal) {
        let f = try fixture(), accepted = change(f["recipient_response"],["status":.string("accepted")])
        let c = try control([(200,accepted),(200,f["media_response"])] + Array(repeating:(200,f["media_ready_response"]),count:readinessReplies) + extra)
        let invitation = try await c.invitation(callID:UUID(uuidString:accepted["call_id"].string!)!), lease = try await c.mediaLease(invitation)
        var task: AdapterTask!
        let socket = try OpenVoiceURLSessionSocket(origin:origin,lease:lease,now:Date(timeIntervalSince1970:1792429200),timeout:2) { _,_,life in task = AdapterTask(life); task.autoSend = true; return task }
        let pump = try OpenVoiceMediaOwnerPump(socket:socket,lease:lease,localCallEpoch:UUID())
        let journal = OpenVoiceOperationJournal(file:URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),save:{ _ in })
        let backend = try OpenVoiceBackend(pump:pump,invitation:invitation,control:c,journal:journal)
        try await backend.startMedia()
        try await deliver(task,"session.created",fields:["session":try OpenVoiceWire.createSession("sess_fixture")]); await task.waitConfiguration()
        try await deliver(task,"session.updated",fields:["session":try OpenVoiceWire.createSession("sess_fixture")])
        return (backend,task,journal)
    }
    @MainActor private func candidateController(_ backend: OpenVoiceBackend, input: AudioInput, synth: FakeSynth, output: AudioOutput) -> ConversationController {
        var voice = VoiceConfig(); voice.onsetGraceMs = 0; voice.pauseMs = 100
        let settings = LoadedSettings(app:AppSettings(),voice:voice,voiceFile:nil,appFile:"/nonexistent",chiefFile:"/nonexistent")
        return ConversationController(settings:settings,backend:backend,synth:synth,output:output,input:input,
            makeRecognition:{ OpenVoiceRecognition(client:backend.pump.client,callbacks:$0,discardUnsentOnCancel:true) },log:{ _ in })
    }
    @MainActor func testBackendCloseDiagnosticsRetainOwnerAndOriginalCallBank() async throws {
        let stages = StageDiagnostics.shared; stages.beginCall()
        let call = stages.playbackCallToken
        let (backend, _, _) = try await candidateRig()
        backend.controllerWillStop()
        backend.closeMedia(origin:.streamEnd)
        stages.beginCall()
        backend.closeMedia(origin:.owner); await backend.shutdown()
        let entries = try JSONDecoder().decode([DiagnosticEntry].self,from:Data(stages.export().utf8))
        let rows = entries.filter { $0.audio?.values["openVoiceMediaCloseOrigin"] != nil }
        XCTAssertEqual(rows.count,1)
        XCTAssertEqual(rows.first?.diagnosticCall,call)
        XCTAssertEqual(rows.first?.audio?.values["openVoiceMediaCloseOrigin"],3)
        XCTAssertEqual(rows.first?.audio?.values["openVoiceClientFailed"],0)
        XCTAssertEqual(rows.first?.audio?.values["openVoiceMediaEpoch"],1)
        XCTAssertEqual(rows.first?.category,.cancelled)
        XCTAssertTrue(backend.mediaClosed)
    }
    @MainActor func testCandidateControllerCaptureReadinessManualASRAndSoleCanonicalSend() async throws {
        let (backend,task,journal) = try await candidateRig()
        let input = FakeInput(), synth = FakeSynth(), output = FakeOutput(duration:0)
        input.captureGraphReady = false
        let controller = candidateController(backend,input:input,synth:synth,output:output)
        await controller.start()
        XCTAssertTrue(input.started); XCTAssertFalse(backend.ready)
        XCTAssertFalse(RecipientURLProtocol.captured().contains { $0.url!.path.hasSuffix("media-ready") })
        input.frames(30,voiced:true); XCTAssertEqual(task.appends,0)
        input.captureGraphReady = true
        let ready = await waitUntil { controller.status.phase == "ready" }; XCTAssertTrue(ready)
        XCTAssertEqual(controller.status.targetLabel,"New conversation"); XCTAssertTrue(controller.status.manualSend)
        XCTAssertTrue(synth.prepared.isEmpty)
        input.frames(30,voiced:true); input.frames(60,voiced:false)
        let commit = await waitUntil { task.sendCompletion != nil }; XCTAssertTrue(commit)
        try await deliver(task,"input_audio_buffer.committed",fields:["item_id":.string("heard_item"),"previous_item_id":.null])
        try await deliver(task,"conversation.item.input_audio_transcription.completed",fields:["item_id":.string("heard_item"),"content_index":.number(0),"transcript":.string("Exactly the reviewed words."),"usage":.object(["type":.string("duration"),"seconds":.number(1)])])
        task.sent()
        let held = await waitUntil { controller.status.holding == "Exactly the reviewed words." }; XCTAssertTrue(held)
        XCTAssertTrue(journal.records.isEmpty)
        XCTAssertFalse(task.sends.contains { $0.contains("response.create") })
        controller.send()
        let posted = await waitUntil { journal.records.count == 1 && task.sends.contains { $0.contains("response.create") } }; XCTAssertTrue(posted)
        let sent = try task.sends.map { try OpenVoiceWire.parse(Data($0.utf8)) }
        let response = try XCTUnwrap(sent.first { $0["type"] == .string("response.create") })
        XCTAssertEqual(response["response"]["input"],.array([try XCTUnwrap(journal.records.first?.item)]))
        XCTAssertEqual(response["response"]["metadata"]["operation_id"],.string(journal.records[0].id.uuidString.lowercased()))
        XCTAssertFalse(String(data:try response.encoded(),encoding:.utf8)!.contains("[voice]"))
        controller.handle(ServerEvent(type:"session.text.ended",data:["sessionID":backend.target.sessionID,"text":"Never synthesize received text."]))
        XCTAssertTrue(synth.prepared.isEmpty)
        controller.stop(discardUnfinished:true); await backend.shutdown()
        XCTAssertFalse(backend.ready)
    }
    @MainActor func testCandidateCaptureRepairRequiresNewKnownAckAndNeverReplaysResponse() async throws {
        let (backend,task,_) = try await candidateRig()
        let input = FakeInput(), synth = FakeSynth(), controller = candidateController(backend,input:input,synth:synth,output:FakeOutput(duration:0))
        await controller.start()
        var ready = await waitUntil { controller.status.phase == "ready" }; XCTAssertTrue(ready)
        input.captureGraphReady = false
        XCTAssertFalse(backend.ready); XCTAssertEqual(controller.status.phase,"starting")
        input.frames(30,voiced:true); XCTAssertEqual(task.appends,0)
        input.captureGraphReady = true
        ready = await waitUntil { controller.status.phase == "ready" }; XCTAssertTrue(ready)
        XCTAssertEqual(RecipientURLProtocol.captured().filter { $0.url!.path.hasSuffix("media-ready") }.count,2)
        XCTAssertFalse(task.sends.contains { $0.contains("response.create") })
        controller.stop(discardUnfinished:true); await backend.shutdown()
    }
    @MainActor func testCandidateDiscardWaitsForClearHandoffAndAckBeforeNextSegment() async throws {
        let (pump,task,c) = try await configuredPump(); try await pump.reportReadiness(using:c)
        var errors = 0, finals: [String] = []
        let callbacks = RecognitionCallbacks(partial:{ _ in },error:{ _ in errors += 1 },done:{ finals.append($0) })
        let a = OpenVoiceRecognition(client:pump.client,callbacks:callbacks,discardUnsentOnCancel:true)
        a.start(); task.suspendAppends = true
        a.write(Data(count:640)); pump.signalWrites(); await task.waitSend()
        a.cancel()
        task.suspendClear = true
        let b = OpenVoiceRecognition(client:pump.client,callbacks:callbacks,discardUnsentOnCancel:true)
        b.start(); b.write(Data(count:640))
        XCTAssertTrue(b.isWarming); XCTAssertEqual(task.appends,1)
        task.suspendAppends = false; task.sent()
        let clearing = await waitUntil { task.sends.contains { $0.contains("input_audio_buffer.clear") } }; XCTAssertTrue(clearing)
        XCTAssertEqual(task.appends,1); XCTAssertTrue(b.isWarming)
        try await deliver(task,"input_audio_buffer.cleared",fields:[:])
        XCTAssertTrue(b.isWarming); XCTAssertEqual(task.appends,1) // ACK raced exposed send completion.
        task.suspendClear = false; task.sent()
        let appended = await waitUntil { task.appends == 2 }; XCTAssertTrue(appended)
        XCTAssertFalse(b.isWarming); XCTAssertEqual(errors,0); XCTAssertEqual(finals,[""])
        XCTAssertEqual(pump.client.sentSamples,960)
        b.cancel(); await pump.shutdown(); c.close()
    }
    @MainActor func testCandidatePreparedAudioHasNoSynthAndDequeueIsNotHeard() async throws {
        let (backend,task,journal) = try await candidateRig()
        let input = FakeInput(), synth = FakeSynth(), output = CandidateRenderedOutput()
        let controller = candidateController(backend,input:input,synth:synth,output:output)
        await controller.start()
        let ready = await waitUntil { controller.status.phase == "ready" }; XCTAssertTrue(ready)
        try await backend.submitReviewedText("Single input")
        let metadata: J = .object(["operation_id":.string(journal.records[0].id.uuidString.lowercased())])
        try await deliver(task,"response.created",fields:["response":.object(["id":.string("r"),"object":.string("realtime.response"),"status":.string("in_progress"),"status_details":.null,"output":.array([]),"metadata":metadata])])
        try await deliver(task,"response.output_item.added",fields:["response_id":.string("r"),"output_index":.number(0),"item":.object(["id":.string("reply"),"object":.string("realtime.item"),"type":.string("message"),"role":.string("assistant"),"status":.string("in_progress"),"content":.array([])])])
        let co: [String:J] = ["response_id":.string("r"),"item_id":.string("reply"),"output_index":.number(0),"content_index":.number(0)]
        var part = co; part["part"] = .object(["type":.string("audio"),"transcript":.string("")])
        try await deliver(task,"response.content_part.added",fields:part)
        var audio = co; audio["delta"] = .string(Data(count:960).base64EncodedString())
        try await deliver(task,"response.output_audio.delta",fields:audio)
        let consumed = await waitUntil { output.consumed == 480 }; XCTAssertTrue(consumed)
        XCTAssertTrue(synth.prepared.isEmpty); XCTAssertEqual(backend.pump.client.renderedSamples,0)
        output.report(240,.playing)
        XCTAssertEqual(backend.pump.client.renderedSamples,240)
        controller.bargeIn()
        XCTAssertEqual(backend.pump.client.renderedSamples,240)
        let cancelled = await waitUntil { task.sends.contains { $0.contains("response.cancel") } }; XCTAssertTrue(cancelled)
        XCTAssertFalse(RecipientURLProtocol.captured().contains { $0.url!.path.contains("interrupt") || $0.url!.path.contains("speech") })
        XCTAssertEqual(journal.records.count,1)
        controller.stop(discardUnfinished:true); await backend.shutdown()
    }
    @MainActor func testCandidateEndIsDurableBoundOnceAndNeverLegacyAdmission() async throws {
        let (backend,task,journal) = try await candidateRig(readinessReplies:0,extra:[(500,.object([:]))])
        await backend.shutdown(closeControl:false)
        XCTAssertTrue(journal.records.isEmpty) // transport closure alone is NOT an End intent.
        do { try await backend.deliberateEnd(); XCTFail() } catch {}
        let record = try XCTUnwrap(journal.records.first)
        XCTAssertEqual(record.kind,.deliberateEnd); XCTAssertEqual(record.state,.uncertain)
        let end = try XCTUnwrap(RecipientURLProtocol.captured().first { $0.url!.path.hasSuffix("/end") })
        let body = try OpenVoiceWire.parse(XCTUnwrap(end.httpBody))
        XCTAssertEqual(body["operation_id"],.string(record.id.uuidString.lowercased()))
        XCTAssertEqual(body["call_uuid"],.string(backend.invitation.owner.callUUID.uuidString.lowercased()))
        do { try await backend.deliberateEnd(); XCTFail() } catch {}
        XCTAssertEqual(RecipientURLProtocol.captured().filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/end") }.count,1)
        XCTAssertFalse(task.sends.contains { $0.contains("conversation.item.create") || $0.contains("response.create") })
        await backend.shutdown()
    }
    @MainActor func testCandidateFinalReceivedIsVisibleThroughActualControllerSpeakerAndLogWithoutHeardCredit() async throws {
        for mode in ["completed","cancelled","abandoned","held"] {
            let (backend,task,journal) = try await candidateRig()
            let input = FakeInput(), synth = FakeSynth(), output = CandidateRenderedOutput(), surface = VoiceSurface()
            let controller = candidateController(backend,input:input,synth:synth,output:output)
            let binding = surface.replaceBinding(target:backend.target)
            var captions: [CaptionEvent] = []
            controller.onStatus = { surface.update(status:$0,owner:binding) }
            controller.onCaption = { captions.append($0); surface.handle($0,owner:binding) }
            await controller.start()
            let ready = await waitUntil { controller.status.phase == "ready" }; XCTAssertTrue(ready)
            try await backend.submitReviewedText("Single input")
            let metadata: J = .object(["operation_id":.string(journal.records[0].id.uuidString.lowercased())])
            let assistant: J = .object(["id":.string("reply"),"object":.string("realtime.item"),"type":.string("message"),"role":.string("assistant"),"status":.string("in_progress"),"content":.array([])])
            try await deliver(task,"response.created",fields:["response":.object(["id":.string("r"),"object":.string("realtime.response"),"status":.string("in_progress"),"status_details":.null,"output":.array([]),"metadata":metadata])])
            try await deliver(task,"response.output_item.added",fields:["response_id":.string("r"),"output_index":.number(0),"item":assistant])
            let co: [String:J] = ["response_id":.string("r"),"item_id":.string("reply"),"output_index":.number(0),"content_index":.number(0)]
            var part = co; part["part"] = .object(["type":.string("audio"),"transcript":.string("")])
            try await deliver(task,"response.content_part.added",fields:part)
            var audio = co; audio["delta"] = .string(Data(count:960).base64EncodedString())
            try await deliver(task,"response.output_audio.delta",fields:audio)
            let consumed = await waitUntil { output.consumed == 480 }; XCTAssertTrue(consumed)
            XCTAssertTrue(surface.log.turns.filter { $0.role == .chief }.isEmpty)
            XCTAssertEqual(backend.pump.client.renderedSamples,0)
            let oldProgress = output.progress
            if mode == "cancelled" { output.report(240,.playing); controller.bargeIn() }
            if mode == "abandoned" { controller.setOutputMuted(true) }
            if mode == "held" {
                controller.pauseForCall()
                XCTAssertNil(controller.currentLease); XCTAssertFalse(input.started)
                XCTAssertFalse(controller.status.running); XCTAssertFalse(backend.ready)
                XCTAssertTrue(backend.pump.running)
            }
            let beforeFinal = backend.pump.client.renderedSamples
            let final = "Verified full final reply, even if not all audio was heard."
            try await deliver(task,"response.output_audio.done",fields:co)
            var transcript = co; transcript["transcript"] = .string(final)
            try await deliver(task,"response.output_audio_transcript.done",fields:transcript)
            XCTAssertEqual(surface.log.turns.filter { $0.role == .chief }.map(\.spoken),[final])
            XCTAssertEqual(backend.pump.client.renderedSamples,beforeFinal) // final text grants ZERO credit
            XCTAssertTrue(captions.contains(.chiefFinalReceived(label:"reply",text:final)))
            XCTAssertFalse(captions.contains(.chiefStarted(label:"reply",text:final)))
            XCTAssertFalse(captions.contains(.chiefEnded(label:"reply",text:final,outcome:"played")))
            part["part"] = .object(["type":.string("audio"),"transcript":.string(final)])
            try await deliver(task,"response.content_part.done",fields:part)
            let complete = change(assistant,["status":.string("completed"),"content":.array([.object(["type":.string("output_audio"),"transcript":.string(final)])])])
            try await deliver(task,"response.output_item.done",fields:["response_id":.string("r"),"output_index":.number(0),"item":complete])
            let status = mode == "completed" || mode == "held" ? "completed" : "cancelled"
            let details: J = status == "completed" ? .null : .object(["type":.string("cancelled"),"reason":.string("client_cancelled")])
            try await deliver(task,"response.done",fields:["response":.object(["id":.string("r"),"object":.string("realtime.response"),"status":.string(status),"status_details":details,"output":.array([complete]),"metadata":metadata])])
            let finished = await waitUntil { !controller.speaker.active }; XCTAssertTrue(finished)
            XCTAssertEqual(surface.log.turns.filter { $0.role == .chief }.map(\.spoken),[final])
            if mode == "completed" { output.report(480,.completed) }
            else { oldProgress?(PlaybackSourceProgress(renderedSamples:480,state:.completed)) }
            XCTAssertEqual(backend.pump.client.renderedSamples,mode == "completed" ? 480 : mode == "cancelled" ? 240 : 0)
            XCTAssertTrue(synth.prepared.isEmpty)
            let immutableFinal = backend.onFinalProjection
            immutableFinal?("reply",final)
            immutableFinal?("reply","Changed text for the same item")
            immutableFinal?("other","Wrong final coordinates")
            XCTAssertEqual(captions.filter { if case .chiefFinalReceived = $0 { return true }; return false }.count,1)
            XCTAssertEqual(surface.log.turns.filter { $0.role == .chief }.map(\.spoken),[final])
            if mode == "held" {
                XCTAssertNil(controller.currentLease); XCTAssertFalse(input.started)
                XCTAssertFalse(controller.status.running); XCTAssertFalse(backend.ready)
                XCTAssertEqual(input.starts,1)
                XCTAssertEqual(RecipientURLProtocol.captured().filter { $0.url!.path.hasSuffix("media-ready") }.count,1)
            }
            // A cleared/replaced surface rejects the old owner; stopping the old
            // Controller also fences a captured delayed backend final callback.
            let delayed = backend.onFinalProjection
            let next = surface.replaceBinding(target:TargetLease(sessionID:"next",generation:"new"))
            surface.handle(.youFinal("Next turn"),owner:next)
            delayed?("reply","Stale final must not overwrite")
            XCTAssertTrue(surface.log.turns.filter { $0.role == .chief }.isEmpty)
            controller.stop(discardUnfinished:true)
            delayed?("other","Stopped owner must not display")
            XCTAssertTrue(surface.log.turns.filter { $0.role == .chief }.isEmpty)
            await backend.shutdown()
        }
    }
    @MainActor private func candidatePush(_ backend: OpenVoiceBackend, id: UUID? = nil) -> PushInvitation {
        let expiry = Date().addingTimeInterval(60).timeIntervalSince1970 * 1000
        return PushInvitation(payload:["reachoutID":"candidate_fixture","callUUID":(id ?? backend.invitation.owner.callUUID).uuidString,"expiry":expiry,"ringDeadline":expiry])
    }
    @MainActor func testCandidateLocalOptoutSynchronouslyStopsProducerAndEndsOnlyItsBoundCallWithoutEndIntent() async throws {
        let (backend,task,journal) = try await candidateRig()
        let input = FakeInput(), output = FakeOutput(duration:0), synth = FakeSynth()
        let controller = candidateController(backend,input:input,synth:synth,output:output)
        var providers: [FakeCallProvider] = []
        let calls = CallCoordinator(makeProvider:{ _ in let p = FakeCallProvider(); providers.append(p); return p })
        let push = candidatePush(backend)
        var owner: IncomingCallOwner?, deliberate = 0, ends = 0
        var teardown: Task<Void,Never>?
        var receipts: [CallReceipt] = []
        calls.onDeliberateEnd = { _ in deliberate += 1 }
        calls.detailedReceipt = { _,receipt in receipts.append(receipt) }
        calls.resolveIncoming = { invitation in
            let resolved = try IncomingCallOwner(lifecycle:calls.lifecycle,invitation:invitation)
            try calls.registerCandidateAuthority(backend,owner:resolved); owner = resolved
            return backend.target
        }
        calls.beginMedia = { _ in
            await controller.start()
            return await waitUntil { controller.status.phase == "ready" }
        }
        calls.endMedia = { ends += 1; teardown = Task { await backend.shutdown() } }
        calls.receivePush(push,allowed:true,completion:{})
        let provider = try XCTUnwrap(providers.first)
        provider.emit(.answer(push.id,{ XCTAssertTrue($0) }))
        var reached = await waitUntil { calls.lifecycle.state == .connecting }; XCTAssertTrue(reached)
        provider.emit(.activated)
        reached = await waitUntil { calls.lifecycle.state == .active }; XCTAssertTrue(reached)
        XCTAssertTrue(calls.hasEverBeenMediaReady); XCTAssertTrue(input.started); XCTAssertTrue(controller.status.running)
        let captured = try XCTUnwrap(owner)
        try await backend.submitReviewedText("Existing harness work is not cancelled by local optout")
        // Reentrant stop/status callbacks cannot recurse into a second finish.
        controller.onStatus = { status in if !status.running { XCTAssertFalse(calls.revokeCandidateAuthority(backend,owner:captured)) } }
        XCTAssertTrue(calls.revokeCandidateAuthority(backend,owner:captured))
        XCTAssertFalse(input.started); XCTAssertGreaterThan(input.stops,0)
        XCTAssertFalse(controller.status.running); XCTAssertFalse(backend.ready); XCTAssertFalse(backend.pump.running)
        XCTAssertEqual(calls.lifecycle.state,.ended); XCTAssertEqual(provider.endedCount,1); XCTAssertEqual(ends,1)
        XCTAssertEqual(deliberate,0); XCTAssertEqual(journal.records.map(\.kind),[.exchange])
        XCTAssertEqual(receipts.last?.endReason,.policyRestricted)
        let stops = input.stops
        XCTAssertFalse(calls.revokeCandidateAuthority(backend,owner:captured)); backend.closeMedia()
        await teardown?.value
        XCTAssertNotNil(teardown); XCTAssertTrue(task.cancelled)
        XCTAssertEqual(input.stops,stops)
        XCTAssertFalse(RecipientURLProtocol.captured().contains { $0.url!.path.hasSuffix("/end") || $0.url!.path.contains("interrupt") })
        XCTAssertFalse(task.sends.contains { $0.contains("response.cancel") || $0.contains("voice ended") })
        provider.emit(.deactivated)
        let replacement = Rig()
        calls.beginMedia = { _ in await replacement.start(); return replacement.controller.status.phase == "ready" }
        calls.endMedia = { replacement.controller.stop(discardUnfinished:true) }
        calls.start(target:TargetLease(sessionID:"ses_A",generation:"initial"))
        let next = try XCTUnwrap(providers.last); next.performStart(); next.emit(.activated)
        reached = await waitUntil { calls.lifecycle.state == .active }; XCTAssertTrue(reached)
        XCTAssertTrue(replacement.input.started)
        XCTAssertFalse(calls.revokeCandidateAuthority(backend,owner:captured))
        XCTAssertTrue(replacement.input.started); XCTAssertTrue(replacement.controller.status.running)
        next.emit(.reset)
        controller.onStatus = nil; calls.resolveIncoming = nil; calls.beginMedia = nil; calls.endMedia = nil
    }
    @MainActor func testCandidateRevocationRejectsLegacyNilTargetStaleEpochUUIDAndWrongTargetButAllowsRegisteredPrebind() async throws {
        for scenario in ["unregistered","staleEpoch","wrongUUID","wrongTarget","validPrebind"] {
            let (backend,_,journal) = try await candidateRig()
            let provider = FakeCallProvider(), calls = CallCoordinator(makeProvider:{ _ in provider })
            let push = candidatePush(backend)
            calls.receivePush(push,allowed:true,completion:{})
            let owner = try IncomingCallOwner(lifecycle:calls.lifecycle,invitation:push)
            if scenario != "unregistered" { try calls.registerCandidateAuthority(backend,owner:owner) }
            var supplied = owner
            if scenario == "staleEpoch" {
                let stale = CallLifecycle(); let first = stale.incoming(id:push.id)!
                stale.end(first); stale.incoming(id:push.id)
                supplied = try IncomingCallOwner(lifecycle:stale,invitation:push)
            }
            if scenario == "wrongUUID" {
                let wrong = candidatePush(backend,id:UUID()), other = CallLifecycle()
                other.incoming(id:wrong.id)
                supplied = try IncomingCallOwner(lifecycle:other,invitation:wrong)
            }
            if scenario == "wrongTarget" {
                XCTAssertTrue(calls.lifecycle.bindIncoming(TargetLease(sessionID:"ses_wrong",generation:"wrong"),owner:owner.epoch))
            }
            let revoked = calls.revokeCandidateAuthority(backend,owner:supplied)
            XCTAssertEqual(revoked,scenario == "validPrebind")
            XCTAssertEqual(provider.endedCount,scenario == "validPrebind" ? 1 : 0)
            XCTAssertEqual(backend.pump.running,scenario != "validPrebind")
            XCTAssertTrue(journal.records.isEmpty)
            if scenario != "validPrebind" { provider.emit(.reset) }
            await backend.shutdown()
        }
    }
    @MainActor func testCandidateBackendClosureAndTerminalStreamLossStopCaptureNotOnlyPCMAdmission() async throws {
        for loss in ["close","socketFailure","terminalStream"] {
            let (backend,_,journal) = try await candidateRig()
            let input = FakeInput(), output = FakeOutput(duration:0)
            let controller = candidateController(backend,input:input,synth:FakeSynth(),output:output)
            await controller.start()
            let ready = await waitUntil { controller.status.phase == "ready" }; XCTAssertTrue(ready)
            XCTAssertTrue(input.started)
            switch loss {
            case "close": backend.closeMedia()
            case "socketFailure": backend.pump.client.socketClosed(fence:backend.pump.fence)
            default: controller.dropConnection(holdOff:0)
            }
            let stopped = await waitUntil { !input.started && !controller.status.running }; XCTAssertTrue(stopped)
            XCTAssertFalse(backend.ready); XCTAssertFalse(backend.pump.running)
            XCTAssertGreaterThan(input.stops,0); XCTAssertGreaterThan(output.stops,0)
            let starts = input.starts, stops = input.stops
            backend.closeMedia(); await controller.start()
            XCTAssertEqual(input.starts,starts); XCTAssertEqual(input.stops,stops)
            XCTAssertFalse(input.started); XCTAssertTrue(journal.records.isEmpty)
            await backend.shutdown()
        }
    }
    @MainActor func testTerminalTransportFailureNotifiesCurrentCoordinatorButCannotPauseReplacement() async throws {
        try await terminalCandidateFailure(inputFault:false)
        try await terminalCandidateFailure(inputFault:true)
    }
    @MainActor private func terminalCandidateFailure(inputFault: Bool) async throws {
        let (backend, task, journal) = try await candidateRig()
        let input = FakeInput(), controller = candidateController(backend,input:input,synth:FakeSynth(),output:FakeOutput(duration:0))
        var providers: [FakeCallProvider] = []
        let calls = CallCoordinator(makeProvider:{ _ in let p = FakeCallProvider(); providers.append(p); return p })
        let push = candidatePush(backend)
        var ownerEpoch = -1, reports = 0, deliberate = 0, pauses: [CallEndCause] = [], notices: [String] = []
        calls.onDeliberateEnd = { _ in deliberate += 1 }
        calls.recoveryPaused = { pauses.append($0) }
        calls.failed = { notices.append($0) }
        calls.resolveIncoming = { invitation in
            let owner = try IncomingCallOwner(lifecycle:calls.lifecycle,invitation:invitation)
            try calls.registerCandidateAuthority(backend,owner:owner); ownerEpoch = owner.epoch
            return backend.target
        }
        calls.beginMedia = { _ in
            await controller.start()
            return await waitUntil { controller.status.phase == "ready" }
        }
        calls.pauseMedia = { controller.pauseForCall() }
        calls.endMedia = { controller.stop(discardUnfinished:true) }
        controller.onCandidateTerminalFailure = { cause in
            if calls.candidateBackendFailed(backend,ownerEpoch:ownerEpoch,cause:cause) { reports += 1 }
        }
        controller.onCandidateInputFailure = { failure in
            if calls.candidateInputFailed(backend,ownerEpoch:ownerEpoch,failure:failure) { reports += 1 }
        }
        calls.receivePush(push,allowed:true,completion:{})
        let provider = try XCTUnwrap(providers.first)
        provider.emit(.answer(push.id,{ XCTAssertTrue($0) }))
        var reached = await waitUntil { calls.lifecycle.state == .connecting }; XCTAssertTrue(reached)
        provider.emit(.activated)
        reached = await waitUntil { calls.lifecycle.state == .active }; XCTAssertTrue(reached)
        let staleCallback = try XCTUnwrap(controller.onCandidateTerminalFailure)
        let staleInputCallback = try XCTUnwrap(controller.onCandidateInputFailure)
        XCTAssertFalse(calls.candidateBackendFailed(backend,ownerEpoch:ownerEpoch,cause:.backendFailure)) // Live backend is not fatal proof.
        XCTAssertFalse(calls.candidateInputFailed(backend,ownerEpoch:ownerEpoch,failure:.deliveryStalled)) // A typed argument alone is not proof.
        if inputFault {
            controller.stop(discardUnfinished:true)
            backend.closeForInputFailure(.deliveryStalled) // Existing watchdog detection is independently covered at 2232455.
            staleInputCallback(.deliveryStalled)
        } else { backend.pump.client.socketClosed(fence:backend.pump.fence) }
        reached = await waitUntil { calls.lifecycle.state == .ended }; XCTAssertTrue(reached)
        XCTAssertFalse(input.started); XCTAssertNil(input.onPCM); XCTAssertFalse(controller.status.running)
        XCTAssertGreaterThan(input.stops,0) // Actual onMediaClosed capture hook was preserved.
        XCTAssertEqual(backend.mediaCloseOrigin,inputFault ? .controllerStop : .clientFailure)
        XCTAssertEqual(reports,1); XCTAssertTrue(pauses.isEmpty)
        XCTAssertFalse(calls.hasCall); XCTAssertEqual(provider.endedCount,1)
        XCTAssertEqual(notices.count,1); XCTAssertEqual(deliberate,0)
        backend.closeMedia(); XCTAssertEqual(reports,1)
        XCTAssertEqual(deliberate,0); XCTAssertTrue(journal.records.isEmpty)
        XCTAssertFalse(task.sends.contains { $0.contains("response.cancel") || $0.contains("response.create") })
        XCTAssertFalse(RecipientURLProtocol.captured().contains { $0.url!.path.hasSuffix("/end") || $0.url!.path.contains("interrupt") })
        provider.emit(.reset); provider.emit(.deactivated)
        let replacement = Rig()
        calls.beginMedia = { _ in await replacement.start(); return replacement.controller.status.phase == "ready" }
        calls.pauseMedia = { replacement.controller.pauseForCall() }
        calls.endMedia = { replacement.controller.stop(discardUnfinished:true) }
        calls.start(target:TargetLease(sessionID:"ses_A",generation:"initial"))
        let next = try XCTUnwrap(providers.last); next.performStart(); next.emit(.activated)
        reached = await waitUntil { calls.lifecycle.state == .active }; XCTAssertTrue(reached)
        staleCallback(.backendFailure)
        staleInputCallback(.deliveryStalled)
        XCTAssertEqual(reports,1); XCTAssertFalse(calls.mediaIsPaused)
        XCTAssertTrue(replacement.input.started); XCTAssertTrue(replacement.controller.status.running)
        next.emit(.reset); next.emit(.deactivated)
        await backend.shutdown()
        calls.resolveIncoming = nil; calls.beginMedia = nil; calls.pauseMedia = nil; calls.endMedia = nil
        controller.onCandidateTerminalFailure = nil
        controller.onCandidateInputFailure = nil
    }
    @MainActor func testCandidateRevocationAlsoFencesLateInputStartCompletion() async throws {
        let (backend,_,_) = try await candidateRig(), input = CandidateDelayedInput()
        let controller = candidateController(backend,input:input,synth:FakeSynth(),output:FakeOutput(duration:0))
        let starting = Task { await controller.start() }
        let entered = await waitUntil { input.waiter != nil }; XCTAssertTrue(entered)
        backend.closeMedia()
        XCTAssertFalse(controller.status.running)
        input.release(); await starting.value
        XCTAssertFalse(input.started); XCTAssertGreaterThan(input.stops,0)
        XCTAssertFalse(backend.ready); XCTAssertFalse(backend.pump.running)
        await backend.shutdown()
    }
    @MainActor func testLegacyActivePolicyRestrictionStillPausesWithoutCandidateTerminalPrivilege() async {
        let rig = CallCoordinatorRig(), provider = await rig.active()
        rig.calls.restrictPolicy()
        XCTAssertTrue(rig.calls.hasCall); XCTAssertTrue(rig.calls.mediaIsPaused)
        XCTAssertEqual(provider.endedCount,0); XCTAssertEqual(provider.invalidations,0); XCTAssertEqual(rig.ends,0)
        provider.emit(.reset)
    }
    @MainActor func testFirstLateWireFinalCannotOverwriteStoppedOwnerOrReplacementCallDisplay() async throws {
        for stopped in [true,false] {
            let (backend,task,journal) = try await candidateRig()
            let input = FakeInput(), surface = VoiceSurface(), synth = FakeSynth()
            let controller = candidateController(backend,input:input,synth:synth,output:CandidateRenderedOutput())
            let binding = surface.replaceBinding(target:backend.target)
            var finals = 0
            controller.onStatus = { surface.update(status:$0,owner:binding) }
            controller.onCaption = { event in
                if case .chiefFinalReceived = event { finals += 1 }
                surface.handle(event,owner:binding)
            }
            await controller.start()
            let ready = await waitUntil { controller.status.phase == "ready" }; XCTAssertTrue(ready)
            try await backend.submitReviewedText("Old call input")
            let metadata: J = .object(["operation_id":.string(journal.records[0].id.uuidString.lowercased())])
            try await deliver(task,"response.created",fields:["response":.object(["id":.string("r"),"object":.string("realtime.response"),"status":.string("in_progress"),"status_details":.null,"output":.array([]),"metadata":metadata])])
            try await deliver(task,"response.output_item.added",fields:["response_id":.string("r"),"output_index":.number(0),"item":.object(["id":.string("reply"),"object":.string("realtime.item"),"type":.string("message"),"role":.string("assistant"),"status":.string("in_progress"),"content":.array([])])])
            let co: [String:J] = ["response_id":.string("r"),"item_id":.string("reply"),"output_index":.number(0),"content_index":.number(0)]
            var part = co; part["part"] = .object(["type":.string("audio"),"transcript":.string("")])
            try await deliver(task,"response.content_part.added",fields:part)
            controller.pauseForCall()
            if stopped { controller.stop(discardUnfinished:true) }
            let replacement = surface.replaceBinding(target:TargetLease(sessionID:"new-call",generation:"new-owner"))
            surface.handle(.youFinal("New call turn"),owner:replacement)
            try await deliver(task,"response.output_audio.done",fields:co)
            var final = co; final["transcript"] = .string("First late final from old call")
            try await deliver(task,"response.output_audio_transcript.done",fields:final)
            XCTAssertEqual(finals,stopped ? 0 : 1)
            XCTAssertEqual(surface.log.turns.map(\.spoken),["New call turn"])
            XCTAssertEqual(backend.pump.client.renderedSamples,0); XCTAssertFalse(input.started)
            XCTAssertTrue(synth.prepared.isEmpty)
            await backend.shutdown()
        }
    }
    @MainActor func testCandidateAuthenticatedLookupRejectsWrongPushCallerAndStaleOwner() async throws {
        let f = try fixture(), c = try control([]); defer { c.close() }
        let raw = f["recipient_response"], call = raw["call_uuid"].string!
        let push = PushInvitation(payload:["reachoutID":"opaque_push","callUUID":call,"expiry":1792429260000.0,"ringDeadline":1792429230000.0])
        let invitation = try c.authenticatedInvitation(raw.encoded(),push:push)
        XCTAssertEqual(invitation.owner.callUUID,push.id)
        for invalid in [f["caller_response"],change(raw,["call_uuid":.string(UUID().uuidString.lowercased())]),change(raw,["status":.string("accepted")]),change(raw,["owner_epoch":raw["call_uuid"]])] {
            XCTAssertThrowsError(try c.authenticatedInvitation(invalid.encoded(),push:push))
        }
        XCTAssertTrue(RecipientURLProtocol.captured().isEmpty)
        let lifecycle = CallLifecycle(); let epoch = lifecycle.incoming(id:push.id)!
        let journal = OpenVoiceOperationJournal(file:URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),save:{ _ in })
        do {
            _ = try await OpenVoiceCallSession.accept(record:raw.encoded(),push:push,lifecycle:lifecycle,control:c,journal:journal,allowed:{ false })
            XCTFail()
        } catch {}
        XCTAssertTrue(RecipientURLProtocol.captured().isEmpty)
        lifecycle.end(epoch)
        do {
            _ = try await OpenVoiceCallSession.accept(record:raw.encoded(),push:push,lifecycle:lifecycle,control:c,journal:journal,allowed:{ true })
            XCTFail()
        } catch {}
        XCTAssertTrue(RecipientURLProtocol.captured().isEmpty)
    }
    @MainActor func testCandidateUncertainReadinessClosesWithoutRetryOrLegacyFallback() async throws {
        let (backend,task,_) = try await candidateRig(readinessReplies:0,extra:[(500,.object([:]))])
        let input = FakeInput(), synth = FakeSynth(), controller = candidateController(backend,input:input,synth:synth,output:FakeOutput(duration:0))
        await controller.start()
        let stopped = await waitUntil { !controller.status.running }; XCTAssertTrue(stopped)
        input.captureGraphReady = false; input.captureGraphReady = true
        XCTAssertEqual(RecipientURLProtocol.captured().filter { $0.url!.path.hasSuffix("media-ready") }.count,1)
        XCTAssertTrue(synth.prepared.isEmpty); XCTAssertEqual(task.appends,0); XCTAssertFalse(backend.ready)
        await backend.shutdown()
    }
    @MainActor func testCandidateExplicitAcceptAssemblyNeverStartsSocketOrCaptureAndFencesLateLookup() async throws {
        for endDuringLookup in [false,true] {
            let f = try fixture(), now = Date(), expiry = (now.addingTimeInterval(50).timeIntervalSince1970 * 1000).rounded(.down)
            let raw = change(f["recipient_response"],["expires_at":.number(expiry)])
            let accepted = change(raw,["status":.string("accepted")])
            let media = change(f["media_response"],["expires_at":.number((now.addingTimeInterval(30).timeIntervalSince1970 * 1000).rounded(.down))])
            RecipientURLProtocol.reset(try [raw,accepted,media].map { (200,try $0.encoded()) })
            let http = OpenVoiceControlHTTP(timeout:1) { $0.protocolClasses = [RecipientURLProtocol.self] }
            let control = try OpenVoiceRecipientControl(origin:origin,credential:OpenVoiceDeviceCredential(pairedDeviceBearer:"synthetic-device-only"),http:http,now:{ now })
            let push = PushInvitation(payload:["reachoutID":"opaque_push","callUUID":raw["call_uuid"].string!,"expiry":expiry,"ringDeadline":expiry])
            let lifecycle = CallLifecycle(), epoch = try XCTUnwrap(lifecycle.incoming(id:push.id))
            let journal = OpenVoiceOperationJournal(file:URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),save:{ _ in })
            if endDuringLookup { RecipientURLProtocol.observe { DispatchQueue.main.async { lifecycle.end(epoch) } } }
            do {
                let backend = try await OpenVoiceCallSession.accept(record:raw.encoded(),push:push,lifecycle:lifecycle,control:control,journal:journal,allowed:{ true })
                XCTAssertFalse(endDuringLookup)
                XCTAssertFalse(lifecycle.activationGranted); XCTAssertFalse(backend.pump.running)
                XCTAssertEqual(backend.pump.client.state,.awaitingCreated); XCTAssertFalse(backend.ready)
                XCTAssertEqual(lifecycle.state,.ringing)
                XCTAssertTrue(backend.target.sessionID.hasPrefix("openvoice_")); XCTAssertFalse(backend.target.sessionID.hasPrefix("ses_"))
                XCTAssertTrue(journal.records.isEmpty)
                await backend.shutdown()
                XCTAssertEqual(backend.pump.client.state,.closed)
            } catch { XCTAssertTrue(endDuringLookup) }
            let requests = RecipientURLProtocol.captured()
            XCTAssertEqual(requests.count,endDuringLookup ? 1 : 3)
            XCTAssertFalse(requests.contains { $0.url!.path.hasSuffix("media-ready") || $0.url!.path.contains("realtime") })
            control.close()
        }
    }
}

@MainActor private final class CandidateDelayedInput: AudioInput, DuplexReporting {
    var onPCM: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onDuplexChange: (() -> Void)?
    var duplexSafe: Bool { true }
    var captureGraphReady: Bool { started }
    var started = false, stops = 0
    var waiter: CheckedContinuation<Void,Never>?
    func start() async throws {
        await withCheckedContinuation { waiter = $0 }
        started = true // Deliberately late producer completion; Controller must seal it.
    }
    func release() { let pending = waiter; waiter = nil; pending?.resume() }
    func stop() { started = false; stops += 1 }
}

@MainActor private final class CandidateRenderedOutput: AudioOutput {
    var consumed = 0
    var rendered = 0
    var progress: (@MainActor (PlaybackSourceProgress) -> Void)?
    func play(_ audio: SpeechAudio, label: String, onStart: @escaping () -> Void) async throws {
        progress = audio.sourceProgress
        for try await chunk in audio.chunks { if consumed == 0 { onStart() }; consumed += chunk.count / 2 }
    }
    func report(_ samples: Int, _ state: PlaybackSourceProgress.State) { rendered = samples; progress?(PlaybackSourceProgress(renderedSamples:samples,state:state)) }
    func stopPlayback() { progress?(PlaybackSourceProgress(renderedSamples:rendered,state:.stopped)); progress = nil }
}
