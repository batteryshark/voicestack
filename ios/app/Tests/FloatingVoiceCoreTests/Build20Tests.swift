import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite @MainActor struct Build20Tests {
    private func listening(_ surface: VoiceSurface) {
        var s = ConversationController.Status(); s.running = true; s.phase = "ready"; s.connection = "connected"
        surface.update(status: s, owner: surface.binding)
        surface.updateCapture(.running, owner: surface.binding)
        surface.update(records: [], connection: "connected", active: false)
    }
    @Test func streamDropDuringUtteranceDoesNotPrepareOrStopListening() {
        let surface = VoiceSurface(); listening(surface)
        var s = surface.pill.status; s.hearing = true; s.connection = "reconnecting"; s.phase = "starting"
        surface.update(status: s, owner: surface.binding)
        surface.update(records: [], connection: "reconnecting", active: false)
        surface.preparing = true // A transport preparation flag cannot override real capture.
        #expect(surface.state == "Listening")
        #expect(PrincipalError.message("Network connection lost (-1005)", captureRunning: true) == nil)
    }
    @Test func quietReconnectDelayAndClear() {
        var clock = 0.0
        let surface = VoiceSurface(now: { clock }); listening(surface)
        surface.update(records: [], connection: "reconnecting", active: false)
        clock = 4999; surface.tick(); #expect(surface.connectionNotice == nil && surface.state == "Listening")
        surface.update(records: [], connection: "connected", active: false)
        clock = 6000; surface.tick(); #expect(surface.connectionNotice == nil)
        surface.update(records: [], connection: "reconnecting", active: false)
        clock = 11000; surface.tick(); #expect(surface.connectionNotice == "Connection lost")
        surface.update(records: [], connection: "connected", active: false)
        #expect(surface.connectionNotice == nil)
    }
    @Test func controllerReconnectAlsoHasFiveSecondGraceAndCannotBeClearedByAStaleBackendLabel() {
        var clock = 0.0
        let surface = VoiceSurface(now: { clock }); listening(surface)
        var status = surface.pill.status; status.connection = "reconnecting"; status.phase = "starting"
        surface.update(status: status, owner: surface.binding)
        surface.update(records: [], connection: "connected", active: false)
        clock = 4999; surface.tick(); #expect(surface.connectionNotice == nil && surface.state == "Listening")
        clock = 5000; surface.tick(); #expect(surface.connectionNotice == "Connection lost")
        status.connection = "connected"; status.phase = "ready"; surface.update(status: status, owner: surface.binding)
        #expect(surface.connectionNotice == nil)
    }
    @Test func routeWithoutRepairKeepsListeningAndRepairIsBriefAndTruthful() {
        let surface = VoiceSurface(); listening(surface)
        // Native route notifications that do not repair capture publish no capture-state change.
        surface.update(status: surface.pill.status, owner: surface.binding)
        #expect(surface.state == "Listening")
        surface.updateCapture(.repairing, owner: surface.binding)
        #expect(surface.state == "Switching audio…")
        surface.updateCapture(.running, owner: surface.binding)
        #expect(surface.state == "Listening")
        surface.updateCapture(.failed, owner: surface.binding)
        #expect(surface.state == "Microphone stopped · try Start voice" && !surface.captureRunning)
        surface.updateCapture(.running, owner: UUID())
        #expect(!surface.captureRunning)
    }
    @Test func stoppedVoiceReportsConnectionLossImmediatelyWithoutTechnicalText() {
        let surface = VoiceSurface(); listening(surface)
        surface.updateCapture(.off, owner: surface.binding)
        surface.update(records: [], connection: "reconnecting", active: false)
        #expect(surface.connectionNotice == "Connection lost")
        #expect(PrincipalError.message("Network connection lost -1005", captureRunning: false) == "Connection lost")
    }
    @Test func nativeControlsAreDeliberateAndKeepTechnicalStateOutOfNormalScreens() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("native/FloatingVoiceApp.swift"))
        let main = try #require(source.components(separatedBy: "struct VoiceMainView: View {").last?.components(separatedBy: "struct HistoryView: View {").first)
        #expect(!main.contains("Toggle(") && !main.contains("state.rawValue") && !main.contains("status.line"))
        #expect(main.contains("callButton(\"Mute mic\"") && main.contains("callButton(\"Mute voice\"") && main.contains("voice.speaker"))
        let audio = try String(contentsOf: root.appendingPathComponent("native/IOSAudio.swift"))
        #expect(!audio.contains("proximityStateDidChangeNotification") && !audio.contains("proximityChanged"))
        #expect(audio.contains("currentPhoneRoute == .phone"))
        let routeSwitch = try String(contentsOf: root.appendingPathComponent("app/Sources/FloatingVoiceCore/LiveRouteSwitch.swift"))
        #expect(audio.contains("transaction.toggle(active: active, mayRunMedia: mayRunMedia"))
        #expect(routeSwitch.contains("current.isBuiltIn ? .allowed : .externalRoute") && routeSwitch.contains("policy.explicitOverride"))
        #expect(!audio.contains("engine.connect(input,") && !audio.contains("engine.connect(engine.inputNode,"))
        #expect(audio.contains("SpeakerRoutePreference.save(newValue)"), "Use the merged voice-turns persisted default")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("native/VoiceTurnRouteShim.swift").path))
        let controller = try String(contentsOf: root.appendingPathComponent("app/Sources/FloatingVoiceCore/Controller.swift"))
        #expect(!controller.contains("PlaybackEchoGuard") && !controller.contains("minimumThreshold"), "No competing echo/barge-in admission policy")
    }
}
