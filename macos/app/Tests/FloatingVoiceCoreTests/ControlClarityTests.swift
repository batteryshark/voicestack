import Foundation
import Testing
import SwiftUI
import AppKit
@testable import FloatingVoiceCore
@testable import FloatingVoiceUI

@Suite(.serialized) @MainActor struct ControlClarityTests {
    var output: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("logs/control-clarity")
    }
    func top(_ pill: PillModel, _ actions: PillActions) -> CardTop {
        CardTop(model: pill, settings: SettingsState(), content: CardContent(pill), actions: actions)
    }

    @Test func actualHeaderReplyAndMutesKeepTheirOwnScope() async throws {
        let rig = Rig(), pill = PillModel()
        defer { rig.controller.stop() }
        rig.controller.onStatus = { pill.update(status: $0) }
        await rig.start()
        let actions = PillActions.conversation(controller: rig.controller)
        func row() -> ControlRow { ControlRow(model: pill, settings: SettingsState(), actions: actions, p: 1) }
        #expect(row().micControl.title == "Mute mic")
        #expect(row().outputControl.title == "Mute agent")
        row().outputControl.action()
        #expect(row().outputControl.title == "Unmute agent")
        row().micControl.action()
        #expect(row().micControl.title == "Unmute mic")
        row().micControl.action()
        #expect(!rig.controller.status.micMuted && rig.controller.status.outputMuted)
        #expect(row().voiceControl?.symbol == "power")
        let reply = try #require(top(pill, actions).replyControl)
        #expect(reply.title == "Stop reply")
        reply.action()
        #expect(await waitUntil { rig.backend.interrupts.count == 1 })
        #expect(rig.controller.status.running && !rig.input.stopped)
        #expect(rig.backend.endAttempts.isEmpty)
        row().voiceControl?.action()
        #expect(!rig.controller.status.running && top(pill, actions).replyControl == nil)
        #expect(await rig.controller.waitForPosts(timeout: 1))
    }

    @Test func sharedUnsentActionsStillSendOrDiscardOnlyDrafts() async {
        let rig = Rig()
        defer { rig.controller.stop() }
        await rig.start()
        rig.controller.setSendMode(.manual)
        let actions = PillActions.conversation(controller: rig.controller)
        rig.controller.composer.utterance("Neutral unsent draft.")
        #expect(rig.controller.status.pendingSpeech)
        actions.discard()
        #expect(!rig.controller.status.pendingSpeech && rig.backend.prompts.isEmpty)
        rig.controller.composer.utterance("Neutral sent draft.")
        actions.send()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        actions.discard()
        #expect(rig.backend.prompts.count == 1 && rig.controller.status.running)
    }

    func model(_ state: String) -> PillModel {
        let pill = PillModel(now: { 1000 })
        var s = ConversationController.Status()
        s.running = state != "off"; s.phase = state == "starting" ? "starting" : "ready"
        s.connection = "connected"; s.target = "ses_neutral"; s.targetTitle = "A neutral session title that is deliberately long"
        s.micMuted = state == "muted" || state == "manual-pending"
        s.outputMuted = s.micMuted
        s.manualSend = state == "manual-pending"; s.pendingSpeech = s.manualSend
        if s.manualSend { s.holding = "A neutral draft, still waiting for Send." }
        if state == "error" { s.lastError = "Example connection error. Check the connection." }
        if state == "notice" { s.notice = "A neutral status notice that is deliberately long" }
        if state == "warmup" { s.warmingSpeech = true }
        pill.update(status: s)
        pill.handle(.youFinal("Please summarize the next steps."))
        if state != "no-agent" { pill.handle(.chiefQueued(label: "neutral", text: "The next step is ready when you are.")) }
        if state == "countdown" { pill.handle(.countdown(totalMs: 3000, elapsedMs: 0, hold: false)) }
        return pill
    }

    func root(_ pill: PillModel) -> some View {
        let motion = PillMotion(); motion.snap(pill)
        return PillRootView(model: pill, settings: SettingsState(), motion: motion, actions: PillActions())
            .frame(width: motion.size.width, height: motion.size.height)
            .environment(\.pillTheme, PillTheme.graphite)
            .background(PillTheme.graphite.materialWash)
            .clipShape(RoundedRectangle(cornerRadius: PillLayout.radius))
    }
    func png<V: View>(_ view: V, _ name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent(name + ".png"))
        return image
    }

    @Test func completeProductionViewsAndPhoneVisual() throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        #expect(PillLayout.top + PillLayout.header + PillLayout.headerGap == 40)
        #expect(PillLayout.header >= PillLayout.button)
        let captionStart = PillLayout.top + PillLayout.header + PillLayout.headerGap
        #expect(PillLayout.top >= 0 && PillLayout.top + PillLayout.button <= captionStart)
        let power = ImageRenderer(content: VoiceToggleButton(status: ConversationController.Status(), width: 28, action: {}))
        #expect(try #require(power.cgImage).width == 28)
        #expect(try #require(power.cgImage).height == 28)
        for (agent, width) in [(false, 82.0), (true, 110.0)] {
            let mute = ImageRenderer(content: MuteButton(muted: true, agent: agent, expanded: true, width: width, action: {}))
            let image = try #require(mute.cgImage)
            #expect(image.width == Int(width) && image.height == 28)
        }
        // Intrinsic label widths, not a pretend pixel/hardware hit test.
        let mic = ImageRenderer(content: Text("Unmute mic").font(.system(size: 11.5, weight: .semibold)))
        let agent = ImageRenderer(content: HStack(spacing: 4) {
            Image(systemName: "speaker.slash.fill").font(.system(size: 12, weight: .semibold))
            Text("Unmute agent").font(.system(size: 11.5, weight: .semibold))
        })
        let micWidth = try #require(mic.cgImage).width
        let agentWidth = try #require(agent.cgImage).width
        print("Measured expanded labels: mic=\(micWidth), agent=\(agentWidth)")
        #expect(micWidth + 12 <= 82)
        #expect(agentWidth + 12 <= 110)
        for state in ["on", "muted", "manual-pending", "error", "countdown", "notice", "warmup", "off", "starting", "no-agent"] {
            let pill = model(state)
            let image = try png(root(pill), "full-" + state)
            #expect(image.width == 720)
            let header = top(pill, PillActions())
            let headerImage = ImageRenderer(content: header.frame(width: PillLayout.cardWidth))
            #expect(try #require(headerImage.cgImage).width == 360)
            let reply = ImageRenderer(content: ReplyStopButton(action: {}).fixedSize())
            let replyImage = try #require(reply.cgImage)
            let replyWidth = replyImage.width
            #expect(replyImage.height == 28)
            // Header actions have fixed intrinsic sizes; the title yields space, never the reply label.
            let cue = ImageRenderer(content: CountdownCue(wait: .countdown(seconds: 3, fraction: 1), action: {}).fixedSize())
            let cueWidth = try #require(cue.cgImage).width
            #expect(replyWidth + cueWidth + 28 + 6 + 4 * 7 + 4 < 328)
            for step in 0...40 {
                let p = Double(step) / 40
                let row = ControlRow(model: pill, settings: SettingsState(), actions: PillActions(), p: p)
                #expect(row.fixedControlsWidth <= lerp(182, 360, p), "\(state): \(p)")
            }
        }
        let compact = PillModel(); var s = ConversationController.Status()
        s.running = true; s.phase = "ready"; s.connection = "connected"; compact.update(status: s)
        let phone = VStack(alignment: .leading, spacing: 20) {
            Text("Voicestack controls").font(.system(size: 23, weight: .semibold))
            root(model("on"))
            HStack { Spacer(); root(compact); Spacer() }
            VStack(alignment: .leading, spacing: 12) {
                Text("Power ends the whole voice session.")
                Text("Stop reply interrupts only the current reply. Voice stays on.")
                Text("Mic and agent voice mute independently.")
            }.font(.system(size: 17, weight: .medium))
        }
        .foregroundStyle(PillTheme.graphite.primary)
        .padding(20).frame(width: 400).background(PillTheme.graphite.materialWash)
        _ = try png(phone, "phone-controls")
    }

    @Test func offAndCollapsedRenderingRetainNeutralWords() throws {
        let r = PillRig()
        r.pill.handle(.youFinal("Neutral words remain stored."))
        let before = r.pill.you.text
        r.advance(r.pill.shrinkAfterMs + 1)
        #expect(!r.pill.expanded && r.pill.you.text == before)
        r.set { $0 = ConversationController.Status() }
        let renderer = ImageRenderer(content: root(r.pill))
        #expect(renderer.cgImage != nil && r.pill.you.text == before)
    }
}
