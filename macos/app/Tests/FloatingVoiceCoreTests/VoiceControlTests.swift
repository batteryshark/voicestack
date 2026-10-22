import Foundation
import Testing
import SwiftUI
import AppKit
@testable import FloatingVoiceCore
@testable import FloatingVoiceUI

@Suite(.serialized) @MainActor struct VoiceControlTests {
    func row(_ rig: Rig, p: Double = 0) -> ControlRow {
        let pill = PillModel()
        pill.update(status: rig.controller.status)
        let actions = PillActions.conversation(controller: rig.controller)
        return ControlRow(model: pill, settings: SettingsState(), actions: actions, p: p)
    }

    @Test(arguments: [0.0, 1.0]) func fullToggleAvailableAndRoutesEndThenStart(p: Double) async throws {
        let rig = Rig()
        defer { rig.controller.stop() }
        let off = try #require(row(rig, p: p).voiceControl)
        #expect(off.title == "Start voice")
        #expect(off.symbol == "power")
        off.action()
        #expect(await waitUntil { rig.controller.status.phase == "ready" && rig.controller.status.running })
        for mode in ["on", "muted", "error"] {
            if mode == "muted" { rig.controller.setMicMuted(true); rig.controller.setOutputMuted(true) }
            if mode == "error" { rig.controller.reportShortcutError("Synthetic control error") }
            let on = try #require(row(rig, p: p).voiceControl)
            #expect(on.title == "Stop voice")
            #expect(on.symbol == "power")
            on.action()
            #expect(!rig.controller.status.running && rig.input.stopped)
            #expect(await rig.controller.waitForPosts(timeout: 1))
            #expect(rig.backend.interrupts.isEmpty) // full off, never square Stop reply
            let restart = try #require(row(rig, p: p).voiceControl)
            #expect(restart.title == "Start voice")
            restart.action()
            #expect(await waitUntil { rig.controller.status.running && rig.controller.status.phase == "ready" })
            #expect(!rig.controller.status.micMuted && !rig.controller.status.outputMuted)
        }
        rig.controller.endVoice()
        #expect(await rig.controller.waitForPosts(timeout: 1))
        #expect(rig.backend.endAttempts.count == 4)
    }

    @Test func startingControlCanCancelWithoutEndAdmission() async throws {
        let gate = VoiceLifecycleTests.Gate()
        let rig = Rig(preflight: [.init(name: "gated", run: { await gate.wait() })])
        defer { gate.release(); rig.controller.stop() }
        let start = try #require(row(rig).voiceControl)
        start.action()
        #expect(await waitUntil { gate.entered })
        #expect(rig.controller.status.phase == "starting")
        let cancel = try #require(row(rig).voiceControl)
        #expect(cancel.title == "Stop voice" && cancel.help == "Stop voice (cancel startup)")
        cancel.action()
        #expect(!rig.controller.status.running)
        gate.release()
        #expect(await rig.controller.waitForPosts(timeout: 1))
        #expect(rig.backend.endAttempts.isEmpty)
    }

    @Test func productionRowsRenderOffscreenAndFit() throws {
        let discard = ImageRenderer(content: DiscardButton(textOnly: true, action: {}).fixedSize())
        #expect(try #require(discard.cgImage).width <= 56)
        let send = ImageRenderer(content: SendButton(holding: true, hotkey: "Send", textOnly: true, action: {}).fixedSize())
        #expect(try #require(send.cgImage).width <= 44)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("logs/control-clarity")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for state in ["off", "starting", "on", "muted", "error", "pending", "manual-pending"] {
            let pill = PillModel()
            var status = ConversationController.Status()
            status.running = state != "off"
            status.phase = state == "starting" ? "starting" : "ready"
            status.connection = state == "starting" ? "connecting" : "connected"
            status.micMuted = state == "muted"
            status.outputMuted = state == "muted"
            status.lastError = state == "error" ? "Synthetic error" : nil
            status.pendingSpeech = state.contains("pending")
            status.manualSend = state == "manual-pending"
            pill.update(status: status)
            for step in 0...20 {
                let p = Double(step) / 20
                let width = lerp(PillLayout.pill.width, PillLayout.cardWidth, p)
                let row = ControlRow(model: pill, settings: SettingsState(), actions: PillActions(), p: p)
                #expect(row.fixedControlsWidth <= width, "\(state) at \(p)")
                if step == 0 || step == 20 {
                    let renderer = ImageRenderer(content: row.frame(width: width, height: 44)
                        .background(PillTheme.graphite.tint).environment(\.pillTheme, PillTheme.graphite))
                    renderer.scale = 2
                    let image = try #require(renderer.cgImage)
                    #expect(image.width == Int(width * 2) && image.height == 88)
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("\(state)-\(step == 0 ? "pill" : "card").png"))
                }
            }
        }
    }
}
