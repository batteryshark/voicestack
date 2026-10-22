#if DEBUG && os(macOS)
import XCTest
import Foundation
import Darwin
@testable import FloatingVoiceCore

private typealias PJ = OpenVoiceJSON
private enum PeerError: Error { case unavailable, refused, timeout, startup(Int,Int32) }

/// Owns one actual Node child and its generated material. No credentials in argv/env,
/// no private-key reads, no process polling, no unbounded output or AsyncStream.
@MainActor private final class NativePeer {
    let root: URL, certificateDER: Data
    let device = "device_" + UUID().uuidString.replacingOccurrences(of:"-",with:"")
    let caller = "caller_" + UUID().uuidString.replacingOccurrences(of:"-",with:"")
    let media = "media_token" + UUID().uuidString.replacingOccurrences(of:"-",with:"")
    private let child = Process(), input = Pipe(), output = Pipe()
    private var launched = false, exited = false
    private var exitWaiter: CheckedContinuation<Void,Never>?
    private var buffer = Data(), totalOutput = 0, requestID = 0
    private var events: [String:PJ] = [:]
    private var waiters: [String:(CheckedContinuation<PJ,Error>,DispatchWorkItem)] = [:]
    private(set) var port = 0
    var origin: URL { URL(string:"https://127.0.0.1:\(port)")! }

    private init(san: String) throws {
        let fm = FileManager.default
        // Use the same ordinary TMPDIR as the Node child, not Foundation's possibly
        // cached/test-runner-specific temporary URL. Canonicalize after creation.
        let ordinary = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath:$0,isDirectory:true) } ?? fm.temporaryDirectory
        let base = ordinary.resolvingSymlinksInPath().appendingPathComponent("opencode")
        let candidate = base.appendingPathComponent("fv-native-swift-peer-" + UUID().uuidString)
        try fm.createDirectory(at:candidate,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        root = candidate.resolvingSymlinksInPath()
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
        let config = root.appendingPathComponent("req.cnf"), cert = root.appendingPathComponent("cert.pem"), key = root.appendingPathComponent("key.pem")
        do {
            try Data("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=fixture.invalid\n[ext]\nsubjectAltName=\(san)\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n".utf8).write(to:config)
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:config.path)
            let generator = Process(); generator.executableURL = URL(fileURLWithPath:"/usr/bin/openssl")
            generator.arguments = ["req","-x509","-newkey","rsa:2048","-nodes","-days","1","-config",config.path,"-keyout",key.path,"-out",cert.path]
            generator.environment = ["PATH":"/usr/bin:/bin","HOME":root.path,"OPENSSL_CONF":config.path,"TMPDIR":ProcessInfo.processInfo.environment["TMPDIR"] ?? fm.temporaryDirectory.path]
            generator.standardOutput = FileHandle.nullDevice; generator.standardError = FileHandle.nullDevice
            try generator.run()
            let kill = DispatchWorkItem { if generator.isRunning { Darwin.kill(generator.processIdentifier,SIGKILL) } }
            DispatchQueue.global().asyncAfter(deadline:.now()+10,execute:kill)
            generator.waitUntilExit(); kill.cancel()
            guard generator.terminationStatus == 0 else { throw PeerError.refused }
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:cert.path)
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:key.path)
            let pem = try String(contentsOf:cert,encoding:.utf8)
            guard let der = Data(base64Encoded:pem.components(separatedBy:.newlines).filter { !$0.hasPrefix("---") }.joined()) else { throw PeerError.refused }
            certificateDER = der
        } catch { try? fm.removeItem(at:root); throw error }
    }
    static func start(mode: String, san: String = "IP:127.0.0.1") async throws -> NativePeer {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("opencode/open-voice-native-peer-deps-7e80c15")
        guard fm.fileExists(atPath:staging.appendingPathComponent("node_modules/ws/package.json").path) else {
            throw XCTSkip("Owned exact-commit offline peer dependency not staged; actual peer proof NOT RUN.")
        }
        let peer = try NativePeer(san:san)
        do {
            peer.child.executableURL = URL(fileURLWithPath:"/opt/homebrew/bin/node")
            peer.child.arguments = [staging.appendingPathComponent("fixtures/open-voice/native-tls-peer.mjs").path]
            peer.child.currentDirectoryURL = peer.root
            peer.child.environment = ["PATH":"/opt/homebrew/bin:/usr/bin:/bin","HOME":peer.root.path,"TMPDIR":ProcessInfo.processInfo.environment["TMPDIR"] ?? fm.temporaryDirectory.path]
            peer.child.standardInput = peer.input; peer.child.standardOutput = peer.output; peer.child.standardError = FileHandle.nullDevice
            peer.output.fileHandleForReading.readabilityHandler = { [weak peer] handle in
                let data = handle.availableData
                DispatchQueue.main.async { peer?.consume(data) }
            }
            peer.child.terminationHandler = { [weak peer] _ in DispatchQueue.main.async { peer?.didExit() } }
            try peer.child.run(); peer.launched = true
            guard let resolved = Darwin.realpath(peer.root.path,nil) else { throw PeerError.refused }
            let canonicalRoot = String(cString:resolved); free(resolved)
            let startup: PJ = .object(["synthetic":.bool(true),"root":.string(canonicalRoot),"cert_path":.string(canonicalRoot + "/cert.pem"),"key_path":.string(canonicalRoot + "/key.pem"),"device_token":.string(peer.device),"caller_token":.string(peer.caller),"media_token":.string(peer.media),"mode":.string(mode)])
            try peer.write(startup,limit:8192)
            let ready = try await peer.wait("ready",timeout:5)
            guard let port = ready["port"].number, port > 0 && port <= 65535 else { throw PeerError.refused }
            peer.port = Int(port); return peer
        } catch { await peer.shutdown(); throw error }
    }
    private func write(_ value: PJ, limit: Int = 512) throws {
        let data = try value.encoded(); guard data.count <= limit else { throw PeerError.refused }
        try input.fileHandleForWriting.write(contentsOf:data + Data([10]))
    }
    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }; totalOutput += data.count; buffer.append(data)
        guard totalOutput <= 65536 && buffer.count <= 8192 else { child.terminate(); return }
        while let end = buffer.firstIndex(of:10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let event = try? OpenVoiceWire.parse(line), let name = event["event"].string,
                  ["ready","counters","closed","stopped","idle_elapsed"].contains(name) else { child.terminate(); return }
            let key = name + (event["request_id"].number.map { ":\(Int($0))" } ?? "")
            if let (waiter,timer) = waiters.removeValue(forKey:key) { timer.cancel(); waiter.resume(returning:event) }
            else if events.count < 128 { events[key] = event }
            else { child.terminate() }
        }
    }
    private func didExit() {
        exited = true
        let pending = waiters; waiters.removeAll()
        let step = Int(events["stopped"]?["counters"]["startup_step"].number ?? -1)
        for (_, (waiter,timer)) in pending { timer.cancel(); waiter.resume(throwing:PeerError.startup(step,child.terminationStatus)) }
        exitWaiter?.resume(); exitWaiter = nil
    }
    func wait(_ name: String, id: Int? = nil, timeout: Double = 3) async throws -> PJ {
        let key = name + (id.map { ":\($0)" } ?? "")
        if let event = events.removeValue(forKey:key) { return event }
        guard !exited && waiters[key] == nil else { throw PeerError.refused }
        return try await withCheckedThrowingContinuation { continuation in
            let timer = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
                self?.waiters.removeValue(forKey:key)?.0.resume(throwing:PeerError.timeout)
            } }
            waiters[key] = (continuation,timer); DispatchQueue.main.asyncAfter(deadline:.now()+timeout,execute:timer)
        }
    }
    func command(_ name: String) async throws -> PJ {
        requestID += 1; guard requestID <= 64 else { throw PeerError.refused }
        try write(.object(["command":.string(name),"request_id":.number(Double(requestID))]))
        return try await wait(name == "close" ? "closed" : "counters",id:requestID)["counters"]
    }
    func shutdown() async {
        if launched && !exited {
            try? write(.object(["command":.string("shutdown")]))
            let term = DispatchWorkItem { [child] in if child.isRunning { child.terminate() } }
            let kill = DispatchWorkItem { [child] in if child.isRunning { Darwin.kill(child.processIdentifier,SIGKILL) } }
            DispatchQueue.main.asyncAfter(deadline:.now()+1,execute:term)
            DispatchQueue.main.asyncAfter(deadline:.now()+3,execute:kill)
            await withCheckedContinuation { exitWaiter = $0 }
            term.cancel(); kill.cancel()
        }
        if launched { child.waitUntilExit() }
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        try? FileManager.default.removeItem(at:root)
    }
}

final class OpenVoiceTLSPeerTests: XCTestCase {
    @MainActor private func withPeer(_ mode: String, san: String = "IP:127.0.0.1", body: (NativePeer) async throws -> Void) async throws {
        let peer = try await NativePeer.start(mode:mode,san:san)
        do { try await body(peer) } catch { await peer.shutdown(); throw error }
        await peer.shutdown()
    }
    private func vectors() throws -> PJ {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(PJ.self,from:Data(contentsOf:root.appendingPathComponent("bridge/fixtures/open-voice/control-vectors.json")))
    }
    @MainActor private func owner() throws -> OpenVoiceRecipientOwner {
        let v = try vectors(), o = v["owner_body"]
        return OpenVoiceRecipientOwner(callID:UUID(uuidString:v["recipient_response"]["call_id"].string!)!,callUUID:UUID(uuidString:o["call_uuid"].string!)!,ownerEpoch:UUID(uuidString:o["owner_epoch"].string!)!,targetID:UUID(uuidString:o["target_id"].string!)!,bindingRevision:1)
    }
    @MainActor private func lease(_ peer: NativePeer, bearer: String? = nil) throws -> OpenVoiceMediaLease {
        OpenVoiceMediaLease(owner:try owner(),epoch:"1",expiresAt:Date().addingTimeInterval(60),origin:peer.origin,bearer:bearer ?? peer.media)
    }
    @MainActor private func socket(_ peer: NativePeer, pin: Data? = nil, bearer: String? = nil,
                                   tlsDecision: ((Bool) -> Void)? = nil,
                                   decorate: ((OpenVoiceHeldSystemCompletion) -> Void)? = nil) throws -> OpenVoiceURLSessionSocket {
        let policy = OpenVoiceTestTrust(certificateDER:peer.certificateDER,expectedPin:pin)
        return try OpenVoiceURLSessionSocket(origin:peer.origin,lease:lease(peer,bearer:bearer),now:Date(),timeout:10) { req,config,lifecycle in
            lifecycle.testTLSChallenge = { challenge,completion in
                policy.handler(challenge) { disposition,credential in
                    tlsDecision?(disposition == .useCredential); completion(disposition,credential)
                }
            }
            let actual = openVoiceTestSystemTask(request:req,configuration:config,lifecycle:lifecycle)
            if let decorate { let held = OpenVoiceHeldSystemCompletion(actual); decorate(held); return held }
            return actual
        }
    }
    @MainActor private func control(_ peer: NativePeer, bearer: String? = nil) throws -> OpenVoiceRecipientControl {
        let http = OpenVoiceControlHTTP(); http.testTLSChallenge = OpenVoiceTestTrust(certificateDER:peer.certificateDER).handler
        return try OpenVoiceRecipientControl(origin:peer.origin,credential:OpenVoiceDeviceCredential(pairedDeviceBearer:bearer ?? peer.device),http:http,now:Date.init)
    }
    @MainActor func testActualDefaultTLSRejectsAndCorrectPinAndHostSucceeds() async throws {
        try await withPeer("normal") { peer in
            let normal = try OpenVoiceURLSessionSocket(origin:peer.origin,lease:lease(peer))
            do { try await normal.open(); XCTFail("public factory trusted self-signed fixture") } catch {}; normal.close()
            let defaultHTTP = try OpenVoiceRecipientControl(origin:peer.origin,credential:OpenVoiceDeviceCredential(pairedDeviceBearer:peer.device))
            do { _ = try await defaultHTTP.invitation(callID:owner().callID); XCTFail("default HTTP trusted fixture") } catch {}; defaultHTTP.close()
            let wrong = try socket(peer,pin:Data(repeating:0,count:32))
            do { try await wrong.open(); XCTFail("wrong leaf pin trusted") } catch {}; wrong.close()
            var acceptedTLS = 0
            let actual = try socket(peer,tlsDecision:{ if $0 { acceptedTLS += 1 } })
            do { try await actual.open() } catch {
                let c = try await peer.command("counters")
                XCTFail("Correct-pin open failed: accepted TLS decisions=\(acceptedTLS), upgrades=\(c["ws_upgrades"].number ?? -1), opened=\(c["ws_opened"].number ?? -1), TLS errors=\(c["tls_errors"].number ?? -1)")
                actual.close(); throw error
            }
            let event = try OpenVoiceWire.server(OpenVoiceWire.parse(await actual.receive()))
            XCTAssertEqual(event.kind,.sessionCreated); actual.close()
            let c = try await peer.command("counters"); XCTAssertEqual(c["ws_opened"],.number(1))
        }
    }
    @MainActor func testCorrectPinWrongSANIsRejected() async throws {
        try await withPeer("normal",san:"IP:127.0.0.2") { peer in
            let actual = try socket(peer)
            do { try await actual.open(); XCTFail("pin bypassed SSL hostname policy") } catch {}; actual.close()
            let c = try await peer.command("counters"); XCTAssertEqual(c["ws_opened"],.number(0))
        }
    }
    @MainActor func testActualRedirectsNeverForwardAuthorizationToTrap() async throws {
        for mode in ["ws-302","http-302"] {
            try await withPeer(mode) { peer in
                if mode == "ws-302" {
                    let actual = try socket(peer); do { try await actual.open(); XCTFail() } catch {}; actual.close()
                } else {
                    let http = try control(peer); do { _ = try await http.invitation(callID:owner().callID); XCTFail() } catch {}; http.close()
                }
                let c = try await peer.command("counters")
                XCTAssertEqual(c["redirects"],.number(1)); XCTAssertEqual(c["trap_requests"],.number(0)); XCTAssertEqual(c["trap_authorization_present"],.number(0))
            }
        }
    }
    @MainActor func testActualCredentialRolesAndOversizedFrame() async throws {
        try await withPeer("normal") { peer in
            for wrong in [peer.device,peer.caller] {
                let actual = try socket(peer,bearer:wrong); do { try await actual.open(); XCTFail() } catch {}; actual.close()
            }
            for wrong in [peer.media,peer.caller] {
                let http = try control(peer,bearer:wrong)
                do { _ = try await http.invitation(callID:owner().callID); XCTFail() } catch {}; http.close()
            }
            let actual = try socket(peer); try await actual.open(); actual.close()
            let c = try await peer.command("counters"); XCTAssertGreaterThanOrEqual(c["role_denials"].number!,3)
        }
        try await withPeer("oversized-text") { peer in
            let actual = try socket(peer); try await actual.open()
            do {
                _ = try await actual.receive() // initial created may arrive before actual oversized frame failure
                _ = try await actual.receive(); XCTFail("oversized frame escaped maximumMessageSize")
            } catch {}
            XCTAssertFalse(actual.isOpen); actual.close()
        }
    }
    @MainActor func testActualCommitRXBeforeExposedHandoffAndPendingCancellation() async throws {
        for cancel in [false,true] {
            try await withPeer("immediate-commit") { peer in
                let http = try control(peer)
                let invitation = try await http.invitation(callID:owner().callID), leased = try await http.mediaLease(invitation)
                let configured = expectation(description:"real session.updated"), received = expectation(description:"real transcript processed before exposed handoff"), final = expectation(description:"one recognition result")
                var barrier: OpenVoiceHeldSystemCompletion!
                let actual = try socket(peer,decorate:{ task in
                    barrier = task
                    task.onPriorReceiveHandled = { type in if type == "conversation.item.input_audio_transcription.completed" { received.fulfill() } }
                })
                let pump = try OpenVoiceMediaOwnerPump(socket:actual,lease:leased,localCallEpoch:UUID())
                pump.client.onEvent = { e in if e.kind == .sessionUpdated { configured.fulfill() } }
                try await pump.start(); await fulfillment(of:[configured],timeout:5)
                pump.nativeCaptureReady(true,fence:pump.fence); try await pump.reportReadiness(using:http)
                var finals:[String] = [], errors = 0
                let recognition = OpenVoiceRecognition(client:pump.client,callbacks:RecognitionCallbacks(partial:{_ in XCTFail()},error:{_ in errors += 1},done:{ finals.append($0); final.fulfill() }))
                recognition.start(); recognition.write(Data(repeating:0,count:640)); recognition.end(); pump.signalWrites()
                await fulfillment(of:[received],timeout:4); XCTAssertTrue(finals.isEmpty)
                let c = try await peer.command("counters"); XCTAssertEqual(c["commit_acks"],.number(1)); XCTAssertEqual(c["transcripts"],.number(1))
                if cancel { await pump.shutdown() } else { barrier.release() }
                await fulfillment(of:[final],timeout:3)
                XCTAssertEqual(finals,cancel ? [""] : ["Synthetic transcript."]); XCTAssertEqual(errors,cancel ? 1 : 0)
                await pump.shutdown(); barrier.release(); http.close(); XCTAssertFalse(pump.running)
                XCTAssertEqual(pump.client.renderedSamples,0)
            }
        }
    }
    @MainActor func testActualHealthySixteenSecondSilenceAndMissingPongDeadline() async throws {
        for responsive in [true,false] {
            try await withPeer(responsive ? "idle-auto-pong" : "idle-no-pong") { peer in
                let actual = try socket(peer), client = try OpenVoiceClient(socket:actual,fence:OpenVoiceMediaFence(call:UUID(),media:"1"))
                try await actual.open()
                try await client.receiveOne()
                try client.enqueue(.object(["type":.string("session.update"),"session":.object(["type":.string("realtime")])]))
                try await client.flush()
                try await client.receiveOne(); try await client.receiveOne()
                let baseline = try await peer.command("counters")
                let started = ProcessInfo.processInfo.systemUptime
                var failedAt: TimeInterval?
                let pending = Task {
                    do { try await client.receiveOne() }
                    catch { failedAt = ProcessInfo.processInfo.systemUptime; throw error }
                }
                let elapsed = try await peer.wait("idle_elapsed",timeout:20)["counters"]
                XCTAssertEqual(elapsed["app_events_sent"],baseline["app_events_sent"])
                XCTAssertGreaterThanOrEqual(elapsed["pings_received"].number!,1)
                XCTAssertEqual(client.consumedSamples,0); XCTAssertEqual(client.renderedSamples,0); XCTAssertEqual(client.generatedSamples,0)
                XCTAssertEqual(elapsed["commit_acks"],.number(0)); XCTAssertEqual(elapsed["transcripts"],.number(0))
                if responsive {
                    XCTAssertTrue(actual.isOpen); XCTAssertGreaterThanOrEqual(elapsed["pongs_sent"].number!,2)
                    XCTAssertEqual(client.state,.configured) // pongs did not activate native capture
                    pending.cancel()
                } else {
                    XCTAssertFalse(actual.isOpen); XCTAssertEqual(elapsed["pongs_sent"],.number(0))
                    XCTAssertEqual(elapsed["pings_received"],.number(1)) // never overlap pings awaiting pong
                    let failureTime = try XCTUnwrap(failedAt)
                    XCTAssertGreaterThanOrEqual(failureTime-started,14)
                    XCTAssertLessThan(failureTime-started,18) // five-second first ping + ten-second deadline
                }
                do { try await pending.value; XCTFail("pending RX should visibly fail on cancel/missing pong") } catch {}
                actual.close()
            }
        }
    }
    @MainActor func testActualRemoteCloseFailsPendingReceive() async throws {
        try await withPeer("normal") { peer in
            let actual = try socket(peer); try await actual.open(); _ = try await actual.receive()
            let pending = Task { try await actual.receive() }
            _ = try await peer.command("close")
            do { _ = try await pending.value; XCTFail("remote close must fail pending RX") } catch {}
            XCTAssertFalse(actual.isOpen); actual.close()
        }
    }
}
#endif
