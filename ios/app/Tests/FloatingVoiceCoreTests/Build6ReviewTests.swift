import Foundation
import Testing
@testable import FloatingVoiceCore

private final class SuspensionSecureItem: SecureItemAdapter {
    var reads = 0
    func read() -> (Int32, Data?) { reads += 1; return (0, Data("test-credential".utf8)) }
    func update(_ data: Data) -> Int32 { -25291 }
    func add(_ data: Data) -> Int32 { -25291 }
    func delete() -> Int32 { -25291 }
}

@Suite(.serialized) @MainActor struct Build6ReviewTests {
    @Test func protectedSuspensionThenNewRunCannotRebindLateFinal() async throws {
        var available = true
        let item = SuspensionSecureItem()
        let credential = PreservingCredentialStore(adapter: item, available: { available })
        let transport = try BridgeTransport(base: URL(string: "https://example.test/floating-voice")!, credentials: credential)
        let config = try transport.voiceConfig(VoiceConfig()) // production pre-capture credential/config boundary
        var app = AppSettings(); app.target = "ses_A"
        let backend = FakeBackend(), input = FakeInput(), output = FakeOutput()
        var recognitions: [FakeRecognition] = []
        let controller = ConversationController(settings: LoadedSettings(app: app, voice: config, voiceFile: nil, appFile: "/nonexistent", chiefFile: "/nonexistent"), backend: backend, synth: FakeSynth(), output: output, input: input, makeRecognition: { cb in
            let r = FakeRecognition(cb, transcript: ""); r.silentEnd = true; recognitions.append(r); return r
        })
        let lifecycle = NativeVoiceLifecycle(); lifecycle.controller = controller
        await lifecycle.start(lifecycle.requestStart())
        #expect(await waitUntil { controller.currentLease != nil })
        let original = try #require(controller.currentLease)
        input.frames(30, voiced: true)
        let old = try #require(recognitions.first)
        old.callbacks.live("old words")
        let reads = item.reads
        available = false
        var typed = ""
        // This is an ownership test, not the deadline test below: allow a long
        // fixture grace while bounding startup to three seconds independently.
        lifecycle.suspend(typed: &typed, target: original, finalTimeout: 60, retain: { _ in }, disconnect: {})
        #expect(old.ended && !input.started && item.reads == reads)
        #expect(try credential.load() == "test-credential")
        #expect(item.reads == reads + 1) // AfterFirstUnlock reads consult the adapter
        available = true
        controller.setTargetSetting("ses_B")
        let owner = lifecycle.requestStart()
        let restart = Task { await lifecycle.start(owner) }
        defer { restart.cancel(); controller.stop() }
        try #require(await waitUntil(3) { controller.currentLease?.sessionID == "ses_B" && controller.status.phase == "ready" && input.starts == 2 })
        #expect(!old.cancelled)
        // The FIRST old final still arrives after B owns the new ready run.
        old.callbacks.done("old words finalized")
        await restart.value // The final grace is already retired before this await.
        old.callbacks.done("stale final after the new run")
        old.callbacks.live("stale partial")
        #expect(controller.draftsForReview == [BoundDraft(target: original, text: "old words finalized", recoveryID: controller.draftsForReview.first?.recoveryID)])
        #expect(controller.composer.held.isEmpty && backend.prompts.isEmpty && backend.admits.isEmpty)
        #expect(item.reads == reads + 1 && input.starts == 2)
    }
    @Test(arguments: [false, true]) func nativeSuspensionFinalIsReviewOnly(_ manual: Bool) async throws {
        let rig = Rig(holdMs: 10_000)
        if manual { rig.controller.setSendMode(.manual) }
        await rig.start()
        #expect(await waitUntil { rig.controller.currentLease != nil })
        let original = try #require(rig.controller.currentLease)
        rig.controller.composer.utterance("Existing held words")
        rig.silentEnd = true
        rig.input.frames(30, voiced: true)
        let asr = try #require(rig.recognitions.first)
        asr.callbacks.live("unfinished words")
        let lifecycle = NativeVoiceLifecycle(); lifecycle.controller = rig.controller
        lifecycle.setOutputMuted(true)
        var typed = "Typed review", review: [BoundDraft] = []
        func retain(_ draft: BoundDraft) {
            if let id = draft.recoveryID, let i = review.firstIndex(where: { $0.recoveryID == id }) { review[i] = draft }
            else if !review.contains(draft) { review.append(draft) }
        }
        var protected = true, disconnected = false
        let connects = rig.backend.connects
        // This is the same production seam called by PhoneModel for scene and protected-data loss.
        lifecycle.suspend(typed: &typed, target: original, finalTimeout: 0.2, retain: retain) {
            #expect(!rig.input.started && !rig.controller.status.running)
            #expect(review.count == 3)
            protected = false; disconnected = true
        }
        #expect(disconnected && !protected && asr.ended && !asr.cancelled && typed.isEmpty)
        #expect(review.last(where: { $0.recoveryID != nil })?.nonAuthoritative == true)
        lifecycle.suspend(typed: &typed, target: nil, retain: retain, disconnect: {})
        rig.controller.send(); rig.input.frames(60, voiced: true)
        rig.controller.setTargetSetting("ses_B")
        // Availability returns but does not grant capture or automatic sends; late final keeps old lease.
        protected = true
        await lifecycle.start(lifecycle.generation)
        asr.callbacks.done("unfinished words finalized")
        asr.callbacks.done("duplicate late final")
        #expect(review.count == 3)
        let final = try #require(review.first(where: { $0.recoveryID != nil }))
        #expect(final.text == "unfinished words finalized" && !final.nonAuthoritative && final.target == original)
        #expect(review.allSatisfy { $0.target == original })
        #expect(lifecycle.outputMuted && !lifecycle.requested && rig.input.starts == 1)
        #expect(rig.backend.prompts.isEmpty && rig.backend.admits.isEmpty && rig.backend.connects == connects)
    }

    @Test(arguments: [false, true]) func nativeSuspensionDeadlineOrFailedFinalRetainsPartial(_ failed: Bool) async throws {
        let rig = Rig(); await rig.start(); rig.silentEnd = true
        #expect(await waitUntil { rig.controller.currentLease != nil })
        let owner = try #require(rig.controller.currentLease)
        rig.input.frames(30, voiced: true)
        let asr = try #require(rig.recognitions.first)
        asr.callbacks.partial("already recognized")
        let lifecycle = NativeVoiceLifecycle(); lifecycle.controller = rig.controller
        lifecycle.setMicMuted(true) // already waiting for a final; suspension must not request end twice
        var typed = ""
        lifecycle.suspend(typed: &typed, target: owner, finalTimeout: 0.03, retain: { _ in }, disconnect: {})
        if failed { asr.callbacks.error(URLError(.networkConnectionLost)); asr.callbacks.done("") }
        if failed {
            try? await Task.sleep(nanoseconds: 80_000_000)
        } else {
            // Other parallel MainActor tests can delay the deadline task's first
            // scheduling. Inject the late final after the real cancellation
            // boundary, not after an assumed wall-clock scheduling order.
            #expect(await waitUntil { asr.cancelled })
        }
        asr.callbacks.done("too late")
        let draft = try #require(rig.controller.draftsForReview.first)
        #expect(draft.text == "already recognized" && draft.nonAuthoritative && draft.target == owner)
        #expect(rig.controller.draftsForReview.count == 1 && !rig.controller.status.running)
        #expect(failed || asr.cancelled)
        #expect(rig.backend.prompts.isEmpty && rig.backend.admits.isEmpty && lifecycle.micMuted)
    }

    @Test(arguments: ["completed", "error"]) func productionToolDetailsFeedMarkdownInSourceOrder(_ status: String) throws {
        let row = try #require(MessageRow(JSONSerialization.data(withJSONObject: [
            "id": "mixed", "type": "assistant", "content": [
                ["type": "text", "text": "Before"],
                ["type": "tool", "name": "shell", "state": ["status": status, "input": ["command": "printf hello"], "content": [
                    ["type": "text", "text": "```md\n# Result\n| A | B |\n| --- | --- |\n| 1 | 2 |\n```"],
                    ["type": "text", "text": "```swift\nprint(1)\n```"],
                    ["type": "future", "raw": "unknown"]]]],
                ["type": "text", "text": "After"]
            ]
        ])))
        #expect(row.role == "Chief" && row.steps == 1)
        #expect(row.body.map(\.label) == [nil, "shell · \(status)", "shell · result 3", nil])
        #expect(row.body[2].rawDetail?.contains("unknown") == true)
        #expect(row.body.first?.markdown == "Before" && row.body.last?.markdown == "After")
        #expect(row.body[1].command == "printf hello")
        let markdown = BlockMarkdown.parse(row.body[1].markdown) // exact native expanded MarkdownView input
        #expect(markdown.first == .markdown("# Result\n| A | B |\n| --- | --- |\n| 1 | 2 |"))
        #expect(markdown.last == .code("swift", "print(1)"))
        #expect(row.detail.contains("unknown"))
    }
    @Test func unknownToolAndUnknownRecordRemainRawFallback() throws {
        let row = try #require(MessageRow(JSONSerialization.data(withJSONObject: ["id": "raw", "type": "future", "content": [["type": "unknown", "payload": "not discarded"]]])))
        #expect(row.role == "Other record" && !row.body.isEmpty && row.detail.contains("not discarded"))
        let tool = try #require(MessageRow(JSONSerialization.data(withJSONObject: ["id": "tool", "type": "tool", "content": [["type": "tool", "name": "future", "state": ["unrecognized": true]]]])))
        #expect(tool.body.first?.label == "future · details" && tool.detail.contains("unrecognized"))
    }
}
