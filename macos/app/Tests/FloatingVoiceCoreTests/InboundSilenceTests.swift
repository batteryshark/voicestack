import Foundation
import Testing
@testable import FloatingVoiceCore

/// Incoming messages are shown, never spoken. Only the target chief's assistant replies reach speech, and their
/// fenced detail is stripped. These drive the real event route with fakes: no session, network, mic, audio or window.
@Suite(.serialized) @MainActor struct InboundSilenceTests {
    private func inbound(_ text: String, id: String, target: String = "ses_A") -> ServerEvent {
        ServerEvent(type: "session.inbox.enqueued",
                    data: ["sessionID": target, "inboxID": id,
                           "item": ["type": "user", "delivery": "steer", "payload": ["text": text]]])
    }

    private func inboundCount(_ captions: [CaptionEvent]) -> Int {
        captions.filter { if case .inbound = $0 { return true }; return false }.count
    }

    /// Every inbound sender renders as a caption while preparing and playing nothing.
    @Test(arguments: [
        ("lead", "From the Dream Studio lead: the build is ready."),
        ("docket", "Docket timer fired: review the deadline."),
        ("canvas", "[Agent Canvas] Selected: review first."),
        ("voice-ended", "[voice] ended"),
        ("a2a", "[a2a] Message from another AI agent: session local/ses_SOURCE (trace a2a_test, hop 1).\nBody text."),
    ])
    func externalInboundRendersAndNeverSpeaks(_ sender: String, _ text: String) async {
        let rig = Rig()
        var captions: [CaptionEvent] = []
        rig.controller.onCaption = { captions.append($0) }
        await rig.start()
        #expect(rig.synth.prepared.isEmpty)

        rig.controller.handle(inbound(text, id: "msg_" + sender))
        #expect(inboundCount(captions) == 1, "\(sender) should still be shown")
        // Let any incorrect asynchronous speech path start before asserting its silence.
        try? await Task.sleep(for: .milliseconds(120))

        #expect(rig.synth.prepared.isEmpty, "\(sender) must never be synthesized")
        #expect(rig.output.plays.isEmpty, "\(sender) must never be played")
        #expect(rig.output.stops == 0)
        #expect(rig.backend.interrupts.isEmpty)
        #expect(rig.controller.status.running) // incoming lifecycle-looking text is never a control action
        #expect(!captions.contains { if case .chiefQueued = $0 { return true }; return false })
        #expect(!captions.contains { if case .chiefStarted = $0 { return true }; return false })
        rig.controller.stop()
    }

    /// An update arriving mid-reply queues no speech and leaves the reply playing, untouched.
    @Test func inboundDuringPlaybackAddsNoSpeechAndLeavesTheReplyAlone() async {
        let rig = Rig(duration: 0.6)
        var captions: [CaptionEvent] = []
        rig.controller.onCaption = { captions.append($0) }
        await rig.start()
        let reply = "The chief replies here with enough words to be spoken aloud."
        rig.reply(id: "block", reply)
        #expect(await waitUntil { !rig.output.playing.isEmpty })
        let prepared = rig.synth.prepared
        let plays = rig.output.plays
        let stops = rig.output.stops
        #expect(prepared == [reply])

        rig.controller.handle(inbound("From the Dream Studio lead: quoting the lead.", id: "msg_1"))
        rig.controller.handle(inbound("Docket timer fired: keep going.", id: "msg_2"))
        rig.controller.handle(inbound("[Agent Canvas] continuing.", id: "msg_3"))
        #expect(await waitUntil { inboundCount(captions) == 3 })
        try? await Task.sleep(for: .milliseconds(150))

        #expect(rig.synth.prepared == prepared, "no sentence may be prepared from an inbound update")
        #expect(rig.output.stops == stops, "an inbound update must not stop playback")
        #expect(rig.output.plays.map(\.text) == plays.map(\.text))
        #expect(rig.output.plays.allSatisfy { $0.outcome != "stopped" }, "the existing reply keeps playing")
        rig.controller.stop()
    }

    /// Non-target text events are dropped before speech, even while the target is idle.
    @Test func nonTargetAssistantTextIsNeverSpoken() async {
        let rig = Rig()
        await rig.start()
        let other = "Another session is talking here at enough length to be spoken aloud."
        rig.backend.send("session.text.started", "ses_B", ["assistantMessageID": "b", "ordinal": 0])
        rig.backend.send("session.text.delta", "ses_B", ["assistantMessageID": "b", "ordinal": 0, "delta": other])
        rig.backend.send("session.text.ended", "ses_B", ["assistantMessageID": "b", "ordinal": 0, "text": other])
        // A target reply afterwards proves the stream was processed, so the absence above is not just timing.
        let mine = "The chief replies here with enough words to be spoken aloud."
        rig.reply("ses_A", id: "a", mine)
        #expect(await waitUntil { !rig.synth.prepared.isEmpty })
        #expect(rig.synth.prepared == [mine])
        rig.controller.stop()
    }

    /// A target reply of only fenced detail stays silent; normal prose still speaks.
    @Test func fencedOnlyTargetReplyIsSilentAndProseSpeaks() async {
        let rig = Rig()
        await rig.start()
        let fenced = """
        ```md
        | project | next |
        |---|---|
        | Voicestack | review |
        ```
        """
        rig.reply("ses_A", id: "fenced", fenced)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.synth.prepared.isEmpty, "fenced-only detail must not be narrated")
        #expect(rig.output.plays.isEmpty)

        let prose = "Here is the spoken part with enough words to be spoken aloud."
        rig.reply("ses_A", id: "prose", prose)
        #expect(await waitUntil { rig.synth.prepared == [prose] })

        // Prose plus a fenced detail block: only the prose is spoken.
        let mixed = "The summary goes here in enough words to be spoken aloud.\n```md\n| project | next |\n|---|---|\n```"
        rig.reply("ses_A", id: "mixed", mixed)
        #expect(await waitUntil { rig.synth.prepared == [prose, "The summary goes here in enough words to be spoken aloud."] })
        rig.controller.stop()
    }
}
