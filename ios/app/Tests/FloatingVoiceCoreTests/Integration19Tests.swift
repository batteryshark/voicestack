import Foundation
import Testing
@testable import FloatingVoiceCore

@MainActor @Suite struct Integration19Tests {
    @Test func loopProbeUsesTheSameCallKitStartAndSceneOwnershipAsNormalUI() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("native/FloatingVoiceApp.swift"))
        let mode = try #require(app.split(separator: "\n").first { $0.contains("private var probeMode:") })
        #expect(!mode.contains("PhoneLoopProbe"), "loop proof must not bypass CallKit or lock-aware scene handling")
        let loop = try String(contentsOf: root.appendingPathComponent("native/PhoneLoopProbe.swift"))
        #expect(loop.contains("await model.startVoice()") && loop.contains("await model.stopVoiceByUser()"))
        let audio = try String(contentsOf: root.appendingPathComponent("native/IOSAudio.swift"))
        let activation = try #require(audio.components(separatedBy: "func activate() throws {").last?.components(separatedBy: "func activationObserved").first)
        #expect(!activation.contains("PhoneLoopProbe.enabled"), "no standalone activation escape for the loop probe")
        let adapter = try String(contentsOf: root.appendingPathComponent("native/CallCoordinator.swift"))
        #expect(adapter.contains("CXStartCallAction") && adapter.contains("didActivate audioSession"))
    }
    @Test func buildAndClosedCallLivenessFieldsRoundTripInSanitizedExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = StageDiagnostics()
        log.configure(file: directory.appendingPathComponent("stages.json"), build: 42)
        log.record(.call, .ready, audio: CaptureSnapshot([.callState: 4, .callActivation: 1, .streamBytes: 128, .streamIdleSeconds: 3]))
        let entries = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(log.export().utf8))
        #expect(entries.first?.build == 42)
        #expect(entries.first?.audio?.values["callActivation"] == 1)
        #expect(entries.first?.audio?.values["streamBytes"] == 128)
        #expect(!log.export().contains("credentialValue"))
    }
    @Test func transportLivenessAgeIsMonotonicAndCommentsRefreshIt() {
        var watch = StreamIdleWatchdog(now: 10)
        #expect(watch.age(now: 40) == 30)
        watch.received(now: 40) // every data callback includes SSE comments
        #expect(watch.age(now: 41) == 1 && !watch.expired(now: 114))
        #expect(watch.expired(now: 115))
    }
}
