import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct VoicePostTests {
    @Test(arguments: ["Words.", "[voice] words", "[voice]words", "[voice] [voice] literal", ""]) func markerPreservesAllLiteralContent(_ raw: String) {
        #expect(VoicePost.transportText(raw) == "[voice] " + raw)
        #expect(VoiceOrigin.displayText(VoicePost.transportText(raw)) == raw)
    }
    @Test func everyAdmittedBoundaryMarksOnceWhileLogsStayRaw() async throws {
        let rig = Rig(); await rig.start(); defer { rig.controller.stop() }
        let target = try #require(rig.controller.currentLease)
        for kind in [PostKind.normal, .delivery(.queue), .delivery(.steer), .admitOnly] {
            await rig.controller.post("[voice] literal words", kind: kind, reason: "marker test", to: target)
        }
        #expect(rig.backend.prompts.map(\.text) == Array(repeating: "[voice] [voice] literal words", count: 3))
        #expect(rig.backend.prompts.map(\.delivery) == [nil, .queue, .steer])
        #expect(rig.backend.admits == ["[voice] [voice] literal words"])
        #expect(rig.lines.filter { $0.hasPrefix("post ->") }.allSatisfy { $0.hasSuffix(": [voice] literal words") })
    }
    @Test func manualSendAndMuteFinalizeKeepCaptionsAndHeldWordsUnmarked() async throws {
        for mute in [false, true] {
            let rig = Rig(holdMs: 10_000); rig.transcript = "My edited dictated thought."
            if !mute { rig.controller.setSendMode(.manual) }
            var posted: [String] = []
            rig.controller.onCaption = { if case .posted(let text) = $0 { posted.append(text) } }
            await rig.start(); rig.input.frames(30, voiced: true)
            if mute { rig.controller.setMicMuted(true) }
            else {
                rig.input.frames(60, voiced: false)
                #expect(await waitUntil { rig.controller.status.holding == rig.transcript })
                rig.controller.send()
            }
            #expect(await waitUntil { rig.backend.prompts.count == 1 })
            #expect(rig.backend.prompts[0].text == "[voice] " + rig.transcript)
            #expect(posted == [rig.transcript]); rig.controller.stop()
        }
    }
    @Test func failedAdmissionNeverReplaysOrStacksMarker() async throws {
        let rig = Rig(); await rig.start(); defer { rig.controller.stop() }
        rig.backend.admitError = ClientError("Lost response")
        await rig.controller.post("[voice] literal", kind: .admitOnly, reason: "failure", to: try #require(rig.controller.currentLease))
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(rig.backend.admits == ["[voice] [voice] literal"] && rig.backend.prompts.isEmpty)
    }
    @Test func generalTypedPromptAndAdmissionRemainRaw() async throws {
        let backend = FakeBackend(); let target = try await backend.targetLease(sessionID: "ses_A")
        try await backend.prompt(target: target, text: "Typed only", delivery: nil)
        try await backend.admit(target: target, text: "Typed admit")
        #expect(backend.prompts.map(\.text) == ["Typed only"] && backend.admits == ["Typed admit"])
    }
}
