import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite @MainActor struct AgentPresentationTests {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    @Test func fixedLabelAndGeneratedAccessorMatchTheSingleSharedConstant() throws {
        let shared = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shared/presentation.json"))) as! [String: String]
        #expect(AgentPresentation.name == "Agent" && AgentPresentation.name == shared["assistantLabel"])
        #expect(AgentPresentation.roleLabel("Chief") == "Agent")
        #expect(AgentPresentation.roleLabel("You") == "You")
    }
    @Test func speakingThinkingAndCallDisplayUseAgent() throws {
        let surface = VoiceSurface()
        var status = ConversationController.Status(); status.running = true; status.speaking = true
        surface.updateCapture(.running, owner: surface.binding); surface.update(status: status, owner: surface.binding)
        #expect(surface.state == "Agent speaking")
        status.speaking = false; status.busy = true; surface.update(status: status, owner: surface.binding)
        #expect(surface.state == "Agent thinking")
        let native = try String(contentsOf: root.appendingPathComponent("native/CallCoordinator.swift"))
        #expect(native.components(separatedBy: "AgentPresentation.name").count == 6, "Outgoing handle and incoming/outgoing caller+handle use the same label")
        #expect(!native.contains("value: \"Chief\"") && !native.contains("localizedCallerName = \"Chief\""))
    }
    @Test func noDisplayNameSettingOrPersistenceAndNoRouteShim() throws {
        let main = try String(contentsOf: root.appendingPathComponent("native/FloatingVoiceApp.swift"))
        #expect(!main.contains("settings.assistantName") && !main.contains("assistantNameDraft") && !main.contains("setAssistantName"))
        #expect(!main.contains("assistant.displayName"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("native/VoiceTurnRouteShim.swift").path))
    }
}
