import Foundation
import Testing
@testable import FloatingVoiceCore

@MainActor private final class ReadinessGate {
    var waiting = false
    var opened = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { opened = true; continuation?.resume(); continuation = nil }
}

@Suite(.serialized) @MainActor struct VoiceFirstTests {
    @Test func explicitPhoneStopDiscardsUnfinishedWordsWithoutPosting() async {
        let rig = Rig(holdMs: 5000)
        await rig.start()
        rig.silentEnd = true
        rig.input.frames(30, voiced: true)
        #expect(rig.controller.utteranceInProgress)
        rig.controller.stop(keepHeld: true, discardUnfinished: true)
        rig.recognitions.first?.callbacks.done("unfinished room speech")
        await Task.yield()
        #expect(!rig.controller.status.running && rig.backend.prompts.isEmpty)
    }
    @Test func readyRequiresLeaseStateAndCaptureAndRejectsPreAuthorityPCM() async {
        let rig = Rig(holdMs: 5000), gate = ReadinessGate()
        rig.backend.leaseGate = { await gate.wait() }
        await rig.controller.start()
        #expect(await waitUntil { gate.waiting && rig.input.started })
        #expect(rig.controller.status.phase == "starting")
        #expect(rig.controller.status.connection != "connected")
        rig.input.frames(30, voiced: true)
        #expect(rig.recognitions.isEmpty && !rig.controller.utteranceInProgress)
        gate.release()
        #expect(await waitUntil { rig.controller.status.phase == "ready" && rig.controller.currentLease != nil })
        rig.silentEnd = true; rig.transcript = "and then we could"
        rig.input.frames(30, voiced: true)
        #expect(rig.controller.utteranceInProgress)
        rig.controller.setMicMuted(true)
        #expect(rig.recognitions.first?.ended == true && rig.backend.prompts.isEmpty)
        // Explicitly release the final: no one-second assumption or arbitrary sleep increase.
        rig.recognitions.first?.callbacks.done("and then we could")
        #expect(await waitUntil { rig.backend.prompts.count == 1 })
        #expect(rig.backend.prompts.first?.text == "[voice] and then we could")
        #expect(rig.backend.sentLeases == [TargetLease(sessionID: "ses_A", generation: "initial")])
        rig.controller.stop()
    }
    @Test func delayedAuthorityCannotReviveStoppedCapture() async {
        let rig = Rig(), gate = ReadinessGate()
        rig.backend.leaseGate = { await gate.wait() }
        await rig.controller.start()
        #expect(await waitUntil { gate.waiting })
        rig.controller.stop(); gate.release()
        await Task.yield()
        #expect(!rig.controller.status.running && rig.controller.currentLease == nil)
        #expect(!rig.input.started)
    }
    @Test func leaseFailureIsVisibleAndNeverListens() async {
        let rig = Rig()
        rig.backend.leaseGate = { throw ClientError("Synthetic authority failure") }
        await rig.controller.start()
        #expect(await waitUntil { rig.controller.status.lastError != nil })
        #expect(rig.controller.status.phase == "starting" && rig.controller.status.connection != "connected")
        rig.input.frames(30, voiced: true)
        #expect(rig.recognitions.isEmpty && rig.controller.currentLease == nil)
        rig.controller.stop()
    }
    @Test func nativeBindingsUseProductionProjectionAndKeepHistoryOutOfDefaultScreen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("native/FloatingVoiceApp.swift"))
        let rich = try String(contentsOf: root.appendingPathComponent("native/RichContentViews.swift"))
        let main = try #require(source.components(separatedBy: "struct VoiceMainView: View {").last?.components(separatedBy: "struct HistoryView: View {").first)
        #expect(!main.contains("ForEach(model.messages)"))
        #expect(main.contains("NativeWaveform(levels: pill.micLevels") && main.contains("NativeWaveform(levels: pill.outputLevels"))
        #expect(main.contains("surface.log.turns") && main.contains("voice.userCaption") && main.contains("voice.chiefCaption"))
        #expect(rich.contains("MarkdownView(blocks: part.blocks)") && source.contains("MessageContentView(model: model, row: row, part: part, ordinal: ordinal)"))
        #expect(source.contains("surface.handle(event, owner: owner)") && source.contains("surface.update(status: status, owner: binding)"))
        #expect(source.contains("self.backend?.lease == lease") && source.contains("self.surface.binding == binding"))
        #expect(source.contains("surface.typedPosted(text, owner: binding)") && source.contains("surface.replaceBinding(target: nil)"))
        #expect(source.contains(".defaultScrollAnchor(.bottom)") && source.contains("model.historyVisible = true"))
        #expect(source.contains("ViewThatFits(in: .horizontal)") && rich.contains("Shell command · display only"))
        let audio = try String(contentsOf: root.appendingPathComponent("native/IOSAudio.swift"))
        #expect(audio.contains("engine.mainMixerNode.installTap") && audio.contains("capture.admits(owner)"))
        #expect(!audio.contains("onLevel?(TurnTaker.rms(data))"), "meter rendered output, not queued downloads")
    }
    @Test func surfaceUsesActualLevelsCaptionsAndSeparateHistoryProjection() throws {
        var clock = 1000.0
        let pill = PillModel(now: { clock }); pill.thinkingSwell = false
        var status = ConversationController.Status(); status.running = true; status.phase = "starting"; status.connection = "connecting"
        pill.update(status: status); pill.tick()
        #expect(pill.levels.allSatisfy { $0 == 0 })
        status.phase = "ready"; status.connection = "connected"; status.hearing = true
        pill.update(status: status); pill.handle(.micLevel(0.1)); pill.tick()
        #expect(pill.voice == .you && pill.levels.last! > 0)
        status.hearing = false; status.speaking = true
        pill.update(status: status); pill.handle(.chiefStarted(label: "b", text: "Spoken now")); pill.handle(.outputLevel(0.2)); pill.tick()
        #expect(pill.voice == .chief && pill.chief.current == "Spoken now")
        status.speaking = false; status.busy = true; status.micMuted = true
        pill.update(status: status); pill.handle(.posted("words")); clock += 1000
        for _ in 0..<PillModel.barCount { pill.tick() }
        #expect(pill.wait == .thinking && pill.levels.allSatisfy { $0 == 0 })
        let surface = VoiceSurface()
        func raw(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o) }
        surface.update(records: [try raw(["id":"a", "type":"assistant", "content":[["type":"text","text":"Old reply"]]]), try raw(["id":"u", "type":"user","text":"New question", "sender":["kind":"principal", "label":"You"]]), try raw(["id":"b", "type":"assistant","content":[["type":"text","text":"Live reply"]]])], connection: "connected", active: true)
        #expect(surface.userCaption == "New question" && surface.chiefCaption == "Live reply")
        #expect(surface.state == "Agent thinking")
        let owner = surface.binding
        var submitting = ConversationController.Status(); submitting.sending = true
        surface.update(status: submitting, owner: owner)
        #expect(surface.state == "Sending message…")
        submitting.sending = false
        surface.update(status: submitting, owner: UUID())
        #expect(surface.state == "Sending message…", "stale owner cannot clear submission state")
        surface.update(status: submitting, owner: owner)
        #expect(surface.state == "Agent thinking")
        surface.preparing = true
        #expect(surface.state.contains("Preparing") && !surface.state.contains("Listening"))
        surface.pill.handle(.youLive("Actual partial"))
        #expect(surface.userCaption == "Actual partial")
        var follow = BottomFollow(); follow.userScrolled(bottomVisible: false)
        #expect(!follow.following); follow.selected(); #expect(follow.following)
    }
    @Test func nativeBodyBindingExpandsMarkdownAndPreservesCodeAndToolInput() throws {
        let row = try #require(MessageRow(JSONSerialization.data(withJSONObject: ["id":"m", "type":"assistant", "content":[["type":"text","text":"````markdown\n# Detail\n| A | B |\n| --- | --- |\n| x | y |\n- [link](https://example.test)\n```swift\nlet a = 1\n```\n````"], ["type":"tool","name":"write","state":["status":"completed","input":["text":"```md\n## Tool input\n```"],"content":[["type":"text","text":"```swift\n  let x = 2\n```"]]]]]])))
        #expect(row.body[0].blocks.contains(.heading(1, "Detail")))
        #expect(row.body[0].blocks.contains(.code("swift", "let a = 1")))
        #expect(row.body[0].blocks.contains { if case .table = $0 { true } else { false } })
        #expect(row.body[1].blocks.contains(.heading(2, "Tool input")))
        #expect(row.body[1].blocks.contains(.code("swift", "  let x = 2")))
    }
    @Test func productionSurfaceBindingFencesBothCaptionsAndPreservesStableLiveWords() throws {
        let surface = VoiceSurface()
        let a = TargetLease(sessionID: "A", generation: "one"), b = TargetLease(sessionID: "B", generation: "two")
        func records(_ id: String, _ text: String) throws -> [Data] {
            [try JSONSerialization.data(withJSONObject: ["id": id, "type": "user", "text": text, "sender":["kind":"principal", "label":"You"]])]
        }
        let ownerA = surface.replaceBinding(target: a)
        surface.update(records: try records("a", "A question"), connection: "connected", active: false)
        surface.handle(.youFinal("Old A words"), owner: ownerA)
        surface.handle(.posted("Old A words"), owner: ownerA)
        var status = ConversationController.Status(); status.running = true; status.speaking = true; status.micMuted = true; status.outputMuted = true
        surface.update(status: status, owner: ownerA)
        surface.handle(.chiefStarted(label: "a", text: "Old A chief"), owner: ownerA)
        let ownerB = surface.replaceBinding(target: b)
        surface.update(records: try records("b", "B question"), connection: "connected", active: false)
        surface.handle(.youFinal("Late A"), owner: ownerA)
        surface.handle(.chiefStarted(label: "late", text: "Late A chief"), owner: ownerA)
        surface.update(status: status, owner: ownerA)
        #expect(surface.userCaption == "B question" && surface.chiefCaption.isEmpty)
        #expect(!surface.pill.status.running && surface.pill.status.micMuted && surface.pill.status.outputMuted)
        surface.handle(.youLive("Legitimate B partial"), owner: ownerB)
        surface.update(records: try records("b", "B question"), connection: "connected", active: true)
        #expect(surface.userCaption == "Legitimate B partial")
        // Typed acknowledgement replaces the old thought, never appends to it.
        surface.typedPosted("New B typed", owner: ownerB)
        #expect(surface.userCaption == "New B typed")
        surface.update(records: try records("b2", "New B typed"), connection: "connected", active: true)
        #expect(surface.userCaption == "New B typed")
        surface.handle(.youFinal("Prior caption"), owner: ownerB); surface.handle(.posted("Prior caption"), owner: ownerB)
        surface.update(records: try records("b3", "Another typed exchange"), connection: "connected", active: true)
        #expect(surface.userCaption == "Another typed exchange")
        let newA = surface.replaceBinding(target: a)
        surface.handle(.youLive("A current"), owner: newA)
        surface.handle(.youFinal("Original A late"), owner: ownerA)
        #expect(surface.userCaption == "A current")
        let generation = surface.replaceBinding(target: TargetLease(sessionID: "A", generation: "new"))
        surface.handle(.chiefStarted(label: "old", text: "Stale generation"), owner: newA)
        #expect(surface.chiefCaption.isEmpty && surface.userCaption.isEmpty)
        let replacement = surface.replaceBinding(target: surface.target)
        surface.handle(.youFinal("Late replaced controller"), owner: generation)
        surface.handle(.youLive("Replacement live"), owner: replacement)
        #expect(surface.userCaption == "Replacement live")
    }
}
