#if DEBUG && os(macOS)
import XCTest
import Foundation
import Darwin
@testable import FloatingVoiceCore

enum FixtureFailure: Error { case protocolFailure, timeout, childExited }

/// One bounded actual-Node-engine child; no token in argv/env/log and no private-key
/// read by Swift. The child returns only a public certificate and synthetic device
/// bearer via its bounded stdout pipe. This is NOT native-tls-peer.mjs.
@MainActor final class ActualEngineFixture {
    static let nodeRef = "757782eac430924aee459319385f5011d8b8a2ee"
    static let nativeRef = "757782eac430924aee459319385f5011d8b8a2ee"
    let root: URL
    private let process = Process(), input = Pipe(), output = Pipe()
    private var bytes = Data(), total = 0, pending: CheckedContinuation<OpenVoiceJSON,Error>?
    private var timer: DispatchWorkItem?, exitTimer: DispatchWorkItem?, exitWaiter: CheckedContinuation<Void,Never>?
    private var exited = false, requestID = 0
    private var held: [OpenVoiceJSON] = []
    private var stopped: OpenVoiceJSON?
    private(set) var origin: URL!
    private(set) var certificateDER = Data()
    private(set) var credential: OpenVoiceDeviceCredential!
    private(set) var build = ""
    private init() throws {
        let file = URL(fileURLWithPath: #filePath)
        root = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static func start(_ scenario: String = "normal") async throws -> ActualEngineFixture {
        let f = try ActualEngineFixture()
        f.process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        f.process.arguments = [f.root.appendingPathComponent("actual-engine-fixture.mjs").path]
        f.process.currentDirectoryURL = f.root
        f.process.environment = ["PATH":"/opt/homebrew/bin:/usr/bin:/bin", "HOME":f.root.path,"TMPDIR":f.root.path]
        f.process.standardInput = f.input; f.process.standardOutput = f.output
        f.process.standardError = FileHandle.nullDevice
        f.output.fileHandleForReading.readabilityHandler = { [weak f] handle in
            let data = handle.availableData
            DispatchQueue.main.async { f?.consume(data) }
        }
        f.process.terminationHandler = { [weak f] _ in DispatchQueue.main.async {
            guard let f else { return }; f.exited = true
            f.timer?.cancel(); f.pending?.resume(throwing:FixtureFailure.childExited); f.pending = nil
            f.exitWaiter?.resume(); f.exitWaiter = nil
        } }
        try f.process.run()
        do {
            try f.write(.object(["command":.string("start"),"scenario":.string(scenario)]))
            let ready = try await f.read()
            guard ready["event"] == .string("ready"), ready["node_ref"] == .string(nodeRef),
                  let raw = ready["origin"].string, let origin = URL(string:raw), origin.host == "127.0.0.1",
                  let cert = ready["certificate_der"].string, let der = Data(base64Encoded:cert),
                  let token = ready["device_token"].string, let build = ready["build"].string else { throw FixtureFailure.protocolFailure }
            f.origin = origin; f.certificateDER = der; f.credential = try OpenVoiceDeviceCredential(pairedDeviceBearer:token); f.build = build
            return f
        } catch { await f.stop(); throw error }
    }
    private func write(_ value: OpenVoiceJSON) throws {
        let data = try value.encoded(); guard data.count <= 512 else { throw FixtureFailure.protocolFailure }
        try input.fileHandleForWriting.write(contentsOf:data + Data([10]))
    }
    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }; total += data.count; bytes.append(data)
        guard total <= 65536 && bytes.count <= 8192 else { fail(); return }
        while let i = bytes.firstIndex(of:10) {
            let line = Data(bytes[..<i]); bytes.removeSubrange(...i)
            guard let value = try? OpenVoiceWire.parse(line), let event = value["event"].string,
                  ["ready","invitation","snapshot","stopped","diagnostics"].contains(event) else { fail(); return }
            if event == "stopped" { stopped = value }
            if let p = pending { pending = nil; timer?.cancel(); timer = nil; p.resume(returning:value) }
            else if held.count < 4 { held.append(value) }
            else { fail(); return }
        }
    }
    private func fail() { timer?.cancel(); pending?.resume(throwing:FixtureFailure.protocolFailure); pending = nil }
    private func read() async throws -> OpenVoiceJSON {
        if !held.isEmpty { return held.removeFirst() }
        guard pending == nil && !exited else { throw FixtureFailure.childExited }
        return try await withCheckedThrowingContinuation { p in
            pending = p
            let deadline = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
                self?.pending?.resume(throwing:FixtureFailure.timeout); self?.pending = nil
            } }
            timer = deadline; DispatchQueue.main.asyncAfter(deadline:.now()+6,execute:deadline)
        }
    }
    func command(_ command: String) async throws -> OpenVoiceJSON {
        requestID += 1; guard requestID <= 40 else { throw FixtureFailure.protocolFailure }
        try write(.object(["command":.string(command),"request_id":.number(Double(requestID))]))
        let value = try await read()
        guard value["request_id"] == .number(Double(requestID)) else { throw FixtureFailure.protocolFailure }
        return value
    }
    func control() throws -> OpenVoiceRecipientControl {
        let http = OpenVoiceControlHTTP(timeout:4)
        var trust = OpenVoiceTestTrust(certificateDER:certificateDER)
        trust.diagnostic = { stage, result, status in
            print("SETUP_TLS stage=\(stage) result=\(result) osstatus=\(status)")
        }
        http.testTLSChallenge = trust.handler
        return try OpenVoiceRecipientControl(origin:origin,credential:credential,http:http,now:Date.init)
    }
    func pump(_ lease: OpenVoiceMediaLease) throws -> OpenVoiceMediaOwnerPump {
        let trust = OpenVoiceTestTrust(certificateDER:certificateDER)
        let socket = try OpenVoiceURLSessionSocket(origin:origin,lease:lease,now:Date(),timeout:4,clock:Date.init) { request, config, lifecycle in
            lifecycle.testTLSChallenge = trust.handler
            return openVoiceTestSystemTask(request:request,configuration:config,lifecycle:lifecycle)
        }
        return try OpenVoiceMediaOwnerPump(socket:socket,lease:lease,localCallEpoch:UUID())
    }
    func stop() async {
        if !exited {
            // Watchdogs affect only this owned child, never another compiler/session.
            let term = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
            let kill = DispatchWorkItem { [process] in if process.isRunning { Darwin.kill(process.processIdentifier,SIGKILL) } }
            DispatchQueue.main.asyncAfter(deadline:.now()+2,execute:term)
            DispatchQueue.main.asyncAfter(deadline:.now()+4,execute:kill)
            try? write(.object(["command":.string("shutdown")]))
            if !exited { await withCheckedContinuation { exitWaiter = $0 } }
            term.cancel(); kill.cancel()
        }
        timer?.cancel(); output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        XCTAssertEqual(process.terminationStatus,0,"owned actual-engine child must exit cleanly")
        guard let stopped else { XCTFail("missing actual-engine teardown acknowledgement"); return }
        for field in ["sessions","pendingJobs","pendingUpgrades","inputPCMBytes","rawBytes"] {
            XCTAssertEqual(stopped["engine"][field],.number(0),field)
        }
    }
}
#endif
