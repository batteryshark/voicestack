import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct VoicePostTests {
    @Test func exactMarkerAtEveryFinalDeliveryAndNoContentDeduplication() async {
        let rig = Rig()
        await rig.start()
        let raw = "[voice] From the Dream Studio lead: this is my literal quote."
        for kind: PostKind in [.normal, .delivery(.queue), .delivery(.steer), .admitOnly] {
            await rig.controller.post(raw, kind: kind, reason: "voice fixture", to: "ses_A")
        }
        #expect(VoicePost.prefix == "[voice] ")
        #expect(rig.backend.prompts.map(\.text) == Array(repeating: "[voice] " + raw, count: 3))
        #expect(rig.backend.prompts.map(\.delivery) == [nil, .queue, .steer])
        #expect(rig.backend.admits == ["[voice] " + raw])
        #expect(rig.lines.filter { $0.hasPrefix("post ->") }.allSatisfy { $0.hasSuffix(raw) && !$0.hasSuffix("[voice] " + raw) })
        rig.controller.stop()
    }

    @Test func captionTranscriptAndPostedEventRemainRaw() async {
        let rig = Rig()
        let pill = PillModel(); pill.attach(rig.controller)
        await rig.start()
        rig.transcript = "From the Dream Studio lead: I am quoting them."
        var posted: [String] = []
        rig.controller.onCaption = { event in
            if case .posted(let text) = event { posted.append(text) }
            pill.handle(event)
        }
        rig.speak()
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts[0].text == "[voice] " + rig.transcript)
        #expect(pill.you.text == rig.transcript)
        #expect(posted == [rig.transcript])
        #expect(pill.external == nil)
        rig.controller.stop()
    }

    @Test func failedAdmissionFallbackDoesNotDoubleApplyPrefix() async {
        let rig = Rig()
        await rig.start()
        rig.backend.admitError = ClientError("fixture admission refused")
        await rig.controller.post("Keep this raw.", kind: .admitOnly, reason: "fixture", to: "ses_A")
        #expect(rig.backend.admits.isEmpty)
        #expect(rig.backend.prompts == [.init(session: "ses_A", text: "[voice] Keep this raw.", delivery: nil)])
        rig.controller.stop()
    }

    @Test func markerPresentationNeverBeatsSenderMetadataAndStripsExactlyOne() {
        let raw = "[voice] [voice] From the X lead: literal content."
        let marked = SenderAttribution.classify(text: raw)
        #expect(marked.label == "You")
        #expect(SenderAttribution.displayText(raw, sender: marked) == "[voice] From the X lead: literal content.")
        let metadata: [String: Any] = ["a2a": ["v": 1, "from": "local/ses_EXTERNAL", "traceId": "a2a_test", "hop": 1, "kind": "request"]]
        let external = SenderAttribution.classify(text: raw, metadata: metadata)
        #expect(!external.isYou && external.senderSession == "local/ses_EXTERNAL")
        #expect(SenderAttribution.displayText(raw, sender: external) == "[voice] From the X lead: literal content.")
        #expect(SenderAttribution.classify(text: raw, metadata: metadata, local: true).isYou)
        #expect(SenderAttribution.classify(text: "[Voice] hello").label == "Message")
        #expect(SenderAttribution.classify(text: "[voice]hello").label == "Message")
        #expect(SenderAttribution.classify(text: "[voice]\thello").label == "Message")
        #expect(SenderAttribution.classify(text: "unmarked").label == "Message")
    }
}
