import Foundation
import Testing
@testable import FloatingVoiceCore
@testable import FloatingVoiceUI

/// The assistant's fixed turn label ("Agent") on the caption and in the thinking text, and that an old settings file
/// still carrying the removed `assistantName` key loads without error (and is not rewritten).
@Suite struct AssistantLabelTests {
    @MainActor @Test func labelAndThinkingTextUseTheConstant() {
        #expect(AssistantLabel.name == "Agent")
        let pill = PillModel()
        #expect(pill.assistantName == AssistantLabel.name)
        #expect(pill.assistantLabel == "AGENT")
        #expect(pill.assistantLabel == AssistantLabel.name.uppercased())

        var clock = 1_000_000.0
        let thinking = PillModel(now: { clock })
        var status = ConversationController.Status()
        status.running = true
        status.phase = "ready"
        status.busy = true
        thinking.update(status: status)
        thinking.handle(.posted("Check the build."))
        clock += 1000 // past the brief "Sent" beat
        thinking.tick()
        #expect(thinking.wait == .thinking)
        #expect(CardContent(thinking).chiefString == "\(AssistantLabel.name) is thinking…")
    }

    @Test func oldSettingsWithAssistantNameLoadWithoutError() throws {
        let dir = tempDir()
        let app = dir + "/settings.json"
        let text = #"{"target": "ses_old", "assistantName": "Ava"}"# + "\n"
        try text.write(toFile: app, atomically: true, encoding: .utf8)
        let env = ["FV_SETTINGS": app, "FV_AGENT_VOICE_SETTINGS": dir + "/none.json", "HOME": dir]
        let loaded = SettingsStore.load(env: env)
        #expect(loaded.app.target == "ses_old")
        #expect(!loaded.appFileUnreadable)
        // Loading never writes: the unknown key stays in the file untouched.
        #expect(try String(contentsOfFile: app, encoding: .utf8) == text)
    }
}
