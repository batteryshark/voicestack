import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct SendModeTests {
    func say(_ rig: Rig, _ text: String) async {
        rig.transcript = text
        rig.speak()
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    func manualRig(busyDelivery: BusyDelivery = .queue, duration: TimeInterval = 0.25) async -> Rig {
        let rig = Rig(busyDelivery: busyDelivery, duration: duration)
        rig.controller.setSendMode(.manual)
        await rig.start()
        #expect(rig.controller.status.manualSend)
        return rig
    }

    @Test func manualHoldsEverythingUntilSend() async {
        let rig = await manualRig()
        await say(rig, "First, check the build.")
        await say(rig, "Then tell me what failed.")
        try? await Task.sleep(nanoseconds: 700_000_000) // well past the hold (200 ms) and merge (300 ms) timers
        #expect(rig.backend.prompts.isEmpty, "complete sentences and pauses never post in manual mode")
        #expect(rig.controller.status.holding == "First, check the build. Then tell me what failed.")
        rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0] == .init(session: "ses_A", text: "[voice] First, check the build. Then tell me what failed.", delivery: nil))
        #expect(rig.controller.status.holding == nil)
        rig.controller.send() // nothing held: no-op
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.backend.prompts.count == 1)
        rig.controller.stop()
    }

    @Test func sendMidUtteranceIncludesIt() async {
        let rig = await manualRig()
        await say(rig, "Look at the logs.")
        rig.transcript = "And the crash report."
        rig.input.frames(30, voiced: true) // still talking
        rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] Look at the logs. And the crash report.")
        rig.controller.stop()
    }

    @Test func busyManualDoesNotFlushAtTurnEndAndSendUsesBusyDelivery() async {
        let rig = await manualRig()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "When you finish, check the tests.")
        rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].delivery == .queue)
        await say(rig, "And the docs.")
        rig.backend.send("session.execution.succeeded", "ses_A")
        try? await Task.sleep(nanoseconds: 700_000_000)
        #expect(rig.backend.prompts.count == 1, "the turn ending does not post in manual mode")
        rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 2 })
        #expect(rig.backend.prompts[1] == .init(session: "ses_A", text: "[voice] And the docs.", delivery: nil))
        rig.controller.stop()
    }

    @Test func stopInterruptsButKeepsHoldingForSend() async {
        let rig = await manualRig()
        rig.backend.send("session.execution.started", "ses_A")
        #expect(await waitUntil { rig.controller.status.busy })
        await say(rig, "Wait, that's the wrong file.")
        await rig.controller.stopReply()
        #expect(rig.backend.interrupts == ["ses_A"])
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(rig.backend.admits.isEmpty && rig.backend.prompts.isEmpty, "only Send sends in manual mode")
        #expect(rig.controller.status.holding == "Wait, that's the wrong file.")
        rig.controller.stop()
    }

    @Test func switchingBackToAutoPostsWhatIsHeld() async {
        let rig = await manualRig()
        await say(rig, "Keep this for later.")
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(rig.backend.prompts.isEmpty)
        rig.controller.setSendMode(.auto)
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] Keep this for later.")
        #expect(!rig.controller.status.manualSend)
        // Auto again: a complete sentence posts by itself.
        await say(rig, "Now this one goes at once.")
        #expect(await waitUntil { rig.backend.prompts.count == 2 })
        rig.controller.stop()
    }

    @Test func micMuteKeepsHeldWordsInManualMode() async {
        let rig = await manualRig()
        await say(rig, "Hold on to this.")
        rig.controller.setMicMuted(true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(rig.backend.prompts.isEmpty)
        #expect(rig.controller.status.holding == "Hold on to this.")
        rig.controller.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        rig.controller.stop()
    }

    @Test func bargeInWorksInManualMode() async {
        let rig = await manualRig(duration: 1.0)
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.output.playing == [one] })
        await say(rig, "Hang on.")
        #expect(rig.output.plays.first?.outcome == "stopped")
        #expect(rig.backend.prompts.isEmpty)
        rig.controller.stop()
    }

    @Test func sendModeAndHotkeyAreSettings() async throws {
        let dir = tempDir()
        let appFile = dir + "/settings.json"
        let rig = Rig(appFile: appFile)
        await rig.start()
        try await rig.controller.apply(.sendMode(.manual))
        try await rig.controller.apply(.sendHotkey("ctrl+option+return"))
        await #expect(throws: (any Error).self) { try await rig.controller.apply(.sendHotkey("banana")) }
        let stored = SettingsStore.readJSON(appFile) ?? [:]
        #expect(stored["sendMode"] as? String == "manual" && stored["sendHotkey"] as? String == "ctrl+option+return")
        #expect(rig.controller.app.sendMode == .manual && rig.controller.status.manualSend)
        let parsed = SettingsStore.parseApp(stored)
        #expect(parsed.sendMode == .manual && parsed.sendHotkey == "ctrl+option+return")
        rig.controller.stop()
    }

    @Test func hotkeyParsing() {
        let h = Hotkey.parse("ctrl+option+space")
        #expect(h == Hotkey(keyCode: 49, modifiers: 0x1800, display: "⌃⌥Space"))
        #expect(Hotkey.parse("Cmd + Shift + Return")?.display == "⇧⌘Return")
        #expect(Hotkey.parse("ctrl+alt+s")?.keyCode == 1)
        #expect(Hotkey.parse("space") == nil, "a bare key would swallow typing")
        #expect(Hotkey.parse("ctrl+hyper+space") == nil)
        #expect(Hotkey.parse("ctrl+option+f13") == nil)
        #expect(Hotkey.presets.allSatisfy { Hotkey.parse($0) != nil })
        #expect(Hotkey.parse(Hotkey.defaultSpec)?.display == "⌃⌥⌘Space")
        #expect(AppSettings().sendHotkey == "ctrl+option+cmd+space")
    }
}
