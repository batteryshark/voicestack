import Foundation

public struct OpenVoiceDeviceCredential: CustomStringConvertible, CustomDebugStringConvertible {
    let bearer: String
    public init(pairedDeviceBearer: String) throws {
        try OpenVoiceWire.check(!pairedDeviceBearer.isEmpty && pairedDeviceBearer.utf8.count <= 512 && pairedDeviceBearer.utf8.allSatisfy { (33...126).contains($0) })
        bearer = pairedDeviceBearer
    }
    public var description: String { "<paired-device credential>" }
    public var debugDescription: String { description }
}
public struct OpenVoiceRecipientOwner: Equatable {
    public let callID: UUID, callUUID: UUID, ownerEpoch: UUID, targetID: UUID
    public let bindingRevision: Int
    var json: OpenVoiceJSON { .object(["call_uuid":.string(callUUID.uuidString.lowercased()),"owner_epoch":.string(ownerEpoch.uuidString.lowercased()),
        "binding_revision":.number(Double(bindingRevision)),"target_id":.string(targetID.uuidString.lowercased())]) }
}
public struct OpenVoiceInvitation {
    public let owner: OpenVoiceRecipientOwner
    public let status: String
    public let expiresAt: Date
    public let json: OpenVoiceJSON
}
public struct OpenVoiceMediaLease: CustomStringConvertible, CustomDebugStringConvertible {
    public let owner: OpenVoiceRecipientOwner
    public let epoch: String
    public let expiresAt: Date
    let origin: URL, bearer: String
    public var description: String { "<recipient media lease>" }
    public var debugDescription: String { description }
}
/// Constructed by the actual owner pump only, after same-socket effective configuration
/// and an explicit native-capture callback. Recipient report, not server hardware proof.
public struct OpenVoiceMediaReadiness {
    let lease: OpenVoiceMediaLease
    let sessionID: String
}
public struct OpenVoiceControlAttempt {
    public enum Outcome: Equatable { case pending, confirmed, refused, uncertain }
    public let action: String
    public let callID: UUID?
    public let operationID: UUID?
    public fileprivate(set) var outcome: Outcome
}
enum OpenVoiceHTTPFailure: Error { case refused(Int), failed }

/// One bounded request at a time, ephemeral storage, system TLS, no redirects.
/// Delegate callbacks use this session's main OperationQueue; no per-chunk tasks.
@MainActor final class OpenVoiceControlHTTP: NSObject, URLSessionDataDelegate {
#if DEBUG
    var testTLSChallenge: OpenVoiceTestTLSChallenge?
#endif
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var waiter: CheckedContinuation<Data, Error>?
    private var response = Data()
    private var timer: DispatchWorkItem?
    private var expectedURL: URL?
    private var requestID: UUID?
    private var closed = false
    private let timeout: TimeInterval
    init(timeout: TimeInterval = 10, configure: ((URLSessionConfiguration) -> Void)? = nil) {
        self.timeout = timeout; super.init()
        let config = OpenVoiceURLSessionPolicy.configuration(timeout: timeout)
        configure?(config) // Internal test-only URLProtocol injection, no TLS override.
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }
    func perform(_ request: URLRequest) async throws -> Data {
        try OpenVoiceWire.check(!closed && waiter == nil, "local_failure")
        let id = UUID(); requestID = id
        defer { if Task.isCancelled && requestID == id { finish(.failure(OpenVoiceHTTPFailure.failed)) } }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                waiter = continuation; response.removeAll(); expectedURL = request.url
                let t = session.dataTask(with: request); task = t
                let watchdog = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if self?.requestID == id { self?.finish(.failure(OpenVoiceHTTPFailure.failed)) } } }
                timer = watchdog; DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: watchdog); t.resume()
            }
            try Task.checkCancellation(); return data
        }, onCancel: { [weak self] in DispatchQueue.main.async { if self?.requestID == id { self?.finish(.failure(OpenVoiceHTTPFailure.failed)) } } })
    }
    private func finish(_ result: Result<Data, Error>) {
        let w = waiter; waiter = nil; let old = task; task = nil
        timer?.cancel(); timer = nil; response.removeAll(); expectedURL = nil; requestID = nil
        old?.cancel(); w?.resume(with: result)
    }
    func close() { closed = true; finish(.failure(OpenVoiceHTTPFailure.failed)); session.invalidateAndCancel() }
    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
#if DEBUG
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let handler = testTLSChallenge else { return false }
                handler(challenge, completionHandler); return true
            }
            if handled { return }
        }
#endif
        completionHandler(.performDefaultHandling, nil)
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        MainActor.assumeIsolated { if task === self.task { finish(.failure(OpenVoiceHTTPFailure.failed)) } }
    }
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        MainActor.assumeIsolated {
            guard dataTask === task, let r = response as? HTTPURLResponse, r.url == expectedURL else { completionHandler(.cancel); return }
            guard r.statusCode == 200 else { completionHandler(.cancel); finish(.failure(OpenVoiceHTTPFailure.refused(r.statusCode))); return }
            guard r.mimeType == "application/json", r.expectedContentLength <= Int64(OpenVoiceWire.maxMessageBytes) else {
                completionHandler(.cancel); finish(.failure(OpenVoiceHTTPFailure.failed)); return
            }
            completionHandler(.allow)
        }
    }
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard dataTask === task else { return }
            guard response.count + data.count <= OpenVoiceWire.maxMessageBytes else { finish(.failure(OpenVoiceHTTPFailure.failed)); return }
            response.append(data)
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard task === self.task else { return }
            finish(error == nil ? .success(response) : .failure(OpenVoiceHTTPFailure.failed))
        }
    }
}

/// Recipient-only client. No caller grants, admin APIs, selection, legacy fallback,
/// automatic acceptance, retries or mutation reconciliation-by-reposting.
@MainActor public final class OpenVoiceRecipientControl {
    public let origin: URL
    public private(set) var attempts: [OpenVoiceControlAttempt] = []
    private let credential: OpenVoiceDeviceCredential
    private let http: OpenVoiceControlHTTP
    private let now: () -> Date
    private var busy = false
    private var latestEpoch: [UUID: String] = [:]
    private var endOperations = Set<UUID>()
    public convenience init(origin: URL, credential: OpenVoiceDeviceCredential) throws {
        let validated = try OpenVoiceURLSessionPolicy.origin(origin)
        try self.init(origin: validated, credential: credential, http: OpenVoiceControlHTTP(), now: Date.init)
    }
    init(origin: URL, credential: OpenVoiceDeviceCredential, http: OpenVoiceControlHTTP, now: @escaping () -> Date) throws {
        self.origin = try OpenVoiceURLSessionPolicy.origin(origin); self.credential = credential; self.http = http; self.now = now
    }
    public func close() { http.close() }
    private func path(_ id: UUID, _ action: String? = nil) -> String {
        "/calls/" + id.uuidString.lowercased() + (action.map { "/" + $0 } ?? "")
    }
    private func request(_ method: String, _ path: String, _ body: OpenVoiceJSON? = nil) throws -> URLRequest {
        // All paths come from closed method names and typed UUIDs, never a response URL.
        var c = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        c.path = "/floating-voice/voice/v1" + path
        var r = URLRequest(url: c.url!); r.httpMethod = method; r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("Bearer \(credential.bearer)", forHTTPHeaderField:"Authorization")
        r.setValue("application/json", forHTTPHeaderField:"Accept")
        if let body {
            let d = try body.encoded(); try OpenVoiceWire.check(d.count <= 4096, "message_too_large")
            r.httpBody = d; r.setValue("application/json", forHTTPHeaderField:"Content-Type")
        }
        return r
    }
    private func execute<T>(_ method: String, _ path: String, body: OpenVoiceJSON? = nil, call: UUID? = nil, operation: UUID? = nil,
                            validate: (OpenVoiceJSON) throws -> T) async throws -> T {
        try OpenVoiceWire.check(!busy && (method == "GET" || attempts.count < 128), "local_failure")
        let r = try request(method,path,body); busy = true; defer { busy = false }
        let index = attempts.count
        if method != "GET" { attempts.append(OpenVoiceControlAttempt(action:path,callID:call,operationID:operation,outcome:.pending)) }
        do {
            let data = try await http.perform(r); let value = try validate(OpenVoiceWire.parse(data))
            if method != "GET" { attempts[index].outcome = .confirmed }; return value
        } catch {
            if method != "GET" {
                if case OpenVoiceHTTPFailure.refused(let status) = error, [400,401,403,404,409,410,413,429].contains(status) { attempts[index].outcome = .refused }
                else { attempts[index].outcome = .uncertain }
            }
            throw OpenVoiceFailure("local_failure") // Never surface transport URLs, headers or response text.
        }
    }
    private func date(_ v: OpenVoiceJSON) throws -> Date {
        try OpenVoiceWire.uint(v); try OpenVoiceWire.check(v.number! > 0)
        return Date(timeIntervalSince1970:v.number! / 1000)
    }
    private func uuid(_ v: OpenVoiceJSON) throws -> UUID {
        guard let s = v.string, let id = UUID(uuidString:s), id.uuidString.lowercased() == s else { throw OpenVoiceFailure() }; return id
    }
    private func invitation(_ j: OpenVoiceJSON, id: UUID) throws -> OpenVoiceInvitation {
        try OpenVoiceWire.keys(j,["call_id","status","context","call_uuid","owner_epoch","binding_revision","target_id","project_id","caller_id","reason","summary","expires_at","profile"])
        try OpenVoiceWire.check(try uuid(j["call_id"]) == id)
        try OpenVoiceWire.check(j["context"] == .string("open-voice") && j["profile"] == .string(OpenVoiceWire.profile))
        try OpenVoiceWire.check(["ringing","accepted","ended","rejected","expired"].contains(j["status"].string ?? ""))
        for key in ["project_id","caller_id"] { try OpenVoiceWire.id(j[key]); try OpenVoiceWire.check(j[key].string!.utf8.count <= 100) }
        try OpenVoiceWire.check(["decision","goal-risk"].contains(j["reason"].string ?? ""))
        try OpenVoiceWire.text(j["summary"],empty:false); try OpenVoiceWire.check(j["summary"].string!.utf16.count <= 240)
        try OpenVoiceWire.check(!j["summary"].string!.unicodeScalars.contains { $0.value < 32 || $0.value == 127 })
        try OpenVoiceWire.uint(j["binding_revision"]); try OpenVoiceWire.check(j["binding_revision"].number! > 0)
        let owner = try OpenVoiceRecipientOwner(callID:id,callUUID:uuid(j["call_uuid"]),ownerEpoch:uuid(j["owner_epoch"]),targetID:uuid(j["target_id"]),bindingRevision:Int(j["binding_revision"].number!))
        try OpenVoiceWire.check(owner.callID != owner.callUUID && owner.callID != owner.ownerEpoch && owner.callUUID != owner.ownerEpoch)
        return try OpenVoiceInvitation(owner:owner,status:j["status"].string!,expiresAt:date(j["expires_at"]),json:j)
    }
    public func capability(enabled: Bool, build: String, freshnessSeconds: Int = 300) async throws -> Date {
        try OpenVoiceWire.text(.string(build),empty:false)
        try OpenVoiceWire.check((1...300).contains(freshnessSeconds) && !build.isEmpty && build.utf16.count <= 40 && !build.unicodeScalars.contains { $0.value < 32 || $0.value == 127 })
        let body: OpenVoiceJSON = .object(["enabled":.bool(enabled),"profile":.string(OpenVoiceWire.profile),"build":.string(build),"expires_in":.number(Double(freshnessSeconds))])
        return try await execute("PUT","/device-capability",body:body) { j in
            try OpenVoiceWire.keys(j,["acknowledged","expires_at"]); try OpenVoiceWire.check(j["acknowledged"] == .bool(true))
            let d = try date(j["expires_at"]); try OpenVoiceWire.check(d > now() && d <= now().addingTimeInterval(Double(freshnessSeconds))); return d
        }
    }
    public func invitation(callID: UUID) async throws -> OpenVoiceInvitation {
        try await execute("GET",path(callID)) { try invitation($0,id:callID) }
    }
    /// Only use for the result of the paired, authenticated reach-out lookup.
    /// A PushKit payload itself is never recipient authority.
    public func authenticatedInvitation(_ record: Data, push: PushInvitation) throws -> OpenVoiceInvitation {
        try OpenVoiceWire.check(push.valid && (push.expiry ?? .distantPast) > now())
        let json = try OpenVoiceWire.parse(record), id = try uuid(json["call_id"])
        let value = try invitation(json,id:id)
        try OpenVoiceWire.check(value.owner.callUUID == push.id && value.status == "ringing" && value.expiresAt > now())
        return value
    }
    public func accept(_ invitation: OpenVoiceInvitation) async throws -> OpenVoiceInvitation {
        try OpenVoiceWire.check(invitation.status == "ringing" && invitation.expiresAt > now())
        return try await execute("POST",path(invitation.owner.callID,"accept"),body:invitation.owner.json,call:invitation.owner.callID) { j in
            let value = try self.invitation(j,id:invitation.owner.callID)
            try OpenVoiceWire.check(value.owner == invitation.owner && value.status == "accepted")
            var immutable = j.object!; immutable["status"] = invitation.json["status"]
            try OpenVoiceWire.check(.object(immutable) == invitation.json)
            return value
        }
    }
    public func decline(_ invitation: OpenVoiceInvitation) async throws {
        try OpenVoiceWire.check(invitation.status == "ringing" && invitation.expiresAt > now())
        let _: Bool = try await execute("POST",path(invitation.owner.callID,"decline"),body:invitation.owner.json,call:invitation.owner.callID) { j in
            try OpenVoiceWire.keys(j,["call_id","status"]); try OpenVoiceWire.check(j["call_id"] == .string(invitation.owner.callID.uuidString.lowercased()) && j["status"] == .string("rejected")); return true
        }
    }
    public func mediaLease(_ invitation: OpenVoiceInvitation) async throws -> OpenVoiceMediaLease {
        try OpenVoiceWire.check(invitation.status == "accepted")
        return try await execute("POST",path(invitation.owner.callID,"media"),body:invitation.owner.json,call:invitation.owner.callID) { j in
            try OpenVoiceWire.keys(j,["media_lease","media_epoch","expires_at","binding_revision","profile","limits","model","transcription","voice","semantics","cancellation"])
            let expected: OpenVoiceJSON = .object(["max_message_bytes":.number(65536),"sample_rate":.number(24000),"channels":.number(1),"input_window_samples":.number(48000),"output_window_samples":.number(48000)])
            try OpenVoiceWire.check(j["profile"] == .string(OpenVoiceWire.profile) && j["limits"] == expected && j["binding_revision"] == .number(Double(invitation.owner.bindingRevision)))
            for (k,v) in ["model":"local-chain-m1","transcription":"local-stt","voice":"local-default","semantics":"manual-text-one-exchange","cancellation":"narration-only"] { try OpenVoiceWire.check(j[k] == .string(v)) }
            guard let bearer = j["media_lease"].string, bearer.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil,
                  let epoch = j["media_epoch"].string, epoch.range(of:"^[1-9][0-9]{0,15}$",options:.regularExpression) != nil else { throw OpenVoiceFailure() }
            try OpenVoiceWire.check(epoch.count < 16 || epoch <= "9007199254740991")
            if let old = latestEpoch[invitation.owner.callID] { try OpenVoiceWire.check(epoch.count > old.count || (epoch.count == old.count && epoch > old)) }
            let expiry = try date(j["expires_at"]); try OpenVoiceWire.check(expiry > now() && expiry <= now().addingTimeInterval(60))
            try OpenVoiceWire.check(latestEpoch.count < 128 || latestEpoch[invitation.owner.callID] != nil)
            latestEpoch[invitation.owner.callID] = epoch
            return OpenVoiceMediaLease(owner:invitation.owner,epoch:epoch,expiresAt:expiry,origin:origin,bearer:bearer)
        }
    }
    public func mediaReady(_ proof: OpenVoiceMediaReadiness) async throws {
        let lease = proof.lease
        try OpenVoiceWire.check(lease.origin == origin && latestEpoch[lease.owner.callID] == lease.epoch)
        try OpenVoiceWire.id(.string(proof.sessionID))
        var body = lease.owner.json.object!
        body["media_epoch"] = .string(lease.epoch); body["session_id"] = .string(proof.sessionID); body["native_capture_ready"] = .bool(true)
        // Consumed attachment-token expiry is deliberately NOT active-call authority.
        let _: Bool = try await execute("POST",path(lease.owner.callID,"media-ready"),body:.object(body),call:lease.owner.callID) { j in
            try OpenVoiceWire.keys(j,["call_id","media_epoch","session_id","status"])
            try OpenVoiceWire.check(j["call_id"] == .string(lease.owner.callID.uuidString.lowercased()) && j["media_epoch"] == .string(lease.epoch) && j["session_id"] == .string(proof.sessionID) && j["status"] == .string("media_ready"))
            return true
        }
    }
    private func operation(_ j: OpenVoiceJSON, id: UUID, kind: String? = nil) throws -> OpenVoiceJSON {
        try OpenVoiceWire.keys(j,["operation_id","kind","hash","state","response_id","source_user_id","source_assistant_id","delivery","planned_inbox_id","admission_inbox_id","response_status"],["operation_id","kind","hash","state"])
        try OpenVoiceWire.check(try uuid(j["operation_id"]) == id)
        try OpenVoiceWire.check(["end","exchange"].contains(j["kind"].string ?? "") && (kind == nil || j["kind"] == .string(kind!)))
        if j["kind"] == .string("end") {
            try OpenVoiceWire.keys(j,["operation_id","kind","hash","state"])
            try OpenVoiceWire.check(["prepared","dispatching","completed","uncertain"].contains(j["state"].string ?? ""))
        }
        else { try OpenVoiceWire.check(j.object?["response_id"] != nil) }
        try OpenVoiceWire.check(j["hash"].string?.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil)
        try OpenVoiceWire.check(["prepared","dispatching","admitted","completed","rejected","uncertain"].contains(j["state"].string ?? ""))
        if j.object?["response_id"] != nil { _ = try uuid(j["response_id"]) }
        for key in ["source_user_id","source_assistant_id"] where j.object?[key] != nil { try OpenVoiceWire.id(j[key]); try OpenVoiceWire.check(j[key].string!.utf8.count <= 100) }
        for key in ["planned_inbox_id","admission_inbox_id"] where j.object?[key] != nil { try OpenVoiceWire.id(j[key]); try OpenVoiceWire.check(j[key].string!.utf8.count <= 100) }
        if j.object?["admission_inbox_id"] != nil { try OpenVoiceWire.check(j["admission_inbox_id"] == j["planned_inbox_id"]) }
        if j.object?["response_status"] != nil { try OpenVoiceWire.check(["completed","cancelled","failed"].contains(j["response_status"].string ?? "")) }
        if j["kind"] == .string("exchange") {
            if ["admitted","completed"].contains(j["state"].string ?? "") { try OpenVoiceWire.id(j["source_user_id"]) }
            if j["state"] == .string("completed") { try OpenVoiceWire.id(j["source_assistant_id"]) }
        }
        if j.object?["delivery"] != nil {
            try OpenVoiceWire.keys(j["delivery"],["rendered_samples","state"]); try OpenVoiceWire.uint(j["delivery"]["rendered_samples"])
            try OpenVoiceWire.check(["unknown","partial","completed"].contains(j["delivery"]["state"].string ?? ""))
        }
        return j
    }
    public func deliberateEnd(_ owner: OpenVoiceRecipientOwner, operationID: UUID) async throws -> OpenVoiceJSON {
        try OpenVoiceWire.check(!busy && !endOperations.contains(operationID) && attempts.count < 128, "operation_conflict")
        var body = owner.json.object!; body["operation_id"] = .string(operationID.uuidString.lowercased()); body["reason"] = .string("deliberate-user")
        endOperations.insert(operationID) // No re-POST even after an uncertain result. Reconcile by GET.
        return try await execute("POST",path(owner.callID,"end"),body:.object(body),call:owner.callID,operation:operationID) { try operation($0,id:operationID,kind:"end") }
    }
    public func operation(owner: OpenVoiceRecipientOwner, operationID: UUID) async throws -> OpenVoiceJSON {
        try await execute("GET",path(owner.callID,"operations/" + operationID.uuidString.lowercased())) { try operation($0,id:operationID) }
    }
}
