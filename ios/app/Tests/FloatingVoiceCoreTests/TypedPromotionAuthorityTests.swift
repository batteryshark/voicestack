import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite @MainActor struct TypedPromotionAuthorityTests {
    let question = "Question", raw = "## Ready\n\nUNHEARD continuation."
    func records() throws -> [Data] {
        let values: [[String: Any]] = [
            ["id":"question", "type":"user", "text":question, "sender":["kind":"principal", "label":"You"]],
            ["id":"reply", "type":"assistant", "content":[["type":"text", "text":raw]]]
        ]
        return try values.map { try JSONSerialization.data(withJSONObject: $0) }
    }
    func replyBeforeAcknowledgement() throws -> VoiceSurface {
        let surface = VoiceSurface(), owner = surface.binding
        var status = ConversationController.Status()
        status.running = true; status.phase = "ready"; status.connection = "connected"
        surface.update(status: status, owner: owner)
        surface.beginTypedTurn(question, owner: owner)
        surface.update(records: try records(), connection: "connected", active: true)
        surface.handle(.chiefQueued(label: "reply:0", text: "Ready"), owner: owner)
        surface.handle(.chiefQueued(label: "reply:0", text: "UNHEARD continuation."), owner: owner)
        surface.handle(.chiefStarted(label: "reply:0", text: "Ready"), owner: owner)
        status.speaking = true; surface.update(status: status, owner: owner)
        return surface
    }
    func reply(_ surface: VoiceSurface) throws -> VoiceLogTurn {
        try #require(surface.log.turns.first { $0.id == "reply" })
    }

    @Test func typedAcknowledgementAfterReplyStartsCannotApproveThatReply() throws {
        let surface = try replyBeforeAcknowledgement(), owner = surface.binding
        let before = try reply(surface)
        #expect(before.spoken == "Ready" && before.spokenBlocks == [.paragraph("Ready")])
        surface.typedPosted(question, owner: owner)
        surface.update(records: try records(), connection: "connected", active: false)
        surface.handle(.chiefQueued(label: "reply:0", text: "UNHEARD continuation."), owner: owner)
        surface.handle(.chiefEnded(label: "reply:0", text: "Ready", outcome: "played"), owner: owner)
        let after = try reply(surface)
        #expect(surface.pill.status.running && surface.pill.status.speaking && !surface.pill.status.outputMuted)
        #expect(after.spoken == before.spoken && after.details == before.details)
        #expect(after.spokenBlocks == [.paragraph("Ready")])
        #expect(after.markdownSources.isEmpty)
    }

    @Test(arguments: ["typed", "voice", "off", "mute"])
    func onlyOffAndMuteApproveEarlierReply(_ boundary: String) throws {
        let surface = try replyBeforeAcknowledgement(), owner = surface.binding
        surface.typedPosted(question, owner: owner)
        #expect(try reply(surface).spokenBlocks == [.paragraph("Ready")])
        switch boundary {
        case "typed": surface.beginTypedTurn("A genuinely newer question", owner: owner)
        case "voice": surface.handle(.youStarted, owner: owner)
        default:
            var status = surface.pill.status
            if boundary == "off" { status.running = false } else { status.outputMuted = true }
            surface.update(status: status, owner: owner)
        }
        let expected: [MarkdownBlock] = ["off", "mute"].contains(boundary) ? [.heading(2, "Ready"), .paragraph("UNHEARD continuation.")] : [.paragraph("Ready")]
        #expect(try reply(surface).spokenBlocks == expected)
    }

    @Test func genericBookkeepingAndCaptionRefreshDoNotGrantApproval() throws {
        var log = ConversationVoiceLog(); log.setVoice(running: true, muted: false)
        log.update(records: try records())
        log.handle(.chiefStarted(label: "reply:0", text: "Ready"), userText: "")
        log.beginUser()
        log.handle(.youFinal(question), userText: question)
        log.handle(.posted(question), userText: question)
        log.update(records: try records())
        #expect(log.turns.first { $0.id == "reply" }?.spokenBlocks == [.paragraph("Ready")])
        log.handle(.youStarted, userText: "")
        #expect(log.turns.first { $0.id == "reply" }?.spokenBlocks == [.paragraph("Ready")])
    }

    @Test func staleBindingCannotApproveThroughTypedOrVoiceStart() throws {
        let surface = try replyBeforeAcknowledgement(), stale = UUID()
        surface.beginTypedTurn("Stale", owner: stale)
        surface.handle(.youStarted, owner: stale)
        #expect(try reply(surface).spokenBlocks == [.paragraph("Ready")])
    }

    @Test func actualVADOnsetThenYeahBackchannelNeverApprovesUnstartedSource() async throws {
        let backend = FakeBackend(), input = FakeInput(), output = FakeOutput(duration: 60)
        var app = AppSettings(); app.target = "ses_authority"
        var voice = VoiceConfig(); voice.pauseMs = 200; voice.onsetGraceMs = 0; voice.duplex = true
        var recognitions: [FakeRecognition] = [], outcomes: [UtteranceOutcomeDiagnostic] = []
        let controller = ConversationController(settings: LoadedSettings(app: app, voice: voice, voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent"),
            backend: backend, synth: FakeSynth(), output: output, input: input, makeRecognition: { callbacks in
                let recognition = FakeRecognition(callbacks, transcript: "yeah")
                recognitions.append(recognition); return recognition
            })
        let surface = VoiceSurface()
        let owner = surface.replaceBinding(target: TargetLease(sessionID: app.target, generation: "initial"))
        controller.onStatus = { surface.update(status: $0, owner: owner) }
        controller.onCaption = { surface.handle($0, owner: owner) }
        controller.outcomeDiagnostics = UtteranceOutcomeLog(write: { value, _ in outcomes.append(value) })
        await controller.start(); defer { controller.stop() }
        try #require(await waitUntil { controller.status.phase == "ready" })
        surface.update(records: Array(try records().suffix(1)), connection: "connected", active: true)
        controller.consumeNarration(NarrationUpdate(blockKey: "reply:0", suffix: "Ready", context: "Ready", silentUTF16: 0, final: true))
        try #require(await waitUntil { output.playing == ["Ready"] })
        controller.consumeNarration(NarrationUpdate(blockKey: "reply:0", suffix: " UNHEARD continuation.", context: "Ready UNHEARD continuation.", silentUTF16: 0, final: true))
        #expect(controller.speaker.queuedCount == 1)
        let stops = output.stops
        input.frames(8, voiced: true) // Real TurnTaker onset emits youStarted BEFORE ASR.
        let recognition = try #require(recognitions.first)
        #expect(try reply(surface).spokenBlocks == [.paragraph("Ready")])
        #expect(output.playing == ["Ready"] && output.stops == stops)
        recognition.callbacks.live("yeah")
        input.frames(10, voiced: true); input.frames(10, voiced: false)
        try #require(await waitUntil { outcomes.contains { $0.outcome == .backchannel } })
        #expect(backend.prompts.isEmpty && backend.admits.isEmpty && backend.interrupts.isEmpty)
        #expect(output.playing == ["Ready"] && output.stops == stops && !output.cutInPaused)
        #expect(controller.status.running && !controller.status.outputMuted)
        #expect(try reply(surface).spoken == "Ready")
        #expect(try reply(surface).spokenBlocks == [.paragraph("Ready")])
        #expect(try reply(surface).markdownSources.isEmpty)
    }
}
